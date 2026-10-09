import Foundation

/// What the coordinator needs from the note store. `PipelineHistoryStore`
/// provides it; tests use a fake.
protocol NoteSyncLocalStore: AnyObject {
    /// False while the store can't save (it needs recovery).
    var isReadyForSync: Bool { get }
    func syncRecord(id: UUID) -> NoteSyncRecord?
    func syncSystemFields(id: UUID) -> Data?
    func setSyncSystemFields(_ data: Data?, id: UUID) throws
    func clearAllSyncSystemFields() throws
    func syncableNoteIDs() -> [UUID]
    func isSyncable(id: UUID) -> Bool
    func applySynced(_ record: NoteSyncRecord, systemFields: Data?) throws -> NoteSyncApplyResult
    func removeSynced(id: UUID) throws -> DeletedPipelineHistoryAssets?
    func audioManifest(id: UUID) -> NoteAudioManifest?
    func setAudioManifest(_ manifest: NoteAudioManifest, id: UUID) throws
}

/// A note's audio file on this Mac.
struct NoteSyncLocalAudio: Equatable {
    let url: URL
    let bytes: Int64
}

extension PipelineHistoryStore: NoteSyncLocalStore {}

extension NoteSyncLocalStore {
    /// Stale change tags only cause conflicts that merge on the next upload,
    /// so a failure here is logged, not fatal.
    func clearChangeTags() {
        do {
            try clearAllSyncSystemFields()
        } catch {
            print("[NoteSync] Couldn't clear change tags")
        }
    }

    /// The note's audio file on this Mac and its size, when it is here.
    func localAudioFile(id: UUID, resolve: (String) -> URL?) -> NoteSyncLocalAudio? {
        guard case .string(let name)? = syncRecord(id: id)?.fields[NoteSyncField.audioFileName.rawValue],
              let url = resolve(name),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        else { return nil }
        return NoteSyncLocalAudio(url: url, bytes: size.int64Value)
    }
}

/// The sync engine's pending changes, as the coordinator sees them.
protocol NoteSyncEngineClient: AnyObject {
    func enqueueSaves(_ ids: [UUID])
    func enqueueDeletes(_ ids: [UUID])
    /// Drops deletes still waiting to go up.
    func cancelDeletes(_ ids: [UUID])
    func enqueueAudioSaves(_ parts: [NoteAudioPartID])
    func enqueueAudioDeletes(_ parts: [NoteAudioPartID])
    /// Parts of this note's audio still waiting to go up.
    func pendingAudioSaves(noteID: UUID) -> [NoteAudioPartID]
    func cancelAudioSaves(noteID: UUID)
}

/// One audio part to send: which bytes of which file.
struct NoteSyncOutgoingAudio: Equatable {
    let part: NoteAudioPartID
    let fileURL: URL
    let byteCount: Int64
}

enum NoteAudioSendFailure {
    case quotaExceeded(NoteAudioPartID)
    /// Offline or throttled; the engine retries these itself.
    case network
    case failed(NoteAudioPartID)
    case deleteFailed(NoteAudioPartID)
}

struct NoteSyncOutgoing: Equatable {
    let record: NoteSyncRecord
    /// The CloudKit system fields from the last save, carrying its change tag.
    let systemFields: Data?
}

struct NoteSyncFetched {
    let noteID: UUID
    let payload: Data?
    let systemFields: Data
}

enum NoteSyncSendFailure {
    case serverChanged(noteID: UUID, serverPayload: Data?, serverSystemFields: Data)
    case quotaExceeded(noteID: UUID)
    case network(noteID: UUID)
    case unknownItemOnDelete(noteID: UUID)
    /// iCloud has no record for the saved change tag (another Mac removed
    /// it): the save is tried again without the tag.
    case unknownItemOnSave(noteID: UUID)
    /// Any other failed delete: retried as a delete.
    case deleteFailed(noteID: UUID)
    case other(noteID: UUID)
}

enum NoteSyncPauseReason: Equatable {
    case offline
    case quotaExceeded(pending: Int)
    case accountChanged
    case signedOut
    case deletedElsewhere
}

