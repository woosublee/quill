import Foundation

/// The engine the controller drives. `NoteSyncCloudKitEngine` is the real
/// one; tests use a fake.
protocol NoteSyncEngineHandle: NoteSyncEngineClient {
    func attach(_ coordinator: NoteSyncCoordinator)
    /// Starts syncing: removes payload files left from an earlier run,
    /// schedules regular fetches, and fetches once.
    func start()
    func fetchNow()
    func deleteAllFromICloud() async throws
    func stop(forgetState: Bool)
}

enum NoteSyncEngineError: Error {
    case notRunning
    case zoneDeleteFailed
}

struct NoteSyncEngineEvents {
    let remoteChange: @MainActor (NoteSyncRemoteChange) -> Void
}

/// iCloud sync on and off, its status for Settings, and the engine's life.
/// Sync is off until the user turns it on; an account change or a deletion
/// from another Mac turns it off again, keeping every local note.
@MainActor
final class NoteSyncController: ObservableObject {
    static let enabledKey = "iCloudNoteSyncEnabled"

    @Published private(set) var status: NoteSyncStatus = .off
    @Published private(set) var isEnabled: Bool
    let unavailableReason: NoteSyncUnavailableReason?
    var onRemoteChange: ((NoteSyncRemoteChange) -> Void)?

    private let defaults: UserDefaults
    private let makeEngine: (NoteSyncEngineEvents) -> NoteSyncEngineHandle?
    private weak var store: NoteSyncLocalStore?
    private var engine: NoteSyncEngineHandle?
    private var coordinator: NoteSyncCoordinator?

    init(
        defaults: UserDefaults = .standard,
        unavailableReason: NoteSyncUnavailableReason? = NoteSyncAvailability.current(),
        makeEngine: @escaping (NoteSyncEngineEvents) -> NoteSyncEngineHandle?
    ) {
        self.defaults = defaults
        self.unavailableReason = unavailableReason
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
        if isEnabled { startEngine(initialUpload: isReplacement) }
    }

    var syncableNoteCount: Int {
        store?.syncableNoteIDs().count ?? 0
    }

    func turnOn() {
        guard unavailableReason == nil, store != nil, !isEnabled else { return }
        setEnabled(true)
        startEngine(initialUpload: true)
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
            store?.clearAllSyncSystemFields()
        }
        stopEngine(forgetState: true)
        setEnabled(false)
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

    private func startEngine(initialUpload: Bool) {
        guard let store, store.isReadyForSync,
              let engine = makeEngine(NoteSyncEngineEvents(remoteChange: { [weak self] change in
                  self?.onRemoteChange?(change)
              })) else { return }
        let coordinator = NoteSyncCoordinator(store: store, engine: engine)
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
        if initialUpload { coordinator.startInitialUpload() }
    }

    private func startOver() {
        guard isEnabled, coordinator != nil else { return }
        print("[NoteSync] Starting over after a record couldn't be saved")
        stopEngine(forgetState: true)
        startEngine(initialUpload: true)
    }

    private func stopEngine(forgetState: Bool) {
        engine?.stop(forgetState: forgetState)
        engine = nil
        coordinator = nil
    }

    private func coordinatorStatusChanged(_ newStatus: NoteSyncStatus) {
        status = newStatus
        switch newStatus {
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
