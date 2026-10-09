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
    /// The SHA-256 of the audio file this Mac is uploading, which names its
    /// parts; kept on this Mac only.
    func audioUploadKey(id: UUID) -> String?
    func setAudioUploadKey(_ key: String?, id: UUID) throws
    /// Upload keys that applying other Macs' records cleared (their audio
    /// file replaced the one this Mac was sending), taken once.
    func takeClearedAudioUploadKeys() -> [UUID: String]
}

/// A note's audio file on this Mac.
struct NoteSyncLocalAudio: Equatable {
    let url: URL
    let name: String
    let bytes: Int64

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
    /// Drops audio deletes still waiting to go up, for a note that came back.
    func cancelAudioDeletes(noteID: UUID)
    /// Drops waiting deletes of these parts, which a note uses again.
    func cancelAudioDeletes(_ parts: [NoteAudioPartID])
    /// Which of these parts iCloud holds. Never reads the audio.
    func existingAudioParts(_ parts: [NoteAudioPartID]) async throws -> Set<NoteAudioPartID>
    /// Every part in iCloud for these notes, whatever file it came from.
    func audioParts(ofNotes ids: Set<UUID>) async throws -> [NoteAudioPartID]
}

/// One audio part to send: which bytes of which file.
struct NoteSyncOutgoingAudio: Equatable {
    let part: NoteAudioPartID
    let fileURL: URL
    /// The whole file's size.
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
    /// A part that failed this many times waits for the next launch.
    static let maxAudioAttempts = 3
    private var audioFailures: [NoteAudioPartID: Int] = [:]
    private var audioPartsGivenUp: Set<NoteAudioPartID> = []
    /// Notes whose parts in iCloud are being checked, and notes to check
    /// again after the next sync because a check couldn't finish.
    private var audioChecking: Set<UUID> = []
    private var audioToCheck: Set<UUID> = []
    /// Notes whose leftover parts must be looked for, because no marker
    /// names them, with the part keys to remove (nil: every key the note
    /// doesn't use); kept when the lookup failed.
    private var audioToClean: [UUID: Set<String>?] = [:]
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
        uploadWaitingAudio = Set(ids.filter { store.audioManifest(id: $0) == nil && usableAudio($0) != nil })
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

    /// A note that changed: its audio, when it isn't in iCloud yet, is
    /// checked against iCloud and the missing parts sent. A note already
    /// being checked is checked again afterward.
    func queueAudioUploads(for ids: [UUID]) {
        guard !isStopped else { return }
        let busy = notesWithAudioInFlight()
        var check: [UUID] = []
        for id in ids where !busy.contains(id) && !audioToCheck.contains(id) {
            if audioChecking.contains(id) {
                // The running check may have read the note before this
                // change: check it again afterward.
                audioToCheck.insert(id)
                continue
            }
            guard store.audioManifest(id: id) == nil, usableAudio(id) != nil else { continue }
            check.append(id)
        }
        checkAudioSoon(check, verifyMarked: false)
    }

    /// Queues note saves, except notes held until their audio check ends.
    private func enqueueNoteSaves(_ ids: [UUID]) {
        let ready = ids.filter { !savesAfterCheck.contains($0) }
        if !ready.isEmpty { engine.enqueueSaves(ready) }
    }

    /// Notes with parts waiting in the engine or waiting for a retry.
    private func notesWithAudioInFlight() -> Set<UUID> {
        Set(engine.pendingAudioSaves().map(\.noteID)).union(audioSavesToRetry.map(\.noteID))
    }

    private func localAudio(_ id: UUID) -> NoteSyncLocalAudio? {
        guard store.isSyncable(id: id) else { return nil }
        return store.localAudioFile(id: id, resolve: localAudioURL)
    }

    /// The local audio when it has bytes to send; an empty file counts as
    /// no file.
    private func usableAudio(_ id: UUID) -> NoteSyncLocalAudio? {
        localAudio(id).flatMap { $0.partCount > 0 ? $0 : nil }
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
        /// The SHA-256 naming the parts: the marker's, or the local file's.
        let sha256: String
        let count: Int

        var parts: [NoteAudioPartID] { NoteAudioPartID.parts(of: id, sha256: sha256, count: count) }
    }

