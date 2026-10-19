import AppKit
import CloudKit
import CryptoKit
import Foundation
import Network

/// Drives `CKSyncEngine` for the coordinator: queues changes, builds the
/// records it asks for, and hands back what it fetched and sent. Changes
/// from other Macs arrive through CloudKit pushes: the engine asks the
/// server by itself after a push, at start, and when the app comes to the
/// front. On the Production environment pushes brought another Mac's edits
/// within about ten seconds (#509). The fetches asked for here (every
/// minute while sync is on, and when the Mac wakes or the network comes
/// back) reach the server on macOS only once the engine knows something
/// changed, and otherwise return at once. They cost next to nothing and
/// stay as a fallback, and with them whatever runs when a fetch finishes.
@available(macOS 14.0, *)
final class NoteSyncCloudKitEngine: NSObject, NoteSyncEngineHandle, NoteAudioPartFetching, CKSyncEngineDelegate, @unchecked Sendable {
    static let fetchInterval: TimeInterval = 60

    private let stateURL: URL
    private let outbox: URL
    private let events: NoteSyncEngineEvents
    private let database: CKDatabase
    private var syncEngine: CKSyncEngine?
    private weak var coordinator: NoteSyncCoordinator?
    /// Guards `syncEngine`, `isStopped`, `isFetching`, `deleteHold`,
    /// `zoneDeleteFailed` and `deletedZones`, which
    /// CloudKit's queues and the main thread share.
    /// Timers and observers are touched on the main thread only.
    private let lock = NSLock()
    private var isStopped = false
    private var isFetching = false
    private var deleteHold = NoteSyncDeleteHold<CKSyncEngine.PendingRecordZoneChange>()
    private var zoneDeleteFailed = false
    /// Zones this Mac's delete removed, or found already gone.
    private var deletedZones: Set<CKRecordZone.ID> = []
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?

