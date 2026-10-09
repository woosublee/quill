import Foundation

/// What the coordinator needs from the note store. `PipelineHistoryStore`
/// provides it; tests use a fake.
protocol NoteSyncLocalStore: AnyObject {
    func syncRecord(id: UUID) -> NoteSyncRecord?
    func syncSystemFields(id: UUID) -> Data?
    func setSyncSystemFields(_ data: Data?, id: UUID)
    func clearAllSyncSystemFields()
    func syncableNoteIDs() -> [UUID]
    func isSyncable(id: UUID) -> Bool
    func applySynced(_ record: NoteSyncRecord, systemFields: Data?) throws -> NoteSyncApplyResult
    func removeSynced(id: UUID) throws -> DeletedPipelineHistoryAssets?
}

extension PipelineHistoryStore: NoteSyncLocalStore {}

/// The sync engine's pending changes, as the coordinator sees them.
protocol NoteSyncEngineClient: AnyObject {
    func enqueueSaves(_ ids: [UUID])
    func enqueueDeletes(_ ids: [UUID])
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
        guard store.isSyncable(id: id), let record = store.syncRecord(id: id) else { return nil }
        return NoteSyncOutgoing(record: record, systemFields: store.syncSystemFields(id: id))
    }

    func handleSaved(id: UUID, systemFields: Data) {
        store.setSyncSystemFields(systemFields, id: id)
        if case .uploading = status {
            uploadDone = min(uploadDone + 1, uploadTotal)
            status = .uploading(done: uploadDone, total: uploadTotal)
        }
    }

    func handleDeleted(id: UUID) {
        store.setSyncSystemFields(nil, id: id)
    }

    func handleSendFailures(_ failures: [NoteSyncSendFailure]) {
        var quotaCount = 0
        var offline = false
        var resend: [UUID] = []
        for failure in failures {
            switch failure {
            case .serverChanged(let id, let payload, let serverFields):
                let server = payload.flatMap { try? NoteSyncPayload.decode($0) }
                guard let server, server.noteID == id else {
                    store.setSyncSystemFields(serverFields, id: id)
                    resend.append(id)
                    continue
                }
                switch try? store.applySynced(server, systemFields: serverFields) {
                case .updated(needsUpload: false)?:
                    break
                case .inserted?, .updated(needsUpload: true)?:
                    resend.append(id)
                case nil:
                    store.setSyncSystemFields(serverFields, id: id)
                    resend.append(id)
                }
            case .quotaExceeded:
                quotaCount += 1
            case .network:
                offline = true
            case .unknownItemOnDelete(let id):
                store.setSyncSystemFields(nil, id: id)
            case .other:
                break
            }
        }
        if !resend.isEmpty, !isStopped { engine.enqueueSaves(resend) }
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
        var needsUpload: [UUID] = []
        for fetched in records {
            guard let payload = fetched.payload,
                  let record = try? NoteSyncPayload.decode(payload),
                  record.noteID == fetched.noteID else {
                change.skipped += 1
                continue
            }
            do {
                switch try store.applySynced(record, systemFields: fetched.systemFields) {
                case .inserted, .updated(needsUpload: false):
                    change.changed.append(record.noteID)
                case .updated(needsUpload: true):
                    change.changed.append(record.noteID)
                    needsUpload.append(record.noteID)
                }
            } catch {
                change.skipped += 1
            }
        }
        for id in deletions {
            if let assets = try? store.removeSynced(id: id) {
                change.purged.append(assets)
            }
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
        if case .uploading = status, uploadDone < uploadTotal, pending > 0 { return }
        if pending == 0 {
            status = .upToDate(now())
        } else if case .paused(.offline) = status {
            // Back online with changes still to send.
            status = .starting
        }
    }

    func handleAccountChange(signedOut: Bool) {
        store.clearAllSyncSystemFields()
        status = .paused(signedOut ? .signedOut : .accountChanged)
        print("[NoteSync] Paused: iCloud account \(signedOut ? "signed out" : "changed")")
    }

    func handleZoneDeleted() {
        store.clearAllSyncSystemFields()
        status = .paused(.deletedElsewhere)
        print("[NoteSync] Paused: iCloud data was deleted from another Mac")
    }
}