    /// Compares each note's audio with the parts iCloud holds. Missing parts
    /// are sent; when every part is there the marker is written. With
    /// `verifyMarked`, audio already marked is checked too, including audio
    /// that isn't on this Mac, and a marker iCloud can't back is cleared.
    /// Notes whose part names are known are checked first, together; then
    /// each other file is read and its parts sent before the next is read.
    func checkAudio(_ ids: [UUID], verifyMarked: Bool) async {
        guard !isStopped else { return }
        let busy = notesWithAudioInFlight()
        var named: [AudioToCheck] = []
        var unread: [(id: UUID, file: NoteSyncLocalAudio)] = []
        var release: [UUID] = []
        for id in ids {
            if busy.contains(id) || audioChecking.contains(id) {
                // Checked later: a held note keeps waiting for that.
                if audioChecking.contains(id) || savesAfterCheck.contains(id) { audioToCheck.insert(id) }
                continue
            }
            let manifest = store.audioManifest(id: id)
            let file = usableAudio(id)
            if let manifest, verifyMarked, manifest.parts > 0 {
                named.append(AudioToCheck(id: id, file: file, manifest: manifest, sha256: manifest.sha256, count: manifest.parts))
            } else if manifest == nil, let file {
                if let key = store.audioUploadKey(id: id) {
                    named.append(AudioToCheck(id: id, file: file, manifest: nil, sha256: key, count: file.partCount))
                } else {
                    unread.append((id, file))
                }
            } else if savesAfterCheck.contains(id) {
                // Nothing to check: it goes up as it is.
                release.append(id)
            }
        }
        releaseHeldNotes(release)
        let checking = Set(named.map(\.id) + unread.map(\.id))
        guard !checking.isEmpty else { return }
        audioChecking.formUnion(checking)
        defer { audioChecking.subtract(checking) }
        var remaining = checking
        if !named.isEmpty {
            guard let toRead = await settleAudio(named) else {
                if !isStopped { audioToCheck.formUnion(remaining) }
                return
            }
            remaining.subtract(named.map(\.id))
            // A marker iCloud couldn't back: the file here is read and sent
            // under its own name.
            for id in toRead {
                guard let file = usableAudio(id) else { continue }
                unread.append((id, file))
                remaining.insert(id)
            }
        }
        for note in unread {
            guard !isStopped else { return }
            guard let sha256 = await uploadKey(note.id, file: note.file) else {
                guard !isStopped else { return }
                remaining.remove(note.id)
                if store.syncRecord(id: note.id) != nil { audioToCheck.insert(note.id) }
                continue
            }
            guard await settleAudio([AudioToCheck(
                id: note.id, file: note.file, manifest: nil, sha256: sha256, count: note.file.partCount
            )]) != nil else {
                if !isStopped { audioToCheck.formUnion(remaining) }
                return
            }
            remaining.remove(note.id)
        }
    }

    /// Held notes go up now, with whatever marker remains.
    private func releaseHeldNotes(_ ids: [UUID]) {
        guard !ids.isEmpty, !isStopped else { return }
        savesAfterCheck.subtract(ids)
        engine.enqueueSaves(ids)
    }