    init(stateURL: URL, outbox: URL, events: NoteSyncEngineEvents) {
        self.stateURL = stateURL
        self.outbox = outbox
        self.events = events
        database = Self.privateDatabase
        super.init()
        let configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: Self.loadState(from: stateURL),
            delegate: self
        )
        let engine = CKSyncEngine(configuration)
        // The zone is made only when the user turns sync on, never here:
        // a restart that forgets its state (starting over, history
        // recovery) must not recreate a zone another Mac deleted.
        lock.withLock { syncEngine = engine }
    }

    /// Makes the `Notes` and `NoteAudio` zones, or keeps them if they're
    /// there. Turning sync on calls this before the engine starts, so the
    /// engine never meets a zone this Mac deleted earlier.
    static func createZone() async throws {
        let database = privateDatabase
        let zones = [
            CKRecordZone(zoneID: NoteSyncCloudRecord.zoneID()),
            CKRecordZone(zoneID: NoteAudioCloudRecord.zoneID())
        ]
        do {
            let result = try await database.modifyRecordZones(saving: zones, deleting: [])
            for zone in zones {
                if case .failure(let error)? = result.saveResults[zone.zoneID] { throw error }
            }
        } catch let error as CKError
                    where error.code == .notAuthenticated || error.code == .accountTemporarilyUnavailable {
            throw NoteSyncTurnOnFailure.signedOut
        }
    }

    // MARK: - NoteSyncEngineHandle

    func attach(_ coordinator: NoteSyncCoordinator) {
        self.coordinator = coordinator
    }

    /// Call on the main thread.
    func start() {
        NoteSyncCloudRecord.removeAllOutboxFiles(in: outbox)
        NoteAudioDownloader.removeDownloadFiles(in: downloadsDirectory)
        // CKSyncEngine fetches by itself when a CloudKit push arrives; it
        // needs the app registered. Silent pushes need no permission prompt.
        // stop() doesn't unregister: sync restarts by stopping and starting,
        // and a new registration can take minutes to reach CloudKit, while
        // a push for a stopped engine does nothing.
        NSApplication.shared.registerForRemoteNotifications()
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
            // Only a change matters; the first update says whether the Mac
            // starts offline.
            let changed = isOnline == wasOffline
            wasOffline = !isOnline
            guard changed else { return }
            Task { @MainActor [weak self] in self?.coordinator?.handleNetworkChange(isOnline: isOnline) }
            if isOnline { self?.fetchNow() }
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

    func cancelDeletes(_ ids: [UUID]) {
        guard let engine = activeEngine() else { return }
        engine.state.remove(pendingRecordZoneChanges: ids.map { .deleteRecord(NoteSyncCloudRecord.recordID(for: $0)) })
    }

    func enqueueAudioSaves(_ parts: [NoteAudioPartID]) {
        guard let engine = activeEngine() else { return }
        engine.state.add(pendingRecordZoneChanges: parts.map { .saveRecord(NoteAudioCloudRecord.recordID(for: $0)) })
    }

    func enqueueAudioDeletes(_ parts: [NoteAudioPartID]) {
        guard let engine = activeEngine() else { return }
        engine.state.add(pendingRecordZoneChanges: parts.map { .deleteRecord(NoteAudioCloudRecord.recordID(for: $0)) })
    }

    func pendingChangeCount() -> Int {
        activeEngine()?.state.pendingRecordZoneChanges.count ?? 0
    }

    func pendingNoteDeletes() -> [UUID] {
        guard let engine = activeEngine() else { return [] }
        return engine.state.pendingRecordZoneChanges.compactMap { change in
            guard case .deleteRecord(let id) = change, NoteAudioCloudRecord.part(from: id) == nil else { return nil }
            return NoteSyncCloudRecord.noteID(from: id)
        }
    }

    func pendingAudioDeletes() -> [NoteAudioPartID] {
        guard let engine = activeEngine() else { return [] }
        return engine.state.pendingRecordZoneChanges.compactMap { change in
            guard case .deleteRecord(let id) = change else { return nil }
            return NoteAudioCloudRecord.part(from: id)
        }
    }

    func pendingAudioSaves() -> [NoteAudioPartID] {
        guard let engine = activeEngine() else { return [] }
        return engine.state.pendingRecordZoneChanges.compactMap { change in
            guard case .saveRecord(let id) = change else { return nil }
            return NoteAudioCloudRecord.part(from: id)
        }
    }

    func cancelAudioDeletes(noteID: UUID) {
        guard let engine = activeEngine() else { return }
        let deletes = engine.state.pendingRecordZoneChanges.filter { change in
            guard case .deleteRecord(let id) = change else { return false }
            return NoteAudioCloudRecord.part(from: id)?.noteID == noteID
        }
        if !deletes.isEmpty { engine.state.remove(pendingRecordZoneChanges: deletes) }
    }

    func cancelAudioDeletes(_ parts: [NoteAudioPartID]) {
        guard let engine = activeEngine(), !parts.isEmpty else { return }
        engine.state.remove(pendingRecordZoneChanges: parts.map { .deleteRecord(NoteAudioCloudRecord.recordID(for: $0)) })
    }

    func cancelAudioSaves(noteID: UUID) {
        guard let engine = activeEngine() else { return }
        let parts = pendingAudioSaves().filter { $0.noteID == noteID }
        engine.state.remove(pendingRecordZoneChanges: parts.map { .saveRecord(NoteAudioCloudRecord.recordID(for: $0)) })
    }

    /// Looks parts up a few hundred at a time, asking for one small field
    /// only. A part iCloud doesn't have, or a missing zone, reads as absent;
    /// any other error throws.
    func existingAudioParts(_ parts: [NoteAudioPartID]) async throws -> Set<NoteAudioPartID> {
        guard activeEngine() != nil else { throw NoteSyncEngineError.notRunning }
        var found: Set<NoteAudioPartID> = []
        var start = 0
        while start < parts.count {
            let chunk = parts[start..<min(start + 200, parts.count)]
            start += 200
            let results: [CKRecord.ID: Result<CKRecord, Error>]
            do {
                results = try await database.records(
                    for: chunk.map(NoteAudioCloudRecord.recordID(for:)),
                    desiredKeys: NoteAudioCloudRecord.lookupKeys
                )
            } catch let error as CKError where Self.isZoneGone(error.code) {
                continue
            }
            for (recordID, result) in results {
                switch result {
                case .success:
                    if let part = NoteAudioCloudRecord.part(from: recordID) { found.insert(part) }
                case .failure(let error):
                    if let code = (error as? CKError)?.code, code == .unknownItem || Self.isZoneGone(code) { continue }
                    throw error
                }
            }
        }
        return found
    }

    /// Where downloaded parts and partial audio wait, beside the outbox.
    private var downloadsDirectory: URL {
        outbox.deletingLastPathComponent().appendingPathComponent("downloads", isDirectory: true)
    }

    /// Downloads one part, reporting progress, and copies its bytes to a new
    /// file under `Sync/downloads` before CloudKit removes its cached copy.
    func fetchAudioPart(_ part: NoteAudioPartID, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard activeEngine() != nil else { throw NoteAudioFetchError.failed }
        let destination = downloadsDirectory
            .appendingPathComponent("\(part.recordName)-\(UUID().uuidString).fetched")
        let operation = CKFetchRecordsOperation(recordIDs: [NoteAudioCloudRecord.recordID(for: part)])
        operation.desiredKeys = [NoteAudioCloudRecord.dataKey]
        operation.qualityOfService = .userInitiated
        operation.perRecordProgressBlock = { _, fraction in progress(fraction) }
        let outcome = FetchOutcome()
        operation.perRecordResultBlock = { _, result in
            switch result {
            case .success(let record):
                guard let asset = record[NoteAudioCloudRecord.dataKey] as? CKAsset, let file = asset.fileURL else {
                    outcome.result = .failure(NoteAudioFetchError.failed)
                    return
                }
                do {
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.copyItem(at: file, to: destination)
                    outcome.result = .success(destination)
                } catch {
                    outcome.result = .failure(NoteAudioFetchError.failed)
                }
            case .failure(let error):
                outcome.result = .failure(Self.fetchError(error))
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                operation.fetchRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        continuation.resume(with: Self.audioFetchResult(part: outcome.result, operationError: nil))
                    case .failure(let error):
                        // A part copied before the operation failed has no
                        // owner now.
                        if case .success(let copied)? = outcome.result { try? FileManager.default.removeItem(at: copied) }
                        if (error as? CKError)?.code == .operationCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else if case .failure(let partError)? = outcome.result {
                            continuation.resume(throwing: partError)
                        } else {
                            continuation.resume(with: Self.audioFetchResult(part: nil, operationError: error))
                        }
                    }
                }
                database.add(operation)
            }
        } onCancel: {
            operation.cancel()
        }
    }

    /// The part a fetch delivers, set from CloudKit's callback queue.
    private final class FetchOutcome: @unchecked Sendable {
        /// Nil until CloudKit reports the part; offline it never does.
        var result: Result<URL, Error>?
    }

    /// The part's own result when CloudKit gave one, otherwise what the
    /// operation's error says (offline fails the whole fetch).
    static func audioFetchResult(part: Result<URL, Error>?, operationError: Error?) -> Result<URL, Error> {
        if let part { return part }
        guard let operationError else { return .failure(NoteAudioFetchError.failed) }
        return .failure(fetchError(operationError))
    }

    private static func fetchError(_ error: Error) -> NoteAudioFetchError {
        if let error = error as? URLError {
            return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost]
                .contains(error.code) ? .offline : .failed
        }
        guard let error = error as? CKError else { return .failed }
        // One part per fetch: its error is the one that counts.
        if error.code == .partialFailure, let partError = error.partialErrorsByItemID?.values.first {
            return fetchError(partError)
        }
        switch error.code {
        case .networkUnavailable, .networkFailure:
            return .offline
        // Gone: a delete took the part, or the iCloud data was deleted.
        case let code where code == .unknownItem || isZoneGone(code):
            return .missing
        default:
            // Including a busy server, which isn't offline: try again.
            return .failed
        }
    }

    /// Lists the audio zone's records, names only, and keeps the parts of
    /// these notes. Used to find parts no marker names, which is rare.
    /// (The daily leftover search lists the whole zone too, so its cost
    /// grows with every part in iCloud.)
    func audioParts(ofNotes ids: Set<UUID>) async throws -> [NoteAudioPartID] {
        try await listAudioParts().map(\.part).filter { ids.contains($0.noteID) }
    }

    func allAudioParts() async throws -> [NoteAudioPartInICloud] {
        try await listAudioParts()
    }

    /// Every part in the audio zone, read from the start of its changes;
    /// only part names and save dates, never the audio.
    private func listAudioParts() async throws -> [NoteAudioPartInICloud] {
        guard activeEngine() != nil else { throw NoteSyncEngineError.notRunning }
        var parts: [NoteAudioPartInICloud] = []
        var token: CKServerChangeToken?
        var moreComing = true
        while moreComing {
            let changes: (
                modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
                deletions: [CKDatabase.RecordZoneChange.Deletion],
                changeToken: CKServerChangeToken,
                moreComing: Bool
            )
            do {
                changes = try await database.recordZoneChanges(
                    inZoneWith: NoteAudioCloudRecord.zoneID(),
                    since: token,
                    desiredKeys: NoteAudioCloudRecord.lookupKeys
                )
            } catch let error as CKError where Self.isZoneGone(error.code) {
                return []
            }
            for (recordID, result) in changes.modificationResultsByID {
                guard let part = NoteAudioCloudRecord.part(from: recordID) else { continue }
                // The last save counts; without a date, a part counts as just
                // saved, so it stays.
                let record = try? result.get().record
                let saved = record?.modificationDate ?? record?.creationDate ?? Date()
                parts.append(NoteAudioPartInICloud(part: part, saved: saved))
            }
            token = changes.changeToken
            moreComing = changes.moreComing
        }
        return parts
    }

    /// A failure that goes away by itself: no network, a busy server, or
    /// an account that needs a moment.
    private static func isPassing(_ code: CKError.Code) -> Bool {
        switch NoteSyncCloudRecord.sendErrorKind(code) {
        case .network, .throttled, .accountNeedsAttention: return true
        default: return false
        }
    }

    func audioOfNotesInICloud(_ ids: Set<UUID>) async throws -> [UUID: NoteAudioInICloud] {
        var notes: [UUID: NoteAudioInICloud] = [:]
        for (id, result) in try await noteRecordsInICloud(ids, timeLimited: false) {
            switch result {
            case .success(let record?):
                notes[id] = NoteAudioInICloud.read(payload: NoteSyncCloudRecord.payload(of: record))
            case .success(nil):
                notes[id] = .noNote
            case .failure(let error as CKError) where Self.isPassing(error.code):
                // Offline or busy for a moment: the search is tried
                // again soon, rather than a day later without this note.
                throw error
            case .failure:
                // This one note stays as it is; the rest go on.
                notes[id] = .unreadable
            }
        }
        return notes
    }

    func noteCopiesInICloud(_ ids: Set<UUID>) async throws -> [UUID: NoteCopyInICloud] {
        var notes: [UUID: NoteCopyInICloud] = [:]
        for (id, result) in try await noteRecordsInICloud(ids, timeLimited: true) {
            switch result {
            case .success(let record?):
                notes[id] = .found(NoteSyncFetched(
                    noteID: id,
                    payload: NoteSyncCloudRecord.payload(of: record),
                    systemFields: NoteSyncCloudRecord.systemFields(of: record)
                ))
            case .success(nil):
                notes[id] = .noNote
            case .failure:
                notes[id] = .failed
            }
        }
        return notes
    }

    /// These notes' records in iCloud, payload only, in batches: nil for a
    /// note iCloud doesn't hold (or no zone), or that one record's error.
    /// `timeLimited` keeps a stalled request from holding up its caller.
    private func noteRecordsInICloud(_ ids: Set<UUID>, timeLimited: Bool) async throws -> [UUID: Result<CKRecord?, Error>] {
        guard activeEngine() != nil else { throw NoteSyncEngineError.notRunning }
        let limit = CKOperation.Configuration()
        limit.timeoutIntervalForRequest = 30
        limit.timeoutIntervalForResource = 60
        var notes: [UUID: Result<CKRecord?, Error>] = [:]
        let all = Array(ids)
        for start in stride(from: 0, to: all.count, by: 100) {
            let batch = all[start..<min(start + 100, all.count)].map(NoteSyncCloudRecord.recordID(for:))
            let results: [CKRecord.ID: Result<CKRecord, Error>]
            do {
                results = timeLimited
                    ? try await database.configuredWith(configuration: limit) { database in
                        try await database.records(for: batch, desiredKeys: NoteSyncCloudRecord.payloadKeys)
                    }
                    : try await database.records(for: batch, desiredKeys: NoteSyncCloudRecord.payloadKeys)
            } catch let error as CKError where Self.isZoneGone(error.code) {
                for recordID in batch { NoteSyncCloudRecord.noteID(from: recordID).map { notes[$0] = .success(nil) } }
                continue
            }
            for (recordID, result) in results {
                guard let id = NoteSyncCloudRecord.noteID(from: recordID) else { continue }
                switch result {
                case .success(let record):
                    notes[id] = .success(record)
                case .failure(let error as CKError) where error.code == .unknownItem || Self.isZoneGone(error.code):
                    notes[id] = .success(nil)
                case .failure(let error):
                    notes[id] = .failure(error)
                }
            }
        }
        return notes
    }

    /// Sync Now: fetches, then sends what is waiting. The fetch reaches the
    /// server only when the engine knows of a change; pushes bring the
    /// rest, so Sync Now is mainly for sending changes that failed again.
    /// Failures are left to the status the engine's events already report.
    func syncNow() async {
        guard let engine = activeEngine() else { return }
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
        } catch {
            print("[NoteSync] Sync Now didn't finish")
        }
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

    /// Deletes the `Notes` zone, then the `NoteAudio` zone, and with them
    /// every note and its audio in iCloud. Queued uploads are dropped first
    /// so nothing recreates a zone. Unless the `Notes` zone is gone it
    /// throws, and nothing was deleted: the audio zone goes only after it,
    /// so notes never point at audio that is gone. Once the `Notes` zone is
    /// gone the engine keeps ignoring missing zones until it is stopped, so
    /// this Mac's own delete never reads as another Mac's.
    func deleteAllFromICloud() async throws -> Bool {
        guard let engine = activeEngine() else { throw NoteSyncEngineError.notRunning }
        lock.withLock {
            deleteHold.begin()
            zoneDeleteFailed = false
            deletedZones = []
        }
        let droppedUploads = engine.state.pendingRecordZoneChanges
        let notesZone = NoteSyncCloudRecord.zoneID()
        do {
            engine.state.remove(pendingRecordZoneChanges: droppedUploads)
            engine.state.add(pendingDatabaseChanges: [.deleteZone(notesZone)])
            try await engine.sendChanges()
            let stillPending = engine.state.pendingDatabaseChanges.contains {
                if case .deleteZone(let zoneID) = $0 { return zoneID == notesZone }
                return false
            }
            if stillPending || lock.withLock({ zoneDeleteFailed }) {
                throw NoteSyncEngineError.zoneDeleteFailed
            }
        } catch {
            // Cancelled first, so the engine can't send it by itself while
            // iCloud is asked below.
            engine.state.remove(pendingDatabaseChanges: [.deleteZone(notesZone)])
            // CloudKit confirmed the zone is gone, so the delete succeeded
            // even though a later step failed. Otherwise iCloud is asked: a
            // request cut off (even one the engine kept to retry) may have
            // gone through all the same, and the zone missing later would
            // read as another Mac's delete.
            var gone = lock.withLock { deletedZones.contains(notesZone) }
            if !gone { gone = await notesZoneExists() == false }
            if !gone {
                // Sync stays on: put back the dropped and held changes, and
                // only then stop counting as deleting, so a send meanwhile
                // is still held rather than read as another Mac's delete.
                let held = lock.withLock { deleteHold.takeHeld() }
                await putBack(droppedUploads + held, engine: engine)
                let late = lock.withLock { deleteHold.undo() }
                await putBack(late, engine: engine)
                throw error
            }
        }
        lock.withLock { deleteHold.finish() }
        // The notes are gone, so sync turns off whatever happens to the
        // audio: staying on would send into a missing zone. If the audio
        // zone stays, it is deleted again at launch, or a turn-on finds its
        // parts and doesn't send them again.
        return await Self.deleteAudioZoneAfterNotes()
    }

    /// Puts back what an undone delete dropped or held, except a change
    /// for a record that has a newer one waiting, and a delete the
    /// coordinator no longer wants (its note came back meanwhile).
    private func putBack(_ changes: [CKSyncEngine.PendingRecordZoneChange], engine: CKSyncEngine) async {
        guard !changes.isEmpty else { return }
        let wanted = await MainActor.run { () -> [CKSyncEngine.PendingRecordZoneChange] in
            guard let coordinator else { return [] }
            return changes.filter { change in
                guard case .deleteRecord(let id) = change else { return true }
                if let part = NoteAudioCloudRecord.part(from: id) { return coordinator.isDeleteStillWanted(part) }
                guard let noteID = NoteSyncCloudRecord.noteID(from: id) else { return false }
                return coordinator.isDeleteStillWanted(noteID: noteID)
            }
        }
        // Read just before adding, so a change queued during the hop wins.
        let waiting = Set(engine.state.pendingRecordZoneChanges.compactMap(Self.recordID(of:)))
        let back = wanted.filter { change in Self.recordID(of: change).map { !waiting.contains($0) } ?? true }
        if !back.isEmpty { engine.state.add(pendingRecordZoneChanges: back) }
    }

    private static func recordID(of change: CKSyncEngine.PendingRecordZoneChange) -> CKRecord.ID? {
        switch change {
        case .saveRecord(let id), .deleteRecord(let id): return id
        @unknown default: return nil
        }
    }

    /// The notes are gone: their audio zone gets two tries.
    private static func deleteAudioZoneAfterNotes() async -> Bool {
        for _ in 0..<2 {
            if await deleteAudioZone() { return true }
        }
        print("[NoteSync] Notes were deleted from iCloud, but their audio couldn't be")
        return false
    }

    static var container: CKContainer {
        CKContainer(identifier: NoteSyncAvailability.containerIdentifier)
    }

    static var privateDatabase: CKDatabase { container.privateCloudDatabase }

    /// Tells iCloud accounts apart, to know whose audio was left behind: a
    /// hash of the account's record name, so the name itself isn't kept.
    static func accountID() async -> String? {
        guard let name = try? await container.userRecordID().recordName else { return nil }
        return SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Finishes deleting audio a Turn Off and Delete from iCloud left in
    /// the signed-in account, unless iCloud holds notes again (another Mac
    /// turned sync on and uses the audio zone).
    static func deleteLeftoverAudio() async -> NoteSyncLeftoverAudio {
        switch await notesZoneExists(in: privateDatabase) {
        case true?: return .inUse
        case nil: return .failed
        case false?: return await deleteAudioZone() ? .deleted : .failed
        }
    }

    /// Turn Off and Delete from iCloud while no engine runs (sync paused
    /// because notes couldn't be saved here, or history can't be opened):
    /// deletes the zones directly. Returns false when the notes are gone but
    /// their audio couldn't be deleted.
    static func deleteAllWithoutEngine() async throws -> Bool {
        let zoneID = NoteSyncCloudRecord.zoneID()
        let result = try await privateDatabase.modifyRecordZones(saving: [], deleting: [zoneID])
        switch result.deleteResults[zoneID] {
        case .success?:
            break
        case .failure(let error)? where (error as? CKError).map({ isZoneGone($0.code) }) ?? false:
            break
        case .failure(let error)?:
            throw error
        case nil:
            throw NoteSyncEngineError.zoneDeleteFailed
        }
        return await deleteAudioZoneAfterNotes()
    }

    /// Deletes the `NoteAudio` zone; true once it's gone.
    private static func deleteAudioZone() async -> Bool {
        let database = privateDatabase
        let zoneID = NoteAudioCloudRecord.zoneID()
        guard let result = try? await database.modifyRecordZones(saving: [], deleting: [zoneID]) else { return false }
        switch result.deleteResults[zoneID] {
        case .success?:
            return true
        case .failure(let error)?:
            return ((error as? CKError)?.code).map(Self.isZoneGone) ?? false
        case nil:
            return false
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
        NoteAudioDownloader.removeDownloadFiles(in: downloadsDirectory)
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
            if changes.deletions.contains(where: { $0.zoneID == zoneID }),
               zoneGoneMeansDeletedElsewhere() {
                await MainActor.run { coordinator?.handleZoneDeleted() }
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
            for zoneID in [NoteSyncCloudRecord.zoneID(), NoteAudioCloudRecord.zoneID()] {
                if sent.deletedZoneIDs.contains(zoneID) {
                    lock.withLock { _ = deletedZones.insert(zoneID) }
                } else if let error = sent.failedZoneDeletes[zoneID] {
                    if Self.isZoneGone(error.code) {
                        lock.withLock { _ = deletedZones.insert(zoneID) }
                    } else {
                        lock.withLock { zoneDeleteFailed = true }
                    }
                }
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
        // A stale audio part is dropped while the batch is built, which can
        // leave it empty; the next part is tried, so one stale part doesn't
        // hold up the rest until the next sync.
        while true {
            let changes = NoteAudioCloudRecord.nextBatch(
                syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
            )
            guard !changes.isEmpty else { return nil }
            let batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
                await self.record(for: recordID, engine: syncEngine)
            }
            guard let batch else { return nil }
            if !batch.recordsToSave.isEmpty || !batch.recordIDsToDelete.isEmpty { return batch }
            // Each pass drops what it built nothing for, so this ends.
            let dropped = !syncEngine.state.pendingRecordZoneChanges.contains { changes.contains($0) }
            guard dropped, activeEngine() === syncEngine else { return batch }
        }
    }

    /// Only notes are fetched. Audio is downloaded when it is needed.
    func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        CKSyncEngine.FetchChangesOptions(
            scope: .zoneIDs([NoteSyncCloudRecord.zoneID()]),
            operationGroup: context.options.operationGroup
        )
    }

    private func record(for recordID: CKRecord.ID, engine: CKSyncEngine) async -> CKRecord? {
        if let part = NoteAudioCloudRecord.part(from: recordID) {
            guard let outgoing = await MainActor.run(body: { coordinator?.outgoingAudio(for: part) }) else {
                // Stale: the audio is gone, already in iCloud, or shorter.
                engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            do {
                return try NoteAudioCloudRecord.makeRecord(outgoing, outbox: outbox)
            } catch {
                // The part file couldn't be cut (disk full, say): retried
                // like a failed send, so the note's audio isn't left short.
                engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                print("[NoteSync] Couldn't prepare an audio part")
                await MainActor.run { coordinator?.handleAudioSendFailures([.failed(part)]) }
                return nil
            }
        }
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
        var savedParts: [NoteAudioPartID] = []
        var audioFailures: [NoteAudioSendFailure] = []
        var partsWithoutZone: [NoteAudioPartID] = []
        for record in sent.savedRecords {
            if let part = NoteAudioCloudRecord.part(from: record.recordID) {
                NoteAudioCloudRecord.removePartFile(for: part, in: outbox)
                savedParts.append(part)
                continue
            }
            guard let id = NoteSyncCloudRecord.noteID(from: record.recordID) else { continue }
            NoteSyncCloudRecord.removeOutboxFile(for: id, in: outbox)
            saved.append((id, NoteSyncCloudRecord.systemFields(of: record)))
        }
        let deletingZone = !zoneGoneMeansDeletedElsewhere()
        var held: [CKSyncEngine.PendingRecordZoneChange] = []
        for failure in sent.failedRecordSaves {
            let recordID = failure.record.recordID
            if let part = NoteAudioCloudRecord.part(from: recordID) {
                NoteAudioCloudRecord.removePartFile(for: part, in: outbox)
                switch NoteSyncSendRoute.route(.part, isSave: true, code: failure.error.code, deletingZone: deletingZone) {
                case .savedAlready: savedParts.append(part)
                case .resendNow: engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                case .holdForOwnDelete: held.append(.saveRecord(recordID))
                case .partWithoutZone: partsWithoutZone.append(part)
                case .quotaExceeded: audioFailures.append(.quotaExceeded(part))
                case .network: audioFailures.append(.network)
                case .accountNeedsAttention: audioFailures.append(.accountNeedsAttention)
                case .failed: audioFailures.append(.failed(part))
                case .nothing: break
                case .zoneDeletedElsewhere, .serverChanged, .unknownItemOnSave, .unknownItemOnDelete:
                    assertionFailure("No such route for a part save")
                }
                continue
            }
            guard let id = NoteSyncCloudRecord.noteID(from: recordID) else { continue }
            NoteSyncCloudRecord.removeOutboxFile(for: id, in: outbox)
            switch NoteSyncSendRoute.route(.note, isSave: true, code: failure.error.code, deletingZone: deletingZone) {
            case .serverChanged:
                let server = failure.error.serverRecord
                failures.append(.serverChanged(
                    noteID: id,
                    serverPayload: server.flatMap(NoteSyncCloudRecord.payload(of:)),
                    serverSystemFields: server.map(NoteSyncCloudRecord.systemFields(of:)) ?? Data()
                ))
            case .holdForOwnDelete: held.append(.saveRecord(recordID))
            case .zoneDeletedElsewhere: zoneDeletedElsewhere = true
            case .quotaExceeded: failures.append(.quotaExceeded(noteID: id))
            case .network: failures.append(.network(noteID: id))
            case .accountNeedsAttention: failures.append(.accountNeedsAttention)
            case .unknownItemOnSave: failures.append(.unknownItemOnSave(noteID: id))
            case .failed: failures.append(.other(noteID: id))
            case .nothing: break
            case .savedAlready, .resendNow, .partWithoutZone, .unknownItemOnDelete:
                assertionFailure("No such route for a note save")
            }
        }
        var deleted: [UUID] = []
        var deletedParts: [NoteAudioPartID] = []
        for recordID in sent.deletedRecordIDs {
            if let part = NoteAudioCloudRecord.part(from: recordID) {
                deletedParts.append(part)
                continue
            }
            if let id = NoteSyncCloudRecord.noteID(from: recordID) { deleted.append(id) }
        }
        for (recordID, error) in sent.failedRecordDeletes {
            if let part = NoteAudioCloudRecord.part(from: recordID) {
                switch NoteSyncSendRoute.route(.part, isSave: false, code: error.code, deletingZone: deletingZone) {
                case .network: audioFailures.append(.network)
                case .accountNeedsAttention: audioFailures.append(.accountNeedsAttention)
                case .failed: audioFailures.append(.deleteFailed(part))
                case .nothing: break // already gone, or the engine retries it
                case .savedAlready, .resendNow, .holdForOwnDelete, .zoneDeletedElsewhere, .partWithoutZone,
                     .serverChanged, .quotaExceeded, .unknownItemOnSave, .unknownItemOnDelete:
                    assertionFailure("No such route for a part delete")
                }
                continue
            }
            guard let id = NoteSyncCloudRecord.noteID(from: recordID) else { continue }
            switch NoteSyncSendRoute.route(.note, isSave: false, code: error.code, deletingZone: deletingZone) {
            case .holdForOwnDelete: held.append(.deleteRecord(recordID))
            case .zoneDeletedElsewhere: zoneDeletedElsewhere = true
            case .network: failures.append(.network(noteID: id))
            case .accountNeedsAttention: failures.append(.accountNeedsAttention)
            case .unknownItemOnDelete: failures.append(.unknownItemOnDelete(noteID: id))
            case .failed: failures.append(.deleteFailed(noteID: id))
            case .nothing: break // the engine retries it
            case .savedAlready, .resendNow, .partWithoutZone, .serverChanged, .quotaExceeded, .unknownItemOnSave:
                assertionFailure("No such route for a note delete")
            }
        }
        if !held.isEmpty {
            // Put back if this Mac's delete from iCloud is undone; if it was
            // undone already, put back now.
            let late = lock.withLock { deleteHold.hold(held) }
            await putBack(late, engine: engine)
        }
        if !partsWithoutZone.isEmpty, !zoneDeletedElsewhere {
            // The audio zone is missing. If the notes zone is gone too,
            // another Mac deleted everything: stop rather than recreate it.
            // Otherwise this Mac turned sync on before audio synced: the
            // zone is made, and the parts tried again within the retry limit.
            switch await notesZoneExists() {
            case false?:
                zoneDeletedElsewhere = true
            case true?:
                engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: NoteAudioCloudRecord.zoneID()))])
                audioFailures += partsWithoutZone.map { .failed($0) }
            case nil:
                audioFailures += partsWithoutZone.map { .failed($0) }
            }
        }
        let savedRecords = saved
        let deletedIDs = deleted
        let partsDeleted = deletedParts
        let sendFailures = failures
        let stopForDeletion = zoneDeletedElsewhere
        let audioFailureList = audioFailures
        let wentThrough = !saved.isEmpty || !deleted.isEmpty || !savedParts.isEmpty || !deletedParts.isEmpty
        await MainActor.run {
            guard let coordinator else { return }
            if stopForDeletion {
                coordinator.handleZoneDeleted()
                return
            }
            if wentThrough { coordinator.handleChangesWentThrough() }
            for (id, fields) in savedRecords { coordinator.handleSaved(id: id, systemFields: fields) }
            for id in deletedIDs { coordinator.handleDeleted(id: id) }
            for part in partsDeleted { coordinator.handleAudioPartDeleted(part) }
            if !sendFailures.isEmpty { coordinator.handleSendFailures(sendFailures) }
            if !audioFailureList.isEmpty { coordinator.handleAudioSendFailures(audioFailureList) }
            coordinator.handleSendApplied()
        }
        guard !stopForDeletion, let coordinator, !savedParts.isEmpty else { return }
        // Checking iCloud and hashing the file take a while; the engine
        // goes on sending meanwhile.
        Task { @MainActor in
            for part in savedParts {
                await coordinator.handleAudioPartSaved(part)
            }
        }
    }

    /// Whether iCloud has the notes zone; nil when it couldn't be asked.
    private func notesZoneExists() async -> Bool? {
        await Self.notesZoneExists(in: database)
    }

    private static func notesZoneExists(in database: CKDatabase) async -> Bool? {
        do {
            _ = try await database.recordZone(for: NoteSyncCloudRecord.zoneID())
            return true
        } catch let error as CKError where isZoneGone(error.code) {
            return false
        } catch {
            return nil
        }
    }

    /// The zone isn't there: never made, deleted by Quill, or deleted by
    /// the user in System Settings.
    private static func isZoneGone(_ code: CKError.Code) -> Bool {
        code == .zoneNotFound || code == .userDeletedZone
    }

    /// The zone existed when sync started, so a missing one means another
    /// Mac chose Turn Off and Delete from iCloud: stop rather than recreate
    /// what it deleted. During this Mac's own delete it means nothing.
    private func zoneGoneMeansDeletedElsewhere() -> Bool {
        !lock.withLock { deleteHold.isDeleting }
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
