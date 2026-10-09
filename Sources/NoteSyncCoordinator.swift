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
}

/// The sync engine's pending changes, as the coordinator sees them.
protocol NoteSyncEngineClient: AnyObject {
    func enqueueSaves(_ ids: [UUID])
    func enqueueDeletes(_ ids: [UUID])
    /// Drops deletes still waiting to go up.
    func cancelDeletes(_ ids: [UUID])
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
    private var uploadDone = 0
    private var uploadTotal = 0

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
    private var quotaRetryPending = false

    /// After an account change or a deletion elsewhere nothing more is sent;
    /// sync starts again only when the user turns it on.
    private var isStopped: Bool {
        switch status {
        case .paused(.accountChanged), .paused(.signedOut), .paused(.deletedElsewhere): return true
        default: return false
        }
    }

    init(store: NoteSyncLocalStore, engine: NoteSyncEngineClient, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.engine = engine
        self.now = now
    }

    /// Queues every settled note on this Mac, for turning sync on.
    func startInitialUpload() {
        let ids = store.syncableNoteIDs()
        uploadDone = 0
        uploadTotal = ids.count
        engine.enqueueSaves(ids)
        status = ids.isEmpty ? .starting : .uploading(done: 0, total: ids.count)
        print("[NoteSync] Queued \(ids.count) notes for the first upload")
    }

    func handleLocalChanges(_ changes: [PipelineHistoryChange]) {
        guard !isStopped else { return }
        var saves: [UUID] = []
        var deletes: [UUID] = []
        for change in changes {
            switch change {
            case .saved(let id):
                if store.isSyncable(id: id) { saves.append(id) }
            case .deleted(let id, let wasSynced):
                if wasSynced { deletes.append(id) }
            }
        }
        if !saves.isEmpty { engine.enqueueSaves(saves) }
        if !deletes.isEmpty { engine.enqueueDeletes(deletes) }
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
        if case .uploading = status {
            uploadDone = min(uploadDone + 1, uploadTotal)
            status = .uploading(done: uploadDone, total: uploadTotal)
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