    /// Looks the notes' parts up and acts on what is missing: sends it, or
    /// marks audio that is all there, or clears a marker iCloud can't back.
    /// Returns the notes whose file here must be read (an unbacked marker),
    /// or nil when the lookup failed or sync stopped.
    private func settleAudio(_ notes: [AudioToCheck]) async -> [UUID]? {
        // A part this note's file needs is never deleted: a delete waiting
        // for it (an earlier file with the same bytes) is dropped.
        let needed = notes.filter { $0.manifest == nil }.flatMap(\.parts)
        if !needed.isEmpty {
            engine.cancelAudioDeletes(needed)
            audioDeletesToRetry.subtract(needed)
        }
        let found: Set<NoteAudioPartID>
        do {
            found = try await engine.existingAudioParts(notes.flatMap(\.parts))
        } catch {
            print("[NoteSync] Couldn't check audio in iCloud")
            return nil
        }
        guard !isStopped else { return nil }
        let busyNow = notesWithAudioInFlight()
        var send: [NoteAudioPartID] = []
        var marked: [UUID] = []
        var unmarked: [UUID] = []
        var recheck: Set<UUID> = []
        var toRead: [UUID] = []
        for note in notes {
            // The note may have changed while iCloud answered: it is
            // checked again after the next sync.
            guard !busyNow.contains(note.id), usableAudio(note.id) == note.file,
                  store.audioManifest(id: note.id) == note.manifest,
                  note.manifest != nil || store.audioUploadKey(id: note.id) == note.sha256 else {
                if store.syncRecord(id: note.id) != nil { recheck.insert(note.id) }
                continue
            }
            let missing = note.parts.filter { !found.contains($0) }
            if missing.isEmpty {
                if note.manifest == nil, let file = note.file {
                    let manifest = NoteAudioManifest(
                        sha256: note.sha256,
                        bytes: file.bytes,
                        partSize: NoteAudioParts.partSize,
                        parts: note.count
                    )
                    do {
                        try store.setAudioManifest(manifest, id: note.id)
                        marked.append(note.id)
                    } catch {
                        print("[NoteSync] Couldn't record uploaded audio")
                    }
                }
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
                // Audio that isn't here can't be sent; only its marker goes.
                // A file here is read again rather than taken for the marked
                // one, so its parts are named after its own bytes.
                if note.file != nil, (try? store.setAudioUploadKey(nil, id: note.id)) != nil {
                    toRead.append(note.id)
                }
                continue
            }
            send += missing.filter { !audioPartsGivenUp.contains($0) }
        }
        audioToCheck.formUnion(recheck)
        if !send.isEmpty {
            engine.enqueueAudioSaves(send)
            print("[NoteSync] Queued \(send.count) audio parts iCloud doesn't have")
        }
        // The note goes up again so other Macs see its marker change.
        enqueueNoteSaves(marked + unmarked)
        let checked = notes.map(\.id).filter { !recheck.contains($0) }
        releaseHeldNotes(checked.filter(savesAfterCheck.contains))
        if !unmarked.isEmpty {
            if case .uploading = status {
                uploadWaitingAudio.formUnion(unmarked.filter { usableAudio($0) != nil })
            }
            print("[NoteSync] Cleared \(unmarked.count) audio markers iCloud couldn't back")
        }
        if !marked.isEmpty {
            uploadWaitingAudio.subtract(marked)
            reportUploadProgress()
        }
        return toRead
    }

    /// The SHA-256 naming this file's parts: kept from an earlier read, or
    /// read now off the main thread and kept. Nil when the file can't be
    /// read or the note changed meanwhile.
    private func uploadKey(_ id: UUID, file: NoteSyncLocalAudio) async -> String? {
        if let key = store.audioUploadKey(id: id) { return key }
        let sha256: String
        do {
            sha256 = try await hashFile(file.url)
        } catch {
            print("[NoteSync] Couldn't read audio to upload it")
            return nil
        }
        guard !isStopped, usableAudio(id) == file, store.audioManifest(id: id) == nil else { return nil }
        if let key = store.audioUploadKey(id: id) { return key }
        do {
            try store.setAudioUploadKey(sha256, id: id)
        } catch {
            print("[NoteSync] Couldn't record audio to upload")
            return nil
        }
        return sha256
    }

    private func cleanUpAudioSoon(_ targets: [UUID: Set<String>?]) {
        guard !targets.isEmpty, !isStopped else { return }
        lastAudioCheck = Task { await self.cleanUpAudio(targets) }
    }

