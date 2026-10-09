import AppKit
import CloudKit
import Foundation
import Network

/// Drives `CKSyncEngine` for the coordinator: queues changes, builds the
/// records it asks for, and hands back what it fetched and sent. Without
/// push notifications it fetches every minute while sync is on, and right
/// away when the Mac wakes or the network comes back.
@available(macOS 14.0, *)
final class NoteSyncCloudKitEngine: NSObject, NoteSyncEngineHandle, CKSyncEngineDelegate, @unchecked Sendable {
    static let fetchInterval: TimeInterval = 60

    private let stateURL: URL
    private let outbox: URL
    private let events: NoteSyncEngineEvents
    private let database: CKDatabase
    private var syncEngine: CKSyncEngine?
    private weak var coordinator: NoteSyncCoordinator?
    /// Guards `syncEngine`, `isStopped`, `isFetching`, `isDeletingZone`,
    /// `zoneDeleteFailed`, and `zoneTracker`, which CloudKit's queues and the main thread share.
    /// Timers and observers are touched on the main thread only.
    private let lock = NSLock()
    private var isStopped = false
    private var isFetching = false
    private var isDeletingZone = false
    private var zoneDeleteFailed = false
    private let zoneTracker: NoteSyncZoneTracker
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?

    init(stateURL: URL, outbox: URL, zoneMarker: URL, events: NoteSyncEngineEvents) {
        self.stateURL = stateURL
        self.outbox = outbox
        self.events = events
        database = CKContainer(identifier: NoteSyncAvailability.containerIdentifier).privateCloudDatabase
        let isFirstRun = !FileManager.default.fileExists(atPath: stateURL.path)
        zoneTracker = NoteSyncZoneTracker(markerURL: zoneMarker)
        super.init()
        let configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: Self.loadState(from: stateURL),
            delegate: self
        )
        let engine = CKSyncEngine(configuration)
        lock.withLock { syncEngine = engine }
        // A turn-on that quit before the zone was saved saves it again.
        if isFirstRun || zoneTracker.actionForZoneDeletion == .recreateAndUploadAll {
            engine.state.add(pendingDatabaseChanges: [
                .saveZone(CKRecordZone(zoneID: NoteSyncCloudRecord.zoneID()))
            ])
        }
    }

    // MARK: - NoteSyncEngineHandle

    func attach(_ coordinator: NoteSyncCoordinator) {
        self.coordinator = coordinator
    }

    func noteTurnedOnByUser() {
        lock.withLock { zoneTracker.turnedOnByUser() }
    }

    /// Call on the main thread.
    func start() {
        NoteSyncCloudRecord.removeAllOutboxFiles(in: outbox)
        let timer = Timer(timeInterval: Self.fetchInterval, repeats: true) { [weak self] _ in
            self?.fetchNow()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.fetchNow()
        }
        let monitor = NWPathMonitor()
        var wasOffline = false
        monitor.pathUpdateHandler = { [weak self] path in
            let isOnline = path.status == .satisfied
            if isOnline, wasOffline { self?.fetchNow() }
            wasOffline = !isOnline
        }
        monitor.start(queue: DispatchQueue(label: "com.woosublee.quill.note-sync.network"))
        pathMonitor = monitor
        fetchNow()
    }

    func enqueueSaves(_ ids: [UUID]) {
        guard let engine = activeEngine() else { return }
        engine.state.add(pendingRecordZoneChanges: ids.map { .saveRecord(NoteSyncCloudRecord.recordID(for: $0)) })
    }

    func enqueueDeletes(_ ids: [UUID]) {
        guard let engine = activeEngine() else { return }
        engine.state.add(pendingRecordZoneChanges: ids.map { .deleteRecord(NoteSyncCloudRecord.recordID(for: $0)) })
    }

    /// Overlapping calls are coalesced: a fetch already running is enough.
    func fetchNow() {
        guard let engine = activeEngine() else { return }
        lock.lock()
        guard !isFetching else {
            lock.unlock()
            return
        }
        isFetching = true
        lock.unlock()
        Task {
            do {
                try await engine.fetchChanges()
            } catch {
                print("[NoteSync] Fetch failed")
            }
            lock.withLock { isFetching = false }
        }
    }

    /// Deletes the `Notes` zone, and with it every note in iCloud. Queued
    /// uploads are dropped first so nothing recreates the zone, and the
    /// result is checked: a failed delete throws.
    func deleteAllFromICloud() async throws {
        guard let engine = activeEngine() else { throw NoteSyncEngineError.notRunning }
        lock.withLock {
            isDeletingZone = true
            zoneDeleteFailed = false
        }
        defer { lock.withLock { isDeletingZone = false } }
        engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges)
        engine.state.add(pendingDatabaseChanges: [.deleteZone(NoteSyncCloudRecord.zoneID())])
        try await engine.sendChanges()
        let stillPending = engine.state.pendingDatabaseChanges.contains {
            if case .deleteZone(let zoneID) = $0 { return zoneID == NoteSyncCloudRecord.zoneID() }
            return false
        }
        if stillPending || lock.withLock({ zoneDeleteFailed }) {
            throw NoteSyncEngineError.zoneDeleteFailed
        }
    }

    /// Call on the main thread.
    func stop(forgetState: Bool) {
        let engine: CKSyncEngine? = lock.withLock {
            isStopped = true
            // Under the lock, so a state update in flight can't write the
            // file back after it is removed.
            if forgetState {
                try? FileManager.default.removeItem(at: stateURL)
            }
            defer { syncEngine = nil }
            return syncEngine
        }
        timer?.invalidate()
        timer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        NoteSyncCloudRecord.removeAllOutboxFiles(in: outbox)
        if let engine {
            Task { await engine.cancelOperations() }
        }
    }

    // MARK: - CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard activeEngine() === syncEngine else { return }
        switch event {
        case .stateUpdate(let update):
            saveState(update.stateSerialization)

        case .accountChange(let change):
            switch change.changeType {
            case .signIn:
                break
            case .signOut:
                await MainActor.run { coordinator?.handleAccountChange(signedOut: true) }
            case .switchAccounts:
                await MainActor.run { coordinator?.handleAccountChange(signedOut: false) }
            @unknown default:
                break
            }

        case .fetchedDatabaseChanges(let changes):
            let zoneID = NoteSyncCloudRecord.zoneID()
            if changes.deletions.contains(where: { $0.zoneID == zoneID }) {
                switch lock.withLock({ zoneTracker.actionForZoneDeletion }) {
                case .stopSync:
                    await MainActor.run { coordinator?.handleZoneDeleted() }
                case .recreateAndUploadAll:
                    // History from before sync was turned on again.
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                    await MainActor.run { coordinator?.startInitialUpload() }
                }
            }

        case .fetchedRecordZoneChanges(let changes):
            let fetched = changes.modifications.compactMap { modification -> NoteSyncFetched? in
                let record = modification.record
                guard record.recordType == NoteSyncCloudRecord.recordType,
                      let id = NoteSyncCloudRecord.noteID(from: record.recordID) else { return nil }
                return NoteSyncFetched(
                    noteID: id,
                    payload: NoteSyncCloudRecord.payload(of: record),
                    systemFields: NoteSyncCloudRecord.systemFields(of: record)
                )
            }
            let deletions = changes.deletions
                .filter { $0.recordType == NoteSyncCloudRecord.recordType }
                .compactMap { NoteSyncCloudRecord.noteID(from: $0.recordID) }
            await MainActor.run {
                guard let change = coordinator?.handleFetched(fetched, deletions: deletions),
                      change != NoteSyncRemoteChange() else { return }
                events.remoteChange(change)
            }

        case .sentRecordZoneChanges(let sent):
            await handleSent(sent, engine: syncEngine)

        case .sentDatabaseChanges(let sent):
            let zoneID = NoteSyncCloudRecord.zoneID()
            if sent.savedZones.contains(where: { $0.zoneID == zoneID }) {
                lock.withLock { zoneTracker.zoneSaved() }
            }
            if let error = sent.failedZoneDeletes[zoneID], error.code != .zoneNotFound {
                lock.withLock { zoneDeleteFailed = true }
            }

        case .didFetchChanges, .didSendChanges:
            let pending = syncEngine.state.pendingRecordZoneChanges.count
            await MainActor.run { coordinator?.handleFetchFinished(pending: pending) }

        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard activeEngine() === syncEngine else { return nil }
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            await self.record(for: recordID, engine: syncEngine)
        }
    }

    private func record(for recordID: CKRecord.ID, engine: CKSyncEngine) async -> CKRecord? {
        guard let id = NoteSyncCloudRecord.noteID(from: recordID),
              let outgoing = await MainActor.run(body: { coordinator?.outgoing(for: id) }),
              let record = try? NoteSyncCloudRecord.makeRecord(outgoing, outbox: outbox) else {
            // Gone, still in progress, or sync stopped: drop the change.
            engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
        return record
    }

    // MARK: - Private

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine) async {
        var saved: [(UUID, Data)] = []
        var failures: [NoteSyncSendFailure] = []
        var zoneDeletedElsewhere = false
        for record in sent.savedRecords {
            guard let id = NoteSyncCloudRecord.noteID(from: record.recordID) else { continue }
            NoteSyncCloudRecord.removeOutboxFile(for: id, in: outbox)
            saved.append((id, NoteSyncCloudRecord.systemFields(of: record)))
        }
        for failure in sent.failedRecordSaves {
            guard let id = NoteSyncCloudRecord.noteID(from: failure.record.recordID) else { continue }
            NoteSyncCloudRecord.removeOutboxFile(for: id, in: outbox)
            switch failure.error.code {
            case .serverRecordChanged:
                let server = failure.error.serverRecord
                failures.append(.serverChanged(
                    noteID: id,
                    serverPayload: server.flatMap(NoteSyncCloudRecord.payload(of:)),
                    serverSystemFields: server.map(NoteSyncCloudRecord.systemFields(of:)) ?? Data()
                ))
            case .userDeletedZone:
                if lock.withLock({ zoneTracker.actionForZoneDeletion }) == .recreateAndUploadAll {
                    // Deleted before sync was turned on again here.
                    engine.state.add(pendingDatabaseChanges: [
                        .saveZone(CKRecordZone(zoneID: NoteSyncCloudRecord.zoneID()))
                    ])
                    engine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                } else {
                    // Another Mac chose Turn Off and Delete from iCloud: stop
                    // rather than recreate what it deleted.
                    zoneDeletedElsewhere = true
                }
            case .zoneNotFound:
                guard !lock.withLock({ isDeletingZone }) else { continue }
                engine.state.add(pendingDatabaseChanges: [
                    .saveZone(CKRecordZone(zoneID: NoteSyncCloudRecord.zoneID()))
                ])
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
            case .quotaExceeded:
                failures.append(.quotaExceeded(noteID: id))
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
                failures.append(.network(noteID: id))
            default:
                failures.append(.other(noteID: id))
            }
        }
        var deleted: [UUID] = []
        for recordID in sent.deletedRecordIDs {
            if let id = NoteSyncCloudRecord.noteID(from: recordID) { deleted.append(id) }
        }
        for (recordID, error) in sent.failedRecordDeletes {
            guard let id = NoteSyncCloudRecord.noteID(from: recordID) else { continue }
            failures.append(error.code == .unknownItem ? .unknownItemOnDelete(noteID: id) : .other(noteID: id))
        }
        let savedRecords = saved
        let deletedIDs = deleted
        let sendFailures = failures
        let stopForDeletion = zoneDeletedElsewhere
        await MainActor.run {
            guard let coordinator else { return }
            if stopForDeletion {
                coordinator.handleZoneDeleted()
                return
            }
            for (id, fields) in savedRecords { coordinator.handleSaved(id: id, systemFields: fields) }
            for id in deletedIDs { coordinator.handleDeleted(id: id) }
            if !sendFailures.isEmpty { coordinator.handleSendFailures(sendFailures) }
        }
    }

    private func activeEngine() -> CKSyncEngine? {
        lock.lock()
        defer { lock.unlock() }
        return isStopped ? nil : syncEngine
    }

    private static func loadState(from url: URL) -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveState(_ state: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        lock.withLock {
            guard !isStopped else { return }
            try? FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: stateURL, options: .atomic)
        }
    }
}
