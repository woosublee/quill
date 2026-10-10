import Foundation

/// The engine the controller drives. `NoteSyncCloudKitEngine` is the real
/// one; tests use a fake.
protocol NoteSyncEngineHandle: NoteSyncEngineClient {
    func attach(_ coordinator: NoteSyncCoordinator)
    /// Starts syncing: removes payload files left from an earlier run,
    /// schedules regular fetches, and fetches once.
    func start()
    func fetchNow()
    /// Fetches, then sends what is waiting, and returns when both finished.
    func syncNow() async
    func deleteAllFromICloud() async throws
    func stop(forgetState: Bool)
}

enum NoteSyncEngineError: Error {
    case notRunning
    case zoneDeleteFailed
}

/// Why turning sync on didn't happen. `createZone` throws one of these;
/// any other error reads as `.unreachable`.
enum NoteSyncTurnOnFailure: Error, Equatable {
    case unreachable
    /// Signed out of iCloud, or iCloud wants the password again.
    case signedOut
    /// The note store can't save right now (history recovery, for example).
    case notReady
}

struct NoteSyncEngineEvents {
    let remoteChange: @MainActor (NoteSyncRemoteChange) -> Void
}

/// iCloud sync on and off, its status for Settings, and the engine's life.
/// Sync is off until the user turns it on; an account change or a deletion
/// from another Mac turns it off again, keeping every local note.
/// Turning on makes the iCloud zone first, so once sync runs, a missing
/// zone always means another Mac deleted it.
@MainActor
final class NoteSyncController: ObservableObject {
    static let enabledKey = "iCloudNoteSyncEnabled"
    /// Set while sync is on but its engine state was dropped: the next start
    /// sends every note, since changes made meanwhile weren't queued.
    static let needsFullStartKey = "iCloudNoteSyncNeedsFullStart"

    @Published private(set) var status: NoteSyncStatus = .off
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isTurningOn = false
    @Published private(set) var isSyncingNow = false
    let unavailableReason: NoteSyncUnavailableReason?
    var onRemoteChange: ((NoteSyncRemoteChange) -> Void)?
    /// The engine stopped (sync turned off, or stopped by itself): audio
    /// downloads stop with it, since sync off means no talking to iCloud.
    var onEngineStop: (() -> Void)?

    private let defaults: UserDefaults
    private let createZone: () async throws -> Void
    private let localAudioURL: (String) -> URL?
    private let makeEngine: (NoteSyncEngineEvents) -> NoteSyncEngineHandle?
    private weak var store: NoteSyncLocalStore?
    private var engine: NoteSyncEngineHandle?
    private var coordinator: NoteSyncCoordinator?
    /// Sync started over because a fetched note couldn't be saved here, and
    /// hasn't been up to date since: another failure pauses it instead.
    private var startedOver = false

    init(
        defaults: UserDefaults = .standard,
        unavailableReason: NoteSyncUnavailableReason? = NoteSyncAvailability.current(),
        createZone: @escaping () async throws -> Void,
        localAudioURL: @escaping (String) -> URL? = { _ in nil },
        makeEngine: @escaping (NoteSyncEngineEvents) -> NoteSyncEngineHandle?
    ) {
        self.defaults = defaults
        self.unavailableReason = unavailableReason
        self.createZone = createZone
        self.localAudioURL = localAudioURL
        self.makeEngine = makeEngine
        isEnabled = unavailableReason == nil && defaults.bool(forKey: Self.enabledKey)
    }

    /// Points sync at the note store. Called again when the store is
    /// replaced (history recovery); the engine restarts on the new one.
    func attach(store: NoteSyncLocalStore) {
        guard self.store !== store else { return }
        let isReplacement = self.store != nil
        // A replaced store (history recovery) doesn't hold what the old one
        // synced, so its sync starts over: everything up, everything down.
        stopEngine(forgetState: isReplacement)
        self.store = store
        if isReplacement { startedOver = false }
        if isEnabled { startEngine(initialUpload: isReplacement || defaults.bool(forKey: Self.needsFullStartKey)) }
    }

    var syncableNoteCount: Int {
        store?.syncableNoteIDs().count ?? 0
    }

    /// Audio the first upload sends, for the turn-on confirmation: audio on
    /// this Mac that isn't in iCloud yet.
    var uploadAudioByteCount: Int64 {
        guard let store else { return 0 }
        return store.syncableNoteIDs().reduce(Int64(0)) { total, id in
            guard store.audioManifest(id: id) == nil else { return total }
            return total + (store.localAudioFile(id: id, resolve: localAudioURL)?.bytes ?? 0)
        }
    }

    /// Notes whose audio is in iCloud but not on this Mac, for the turn-off
    /// confirmation: deleting from iCloud loses that audio.
    var notesWithAudioOnlyInICloud: Int {
        guard let store else { return 0 }
        return store.syncableNoteIDs().filter { id in
            store.audioManifest(id: id) != nil && store.localAudioFile(id: id, resolve: localAudioURL) == nil
        }.count
    }

