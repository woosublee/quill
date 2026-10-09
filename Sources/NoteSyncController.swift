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

    @Published private(set) var status: NoteSyncStatus = .off
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isTurningOn = false
    @Published private(set) var isSyncingNow = false
    let unavailableReason: NoteSyncUnavailableReason?
    var onRemoteChange: ((NoteSyncRemoteChange) -> Void)?

    private let defaults: UserDefaults
    private let createZone: () async throws -> Void
    private let localAudioURL: (String) -> URL?
    private let makeEngine: (NoteSyncEngineEvents) -> NoteSyncEngineHandle?
    private weak var store: NoteSyncLocalStore?
    private var engine: NoteSyncEngineHandle?
    private var coordinator: NoteSyncCoordinator?

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
        if isEnabled { startEngine(initialUpload: isReplacement) }
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

    /// Sync Now in Settings. A press while it runs does nothing.
    func syncNow() async {
        guard let engine, !isSyncingNow else { return }
        isSyncingNow = true
        defer { isSyncingNow = false }
        await engine.syncNow()
    }

    private func startEngine(initialUpload: Bool) {
        guard let store, store.isReadyForSync,
              let engine = makeEngine(NoteSyncEngineEvents(remoteChange: { [weak self] change in
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
            coordinator.startInitialUpload()
        } else {
            coordinator.resumeAudioUploads()
        }
    }

    private func startOver() {
        guard isEnabled, coordinator != nil else { return }
        print("[NoteSync] Starting over after a record couldn't be saved")
        stopEngine(forgetState: true)
        startEngine(initialUpload: true)
    }

    private func stopEngine(forgetState: Bool) {
        coordinator?.stop()
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
