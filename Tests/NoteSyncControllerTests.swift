import Foundation

@main
struct NoteSyncControllerTests {
    /// What the controller reads as now; each `make` sets it back.
    @MainActor static var clock = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    static func main() throws {
        testAvailabilityDecision()
        testStartsOffAndStaysOffWhenUnavailable()
        testTurnOnUploadsEverySyncableNote()
        testRelaunchResumesWithoutUploadingAgain()
        testTurnOffKeepsNotesAndForgetsEngineState()
        testTurnOffAndDeleteFromICloud()
        testAudioLeftInICloudIsDeletedAtLaunch()
        testLeftoverAudioWaitsWhileSyncIsOn()
        testTurnOnWaitsForTheLeftoverAudioDelete()
        testLeftoverAudioInUseAgainIsForgotten()
        testLeftoverAudioIsKeptPerAccount()
        testTurnOnInAnotherAccountKeepsLeftoverAudio()
        testTurnOffInAnotherAccountKeepsTheFirstOnesAudio()
        testUnreadableAccountAtTurnOffIsRecordedAsUnknown()
        testAccountChangeTurnsSyncOff()
        testLocalChangesReachTheEngineOnlyWhileOn()
        testReplacedStoreStartsOverWithFullUpload()
        testUnreadyStoreDoesNotStartSync()
        testDeleteFromICloudWhileHistoryCantBeOpened()
        testDeleteFromICloudWhilePausedForSaving()
        testFailedDeleteWhilePausedKeepsSyncOn()
        testTurnOnCreatesTheZoneBeforeSyncing()
        testTurnOnStaysOffWhenICloudIsUnreachable()
        testTurnOnWaitsForAReadyStore()
        testTurnOnFailureKeepsWhySyncStopped()
        try testConfirmationsCountAudio()
        testSyncNowRunsOnceAtATime()
        testTurningOffStopsAudioDownloads()
        testStoreFailingAgainAfterStartingOverPauses()
        testStartingOverIsAllowedAgainAfterHalfAnHour()
        testRelaunchAfterAPauseUploadsEverything()
        testHistoryLostMidSessionPausesUntilReplaced()
        testSyncNowTriesFailedChangesAgain()
        print("NoteSyncControllerTests passed")
    }