enum NoteSyncStatus: Equatable {
    case off
    case starting
    case uploading(done: Int, total: Int)
    case upToDate(Date)
    case paused(NoteSyncPauseReason)
}

struct NoteSyncRemoteChange: Equatable {
    var changed: [UUID] = []
    var purged: [DeletedPipelineHistoryAssets] = []
    /// Records that couldn't be read or applied.
    var skipped = 0
}

/// Decides what to send and applies what arrives. It knows nothing about
/// CloudKit: the engine adapter turns its records into `CKRecord`s.
@MainActor
final class NoteSyncCoordinator {
    private let store: NoteSyncLocalStore
    private let engine: NoteSyncEngineClient
    private let now: () -> Date
    private let localAudioURL: (String) -> URL?
    private let hashFile: (URL) async throws -> String
    private var uploadTotal = 0
    /// Notes of the first upload whose text, or whose audio, isn't up yet.
    private var uploadWaitingText: Set<UUID> = []
    private var uploadWaitingAudio: Set<UUID> = []
    private var uploadDone: Int { uploadTotal - uploadWaitingText.union(uploadWaitingAudio).count }

    private(set) var status: NoteSyncStatus = .starting {
        didSet {
            if status != oldValue { onStatusChange?(status) }
        }
    }
    var onStatusChange: ((NoteSyncStatus) -> Void)?
    /// A fetched record couldn't be saved locally while the engine moved
    /// past it, so sync must start over from the beginning.
    var onNeedsFullRefetch: (() -> Void)?
    /// Saves that failed for lack of space or another lasting reason; tried
    /// again after the next sync finishes.
    private var savesToRetry: Set<UUID> = []
    private var deletesToRetry: Set<UUID> = []
    private var audioSavesToRetry: Set<NoteAudioPartID> = []
    private var audioDeletesToRetry: Set<NoteAudioPartID> = []
    private var quotaRetryPending = false

    /// After an account change or a deletion elsewhere nothing more is sent;
    /// sync starts again only when the user turns it on.
    private var isStopped: Bool {
        switch status {
        case .paused(.accountChanged), .paused(.signedOut), .paused(.deletedElsewhere): return true
        default: return false
        }
    }

    init(
        store: NoteSyncLocalStore,
        engine: NoteSyncEngineClient,
        now: @escaping () -> Date = Date.init,
        localAudioURL: @escaping (String) -> URL? = { _ in nil },
        hashFile: @escaping (URL) async throws -> String = NoteSyncCoordinator.hashOffMain
    ) {
        self.store = store
        self.engine = engine
        self.now = now
        self.localAudioURL = localAudioURL
        self.hashFile = hashFile
    }

    nonisolated static func hashOffMain(_ url: URL) async throws -> String {
        try await Task.detached(priority: .utility) { try NoteAudioParts.sha256(of: url) }.value
    }

    /// Queues every settled note on this Mac, for turning sync on.
    func startInitialUpload() {
        let ids = store.syncableNoteIDs()
        uploadTotal = ids.count
        uploadWaitingText = Set(ids)
        engine.enqueueSaves(ids)
        uploadWaitingAudio = Set(queueAudioUploads(for: ids))
        status = ids.isEmpty ? .starting : .uploading(done: 0, total: ids.count)
        print("[NoteSync] Queued \(ids.count) notes for the first upload")
    }

    /// After a relaunch: audio that hasn't gone up and isn't waiting.
    func resumeAudioUploads() {
        queueAudioUploads(for: store.syncableNoteIDs())
    }