    /// Deletes parts of these notes that nothing uses any more: every part
    /// of a deleted note, or the parts of an earlier file. Used when no
    /// marker names them (another Mac stopped mid-upload, or an upload here
    /// was cut short). It lists the notes' parts in iCloud, never the audio.
    /// A key set limits it to those keys (what this Mac sent); nil removes
    /// every key the note doesn't use now.
    func cleanUpAudio(_ targets: [UUID: Set<String>?]) async {
        guard !isStopped else { return }
        let found: [NoteAudioPartID]
        do {
            found = try await engine.audioParts(ofNotes: Set(targets.keys))
        } catch {
            if !isStopped { mergeCleanUp(targets) }
            print("[NoteSync] Couldn't look for leftover audio")
            return
        }
        guard !isStopped else { return }
        // A note being checked may be about to use some of these parts.
        let checkingNow = Set(targets.keys).intersection(audioChecking)
        mergeCleanUp(targets.filter { checkingNow.contains($0.key) })
        let pending = Set(engine.pendingAudioSaves())
        var used: [UUID: Set<String>] = [:]
        for id in Set(found.map(\.noteID)) where store.syncRecord(id: id) != nil {
            used[id] = Set([store.audioManifest(id: id)?.sha256, store.audioUploadKey(id: id)]
                .compactMap { $0.map(NoteAudioPartID.key(sha256:)) })
        }
        let leftover = found.filter { part in
            guard !checkingNow.contains(part.noteID), !pending.contains(part),
                  used[part.noteID]?.contains(part.key) != true else { return false }
            guard case .some(.some(let keys)) = targets[part.noteID] else { return true }
            return keys.contains(part.key)
        }
        if !leftover.isEmpty {
            engine.enqueueAudioDeletes(leftover)
            print("[NoteSync] Deleting \(leftover.count) leftover audio parts")
        }
    }

    /// Adds clean-ups to retry; "every unused key" wins over a key set.
    private func mergeCleanUp(_ targets: [UUID: Set<String>?]) {
        for (id, keys) in targets {
            switch (audioToClean[id], keys) {
            case (.none, _):
                audioToClean[id] = keys
            case (.some(.some(let earlier)), .some(let more)):
                audioToClean[id] = earlier.union(more)
            default:
                audioToClean[id] = .some(nil)
            }
        }
    }

    /// Stops this Mac's work on a note's audio: waiting parts are cancelled
    /// and retries forgotten.
    private func stopAudioWork(on id: UUID, pending: [NoteAudioPartID]) -> Bool {
        let waiting = pending.contains { $0.noteID == id }
        if waiting { engine.cancelAudioSaves(noteID: id) }
        audioSavesToRetry = audioSavesToRetry.filter { $0.noteID != id }
        audioPartsGivenUp = audioPartsGivenUp.filter { $0.noteID != id }
        audioFailures = audioFailures.filter { $0.key.noteID != id }
        return waiting
    }

    /// What to delete for audio a note no longer uses: the parts its marker
    /// names, and whether others may be in iCloud that only a lookup finds
    /// (no marker, or an upload in progress).
    private func audioToDelete(of id: UUID, _ audio: NoteAudioSyncState?, wasSending: Bool) -> (parts: [NoteAudioPartID], lookUp: Bool) {
        guard let audio else { return ([], wasSending) }
        let parts = audio.manifest?.partIDs(noteID: id) ?? []
        let uploadUnmarked = audio.uploadKey != nil && audio.uploadKey != audio.manifest?.sha256
        return (parts, audio.manifest == nil || uploadUnmarked || wasSending)
    }

