import Foundation

/// What the coordinator needs from the note store. `PipelineHistoryStore`
/// provides it; tests use a fake.
protocol NoteSyncLocalStore: AnyObject {
    /// False while the store can't save (it needs recovery).
    var isReadyForSync: Bool { get }
    func syncRecord(id: UUID) -> NoteSyncRecord?
    /// Whether the note is on this Mac; nil when the store can't be read,
    /// which must never count as gone.
    func noteExists(id: UUID) -> Bool?
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
    /// Offline; the engine retries these itself.
    case network
    /// The iCloud account needs attention. Says so only: the engine keeps
    /// the part and sends it again itself.
    case accountNeedsAttention
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
    /// The iCloud account needs attention. Says so only: the engine keeps
    /// the change and sends it again itself.
    case accountNeedsAttention
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
    /// iCloud needs the account looked at (a password, new terms) in
    /// System Settings. Sync stays on and goes on once it works again.
    case accountNeedsAttention
    case accountChanged
    case signedOut
    case deletedElsewhere
    /// Some notes kept failing to go up; the rest of sync goes on.
    /// `willRetry`: some of them are still waiting for another try.
    case notesFailed(count: Int, willRetry: Bool)
    /// Notes from iCloud couldn't be saved on this Mac, even after starting
    /// over: sync waits for Sync Now or a relaunch.
    case couldNotSaveHere
    /// Note history can't be read (it is being recovered): sync goes on
    /// once the recovered history is in place.
    case historyUnavailable
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
    /// Changes that failed to send, tried again after a wait; ones that
    /// keep failing are given up until their note changes or Sync Now.
    private var saveRetries = NoteSyncRetries<UUID>()
    private var deleteRetries = NoteSyncRetries<UUID>()
    private var audioSaveRetries = NoteSyncRetries<NoteAudioPartID>()
    private var audioDeleteRetries = NoteSyncRetries<NoteAudioPartID>()
    private var quotaRetryPending = false
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
    /// Audio work started so far (checks and clean-ups), for tests to wait on.
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
        Set(engine.pendingAudioSaves().map(\.noteID)).union(audioSaveRetries.waiting.map(\.noteID))
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

    /// Runs audio work in the background. `lastAudioCheck` then finishes
    /// once this and all earlier work did: one change can start a check and
    /// a clean-up, and a test waits on both.
    private func startAudioWork(_ work: @escaping @MainActor () async -> Void) {
        let earlier = lastAudioCheck
        lastAudioCheck = Task {
            await work()
            await earlier?.value
        }
    }

    private func checkAudioSoon(_ ids: [UUID], verifyMarked: Bool) {
        guard !ids.isEmpty, !isStopped else { return }
        startAudioWork { await self.checkAudio(ids, verifyMarked: verifyMarked) }
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
                if store.noteExists(id: note.id) != false { audioToCheck.insert(note.id) }
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
            for part in needed { audioDeleteRetries.forget(part) }
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
                if store.noteExists(id: note.id) != false { recheck.insert(note.id) }
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
            send += missing.filter { !audioSaveRetries.givenUp.contains($0) }
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
        startAudioWork { await self.cleanUpAudio(targets) }
    }

