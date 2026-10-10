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
    /// Deletes the notes from iCloud, then their audio. Returns false when
    /// the notes are gone but the audio couldn't be deleted.
    func deleteAllFromICloud() async throws -> Bool
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

/// What became of audio a Turn Off and Delete from iCloud left behind.
enum NoteSyncLeftoverAudio: Equatable {
    case deleted
    /// Not this Mac's to delete any more: iCloud holds notes again (another
    /// Mac turned sync on and uses the audio zone).
    case inUse
    /// iCloud couldn't be reached.
    case failed
}

/// Why Turn Off and Delete from iCloud deleted nothing, leaving sync on.
enum NoteSyncTurnOffFailure: Error, Equatable {
    case unreachable
    /// Paused with no engine, and the account sync runs in isn't known, so
    /// it can't be told apart from another signed-in account.
    case accountUnknown
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
    /// The accounts where Turn Off and Delete from iCloud deleted the notes
    /// but not their audio ("" for an account that couldn't be read): the
    /// audio zone is deleted again, in the account signed in, at launch and
    /// when Settings opens.
    static let audioLeftInICloudKey = "iCloudNoteSyncAudioLeftInICloud"
    /// The account sync runs in (a hash, see `accountID`), read when it is
    /// turned on or once its engine starts. Turn Off and Delete without an
    /// engine, which hears no account change, deletes only in this one.
    static let syncAccountKey = "iCloudNoteSyncAccount"
    /// Set when Turn Off and Delete couldn't write note history (it can't be
    /// opened): its change tags and audio markers go once it is attached.
    static let clearTagsOnAttachKey = "iCloudNoteSyncClearTagsOnAttach"

    @Published private(set) var status: NoteSyncStatus = .off
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isTurningOn = false
    @Published private(set) var isSyncingNow = false
    /// Why the last Turn Off and Delete from iCloud failed.
    @Published private(set) var turnOffFailure: NoteSyncTurnOffFailure?
    /// Audio from a Turn Off and Delete from iCloud is still in iCloud.
    @Published private(set) var audioLeftInICloud: Bool
    let unavailableReason: NoteSyncUnavailableReason?
    var onRemoteChange: ((NoteSyncRemoteChange) -> Void)?
    /// The engine stopped (sync turned off, or stopped by itself): audio
    /// downloads stop with it, since sync off means no talking to iCloud.
    var onEngineStop: (() -> Void)?

    private let defaults: UserDefaults
    private let createZone: () async throws -> Void
    private let deleteLeftoverAudioZone: () async -> NoteSyncLeftoverAudio
    /// Turn Off and Delete from iCloud while sync is paused with no engine.
    private let deleteAllWithoutEngine: () async throws -> Bool
    /// Removes the engine's saved state and outbox, which stopping a running
    /// engine does itself.
    private let removeEngineFiles: () -> Void
    /// While Turn Off and Delete runs without an engine, none may start; a
    /// start held back meanwhile (with its initial upload) goes ahead if the
    /// delete fails.
    private var isDeletingFromICloud = false
    private var heldBackStart: Bool?
    private var isLearningAccount = false
    /// A Turn Off in progress, and whether it deletes from iCloud; another
    /// press waits for it.
    private var turnOffInProgress: (task: Task<Bool, Never>, deletes: Bool)?
    /// A hash telling iCloud accounts apart, or nil when it can't be read.
    private let accountID: () async -> String?
    /// A delete of leftover audio in progress; turning on waits for it, so
    /// it can't delete the zone turning on just made.
    private var audioZoneDelete: Task<Void, Never>?
    private let localAudioURL: (String) -> URL?
    private let makeEngine: (NoteSyncEngineEvents) -> NoteSyncEngineHandle?
    private weak var store: NoteSyncLocalStore?
    private var engine: NoteSyncEngineHandle?
    private var coordinator: NoteSyncCoordinator?
    /// When sync last started over because a fetched note couldn't be
    /// saved here (or Sync Now restarted it): another failure within
    /// `startOverWindow` pauses sync instead.
    private var lastStartOver: Date?
    static let startOverWindow: TimeInterval = 30 * 60
    private let now: () -> Date