    /// Queues every part of each note whose audio is here but not in
    /// iCloud. A note with parts already waiting is left alone, so nothing
    /// goes up twice. Returns the notes queued.
    @discardableResult
    func queueAudioUploads(for ids: [UUID]) -> [UUID] {
        guard !isStopped else { return [] }
        var queued: [UUID] = []
        var parts: [NoteAudioPartID] = []
        for id in ids {
            guard store.audioManifest(id: id) == nil,
                  engine.pendingAudioSaves(noteID: id).isEmpty,
                  let file = localAudio(id) else { continue }
            let count = NoteAudioParts.count(bytes: file.bytes)
            guard count > 0 else { continue }
            parts += (0..<count).map { NoteAudioPartID(noteID: id, index: $0) }
            queued.append(id)
        }
        if !parts.isEmpty {
            engine.enqueueAudioSaves(parts)
            print("[NoteSync] Queued \(parts.count) audio parts for \(queued.count) notes")
        }
        return queued
    }

    private func localAudio(_ id: UUID) -> NoteSyncLocalAudio? {
        guard store.isSyncable(id: id) else { return nil }
        return store.localAudioFile(id: id, resolve: localAudioURL)
    }

    private func reportUploadProgress() {
        if case .uploading = status {
            status = .uploading(done: uploadDone, total: uploadTotal)
        }
    }

    func handleLocalChanges(_ changes: [PipelineHistoryChange]) {
        guard !isStopped else { return }
        var saves: [UUID] = []
        var deletes: [UUID] = []
        var audioDeletes: [NoteAudioPartID] = []
        for change in changes {
            switch change {
            case .saved(let id):
                if store.isSyncable(id: id) { saves.append(id) }
            case .deleted(let id, let wasSynced, let audioParts):
                if wasSynced { deletes.append(id) }
                // Parts still waiting never go up; parts already sent are
                // deleted, counted from the manifest or the waiting ones.
                let waiting = engine.pendingAudioSaves(noteID: id).map(\.index)
                if !waiting.isEmpty { engine.cancelAudioSaves(noteID: id) }
                let count = max(audioParts, (waiting.max() ?? -1) + 1)
                audioDeletes += (0..<count).map { NoteAudioPartID(noteID: id, index: $0) }
            }
        }
        if !saves.isEmpty {
            engine.enqueueSaves(saves)
            queueAudioUploads(for: saves)
        }
        if !deletes.isEmpty { engine.enqueueDeletes(deletes) }
        if !audioDeletes.isEmpty { engine.enqueueAudioDeletes(audioDeletes) }
    }

    /// The record to send for `id`, or nil when the note is gone or still
    /// in progress (its pending change is then dropped).
    func outgoing(for id: UUID) -> NoteSyncOutgoing? {
        guard !isStopped, store.isSyncable(id: id), let record = store.syncRecord(id: id) else { return nil }
        return NoteSyncOutgoing(record: record, systemFields: store.syncSystemFields(id: id))
    }

    func handleSaved(id: UUID, systemFields: Data) {
        guard !isStopped else { return }
        guard store.syncRecord(id: id) != nil else {
            // Deleted here while its upload was in flight.
            engine.enqueueDeletes([id])
            return
        }
        do {
            try store.setSyncSystemFields(systemFields, id: id)
        } catch {
            // Without its change tag the next save conflicts and merges, so
            // the note isn't lost; it just isn't counted as uploaded.
            print("[NoteSync] Couldn't record an uploaded note")
            return
        }
        uploadWaitingText.remove(id)
        reportUploadProgress()
    }

    /// The part to send, or nil when it is stale: sync stopped, the audio
    /// is gone or already in iCloud, or the index is past the end.
    func outgoingAudio(for part: NoteAudioPartID) -> NoteSyncOutgoingAudio? {
        guard !isStopped, store.audioManifest(id: part.noteID) == nil,
              let file = localAudio(part.noteID),
              part.index < NoteAudioParts.count(bytes: file.bytes) else { return nil }
        return NoteSyncOutgoingAudio(part: part, fileURL: file.url, byteCount: file.bytes)
    }

