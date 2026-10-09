import Foundation

/// What the coordinator needs from the note store. `PipelineHistoryStore`
/// provides it; tests use a fake.
protocol NoteSyncLocalStore: AnyObject {
    /// False while the store can't save (it needs recovery).
    var isReadyForSync: Bool { get }
    func syncRecord(id: UUID) -> NoteSyncRecord?
    func syncSystemFields(id: UUID) -> Data?
    func setSyncSystemFields(_ data: Data?, id: UUID) throws
    /// `forgettingAudio`: iCloud lost the audio too, so markers go.
    func clearAllSyncSystemFields(forgettingAudio: Bool) throws
    func syncableNoteIDs() -> [UUID]
    func isSyncable(id: UUID) -> Bool
    func applySynced(_ record: NoteSyncRecord, systemFields: Data?) throws -> NoteSyncApplyResult
    func removeSynced(id: UUID) throws -> DeletedPipelineHistoryAssets?
    func audioManifest(id: UUID) -> NoteAudioManifest?
    func setAudioManifest(_ manifest: NoteAudioManifest?, id: UUID) throws
}

/// A note's audio file on this Mac.
struct NoteSyncLocalAudio: Equatable {
    let url: URL
    let name: String
    let bytes: Int64

    var stamp: NoteAudioPartStamp { NoteAudioPartStamp(fileName: name, fileBytes: bytes) }
    var partCount: Int { NoteAudioParts.count(bytes: bytes) }
}

extension PipelineHistoryStore: NoteSyncLocalStore {}