    init(
        defaults: UserDefaults = .standard,
        unavailableReason: NoteSyncUnavailableReason? = NoteSyncAvailability.current(),
        createZone: @escaping () async throws -> Void,
        deleteLeftoverAudio: @escaping () async -> NoteSyncLeftoverAudio = { .deleted },
        deleteAllWithoutEngine: @escaping () async throws -> Bool = { throw NoteSyncEngineError.notRunning },
        removeEngineFiles: @escaping () -> Void = {},
        accountID: @escaping () async -> String? = { nil },
        localAudioURL: @escaping (String) -> URL? = { _ in nil },
        now: @escaping () -> Date = Date.init,
        makeEngine: @escaping (NoteSyncEngineEvents) -> NoteSyncEngineHandle?
    ) {
        self.now = now
        self.defaults = defaults
        self.unavailableReason = unavailableReason
        self.createZone = createZone
        self.deleteLeftoverAudioZone = deleteLeftoverAudio
        self.deleteAllWithoutEngine = deleteAllWithoutEngine
        self.removeEngineFiles = removeEngineFiles
        self.accountID = accountID
        audioLeftInICloud = !(defaults.stringArray(forKey: Self.audioLeftInICloudKey) ?? []).isEmpty
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
        // An engine deleting from iCloud is left to finish; the start waits.
        if !isDeletingFromICloud { stopEngine(forgetState: isReplacement) }
        self.store = store
        clearTagsLeftFromADelete()
        if isReplacement { lastStartOver = nil }
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
    /// confirmation: deleting from iCloud loses that audio. Nil when note
    /// history can't be opened, so they can't be counted.
    var notesWithAudioOnlyInICloud: Int? {
        guard let store else { return 0 }
        guard store.isReadyForSync else { return nil }
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
        clearTagsLeftFromADelete()
        _ = await audioZoneDelete?.value
        let account = Task { await accountID() }
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
        // Audio left in this account is used again: its parts aren't sent
        // twice. Audio left in another account still waits for it.
        let current = await account.value
        if let current {
            accountsWithAudioLeft = accountsWithAudioLeft.filter { $0 != current && !$0.isEmpty }
        }
        setEnabled(true)
        defaults.set(current, forKey: Self.syncAccountKey)
        startEngine(initialUpload: true)
        return nil
    }

    /// Returns false, leaving sync on, when deleting from iCloud failed.
    @discardableResult
    func turnOff(deleteFromICloud: Bool) async -> Bool {
        if let running = turnOffInProgress {
            let result = await running.task.value
            // A delete asked for during a plain Turn Off deleted nothing.
            return deleteFromICloud && !running.deletes ? false : result
        }
        let turningOff = Task { await performTurnOff(deleteFromICloud: deleteFromICloud) }
        turnOffInProgress = (turningOff, deleteFromICloud)
        defer { turnOffInProgress = nil }
        return await turningOff.value
    }

    private func performTurnOff(deleteFromICloud: Bool) async -> Bool {
        if deleteFromICloud {
            // No engine starts (or restarts) until this is done.
            isDeletingFromICloud = true
            turnOffFailure = nil
            // With an engine, read alongside the delete, which reaches
            // iCloud just before; without one, it decides where to delete.
            let signedIn = Task { await accountID() }
            let audioDeleted: Bool
            do {
                if let engine {
                    coordinator?.isHoldingRetries = true
                    audioDeleted = try await engine.deleteAllFromICloud()
                } else if let deleted = try await deleteWithoutEngine(signedIn: await signedIn.value) {
                    audioDeleted = deleted
                } else {
                    // Another account is signed in: nothing of it is
                    // deleted, and sync stops as for an account change.
                    print("[NoteSync] Paused: iCloud account changed")
                    clearChangeTags(forgettingAudio: false)
                    finishTurningOff(status: .paused(.accountChanged))
                    return true
                }
            } catch {
                print("[NoteSync] Deleting from iCloud failed")
                turnOffFailure = error as? NoteSyncTurnOffFailure ?? .unreachable
                isDeletingFromICloud = false
                // Sync stays on: a start held back meanwhile goes ahead, or
                // else what a finished sync skipped meanwhile runs now.
                if heldBackStart == nil { coordinator?.stopHoldingRetries() }
                if let initialUpload = heldBackStart {
                    heldBackStart = nil
                    stopEngine(forgetState: initialUpload)
                    startEngine(initialUpload: initialUpload)
                }
                return false
            }
            // iCloud no longer holds these notes.
            clearChangeTags(forgettingAudio: true)
            if !audioDeleted {
                let account = await signedIn.value ?? ""
                accountsWithAudioLeft = Array(Set(accountsWithAudioLeft + [account])).sorted()
            }
        }
        finishTurningOff(status: .off)
        return true
    }

    /// Paused with no engine (notes couldn't be saved here, or history can't
    /// be opened): the zones go directly, and the saved engine state with
    /// them. No engine hears an account change then, so only the account
    /// sync runs in is deleted: nil when another one is signed in.
    private func deleteWithoutEngine(signedIn: String?) async throws -> Bool? {
        guard let synced = defaults.string(forKey: Self.syncAccountKey) else {
            print("[NoteSync] Couldn't tell which iCloud account to delete from")
            throw NoteSyncTurnOffFailure.accountUnknown
        }
        // The signed-in account can't be read: offline, most likely.
        guard let signedIn else { throw NoteSyncTurnOffFailure.unreachable }
        guard signedIn == synced else { return nil }
        return try await deleteAllWithoutEngine()
    }

    /// Its iCloud data was deleted while history couldn't be written: the
    /// change tags and audio markers go once it can be.
    private func clearTagsLeftFromADelete() {
        guard let store, store.isReadyForSync, defaults.bool(forKey: Self.clearTagsOnAttachKey) else { return }
        store.clearChangeTags(forgettingAudio: true)
        defaults.removeObject(forKey: Self.clearTagsOnAttachKey)
    }

    /// iCloud no longer holds what the change tags point at. History that
    /// can't be opened can't be written now; it forgets them once attached.
    private func clearChangeTags(forgettingAudio: Bool) {
        if let store, store.isReadyForSync {
            store.clearChangeTags(forgettingAudio: forgettingAudio)
        } else {
            defaults.set(true, forKey: Self.clearTagsOnAttachKey)
        }
    }

    /// The end of Turn Off, or of a Turn Off that found another account.
    private func finishTurningOff(status newStatus: NoteSyncStatus) {
        isDeletingFromICloud = false
        turnOffFailure = nil
        heldBackStart = nil
        // Without an engine, nothing else removes its saved state.
        if engine == nil { removeEngineFiles() }
        stopEngine(forgetState: true)
        setEnabled(false)
        defaults.removeObject(forKey: Self.needsFullStartKey)
        lastStartOver = nil
        status = newStatus
    }

    func handleLocalChanges(_ changes: [PipelineHistoryChange]) {
        coordinator?.handleLocalChanges(changes)
    }

    /// At launch and when Settings opens: audio a Turn Off and Delete from
    /// iCloud left behind is deleted again, while sync stays off.
    /// Only audio left in the signed-in account is deleted (or, when an
    /// account couldn't be read back then, audio the notes zone check says
    /// nobody uses); audio left in another account waits for it.
    func deleteLeftoverAudio() async {
        guard audioLeftInICloud, unavailableReason == nil, !isEnabled, !isTurningOn, audioZoneDelete == nil else { return }
        let delete = Task { await deleteLeftoverAudioInSignedInAccount() }
        audioZoneDelete = delete
        await delete.value
        audioZoneDelete = nil
    }

    private func deleteLeftoverAudioInSignedInAccount() async {
        let current = await accountID()
        guard let entry = [current, ""].compactMap({ $0 }).first(where: accountsWithAudioLeft.contains) else {
            print("[NoteSync] Audio left in iCloud waits for the account it was left in")
            return
        }
        switch await deleteLeftoverAudioZone() {
        case .deleted, .inUse:
            accountsWithAudioLeft.removeAll { $0 == entry }
        case .failed:
            print("[NoteSync] Audio left in iCloud still couldn't be deleted")
        }
    }

    private var accountsWithAudioLeft: [String] {
        get { defaults.stringArray(forKey: Self.audioLeftInICloudKey) ?? [] }
        set {
            audioLeftInICloud = !newValue.isEmpty
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.audioLeftInICloudKey)
            } else {
                defaults.set(newValue, forKey: Self.audioLeftInICloudKey)
            }
        }
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
            lastStartOver = now()
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
        guard !isDeletingFromICloud else {
            heldBackStart = initialUpload || (heldBackStart ?? false)
            return
        }
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
            coordinator.startInitialUpload()
        } else {
            coordinator.resumeAudioUploads()
        }
    }

    private func startOver() {
        guard isEnabled, coordinator != nil else { return }
        if isDeletingFromICloud {
            // Not while the engine deletes from iCloud: sync turns off after,
            // or, if the delete fails, starts over then.
            defaults.set(true, forKey: Self.needsFullStartKey)
            heldBackStart = true
            return
        }
        defaults.set(true, forKey: Self.needsFullStartKey)
        stopEngine(forgetState: true)
        // History that can't be read pauses sync (in startEngine) until it's
        // recovered; a store that fails again pauses it rather than looping.
        if store?.isReadyForSync == true {
            if let last = lastStartOver, now().timeIntervalSince(last) < Self.startOverWindow {
                print("[NoteSync] Paused: notes from iCloud couldn't be saved again")
                status = .paused(.couldNotSaveHere)
                return
            }
            print("[NoteSync] Starting over after a record couldn't be saved")
            lastStartOver = now()
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
        case .upToDate, .paused(.notesFailed):
            // A sync got all the way through, so its engine holds what a
            // full start queued.
            defaults.removeObject(forKey: Self.needsFullStartKey)
            if defaults.string(forKey: Self.syncAccountKey) == nil { learnSyncAccount() }
        case .paused(.accountChanged), .paused(.signedOut), .paused(.deletedElsewhere):
            // Sync starts again only when the user turns it on, so notes
            // never cross into another account.
            stopEngine(forgetState: true)
            setEnabled(false)
        default:
            break
        }
    }

    /// For sync turned on before Quill kept its account, or when it
    /// couldn't be read then. Only after a sync got through: an account
    /// changed while Quill was quit has been reported (and sync turned off)
    /// by then.
    private func learnSyncAccount() {
        guard !isLearningAccount else { return }
        isLearningAccount = true
        let syncing = coordinator
        Task { @MainActor [weak self] in
            defer { self?.isLearningAccount = false }
            guard let self, let account = await self.accountID(), self.isEnabled, self.coordinator === syncing,
                  self.defaults.string(forKey: Self.syncAccountKey) == nil else { return }
            self.defaults.set(account, forKey: Self.syncAccountKey)
        }
    }

    private func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if !enabled { defaults.removeObject(forKey: Self.syncAccountKey) }
    }
}