    @MainActor
    static func testConfirmationsCountAudio() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quill-controller-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 300).write(to: dir.appendingPathComponent("here.wav"))
        try Data(count: 200).write(to: dir.appendingPathComponent("uploaded.wav"))
        let store = FakeStore()
        let here = UUID(), uploaded = UUID(), elsewhere = UUID()
        for (id, name) in [(here, "here.wav"), (uploaded, "uploaded.wav"), (elsewhere, "elsewhere.wav")] {
            store.ids.append(id)
            store.records[id] = NoteSyncRecord(
                noteID: id,
                fields: [NoteSyncField.audioFileName.rawValue: .string(name)],
                clock: NoteFieldClock(stamps: [:]),
                deletedAt: nil
            )
        }
        let manifest = NoteAudioManifest(sha256: String(repeating: "ab", count: 32), bytes: 1, partSize: 50_000_000, parts: 1)
        store.manifests[uploaded] = manifest
        store.manifests[elsewhere] = manifest
        let controller = NoteSyncController(
            defaults: UserDefaults(suiteName: "quill-controller-audio-\(UUID().uuidString)")!,
            unavailableReason: nil,
            createZone: {},
            localAudioURL: { name in
                let url = dir.appendingPathComponent(name)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            },
            makeEngine: { _ in nil }
        )
        controller.attach(store: store)
        precondition(controller.uploadAudioByteCount == 300, "only audio that will upload")
        precondition(controller.notesWithAudioOnlyInICloud == 1)
    }

    final class FakeStore: NoteSyncLocalStore {
        var ids: [UUID] = []
        var cleared = false
        var isReadyForSync = true
        var records: [UUID: NoteSyncRecord] = [:]
        func syncRecord(id: UUID) -> NoteSyncRecord? {
            if let record = records[id] { return record }
            return ids.contains(id) ? NoteSyncRecord(noteID: id, fields: [:], clock: NoteFieldClock(stamps: [:]), deletedAt: nil) : nil
        }
        func noteExists(id: UUID) -> Bool? { syncRecord(id: id) != nil }
        func syncSystemFields(id: UUID) -> Data? { nil }
        func setSyncSystemFields(_ data: Data?, id: UUID) {}
        func clearAllSyncSystemFields(forgettingAudio: Bool) { cleared = true }
        func syncableNoteIDs() -> [UUID] { ids }
        func isSyncable(id: UUID) -> Bool { ids.contains(id) }
        func applySynced(_ record: NoteSyncRecord, systemFields: Data?) throws -> NoteSyncApplyResult { .inserted }
        func removeSynced(id: UUID) throws -> DeletedPipelineHistoryAssets? { nil }
        var manifests: [UUID: NoteAudioManifest] = [:]
        func audioManifest(id: UUID) -> NoteAudioManifest? { manifests[id] }
        func setAudioManifest(_ manifest: NoteAudioManifest?, id: UUID) throws { manifests[id] = manifest }
        func audioUploadKey(id: UUID) -> String? { nil }
        func setAudioUploadKey(_ key: String?, id: UUID) throws {}
        func takeClearedAudioUploadKeys() -> [UUID: String] { [:] }
    }

    final class FakeEngine: NoteSyncEngineHandle {
        var saves: [UUID] = []
        var deletes: [UUID] = []
        var started = 0
        var fetches = 0
        var stopped: [Bool] = []
        var deletedFromICloud = false
        var log: CallLog?
        weak var coordinator: NoteSyncCoordinator?
        func enqueueSaves(_ ids: [UUID]) { saves += ids }
        func enqueueDeletes(_ ids: [UUID]) { deletes += ids }
        func cancelDeletes(_ ids: [UUID]) {}
        func enqueueAudioSaves(_ parts: [NoteAudioPartID]) {}
        func enqueueAudioDeletes(_ parts: [NoteAudioPartID]) {}
        func pendingAudioSaves() -> [NoteAudioPartID] { [] }
        func existingAudioParts(_ parts: [NoteAudioPartID]) async throws -> Set<NoteAudioPartID> { [] }
        func audioParts(ofNotes ids: Set<UUID>) async throws -> [NoteAudioPartID] { [] }
        func cancelAudioSaves(noteID: UUID) {}
        func cancelAudioDeletes(noteID: UUID) {}
        func cancelAudioDeletes(_ parts: [NoteAudioPartID]) {}
        func attach(_ coordinator: NoteSyncCoordinator) { self.coordinator = coordinator }
        func start() { started += 1; log?.calls.append("start") }
        func fetchNow() { fetches += 1 }
        var syncsNow = 0
        /// Runs while the sync is still in progress, before it returns.
        var whileSyncing: (@MainActor () async -> Void)?
        func syncNow() async {
            syncsNow += 1
            await whileSyncing?()
        }
        /// Whether the audio zone goes too.
        var audioDeleteWorks = true
        func deleteAllFromICloud() async throws -> Bool {
            deletedFromICloud = true
            return audioDeleteWorks
        }
        func stop(forgetState: Bool) { stopped.append(forgetState) }
    }

    final class CallLog {
        var calls: [String] = []
        var zoneError: Error?
        var leftoverResult = NoteSyncLeftoverAudio.deleted
        /// Whether a delete without an engine takes the audio too.
        var directAudioDeleted = true
        /// The signed-in account, nil when it can't be read.
        var account: String? = "account-a"
        /// Holds an audio zone delete until set back to false.
        var holdAudioDelete = false
    }


    @MainActor
    static func make(
        enabled: Bool = false,
        unavailable: NoteSyncUnavailableReason? = nil,
        log: CallLog = CallLog()
    ) -> (NoteSyncController, FakeStore, () -> FakeEngine?, UserDefaults) {
        let defaults = UserDefaults(suiteName: "quill-sync-controller-tests-\(UUID().uuidString)")!
        defaults.set(enabled, forKey: NoteSyncController.enabledKey)
        clock = Date(timeIntervalSince1970: 1_800_000_000)
        var engines: [FakeEngine] = []
        let controller = NoteSyncController(
            defaults: defaults,
            unavailableReason: unavailable,
            createZone: {
                log.calls.append("createZone")
                if let error = log.zoneError { throw error }
            },
            now: { clock },
            makeEngine: { _ in
                let engine = FakeEngine()
                engine.log = log
                engines.append(engine)
                return engine
            }
        )
        let store = FakeStore()
        store.ids = [UUID(), UUID()]
        return (controller, store, { engines.last }, defaults)
    }

    @MainActor
    static func testAvailabilityDecision() {
        precondition(NoteSyncAvailability.evaluate(isMacOS14OrLater: false, hasCloudKitEntitlement: true) == .requiresMacOS14)
        precondition(NoteSyncAvailability.evaluate(isMacOS14OrLater: true, hasCloudKitEntitlement: false) == .buildWithoutICloud)
        precondition(NoteSyncAvailability.evaluate(isMacOS14OrLater: true, hasCloudKitEntitlement: true) == nil)
        precondition(NoteSyncAvailability.current() == .buildWithoutICloud || NoteSyncAvailability.current() == nil,
                     "an unsigned test runner has no iCloud entitlement")
    }

    @MainActor
    static func testStartsOffAndStaysOffWhenUnavailable() {
        let (controller, store, engine, _) = make(unavailable: .buildWithoutICloud)
        controller.attach(store: store)
        precondition(!controller.isEnabled && controller.status == .off)
        precondition(expectation { await controller.turnOn() })
        precondition(!controller.isEnabled && engine() == nil, "sync can't turn on without iCloud")
    }

    @MainActor
    static func testTurnOnUploadsEverySyncableNote() {
        let (controller, store, engine, defaults) = make()
        controller.attach(store: store)
        precondition(controller.syncableNoteCount == 2)
        precondition(expectation { await controller.turnOn() })
        precondition(controller.isEnabled && defaults.bool(forKey: NoteSyncController.enabledKey))
        precondition(engine()?.started == 1 && Set(engine()?.saves ?? []) == Set(store.ids))
        precondition(controller.status == .uploading(done: 0, total: 2))
    }

    @MainActor
    static func testRelaunchResumesWithoutUploadingAgain() {
        let (controller, store, engine, _) = make(enabled: true)
        controller.attach(store: store)
        precondition(controller.isEnabled && engine()?.started == 1)
        precondition(engine()?.saves.isEmpty == true, "a relaunch sends only what changed")
    }

    @MainActor
    static func testTurnOffKeepsNotesAndForgetsEngineState() {
        let (controller, store, engine, defaults) = make(enabled: true)
        controller.attach(store: store)
        let running = engine()
        let done = expectation { await controller.turnOff(deleteFromICloud: false) }
        precondition(done)
        precondition(!controller.isEnabled && !defaults.bool(forKey: NoteSyncController.enabledKey))
        precondition(running?.stopped == [true] && running?.deletedFromICloud == false)
        precondition(controller.status == .off && !store.cleared, "plain off keeps change tags for next time")
    }

    @MainActor
    static func testTurnOffAndDeleteFromICloud() {
        let (controller, store, engine, _) = make(enabled: true)
        controller.attach(store: store)
        let running = engine()
        precondition(expectation { await controller.turnOff(deleteFromICloud: true) })
        precondition(running?.deletedFromICloud == true && running?.stopped == [true])
        precondition(store.cleared, "nothing in iCloud is left to point at")
    }

    @MainActor
    static func testAccountChangeTurnsSyncOff() {
        let (controller, store, engine, defaults) = make(enabled: true)
        controller.attach(store: store)
        engine()?.coordinator?.handleAccountChange(signedOut: false)
        precondition(!controller.isEnabled && !defaults.bool(forKey: NoteSyncController.enabledKey))
        precondition(engine()?.stopped == [true])
        precondition(controller.status == .paused(.accountChanged), "the reason stays visible after sync turns off")
    }

    @MainActor
    static func testLocalChangesReachTheEngineOnlyWhileOn() {
        let (controller, store, engine, _) = make()
        controller.attach(store: store)
        controller.handleLocalChanges([.saved(store.ids[0])])
        precondition(engine() == nil)
        precondition(expectation { await controller.turnOn() })
        let before = engine()?.saves.count ?? 0
        controller.handleLocalChanges([.saved(store.ids[0])])
        precondition(engine()?.saves.count == before + 1)
        controller.fetchSoon()
        precondition(engine()?.fetches == 1)
    }

    /// Sync Now fetches and sends right away; a second press while it runs
    /// does nothing.
    @MainActor
    static func testSyncNowRunsOnceAtATime() {
        let (controller, store, engine, _) = make(enabled: true)
        controller.attach(store: store)
        var busyWhileSyncing = false
        engine()?.whileSyncing = {
            busyWhileSyncing = controller.isSyncingNow
            // A second press while the first is still running.
            await controller.syncNow()
        }
        precondition(expectation { await controller.syncNow() })
        precondition(busyWhileSyncing && !controller.isSyncingNow)
        precondition(engine()?.syncsNow == 1, "a press while syncing is ignored")
    }

    /// Sync off means no talking to iCloud: audio downloads stop too.
    @MainActor
    static func testTurningOffStopsAudioDownloads() {
        let (controller, store, _, _) = make(enabled: true)
        var stops = 0
        controller.onEngineStop = { stops += 1 }
        controller.attach(store: store)
        precondition(expectation { _ = await controller.turnOff(deleteFromICloud: false) })
        precondition(stops == 1)
    }

    /// Runs an async call to completion on the main run loop.
    @MainActor
    static func expectation(_ body: @escaping @MainActor () async -> Void) -> Bool {
        var finished = false
        Task { @MainActor in
            await body()
            finished = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !finished, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return finished
    }

    @MainActor
    static func testReplacedStoreStartsOverWithFullUpload() {
        let (controller, store, engine, _) = make(enabled: true)
        controller.attach(store: store)
        let first = engine()
        let replacement = FakeStore()
        replacement.ids = [UUID()]
        controller.attach(store: replacement)
        precondition(first?.stopped == [true], "the old store's sync position is forgotten")
        precondition(engine() !== first && engine()?.saves == replacement.ids, "the new store uploads everything")
    }

    @MainActor
    static func testUnreadyStoreDoesNotStartSync() {
        let (controller, store, engine, _) = make(enabled: true)
        store.isReadyForSync = false
        controller.attach(store: store)
        precondition(engine() == nil, "nothing is fetched into a store that can't save it")
        precondition(controller.isEnabled)
        precondition(controller.status == .paused(.historyUnavailable), "Settings says why sync isn't running")
    }

    /// Turning on makes the iCloud zone before sync starts, so the engine
    /// never meets a zone this Mac deleted earlier and mistakes it for
    /// another Mac's deletion.
    @MainActor
    static func testTurnOnCreatesTheZoneBeforeSyncing() {
        let log = CallLog()
        let (controller, store, engine, _) = make(log: log)
        controller.attach(store: store)
        var failure: NoteSyncTurnOnFailure? = .unreachable
        precondition(expectation { failure = await controller.turnOn() })
        precondition(failure == nil && controller.isEnabled)
        precondition(log.calls == ["createZone", "start"], "the zone exists before the first fetch")
        precondition(Set(engine()?.saves ?? []) == Set(store.ids))

        // A relaunch or a replaced store doesn't make the zone again.
        let relaunchLog = CallLog()
        let (relaunched, relaunchStore, _, _) = make(enabled: true, log: relaunchLog)
        relaunched.attach(store: relaunchStore)
        precondition(relaunchLog.calls == ["start"])
    }

    @MainActor
    static func testTurnOnStaysOffWhenICloudIsUnreachable() {
        let log = CallLog()
        log.zoneError = NoteSyncTurnOnFailure.unreachable
        let (controller, store, engine, defaults) = make(log: log)
        controller.attach(store: store)
        var failure: NoteSyncTurnOnFailure?
        precondition(expectation { failure = await controller.turnOn() })
        precondition(failure == .unreachable && !controller.isEnabled && !defaults.bool(forKey: NoteSyncController.enabledKey))
        precondition(engine() == nil && controller.status == .off, "nothing starts without the zone")

        // Signed out of iCloud says so instead of blaming the network, and
        // an unexpected error reads as unreachable.
        log.zoneError = NoteSyncTurnOnFailure.signedOut
        precondition(expectation { failure = await controller.turnOn() })
        precondition(failure == .signedOut)
        struct Unexpected: Error {}
        log.zoneError = Unexpected()
        precondition(expectation { failure = await controller.turnOn() })
        precondition(failure == .unreachable)
    }

    /// A store that can't save yet is checked before iCloud is contacted,
    /// so the status never sticks at "Checking iCloud…".
    @MainActor
    static func testTurnOnWaitsForAReadyStore() {
        let log = CallLog()
        let (controller, store, engine, _) = make(log: log)
        store.isReadyForSync = false
        controller.attach(store: store)
        var failure: NoteSyncTurnOnFailure?
        precondition(expectation { failure = await controller.turnOn() })
        precondition(failure == .notReady && !controller.isEnabled)
        precondition(log.calls.isEmpty && engine() == nil && controller.status == .off)
    }

    /// Why sync stopped stays on screen when turning it on again fails.
    @MainActor
    static func testTurnOnFailureKeepsWhySyncStopped() {
        let log = CallLog()
        let (controller, store, engine, _) = make(enabled: true, log: log)
        controller.attach(store: store)
        engine()?.coordinator?.handleZoneDeleted()
        precondition(controller.status == .paused(.deletedElsewhere) && !controller.isEnabled)
        log.zoneError = NoteSyncTurnOnFailure.unreachable
        precondition(expectation { _ = await controller.turnOn() })
        precondition(controller.status == .paused(.deletedElsewhere))
    }

    /// Lets work the controller put on the main queue run.
    @MainActor
    static func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// A fetched note the store couldn't save starts sync over once; if it
    /// fails again before sync was up to date, sync pauses instead of
    /// fetching everything over and over. Sync Now starts it again.
    @MainActor
    static func testStoreFailingAgainAfterStartingOverPauses() {
        let (controller, store, engine, defaults) = make(enabled: true)
        controller.attach(store: store)
        let first = engine()
        first?.coordinator?.onNeedsFullRefetch?()
        drainMainQueue()
        let second = engine()
        precondition(second !== first && first?.stopped == [true], "started over once")
        precondition(second?.saves == store.ids, "everything goes up again")
        second?.coordinator?.onNeedsFullRefetch?()
        drainMainQueue()
        precondition(engine() === second && second?.stopped == [true], "no third start")
        precondition(controller.status == .paused(.couldNotSaveHere) && controller.isEnabled)
        precondition(defaults.bool(forKey: NoteSyncController.needsFullStartKey), "a relaunch sends everything")
        // The earlier start over is long past; Sync Now counts as a new one.
        clock = clock.addingTimeInterval(NoteSyncController.startOverWindow * 2)
        precondition(expectation { await controller.syncNow() })
        let third = engine()
        precondition(third !== second && third?.saves == store.ids, "Sync Now starts over")
        precondition(defaults.bool(forKey: NoteSyncController.needsFullStartKey), "kept until a sync gets through")
        third?.coordinator?.handleFetchFinished(pending: 0)
        precondition(!defaults.bool(forKey: NoteSyncController.needsFullStartKey))
        third?.coordinator?.onNeedsFullRefetch?()
        drainMainQueue()
        precondition(controller.status == .paused(.couldNotSaveHere), "Sync Now counts as starting over")
    }

    /// Getting up to date doesn't allow another start over (the upload can
    /// finish before the fetch reaches the note that can't be saved); half
    /// an hour later, one is allowed again.
    @MainActor
    static func testStartingOverIsAllowedAgainAfterHalfAnHour() {
        let (controller, store, engine, _) = make(enabled: true)
        controller.attach(store: store)
        engine()?.coordinator?.onNeedsFullRefetch?()
        drainMainQueue()
        let second = engine()
        second?.coordinator?.handleFetchFinished(pending: 0)
        clock = clock.addingTimeInterval(NoteSyncController.startOverWindow - 1)
        second?.coordinator?.onNeedsFullRefetch?()
        drainMainQueue()
        precondition(engine() === second && controller.status == .paused(.couldNotSaveHere), "up to date isn't enough")
        precondition(expectation { await controller.syncNow() })
        let third = engine()
        clock = clock.addingTimeInterval(NoteSyncController.startOverWindow)
        third?.coordinator?.onNeedsFullRefetch?()
        drainMainQueue()
        precondition(engine() !== third, "half an hour later it starts over again")
    }

    /// Sync paused with its engine state dropped: changes made meanwhile
    /// weren't queued, so the next launch sends every note.
    @MainActor
    static func testRelaunchAfterAPauseUploadsEverything() {
        let (controller, store, engine, defaults) = make(enabled: true)
        defaults.set(true, forKey: NoteSyncController.needsFullStartKey)
        controller.attach(store: store)
        precondition(engine()?.saves == store.ids)
        precondition(defaults.bool(forKey: NoteSyncController.needsFullStartKey), "kept in case the app quits before the engine saves")
        engine()?.coordinator?.handleFetchFinished(pending: 0)
        precondition(!defaults.bool(forKey: NoteSyncController.needsFullStartKey))
    }

    /// History that can't be read mid-session pauses sync with a reason
    /// rather than leaving it stopped and saying "Up to date"; recovered
    /// history, attached as a new store, starts it again.
    @MainActor
    static func testHistoryLostMidSessionPausesUntilReplaced() {
        let (controller, store, engine, _) = make(enabled: true)
        controller.attach(store: store)
        engine()?.coordinator?.handleFetchFinished(pending: 0)
        let first = engine()
        store.isReadyForSync = false
        _ = first?.coordinator?.handleFetched([], deletions: [])
        drainMainQueue()
        precondition(first?.stopped == [true] && engine() === first, "no engine runs on it")
        precondition(controller.status == .paused(.historyUnavailable) && controller.isEnabled)
        let recovered = FakeStore()
        recovered.ids = [UUID()]
        controller.attach(store: recovered)
        precondition(engine() !== first && engine()?.saves == recovered.ids, "sync goes on with the recovered history")
    }

    @MainActor
    static func testSyncNowTriesFailedChangesAgain() {
        let (controller, store, engine, _) = make(enabled: true)
        controller.attach(store: store)
        let id = store.ids[0]
        for _ in 0..<4 { engine()?.coordinator?.handleSendFailures([.other(noteID: id)]) }
        precondition(expectation { await controller.syncNow() })
        engine()?.coordinator?.handleFetchFinished(pending: 0)
        precondition(engine()?.saves == [id], "the given-up note goes up with Sync Now")
    }

    @MainActor static let leftKey = NoteSyncController.audioLeftInICloudKey

    @MainActor
    static func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "quill-sync-controller-tests-\(UUID().uuidString)")!
    }

    /// A controller as at launch, on `defaults`, whose leftover audio
    /// delete and account are `log`'s.
    @MainActor
    static func launch(_ defaults: UserDefaults, log: CallLog, engine: FakeEngine = FakeEngine()) -> NoteSyncController {
        NoteSyncController(
            defaults: defaults,
            unavailableReason: nil,
            createZone: { log.calls.append("createZone") },
            deleteLeftoverAudio: { @MainActor in
                log.calls.append("deleteAudioZone")
                while log.holdAudioDelete { await Task.yield() }
                log.calls.append("deleteAudioZone done")
                return log.leftoverResult
            },
            deleteAllWithoutEngine: { @MainActor in
                log.calls.append("deleteAllWithoutEngine")
                if let error = log.zoneError { throw error }
                return log.directAudioDeleted
            },
            accountID: { @MainActor in log.account },
            makeEngine: { _ in engine }
        )
    }

    /// Turn Off and Delete from iCloud deleted the notes but not their
    /// audio: Settings says so, and each launch deletes it again until it
    /// goes.
    @MainActor
    static func testAudioLeftInICloudIsDeletedAtLaunch() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: NoteSyncController.enabledKey)
        let engine = FakeEngine()
        engine.audioDeleteWorks = false
        let log = CallLog()
        let controller = launch(defaults, log: log, engine: engine)
        let store = FakeStore()
        controller.attach(store: store)
        var turnedOff = false
        precondition(expectation { turnedOff = await controller.turnOff(deleteFromICloud: true) })
        precondition(turnedOff && !controller.isEnabled, "sync turns off: the notes are gone")
        precondition(controller.audioLeftInICloud && defaults.stringArray(forKey: leftKey) == ["account-a"])

        log.leftoverResult = .failed
        let relaunched = launch(defaults, log: log)
        precondition(relaunched.audioLeftInICloud, "remembered across launches")
        precondition(expectation { await relaunched.deleteLeftoverAudio() })
        precondition(log.calls == ["deleteAudioZone", "deleteAudioZone done"] && relaunched.audioLeftInICloud)
        log.leftoverResult = .deleted
        let again = launch(defaults, log: log)
        precondition(expectation { await again.deleteLeftoverAudio() })
        precondition(!again.audioLeftInICloud && defaults.object(forKey: leftKey) == nil)
    }

    @MainActor
    static func testLeftoverAudioWaitsWhileSyncIsOn() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: NoteSyncController.enabledKey)
        defaults.set(["account-a"], forKey: leftKey)
        let log = CallLog()
        let controller = launch(defaults, log: log)
        precondition(expectation { await controller.deleteLeftoverAudio() })
        precondition(log.calls.isEmpty, "the zone sync is using isn't deleted")
    }

    /// Turning on while leftover audio is being deleted waits for that
    /// delete, so it can't remove the zone turning on makes; the audio
    /// still there is used again.
    @MainActor
    static func testTurnOnWaitsForTheLeftoverAudioDelete() {
        let defaults = freshDefaults()
        defaults.set(["account-a"], forKey: leftKey)
        let log = CallLog()
        log.leftoverResult = .failed
        log.holdAudioDelete = true
        let controller = launch(defaults, log: log)
        let store = FakeStore()
        controller.attach(store: store)
        Task { @MainActor in await controller.deleteLeftoverAudio() }
        drainMainQueue()
        var turnedOn = false
        Task { @MainActor in turnedOn = await controller.turnOn() == nil }
        drainMainQueue()
        precondition(log.calls == ["deleteAudioZone"], "turning on waits: \(log.calls)")
        log.holdAudioDelete = false
        precondition(expectation { while !turnedOn { await Task.yield() } })
        precondition(log.calls == ["deleteAudioZone", "deleteAudioZone done", "createZone"])
        precondition(controller.isEnabled && !controller.audioLeftInICloud, "the audio left is used again")
    }

    /// Another Mac turned sync on and uses the audio zone: it isn't
    /// deleted, and nothing is left to do.
    @MainActor
    static func testLeftoverAudioInUseAgainIsForgotten() {
        let defaults = freshDefaults()
        defaults.set(["account-a"], forKey: leftKey)
        let log = CallLog()
        log.leftoverResult = .inUse
        let controller = launch(defaults, log: log)
        precondition(expectation { await controller.deleteLeftoverAudio() })
        precondition(!controller.audioLeftInICloud && defaults.object(forKey: leftKey) == nil)
    }

    /// Only audio left in the signed-in account is deleted; audio left in
    /// another one waits. An entry whose account couldn't be read is left
    /// to the notes zone check, in whichever account is signed in.
    @MainActor
    static func testLeftoverAudioIsKeptPerAccount() {
        let defaults = freshDefaults()
        defaults.set(["account-a", "account-b"], forKey: leftKey)
        let log = CallLog()
        log.account = "account-b"
        precondition(expectation { await launch(defaults, log: log).deleteLeftoverAudio() })
        precondition(defaults.stringArray(forKey: leftKey) == ["account-a"], "only account-b's audio went")
        log.calls = []
        log.account = "account-c"
        precondition(expectation { await launch(defaults, log: log).deleteLeftoverAudio() })
        precondition(log.calls.isEmpty && defaults.stringArray(forKey: leftKey) == ["account-a"], "account-a's audio waits for it")
        log.account = nil
        precondition(expectation { await launch(defaults, log: log).deleteLeftoverAudio() })
        precondition(log.calls.isEmpty, "nothing is deleted while the account can't be read")
        defaults.set(["", "account-a"], forKey: leftKey)
        log.account = "account-c"
        precondition(expectation { await launch(defaults, log: log).deleteLeftoverAudio() })
        precondition(defaults.stringArray(forKey: leftKey) == ["account-a"], "the unknown entry goes by the notes zone check")
    }

    /// Turning on in another account doesn't forget audio left in the
    /// first; turning on in that account reuses it. With the account
    /// unreadable, nothing is forgotten.
    @MainActor
    static func testTurnOnInAnotherAccountKeepsLeftoverAudio() {
        for (current, left) in [("account-b", ["account-a"]), ("account-a", []), (nil, ["account-a"])] as [(String?, [String])] {
            let defaults = freshDefaults()
            defaults.set(["account-a"], forKey: leftKey)
            let log = CallLog()
            log.account = current
            let controller = launch(defaults, log: log)
            let store = FakeStore()
            controller.attach(store: store)
            precondition(expectation { _ = await controller.turnOn() })
            precondition(controller.isEnabled && (defaults.stringArray(forKey: leftKey) ?? []) == left, "\(String(describing: current))")
        }
    }

    /// Audio left in account A, then Turn Off and Delete in account B also
    /// leaves audio: both are remembered, each for its own account.
    @MainActor
    static func testTurnOffInAnotherAccountKeepsTheFirstOnesAudio() {
        let defaults = freshDefaults()
        defaults.set(["account-a"], forKey: leftKey)
        let engine = FakeEngine()
        engine.audioDeleteWorks = false
        let log = CallLog()
        log.account = "account-b"
        let controller = launch(defaults, log: log, engine: engine)
        let store = FakeStore()
        controller.attach(store: store)
        precondition(expectation { _ = await controller.turnOn() })
        precondition(expectation { _ = await controller.turnOff(deleteFromICloud: true) })
        precondition(defaults.stringArray(forKey: leftKey) == ["account-a", "account-b"])
    }

    @MainActor
    static func testUnreadableAccountAtTurnOffIsRecordedAsUnknown() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: NoteSyncController.enabledKey)
        let engine = FakeEngine()
        engine.audioDeleteWorks = false
        let log = CallLog()
        log.account = nil
        let controller = launch(defaults, log: log, engine: engine)
        let store = FakeStore()
        controller.attach(store: store)
        precondition(expectation { _ = await controller.turnOff(deleteFromICloud: true) })
        precondition(defaults.stringArray(forKey: leftKey) == [""] && controller.audioLeftInICloud)
    }

    /// Paused because note history can't be opened, so no engine runs:
    /// Turn Off and Delete from iCloud deletes the zones directly. The
    /// history can't be written, so its change tags are left.
    @MainActor
    static func testDeleteFromICloudWhileHistoryCantBeOpened() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: NoteSyncController.enabledKey)
        let log = CallLog()
        log.directAudioDeleted = false
        let controller = launch(defaults, log: log)
        let store = FakeStore()
        store.isReadyForSync = false
        controller.attach(store: store)
        precondition(controller.status == .paused(.historyUnavailable))
        var succeeded = false
        precondition(expectation { succeeded = await controller.turnOff(deleteFromICloud: true) })
        precondition(succeeded && !controller.isEnabled && controller.status == .off)
        precondition(log.calls == ["deleteAllWithoutEngine"] && !store.cleared)
        precondition(defaults.stringArray(forKey: leftKey) == ["account-a"], "audio left is remembered as usual")
    }

    /// Paused because notes couldn't be saved here: the zones go directly,
    /// and the store, which can be written, forgets its change tags.
    @MainActor
    static func testDeleteFromICloudWhilePausedForSaving() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: NoteSyncController.enabledKey)
        let log = CallLog()
        let engine = FakeEngine()
        let controller = launch(defaults, log: log, engine: engine)
        let store = FakeStore()
        controller.attach(store: store)
        engine.coordinator?.onNeedsFullRefetch?()
        drainMainQueue()
        engine.coordinator?.onNeedsFullRefetch?()
        drainMainQueue()
        precondition(controller.status == .paused(.couldNotSaveHere))
        precondition(expectation { _ = await controller.turnOff(deleteFromICloud: true) })
        precondition(log.calls == ["deleteAllWithoutEngine"] && !engine.deletedFromICloud && store.cleared)
        precondition(!controller.isEnabled)
    }

    @MainActor
    static func testFailedDeleteWhilePausedKeepsSyncOn() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: NoteSyncController.enabledKey)
        let log = CallLog()
        log.zoneError = URLError(.notConnectedToInternet)
        let controller = launch(defaults, log: log)
        let store = FakeStore()
        store.isReadyForSync = false
        controller.attach(store: store)
        var succeeded = true
        precondition(expectation { succeeded = await controller.turnOff(deleteFromICloud: true) })
        precondition(!succeeded && controller.isEnabled, "nothing was deleted, so sync stays on and says so")
    }
}