    /// After the last part is up, marks the audio as in iCloud and sends
    /// the note again, so other Macs learn they can download it.
    func handleAudioPartSaved(_ part: NoteAudioPartID) async {
        let id = part.noteID
        guard !isStopped, engine.pendingAudioSaves(noteID: id).isEmpty,
              store.audioManifest(id: id) == nil,
              let file = localAudio(id) else { return }
        let hash: String
        do {
            hash = try await hashFile(file.url)
        } catch {
            print("[NoteSync] Couldn't read audio to finish its upload")
            return
        }
        // The note may have changed while the file was read.
        guard !isStopped, store.audioManifest(id: id) == nil, localAudio(id) == file else { return }
        let manifest = NoteAudioManifest(
            sha256: hash,
            bytes: file.bytes,
            partSize: NoteAudioParts.partSize,
            parts: NoteAudioParts.count(bytes: file.bytes)
        )
        do {
            try store.setAudioManifest(manifest, id: id)
        } catch {
            print("[NoteSync] Couldn't record uploaded audio")
            return
        }
        engine.enqueueSaves([id])
        uploadWaitingAudio.remove(id)
        reportUploadProgress()
    }

    func handleAudioSendFailures(_ failures: [NoteAudioSendFailure]) {
        guard !isStopped else { return }
        var quotaCount = 0
        var offline = false
        for failure in failures {
            switch failure {
            case .quotaExceeded(let part):
                quotaCount += 1
                quotaRetryPending = true
                audioSavesToRetry.insert(part)
            case .network:
                offline = true
            case .failed(let part):
                audioSavesToRetry.insert(part)
            case .deleteFailed(let part):
                audioDeletesToRetry.insert(part)
            }
        }
        if quotaCount > 0 {
            status = .paused(.quotaExceeded(pending: quotaCount))
        } else if offline {
            status = .paused(.offline)
        }
        if !failures.isEmpty {
            print("[NoteSync] \(failures.count) audio changes failed to send")
        }
    }

    func handleDeleted(id: UUID) {
        // The note is usually gone already; nothing is left to update then.
        try? store.setSyncSystemFields(nil, id: id)
    }

    func handleSendFailures(_ failures: [NoteSyncSendFailure]) {
        // A send that fails after sync stopped must not swap the stop for
        // a quota or offline pause, which would let sync resume.
        guard !isStopped else { return }
        var quotaCount = 0
        var offline = false
        var resend: [UUID] = []
        var deletes: [UUID] = []
        for failure in failures {
            switch failure {
            case .serverChanged(let id, let payload, let serverFields):
                guard store.syncRecord(id: id) != nil else {
                    // Deleted here while the save was in flight: delete the
                    // server copy rather than bring the note back.
                    deletes.append(id)
                    continue
                }
                // Without a server copy merged in, the local note never
                // overwrites the server; the next fetch brings the server
                // copy, and the merge sends what this Mac has newer.
                guard let server = payload.flatMap({ try? NoteSyncPayload.decode($0) }),
                      server.noteID == id,
                      let result = try? store.applySynced(server, systemFields: serverFields) else {
                    continue
                }
                if result != .updated(needsUpload: false) { resend.append(id) }
            case .quotaExceeded(let id):
                quotaCount += 1
                quotaRetryPending = true
                savesToRetry.insert(id)
            case .network:
                offline = true
            case .unknownItemOnDelete(let id):
                try? store.setSyncSystemFields(nil, id: id)
            case .unknownItemOnSave(let id):
                // If the note was deleted elsewhere, the fetch removes it
                // here first and the retry is dropped.
                try? store.setSyncSystemFields(nil, id: id)
                savesToRetry.insert(id)
            case .deleteFailed(let id):
                deletesToRetry.insert(id)
            case .other(let id):
                savesToRetry.insert(id)
            }
        }
        if !resend.isEmpty { engine.enqueueSaves(resend) }
        if !deletes.isEmpty { engine.enqueueDeletes(deletes) }
        if quotaCount > 0 {
            status = .paused(.quotaExceeded(pending: quotaCount))
        } else if offline {
            status = .paused(.offline)
        }
        if !failures.isEmpty {
            print("[NoteSync] \(failures.count) changes failed to send")
        }
    }