    /// Returns why sync stayed off, or nil once it is on. The status from
    /// before (such as why sync stopped) stays when turning on fails.
    @discardableResult
    func turnOn() async -> NoteSyncTurnOnFailure? {
        guard unavailableReason == nil, !isEnabled, !isTurningOn else { return nil }
        guard store?.isReadyForSync == true else { return .notReady }
        let previousStatus = status
        isTurningOn = true
        status = .starting
        defer { isTurningOn = false }
        do {
            try await createZone()
        } catch {
            print("[NoteSync] Couldn't create the iCloud zone")
            status = previousStatus
            return error as? NoteSyncTurnOnFailure ?? .unreachable
        }
        guard store?.isReadyForSync == true else {
            status = previousStatus
            return .notReady
        }
        setEnabled(true)
        startEngine(initialUpload: true)
        return nil
    }

    /// Returns false, leaving sync on, when deleting from iCloud failed.
    @discardableResult
    func turnOff(deleteFromICloud: Bool) async -> Bool {
        if deleteFromICloud {
            do {
                guard let engine else { throw NoteSyncEngineError.notRunning }
                try await engine.deleteAllFromICloud()
            } catch {
                print("[NoteSync] Deleting from iCloud failed")
                return false
            }
            // iCloud no longer holds these notes.
            store?.clearChangeTags(forgettingAudio: true)
        }
        stopEngine(forgetState: true)
        setEnabled(false)
        defaults.removeObject(forKey: Self.needsFullStartKey)
        startedOver = false
        status = .off
        return true
    }

    func handleLocalChanges(_ changes: [PipelineHistoryChange]) {
        coordinator?.handleLocalChanges(changes)
    }

    /// Fetches now when sync is on: at launch, and when notes or Settings open.
    func fetchSoon() {
        engine?.fetchNow()
    }

    /// A download found a part missing: a sync may bring a newer marker,
    /// and the note's marker is checked against iCloud.
    func audioMissing(noteID: UUID) {
        fetchSoon()
        coordinator?.handleAudioMissing(noteID: noteID)
    }

    /// What downloads note audio, while sync runs.
    var audioPartFetcher: NoteAudioPartFetching? {
        engine as? NoteAudioPartFetching
    }

    /// Sync Now in Settings: changes that failed are tried again, and sync
    /// paused for notes it couldn't save here starts over. A press while it
    /// runs does nothing.
    func syncNow() async {
        guard isEnabled, !isSyncingNow else { return }
        if engine == nil, status == .paused(.couldNotSaveHere) {
            startEngine(initialUpload: true)
            return
        }
        guard let engine else { return }
        isSyncingNow = true
        defer { isSyncingNow = false }
        coordinator?.retryFailedNow()
        await engine.syncNow()
    }

    private func startEngine(initialUpload: Bool) {
        guard let store else { return }
        guard store.isReadyForSync else {
            // Recovered history is attached as a new store, which starts
            // sync again.
            print("[NoteSync] Waiting for note history before syncing")
            status = .paused(.historyUnavailable)
            return
        }
        guard let engine = makeEngine(NoteSyncEngineEvents(remoteChange: { [weak self] change in
            self?.onRemoteChange?(change)
        })) else { return }
        let coordinator = NoteSyncCoordinator(store: store, engine: engine, localAudioURL: localAudioURL)
        coordinator.onStatusChange = { [weak self] status in
            self?.coordinatorStatusChanged(status)
        }
        coordinator.onNeedsFullRefetch = { [weak self] in
            // Restart after the engine's current event returns.
            DispatchQueue.main.async { self?.startOver() }
        }
        engine.attach(coordinator)
        self.engine = engine
        self.coordinator = coordinator
        status = coordinator.status
        engine.start()
        if initialUpload {
            defaults.removeObject(forKey: Self.needsFullStartKey)
            coordinator.startInitialUpload()
        } else {
            coordinator.resumeAudioUploads()
        }
    }

    private func startOver() {
        guard isEnabled, coordinator != nil else { return }
        defaults.set(true, forKey: Self.needsFullStartKey)
        stopEngine(forgetState: true)
        // History that can't be read pauses sync (in startEngine) until it's
        // recovered; a store that fails again pauses it rather than looping.
        if store?.isReadyForSync == true {
            if startedOver {
                print("[NoteSync] Paused: notes from iCloud couldn't be saved again")
                status = .paused(.couldNotSaveHere)
                return
            }
            print("[NoteSync] Starting over after a record couldn't be saved")
            startedOver = true
        }
        startEngine(initialUpload: true)
    }

    private func stopEngine(forgetState: Bool) {
        if engine != nil { onEngineStop?() }
        coordinator?.stop()
        engine?.stop(forgetState: forgetState)
        engine = nil
        coordinator = nil
    }

    private func coordinatorStatusChanged(_ newStatus: NoteSyncStatus) {
        status = newStatus
        switch newStatus {
        case .upToDate:
            startedOver = false
        case .paused(.accountChanged), .paused(.signedOut), .paused(.deletedElsewhere):
            // Sync starts again only when the user turns it on, so notes
            // never cross into another account.
            stopEngine(forgetState: true)
            setEnabled(false)
        default:
            break
        }
    }

    private func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
    }
}