extension NoteSyncLocalStore {
    /// Stale change tags only cause conflicts that merge on the next upload,
    /// so a failure here is logged, not fatal.
    func clearChangeTags(forgettingAudio: Bool) {
        do {
            try clearAllSyncSystemFields(forgettingAudio: forgettingAudio)
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
        return NoteSyncLocalAudio(url: url, name: name, bytes: size.int64Value)
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
    /// Audio parts still waiting to go up, for every note.
    func pendingAudioSaves() -> [NoteAudioPartID]
    func cancelAudioSaves(noteID: UUID)
    /// Which of these parts iCloud holds, and what each was cut from. Reads
    /// only the records' small fields, never the audio.
    func audioPartStamps(_ parts: [NoteAudioPartID]) async throws -> [NoteAudioPartID: NoteAudioPartStamp]
}

/// One audio part to send: which bytes of which file.
struct NoteSyncOutgoingAudio: Equatable {
    let part: NoteAudioPartID
    let fileURL: URL
    let fileName: String
    /// The whole file's size.
    let byteCount: Int64

    var stamp: NoteAudioPartStamp { NoteAudioPartStamp(fileName: fileName, fileBytes: byteCount) }
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
    /// A part that failed this many times waits for the next launch.
    static let maxAudioAttempts = 3
    private var audioFailures: [NoteAudioPartID: Int] = [:]
    private var audioPartsGivenUp: Set<NoteAudioPartID> = []
    /// How many parts of each note this Mac may have sent, so a delete
    /// removes them before the marker says how many there are.
    private var audioPartCounts: [UUID: Int] = [:]
    /// Notes whose parts in iCloud are being checked, and notes to check
    /// again after the next sync because a check couldn't finish.
    private var audioChecking: Set<UUID> = []
    private var audioToCheck: Set<UUID> = []
    /// Marked notes of the first upload, held back until their marker is
    /// checked: a marker from another account must not reach this one.
    private var savesAfterCheck: Set<UUID> = []
    /// Set once the controller replaces or drops this coordinator: work
    /// still running (an audio check, a hash) must not touch the store.
    private var isRetired = false
    /// The most recent audio check, for tests to wait on.
    private(set) var lastAudioCheck: Task<Void, Never>?

    /// After an account change or a deletion elsewhere nothing more is sent;
    /// sync starts again only when the user turns it on.
    private var isStopped: Bool {
        if isRetired { return true }
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

    /// Queues every settled note on this Mac, for turning sync on. Audio
    /// is checked against iCloud first: parts already there aren't sent
    /// again, and a marker left from audio iCloud no longer has is cleared.
    func startInitialUpload() {
        let ids = store.syncableNoteIDs()
        uploadTotal = ids.count
        uploadWaitingText = Set(ids)
        savesAfterCheck = Set(ids.filter { store.audioManifest(id: $0) != nil })
        engine.enqueueSaves(ids.filter { !savesAfterCheck.contains($0) })
        uploadWaitingAudio = Set(ids.filter { store.audioManifest(id: $0) == nil && localAudio($0) != nil })
        status = ids.isEmpty ? .starting : .uploading(done: 0, total: ids.count)
        print("[NoteSync] Queued \(ids.count) notes for the first upload")
        checkAudioSoon(ids, verifyMarked: true)
    }

    /// After a relaunch: audio that isn't marked as in iCloud and isn't
    /// waiting to go up, such as audio whose last part went up just before
    /// the app quit.
    func resumeAudioUploads() {
        checkAudioSoon(store.syncableNoteIDs(), verifyMarked: false)
    }

    /// Queues every part of each note whose audio is here but not in
    /// iCloud, for a note that just changed. A note with parts already
    /// waiting or being checked is left alone, so nothing goes up twice.
    func queueAudioUploads(for ids: [UUID]) {
        guard !isStopped else { return }
        let busy = notesWithAudioInFlight()
        var parts: [NoteAudioPartID] = []
        var notes = 0
        var check: [UUID] = []
        for id in ids where !busy.contains(id) && !audioChecking.contains(id) && !audioToCheck.contains(id) {
            guard store.audioManifest(id: id) == nil, let file = localAudio(id), file.partCount > 0 else { continue }
            if audioPartsGivenUp.contains(where: { $0.noteID == id }) {
                // Some parts are already in iCloud: send only what's missing.
                check.append(id)
                continue
            }
            noteAudioParts(file.partCount, of: id)
            parts += Self.parts(of: id, count: file.partCount)
            notes += 1
        }
        if !parts.isEmpty {
            engine.enqueueAudioSaves(parts)
            print("[NoteSync] Queued \(parts.count) audio parts for \(notes) notes")
        }
        checkAudioSoon(check, verifyMarked: false)
    }

    private static func parts(of id: UUID, count: Int) -> [NoteAudioPartID] {
        (0..<count).map { NoteAudioPartID(noteID: id, index: $0) }
    }

    /// Notes with parts waiting in the engine or waiting for a retry.
    private func notesWithAudioInFlight() -> Set<UUID> {
        Set(engine.pendingAudioSaves().map(\.noteID)).union(audioSavesToRetry.map(\.noteID))
    }

    private func noteAudioParts(_ count: Int, of id: UUID) {
        audioPartCounts[id] = max(audioPartCounts[id] ?? 0, count)
    }

    private func localAudio(_ id: UUID) -> NoteSyncLocalAudio? {
        guard store.isSyncable(id: id) else { return nil }
        return store.localAudioFile(id: id, resolve: localAudioURL)
    }

    private func checkAudioSoon(_ ids: [UUID], verifyMarked: Bool) {
        guard !ids.isEmpty, !isStopped else { return }
        lastAudioCheck = Task { await self.checkAudio(ids, verifyMarked: verifyMarked) }
    }

    /// One note's audio as a check sees it: the file here, or only the
    /// marker for audio another Mac recorded.
    private struct AudioToCheck {
        let id: UUID
        let file: NoteSyncLocalAudio?
        let manifest: NoteAudioManifest?
        let stamp: NoteAudioPartStamp
        let count: Int
    }

    /// Compares each note's audio with the parts iCloud holds. Missing
    /// parts, or parts cut from an earlier file, are sent; when every part
    /// is there the marker is written. With `verifyMarked`, audio already
    /// marked is checked too, including audio that isn't on this Mac, and a
    /// marker iCloud can't back is cleared.
    func checkAudio(_ ids: [UUID], verifyMarked: Bool) async {
        guard !isStopped else { return }
        let busy = notesWithAudioInFlight()
        var notes: [AudioToCheck] = []
        var release: [UUID] = []
        defer {
            if !release.isEmpty, !isStopped {
                savesAfterCheck.subtract(release)
                engine.enqueueSaves(release)
            }
        }
        for id in ids {
            let manifest = store.audioManifest(id: id)
            let file = localAudio(id)
            // Parts may already be in iCloud, so a delete must know how many.
            if manifest == nil, let file { noteAudioParts(file.partCount, of: id) }
            guard !busy.contains(id) else {
                if savesAfterCheck.contains(id) { release.append(id) }
                continue
            }
            if audioChecking.contains(id) {
                audioToCheck.insert(id)
                continue
            }
            if let file, file.partCount > 0, manifest == nil || verifyMarked {
                notes.append(AudioToCheck(id: id, file: file, manifest: manifest, stamp: file.stamp, count: file.partCount))
            } else if verifyMarked, file == nil, let manifest, manifest.parts > 0,
                      case .string(let name)? = store.syncRecord(id: id)?.fields[NoteSyncField.audioFileName.rawValue] {
                let stamp = NoteAudioPartStamp(fileName: name, fileBytes: manifest.bytes)
                notes.append(AudioToCheck(id: id, file: nil, manifest: manifest, stamp: stamp, count: manifest.parts))
            } else if savesAfterCheck.contains(id) {
                // Nothing to check: it goes up as it is.
                release.append(id)
            }
        }
        guard !notes.isEmpty else { return }
        let checking = Set(notes.map(\.id))
        audioChecking.formUnion(checking)
        defer { audioChecking.subtract(checking) }
        let stamps: [NoteAudioPartID: NoteAudioPartStamp]
        do {
            stamps = try await engine.audioPartStamps(notes.flatMap { Self.parts(of: $0.id, count: $0.count) })
        } catch {
            if !isStopped { audioToCheck.formUnion(checking) }
            print("[NoteSync] Couldn't check audio in iCloud")
            return
        }
        guard !isStopped else { return }
        // Checked: held-back notes go up now, with whatever marker remains.
        release += checking.filter { savesAfterCheck.contains($0) }
        let busyNow = notesWithAudioInFlight()
        var send: [NoteAudioPartID] = []
        var extra: [NoteAudioPartID] = []
        var complete: [(UUID, NoteSyncLocalAudio)] = []
        var unmarked: [UUID] = []
        for note in notes {
            // The note may have changed while iCloud answered.
            guard !busyNow.contains(note.id), localAudio(note.id) == note.file,
                  store.audioManifest(id: note.id) == note.manifest else { continue }
            if note.file != nil {
                if let known = audioPartCounts[note.id], known > note.count, note.manifest == nil {
                    // An earlier, longer file left parts past the end.
                    extra += (note.count..<known).map { NoteAudioPartID(noteID: note.id, index: $0) }
                }
                if note.manifest == nil { audioPartCounts[note.id] = note.count }
            }
            let missing = Self.parts(of: note.id, count: note.count).filter { stamps[$0] != note.stamp }
            if missing.isEmpty {
                if note.manifest == nil, let file = note.file { complete.append((note.id, file)) }
                continue
            }
            if note.manifest != nil {
                do {
                    try store.setAudioManifest(nil, id: note.id)
                    unmarked.append(note.id)
                } catch {
                    print("[NoteSync] Couldn't clear an audio marker")
                    continue
                }
            }
            // Audio that isn't here can't be sent; only its marker goes.
            guard let file = note.file else { continue }
            noteAudioParts(file.partCount, of: note.id)
            send += missing.filter { !audioPartsGivenUp.contains($0) }
        }
        if !extra.isEmpty { engine.enqueueAudioDeletes(extra) }
        if !send.isEmpty {
            engine.enqueueAudioSaves(send)
            print("[NoteSync] Queued \(send.count) audio parts iCloud doesn't have")
        }
        if !unmarked.isEmpty {
            engine.enqueueSaves(unmarked.filter { !release.contains($0) })
            if case .uploading = status {
                uploadWaitingAudio.formUnion(unmarked.filter { localAudio($0) != nil })
            }
            print("[NoteSync] Cleared \(unmarked.count) audio markers iCloud couldn't back")
        }
        for (id, file) in complete {
            await markAudioUploaded(id, file: file)
        }
    }

    /// Every part is in iCloud: hashes the file, writes the marker, and
    /// sends the note again so other Macs learn they can download it.
    private func markAudioUploaded(_ id: UUID, file: NoteSyncLocalAudio) async {
        let hash: String
        do {
            hash = try await hashFile(file.url)
        } catch {
            print("[NoteSync] Couldn't read audio to finish its upload")
            return
        }
        // The note may have changed while the file was read.
        guard !isStopped, store.audioManifest(id: id) == nil, localAudio(id) == file,
              !notesWithAudioInFlight().contains(id) else { return }
        let manifest = NoteAudioManifest(
            sha256: hash,
            bytes: file.bytes,
            partSize: NoteAudioParts.partSize,
            parts: file.partCount
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

    /// Stops sending a note's audio and deletes every part this Mac may
    /// have sent: `markedParts` from its marker, or as many as this Mac
    /// queued.
    private func dropAudio(of id: UUID, markedParts: Int, pending: [NoteAudioPartID]) -> [NoteAudioPartID] {
        let waiting = pending.filter { $0.noteID == id }
        if !waiting.isEmpty { engine.cancelAudioSaves(noteID: id) }
        let count = max(markedParts, audioPartCounts[id] ?? 0, (waiting.map(\.index).max() ?? -1) + 1)
        audioPartCounts[id] = nil
        audioSavesToRetry = audioSavesToRetry.filter { $0.noteID != id }
        audioToCheck.remove(id)
        uploadWaitingText.remove(id)
        uploadWaitingAudio.remove(id)
        return Self.parts(of: id, count: count)
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
        var pending: [NoteAudioPartID]?
        for change in changes {
            switch change {
            case .saved(let id):
                if store.isSyncable(id: id) { saves.append(id) }
            case .deleted(let id, let wasSynced, let audioParts):
                if wasSynced { deletes.append(id) }
                // Parts still waiting never go up; parts already sent are
                // deleted.
                if pending == nil { pending = engine.pendingAudioSaves() }
                audioDeletes += dropAudio(of: id, markedParts: audioParts, pending: pending ?? [])
            }
        }
        if !deletes.isEmpty || !audioDeletes.isEmpty { reportUploadProgress() }
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
              part.index < file.partCount else { return nil }
        return NoteSyncOutgoingAudio(part: part, fileURL: file.url, fileName: file.name, byteCount: file.bytes)
    }

    /// After the last part of a note is up, checks that iCloud holds every
    /// part and writes the marker.
    func handleAudioPartSaved(_ part: NoteAudioPartID) async {
        let id = part.noteID
        audioFailures[part] = nil
        guard !isStopped else { return }
        guard store.syncRecord(id: id) != nil else {
            // Deleted here while the part was in flight.
            engine.enqueueAudioDeletes([part])
            return
        }
        guard !notesWithAudioInFlight().contains(id) else { return }
        await checkAudio([id], verifyMarked: false)
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
                let attempts = (audioFailures[part] ?? 0) + 1
                audioFailures[part] = attempts
                if attempts < Self.maxAudioAttempts {
                    audioSavesToRetry.insert(part)
                } else {
                    // Sending it again keeps failing: try after the next launch.
                    audioPartsGivenUp.insert(part)
                    print("[NoteSync] Stopped retrying an audio part after \(attempts) tries")
                }
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
        var audioDeletes: [NoteAudioPartID] = []
        if !deletions.isEmpty {
            // Audio this Mac was sending for those notes stops, and what it
            // already sent is removed: the other Mac may not know about it.
            let pending = engine.pendingAudioSaves()
            for id in deletions {
                let parts = max(store.audioManifest(id: id)?.parts ?? 0, localAudio(id)?.partCount ?? 0)
                if let assets = try? store.removeSynced(id: id) {
                    change.purged.append(assets)
                }
                audioDeletes += dropAudio(of: id, markedParts: parts, pending: pending)
            }
        }
        if !audioDeletes.isEmpty { engine.enqueueAudioDeletes(audioDeletes) }
        if !returned.isEmpty {
            // A note deleted here while offline and edited on another Mac
            // is back: its delete must not remove it from iCloud.
            deletesToRetry.subtract(returned)
            engine.cancelDeletes(returned)
        }
        if !needsUpload.isEmpty, !isStopped { engine.enqueueSaves(needsUpload) }
        // Another Mac may have cleared a marker for audio this Mac holds:
        // it is checked against iCloud and marked again when it's all there.
        let unmarked = change.changed.filter { store.audioManifest(id: $0) == nil && localAudio($0) != nil }
        checkAudioSoon(unmarked, verifyMarked: false)
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
        if !audioToCheck.isEmpty {
            let retry = Array(audioToCheck)
            audioToCheck = []
            // Only notes that were checked before land here, so a marked
            // one was meant to be verified.
            checkAudioSoon(retry, verifyMarked: true)
        }
        // Notes just queued again for lack of space aren't up to date yet;
        // the pause clears after a sync where they went up.
        if case .paused(.quotaExceeded) = status, retriedForQuota { return }
        let busy = pending > 0 || !audioChecking.isEmpty
        if case .uploading = status, uploadDone < uploadTotal, busy { return }
        if !busy {
            status = .upToDate(now())
        } else if case .paused(.offline) = status {
            // Back online with changes still to send.
            status = .starting
        }
    }

    /// The engine is stopping: nothing more is sent or written.
    func stop() {
        isRetired = true
    }

    func handleAccountChange(signedOut: Bool) {
        // Paused first, so sync stays stopped even if clearing fails.
        status = .paused(signedOut ? .signedOut : .accountChanged)
        // Markers stay: signing back into the same account finds the audio
        // there, and turning sync on checks them against iCloud.
        store.clearChangeTags(forgettingAudio: false)
        print("[NoteSync] Paused: iCloud account \(signedOut ? "signed out" : "changed")")
    }

    func handleZoneDeleted() {
        status = .paused(.deletedElsewhere)
        store.clearChangeTags(forgettingAudio: true)
        print("[NoteSync] Paused: iCloud data was deleted from another Mac")
    }
}