    /// A deleted note: nothing more goes up, and its parts are deleted.
    private func dropAudio(of id: UUID, _ audio: NoteAudioSyncState?, pending: [NoteAudioPartID]) -> (parts: [NoteAudioPartID], lookUp: Bool) {
        let wasSending = stopAudioWork(on: id, pending: pending)
        audioToCheck.remove(id)
        savesAfterCheck.remove(id)
        uploadWaitingText.remove(id)
        uploadWaitingAudio.remove(id)
        return audioToDelete(of: id, audio, wasSending: wasSending)
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
        var lookUp: [UUID] = []
        var pending: [NoteAudioPartID]?
        for change in changes {
            switch change {
            case .saved(let id):
                if store.isSyncable(id: id) { saves.append(id) }
            case .deleted(let id, let wasSynced, let audio):
                if wasSynced { deletes.append(id) }
                // Parts still waiting never go up; parts already sent are
                // deleted.
                if pending == nil { pending = engine.pendingAudioSaves() }
                let drop = dropAudio(of: id, audio, pending: pending ?? [])
                audioDeletes += drop.parts
                if drop.lookUp { lookUp.append(id) }
            case .audioReplaced(let id, let previous):
                // The earlier file's parts go. The deletes wait in the
                // engine, so a quit doesn't lose them; if the new file has
                // the same bytes, its check drops them before they're sent.
                if pending == nil { pending = engine.pendingAudioSaves() }
                let wasSending = stopAudioWork(on: id, pending: pending ?? [])
                let drop = audioToDelete(of: id, previous, wasSending: wasSending)
                audioDeletes += drop.parts
                if drop.lookUp { lookUp.append(id) }
            }
        }
        if !deletes.isEmpty || !audioDeletes.isEmpty { reportUploadProgress() }
        if !saves.isEmpty {
            enqueueNoteSaves(saves)
            queueAudioUploads(for: saves)
        }
        if !deletes.isEmpty { engine.enqueueDeletes(deletes) }
        if !audioDeletes.isEmpty { engine.enqueueAudioDeletes(audioDeletes) }
        cleanUpAudioSoon(Dictionary(lookUp.map { ($0, nil) }, uniquingKeysWith: { first, _ in first }))
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
    /// is gone or already in iCloud, the part was named for another file,
    /// or the index is past the end.
    func outgoingAudio(for part: NoteAudioPartID) -> NoteSyncOutgoingAudio? {
        guard !isStopped, store.audioManifest(id: part.noteID) == nil,
              let file = usableAudio(part.noteID),
              part.index < file.partCount,
              let key = store.audioUploadKey(id: part.noteID),
              NoteAudioPartID.key(sha256: key) == part.key else { return nil }
        return NoteSyncOutgoingAudio(part: part, fileURL: file.url, byteCount: file.bytes)
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
                retryAudio(part)
            case .network:
                offline = true
            case .failed(let part):
                retryAudio(part)
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

    /// Retries a failed part after the next sync, up to a limit: a 50 MB
    /// part that keeps failing (iCloud full, say) waits for a relaunch.
    private func retryAudio(_ part: NoteAudioPartID) {
        let attempts = (audioFailures[part] ?? 0) + 1
        audioFailures[part] = attempts
        if attempts < Self.maxAudioAttempts {
            audioSavesToRetry.insert(part)
        } else {
            audioPartsGivenUp.insert(part)
            print("[NoteSync] Stopped retrying an audio part after \(attempts) tries")
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
        if !resend.isEmpty { enqueueNoteSaves(resend) }
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
        var lookUp: [UUID] = []
        if !deletions.isEmpty {
            // Audio this Mac was sending for those notes stops, and what it
            // already sent is removed: the other Mac may not know about it.
            let pending = engine.pendingAudioSaves()
            for id in deletions {
                let hasAudio = store.syncRecord(id: id)?.fields[NoteSyncField.audioFileName.rawValue] != nil
                let audio = hasAudio
                    ? NoteAudioSyncState(manifest: store.audioManifest(id: id), uploadKey: store.audioUploadKey(id: id))
                    : nil
                if let assets = try? store.removeSynced(id: id) {
                    change.purged.append(assets)
                }
                let drop = dropAudio(of: id, audio, pending: pending)
                audioDeletes += drop.parts
                if drop.lookUp { lookUp.append(id) }
            }
        }
        var cleanUps: [UUID: Set<String>?] = Dictionary(lookUp.map { ($0, nil) }, uniquingKeysWith: { first, _ in first })
        // Another Mac's new audio file replaced the one this Mac was
        // sending: only what this Mac sent goes; the other Mac's upload of
        // the new file must stay.
        for (id, key) in store.takeClearedAudioUploadKeys() where cleanUps[id] == nil {
            cleanUps[id] = [NoteAudioPartID.key(sha256: key)]
        }
        if !audioDeletes.isEmpty { engine.enqueueAudioDeletes(audioDeletes) }
        cleanUpAudioSoon(cleanUps)
        if !returned.isEmpty {
            // A note deleted here while offline and edited on another Mac
            // is back: its delete must not remove it, or its audio, from
            // iCloud.
            deletesToRetry.subtract(returned)
            engine.cancelDeletes(returned)
            let back = Set(returned)
            audioDeletesToRetry = audioDeletesToRetry.filter { !back.contains($0.noteID) }
            for id in returned { engine.cancelAudioDeletes(noteID: id) }
        }
        if !needsUpload.isEmpty, !isStopped { enqueueNoteSaves(needsUpload) }
        // Another Mac may have cleared a marker for audio this Mac holds:
        // it is checked against iCloud and marked again when it's all there.
        // Notes with parts given up are left for the next launch.
        let unmarked = change.changed.filter { id in
            store.audioManifest(id: id) == nil && usableAudio(id) != nil
                && !audioPartsGivenUp.contains(where: { $0.noteID == id })
        }
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
        // Anything queued again here isn't sent yet, so it keeps sync busy.
        var queuedAgain = false
        if !savesToRetry.isEmpty {
            let retry = Array(savesToRetry)
            savesToRetry = []
            enqueueNoteSaves(retry)
            queuedAgain = true
        }
        if !deletesToRetry.isEmpty {
            // A note that came back (another Mac's edit) stays in iCloud.
            let retry = deletesToRetry.filter { store.syncRecord(id: $0) == nil }
            deletesToRetry = []
            if !retry.isEmpty {
                engine.enqueueDeletes(Array(retry))
                queuedAgain = true
            }
        }
        if !audioSavesToRetry.isEmpty {
            let retry = audioSavesToRetry.filter { outgoingAudio(for: $0) != nil }
            audioSavesToRetry = []
            if !retry.isEmpty {
                engine.enqueueAudioSaves(Array(retry))
                queuedAgain = true
            }
        }
        if !audioDeletesToRetry.isEmpty {
            let retry = Array(audioDeletesToRetry)
            audioDeletesToRetry = []
            engine.enqueueAudioDeletes(retry)
            queuedAgain = true
        }
        if !audioToCheck.isEmpty {
            let retry = Array(audioToCheck)
            audioToCheck = []
            // Only notes that were checked before land here, so a marked
            // one was meant to be verified.
            checkAudioSoon(retry, verifyMarked: true)
            queuedAgain = true
        }
        if !audioToClean.isEmpty {
            let retry = audioToClean
            audioToClean = [:]
            cleanUpAudioSoon(retry)
            queuedAgain = true
        }
        // Notes just queued again for lack of space aren't up to date yet;
        // the pause clears after a sync where they went up.
        if case .paused(.quotaExceeded) = status, retriedForQuota { return }
        // Offline stays shown until the network comes back.
        if isOffline, case .paused(.offline) = status { return }
        let busy = pending > 0 || queuedAgain || !audioChecking.isEmpty
        if case .uploading = status, uploadDone < uploadTotal, busy { return }
        if !busy {
            status = .upToDate(now())
        } else if case .paused(.offline) = status {
            // Back online with changes still to send.
            status = .starting
        }
    }

    /// The Mac lost or regained its network. CKSyncEngine waits quietly
    /// while offline, so no send fails to say so; this does.
    func handleNetworkChange(isOnline: Bool) {
        isOffline = !isOnline
        guard !isStopped else { return }
        if !isOnline {
            if case .paused(.quotaExceeded) = status { return }
            status = .paused(.offline)
        } else if case .paused(.offline) = status {
            // The fetch that follows settles the status.
            status = .starting
        }
    }

    /// What the network monitor last said.
    private var isOffline = false

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