    func handleFetched(_ records: [NoteSyncFetched], deletions: [UUID]) -> NoteSyncRemoteChange {
        var change = NoteSyncRemoteChange()
        // After an account change or a deletion elsewhere, nothing that
        // arrives touches local notes.
        guard !isStopped else { return change }
        guard store.isReadyForSync else {
            onNeedsFullRefetch?()
            return change
        }
        var needsUpload: [UUID] = []
        var returned: [UUID] = []
        var needsFullRefetch = false
        for fetched in records {
            guard let payload = fetched.payload,
                  let record = try? NoteSyncPayload.decode(payload),
                  record.noteID == fetched.noteID else {
                change.skipped += 1
                continue
            }
            do {
                switch try store.applySynced(record, systemFields: fetched.systemFields) {
                case .inserted:
                    change.changed.append(record.noteID)
                    returned.append(record.noteID)
                case .updated(needsUpload: false):
                    change.changed.append(record.noteID)
                case .updated(needsUpload: true):
                    change.changed.append(record.noteID)
                    needsUpload.append(record.noteID)
                }
            } catch PipelineHistorySyncError.incompleteRecord, PipelineHistorySyncError.unreadableRecord {
                change.skipped += 1
            } catch {
                // The store couldn't save it; the record would be lost once
                // the engine saves its position.
                needsFullRefetch = true
            }
        }
        if needsFullRefetch {
            onNeedsFullRefetch?()
            return change
        }
        for id in deletions {
            if let assets = try? store.removeSynced(id: id) {
                change.purged.append(assets)
            }
        }
        if !returned.isEmpty {
            // A note deleted here while offline and edited on another Mac
            // is back: its delete must not remove it from iCloud.
            deletesToRetry.subtract(returned)
            engine.cancelDeletes(returned)
        }
        if !needsUpload.isEmpty, !isStopped { engine.enqueueSaves(needsUpload) }
        if change.skipped > 0 {
            print("[NoteSync] Skipped \(change.skipped) records it could not read")
        }
        return change
    }

    /// A fetch or send finished. With nothing left to send, sync is up to date.
    func handleFetchFinished(pending: Int) {
        guard !isStopped else { return }
        let retriedForQuota = quotaRetryPending
        quotaRetryPending = false
        if !savesToRetry.isEmpty {
            let retry = Array(savesToRetry)
            savesToRetry = []
            engine.enqueueSaves(retry)
        }
        if !deletesToRetry.isEmpty {
            // A note that came back (another Mac's edit) stays in iCloud.
            let retry = deletesToRetry.filter { store.syncRecord(id: $0) == nil }
            deletesToRetry = []
            if !retry.isEmpty { engine.enqueueDeletes(Array(retry)) }
        }
        if !audioSavesToRetry.isEmpty {
            let retry = audioSavesToRetry.filter { outgoingAudio(for: $0) != nil }
            audioSavesToRetry = []
            if !retry.isEmpty { engine.enqueueAudioSaves(Array(retry)) }
        }
        if !audioDeletesToRetry.isEmpty {
            let retry = Array(audioDeletesToRetry)
            audioDeletesToRetry = []
            engine.enqueueAudioDeletes(retry)
        }
        // Notes just queued again for lack of space aren't up to date yet;
        // the pause clears after a sync where they went up.
        if case .paused(.quotaExceeded) = status, retriedForQuota { return }
        if case .uploading = status, uploadDone < uploadTotal, pending > 0 { return }
        if pending == 0 {
            status = .upToDate(now())
        } else if case .paused(.offline) = status {
            // Back online with changes still to send.
            status = .starting
        }
    }

    func handleAccountChange(signedOut: Bool) {
        // Paused first, so sync stays stopped even if clearing fails.
        status = .paused(signedOut ? .signedOut : .accountChanged)
        store.clearChangeTags()
        print("[NoteSync] Paused: iCloud account \(signedOut ? "signed out" : "changed")")
    }

    func handleZoneDeleted() {
        status = .paused(.deletedElsewhere)
        store.clearChangeTags()
        print("[NoteSync] Paused: iCloud data was deleted from another Mac")
    }
}