    /// Deletes parts of these notes that nothing uses any more: every part
    /// of a deleted note, or the parts of an earlier file. Used when no
    /// marker names them (another Mac stopped mid-upload, or an upload here
    /// was cut short). It lists the notes' parts in iCloud, never the audio.
    /// A key set limits it to those keys (what this Mac sent); nil, for a
    /// deleted note, removes every key, but not once the note is back.
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
        // The keys a note still uses, read once per note that needs them.
        var used: [UUID: Set<String>] = [:]
        func usedKeys(_ id: UUID) -> Set<String> {
            if let keys = used[id] { return keys }
            let keys = Set([store.audioManifest(id: id)?.sha256, store.audioUploadKey(id: id)]
                .compactMap { $0.map(NoteAudioPartID.key(sha256:)) })
            used[id] = keys
            return keys
        }
        var exists: [UUID: Bool?] = [:]
        let leftover = found.filter { part in
            guard !checkingNow.contains(part.noteID), !pending.contains(part) else { return false }
            guard case .some(.some(let keys)) = targets[part.noteID] else {
                // A deleted note: every part, unless it came back (another
                // Mac edited it), when the other Mac may be uploading.
                // A note that can't be read counts as here, and is looked
                // at again after a later sync.
                if exists[part.noteID] == nil { exists[part.noteID] = store.noteExists(id: part.noteID) }
                return exists[part.noteID] == .some(false)
            }
            return keys.contains(part.key) && !usedKeys(part.noteID).contains(part.key)
        }
        mergeCleanUp(targets.filter { exists[$0.key] == .some(nil) })
        if !leftover.isEmpty {
            engine.enqueueAudioDeletes(leftover)
            print("[NoteSync] Deleting \(leftover.count) leftover audio parts")
        }
    }

    /// Another Mac's new audio file replaced the one this Mac was sending
    /// (a fetch or a conflict merge cleared the upload key): only what this
    /// Mac sent goes; the other Mac's upload of the new file stays.
    private func cleanUpsForClearedUploads() -> [UUID: Set<String>?] {
        store.takeClearedAudioUploadKeys().mapValues { [NoteAudioPartID.key(sha256: $0)] }
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
    /// and retries forgotten. Returns the keys of the parts it was sending
    /// (waiting, to retry, or given up), some of which may be in iCloud.
    private func stopAudioWork(on id: UUID, pending: [NoteAudioPartID]) -> Set<String> {
        let waiting = pending.filter { $0.noteID == id }
        if !waiting.isEmpty { engine.cancelAudioSaves(noteID: id) }
        let retrying = audioSaveRetries.waiting.union(audioSaveRetries.givenUp).filter { $0.noteID == id }
        audioSaveRetries.forget { $0.noteID == id }
        return Set((waiting + retrying).map(\.key))
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
        let wasSending = !stopAudioWork(on: id, pending: pending).isEmpty
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
        var keyedLookUp: [UUID: Set<String>?] = [:]
        var pending: [NoteAudioPartID]?
        for change in changes {
            switch change {
            case .saved(let id):
                // An edit sends its note again and tries its given-up
                // audio again; parts still waiting keep their wait.
                saveRetries.forget(id)
                for part in audioSaveRetries.givenUp where part.noteID == id {
                    audioSaveRetries.forget(part)
                }
                if store.isSyncable(id: id) { saves.append(id) }
            case .deleted(let id, let wasSynced, let audio):
                saveRetries.forget(id)
                deleteRetries.forget(id)
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
                let sending = stopAudioWork(on: id, pending: pending ?? [])
                let sent = sending.union([previous.uploadKey].compactMap { $0.map(NoteAudioPartID.key(sha256:)) })
                let drop = audioToDelete(of: id, previous, wasSending: !sending.isEmpty)
                audioDeletes += drop.parts
                // The note is still here, so only what this Mac sent is
                // looked for: another Mac's upload for it stays.
                if drop.lookUp, !sent.isEmpty { keyedLookUp[id] = sent }
            }
        }
        if !deletes.isEmpty || !audioDeletes.isEmpty { reportUploadProgress() }
        if !saves.isEmpty {
            enqueueNoteSaves(saves)
            queueAudioUploads(for: saves)
        }
        if !deletes.isEmpty { engine.enqueueDeletes(deletes) }
        if !audioDeletes.isEmpty { engine.enqueueAudioDeletes(audioDeletes) }
        var cleanUps = keyedLookUp
        for id in lookUp { cleanUps[id] = .some(nil) }
        cleanUpAudioSoon(cleanUps)
    }

    /// The record to send for `id`, or nil when the note is gone or still
    /// in progress (its pending change is then dropped).
    func outgoing(for id: UUID) -> NoteSyncOutgoing? {
        guard !isStopped, store.isSyncable(id: id), let record = store.syncRecord(id: id) else { return nil }
        return NoteSyncOutgoing(record: record, systemFields: store.syncSystemFields(id: id))
    }

    func handleSaved(id: UUID, systemFields: Data) {
        guard !isStopped else { return }
        switch store.noteExists(id: id) {
        case false?:
            // Deleted here while its upload was in flight.
            engine.enqueueDeletes([id])
            return
        case nil:
            // Can't tell: it went up all the same, and the next save
            // records its change tag.
            saveRetries.forget(id)
            uploadWaitingText.remove(id)
            reportUploadProgress()
            return
        case true?:
            break
        }
        do {
            try store.setSyncSystemFields(systemFields, id: id)
        } catch {
            // Without its change tag the next save conflicts and merges, so
            // the note isn't lost; it just isn't counted as uploaded.
            print("[NoteSync] Couldn't record an uploaded note")
            return
        }
        saveRetries.forget(id)
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
        audioSaveRetries.forget(part)
        guard !isStopped else { return }
        switch store.noteExists(id: id) {
        case false?:
            // Deleted here while the part was in flight.
            engine.enqueueAudioDeletes([part])
            return
        case nil:
            // Can't tell: checked again after the next sync.
            audioToCheck.insert(id)
            return
        case true?:
            break
        }
        guard !notesWithAudioInFlight().contains(id) else { return }
        await checkAudio([id], verifyMarked: false)
    }

    /// A download found a part of this note's audio missing. A note's audio
    /// never changes, so the parts were deleted: a delete sent before the
    /// note came back (edited on another Mac) can't be recalled. The marker
    /// is checked, and one iCloud can't back is cleared so the Mac with the
    /// file sends it again.
    func handleAudioMissing(noteID: UUID) {
        checkAudioSoon([noteID], verifyMarked: true)
    }

    func handleAudioSendFailures(_ failures: [NoteAudioSendFailure]) {
        guard !isStopped else { return }
        let time = now()
        var quotaCount = 0
        var offline = false
        var account = false
        for failure in failures {
            switch failure {
            case .quotaExceeded(let part):
                quotaCount += 1
                quotaRetryPending = true
                audioSaveRetries.failed(part, at: time, keepTrying: true)
            case .network:
                offline = true
            case .accountNeedsAttention:
                account = true
            case .failed(let part):
                audioSaveRetries.failed(part, at: time)
                if audioSaveRetries.givenUp.contains(part) {
                    print("[NoteSync] Stopped retrying an audio part")
                }
            case .deleteFailed(let part):
                audioDeleteRetries.failed(part, at: time, keepTrying: true)
            }
        }
        setFailureStatus(quotaCount: quotaCount, account: account, offline: offline)
        if !failures.isEmpty {
            print("[NoteSync] \(failures.count) audio changes failed to send")
        }
    }

    /// A full iCloud outranks an account to look at, which outranks being
    /// offline.
    private func setFailureStatus(quotaCount: Int, account: Bool, offline: Bool) {
        if quotaCount > 0 {
            status = .paused(.quotaExceeded(pending: quotaCount))
        } else if account {
            if case .paused(.quotaExceeded) = status { return }
            status = .paused(.accountNeedsAttention)
        } else if offline {
            showOffline()
        }
    }

    /// Offline never replaces a full iCloud or an account to look at: coming
    /// back online would clear a notice that still applies.
    private func showOffline() {
        switch status {
        case .paused(.quotaExceeded), .paused(.accountNeedsAttention): return
        default: status = .paused(.offline)
        }
    }

    /// A change went through, so the account works again: the notice gives
    /// way to the upload it interrupted, if any.
    private func accountWorks() {
        guard !isStopped else { return }
        if case .paused(.accountNeedsAttention) = status {
            status = uploadDone < uploadTotal ? .uploading(done: uploadDone, total: uploadTotal) : .starting
        }
    }

    /// Some of a send went through, so the account works: called before
    /// that send's failures, which may show the notice again.
    func handleChangesWentThrough() {
        accountWorks()
    }

    func handleDeleted(id: UUID) {
        // The note is usually gone already; nothing is left to update then.
        try? store.setSyncSystemFields(nil, id: id)
    }

    func handleSendFailures(_ failures: [NoteSyncSendFailure]) {
        // A send that fails after sync stopped must not swap the stop for
        // a quota or offline pause, which would let sync resume.
        guard !isStopped else { return }
        let time = now()
        var quotaCount = 0
        var offline = false
        var account = false
        var resend: [UUID] = []
        var deletes: [UUID] = []
        for failure in failures {
            switch failure {
            case .serverChanged(let id, let payload, let serverFields):
                switch store.noteExists(id: id) {
                case false?:
                    // Deleted here while the save was in flight: delete the
                    // server copy rather than bring the note back.
                    deletes.append(id)
                    continue
                case nil:
                    // Can't tell: the save is tried again later.
                    saveRetries.failed(id, at: time, keepTrying: true)
                    continue
                case true?:
                    break
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
                saveRetries.failed(id, at: time, keepTrying: true)
            case .network:
                offline = true
            case .accountNeedsAttention:
                account = true
            case .unknownItemOnDelete(let id):
                try? store.setSyncSystemFields(nil, id: id)
            case .unknownItemOnSave(let id):
                // If the note was deleted elsewhere, the fetch removes it
                // here first and the retry is dropped.
                try? store.setSyncSystemFields(nil, id: id)
                saveRetries.failed(id, at: time)
            case .deleteFailed(let id):
                // A delete is never given up: the note would stay in iCloud
                // and on other Macs.
                deleteRetries.failed(id, at: time, keepTrying: true)
            case .other(let id):
                saveRetries.failed(id, at: time)
            }
        }
        if !resend.isEmpty { enqueueNoteSaves(resend) }
        if !deletes.isEmpty { engine.enqueueDeletes(deletes) }
        cleanUpAudioSoon(cleanUpsForClearedUploads())
        setFailureStatus(quotaCount: quotaCount, account: account, offline: offline)
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
                let result = try store.applySynced(record, systemFields: fetched.systemFields)
                // The note now holds iCloud's copy: a failed save of it is
                // moot, and one with newer changes here goes up below.
                saveRetries.forget(record.noteID)
                switch result {
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
                saveRetries.forget(id)
                deleteRetries.forget(id)
                let drop = dropAudio(of: id, audio, pending: pending)
                audioDeletes += drop.parts
                if drop.lookUp { lookUp.append(id) }
            }
        }
        var cleanUps: [UUID: Set<String>?] = Dictionary(lookUp.map { ($0, nil) }, uniquingKeysWith: { first, _ in first })
        for (id, keys) in cleanUpsForClearedUploads() where cleanUps[id] == nil {
            cleanUps[id] = keys
        }
        if !audioDeletes.isEmpty { engine.enqueueAudioDeletes(audioDeletes) }
        cleanUpAudioSoon(cleanUps)
        if !returned.isEmpty {
            // A note deleted here while offline and edited on another Mac
            // is back: its delete must not remove it, or its audio, from
            // iCloud.
            for id in returned { deleteRetries.forget(id) }
            engine.cancelDeletes(returned)
            let back = Set(returned)
            audioDeleteRetries.forget { back.contains($0.noteID) }
            for id in returned {
                engine.cancelAudioDeletes(noteID: id)
                // A waiting clean-up would delete parts another Mac is
                // still sending for it.
                audioToClean[id] = nil
            }
        }
        if !needsUpload.isEmpty, !isStopped { enqueueNoteSaves(needsUpload) }
        // Another Mac may have cleared a marker for audio this Mac holds:
        // it is checked against iCloud and marked again when it's all there.
        // Notes with parts given up wait for an edit, Sync Now or a relaunch.
        let unmarked = change.changed.filter { id in
            store.audioManifest(id: id) == nil && usableAudio(id) != nil
                && !audioSaveRetries.givenUp.contains(where: { $0.noteID == id })
        }
        checkAudioSoon(unmarked, verifyMarked: false)
        if change.skipped > 0 {
            print("[NoteSync] Skipped \(change.skipped) records it could not read")
        }
        return change
    }

    /// While this Mac deletes its iCloud data, a finished fetch or send
    /// neither sends failed changes again nor settles the status: sync turns
    /// off after, or, if the delete is undone, `stopHoldingRetries` does
    /// both. (New sends meet the missing zone and are held by the engine.)
    var isHoldingRetries = false
    /// The last finished sync skipped while holding, with what it left.
    private var skippedFinish: Int?

    func stopHoldingRetries() {
        guard isHoldingRetries else { return }
        isHoldingRetries = false
        if let pending = skippedFinish {
            skippedFinish = nil
            handleFetchFinished(pending: pending)
        }
    }

    /// A fetch or send finished. With nothing left to send, sync is up to date.
    func handleFetchFinished(pending: Int) {
        guard !isStopped else { return }
        guard !isHoldingRetries else {
            skippedFinish = pending
            return
        }
        let retriedForQuota = quotaRetryPending
        quotaRetryPending = false
        // Anything queued again here isn't sent yet, so it keeps sync busy.
        var queuedAgain = false
        let time = now()
        let saves = saveRetries.takeDue(at: time)
        if !saves.isEmpty {
            enqueueNoteSaves(saves)
            queuedAgain = true
        }
        let deletes = deleteRetries.takeDue(at: time)
        if !deletes.isEmpty {
            // A note that came back (another Mac's edit) stays in iCloud,
            // and one that can't be read waits for a later sync.
            var retry: [UUID] = []
            for id in deletes {
                switch store.noteExists(id: id) {
                case false?: retry.append(id)
                case nil: deleteRetries.failed(id, at: time, keepTrying: true)
                case true?: deleteRetries.forget(id)
                }
            }
            if !retry.isEmpty {
                engine.enqueueDeletes(retry)
                queuedAgain = true
            }
        }
        let partSaves = audioSaveRetries.takeDue(at: time).filter { outgoingAudio(for: $0) != nil }
        if !partSaves.isEmpty {
            engine.enqueueAudioSaves(partSaves)
            queuedAgain = true
        }
        let partDeletes = audioDeleteRetries.takeDue(at: time)
        if !partDeletes.isEmpty {
            engine.enqueueAudioDeletes(partDeletes)
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
        // Saves that keep trying (for space, or until the note can be read)
        // or failed once aren't up to date; ones that failed again are
        // shown. A waiting delete isn't: its note is already gone here.
        let busy = pending > 0 || queuedAgain || !audioChecking.isEmpty || isWaitingQuietly
        // Shown until a change goes through, or nothing is left to send.
        if case .paused(.accountNeedsAttention) = status, busy { return }
        // Offline stays shown until the network comes back.
        if isOffline, case .paused(.offline) = status { return }
        if case .uploading = status, uploadDone < uploadTotal, busy { return }
        if !busy {
            let failing = failingNotes
            status = failing.count == 0
                ? .upToDate(time)
                : .paused(.notesFailed(count: failing.count, willRetry: failing.willRetry))
        } else if case .paused(.offline) = status {
            // Back online with changes still to send.
            status = .starting
        }
    }

    private var isWaitingQuietly: Bool {
        !saveRetries.waitingQuietly.isEmpty || !audioSaveRetries.waitingQuietly.isEmpty
    }

    /// Notes whose text or audio keeps failing to go up, and whether any of
    /// them waits for another try. Deletes aren't counted: they keep trying.
    private var failingNotes: (count: Int, willRetry: Bool) {
        let notes = saveRetries.failing.union(audioSaveRetries.failing.map(\.noteID))
        let willRetry = !saveRetries.failingToRetry.isEmpty || !audioSaveRetries.failingToRetry.isEmpty
        return (notes.count, willRetry)
    }

    /// Sync Now: every change that failed, given up or still waiting, is
    /// tried again when this sync's fetch finishes.
    func retryFailedNow() {
        let time = now()
        saveRetries.retryAll(at: time)
        deleteRetries.retryAll(at: time)
        audioSaveRetries.retryAll(at: time)
        audioDeleteRetries.retryAll(at: time)
    }

    /// The Mac lost or regained its network. CKSyncEngine waits quietly
    /// while offline, so no send fails to say so; this does.
    func handleNetworkChange(isOnline: Bool) {
        isOffline = !isOnline
        guard !isStopped else { return }
        if !isOnline {
            showOffline()
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
