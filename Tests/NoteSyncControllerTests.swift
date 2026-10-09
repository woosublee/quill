import Foundation

@main
struct NoteSyncControllerTests {
    @MainActor
    static func main() throws {
        testAvailabilityDecision()
        testStartsOffAndStaysOffWhenUnavailable()
        testTurnOnUploadsEverySyncableNote()
        testRelaunchResumesWithoutUploadingAgain()
        testTurnOffKeepsNotesAndForgetsEngineState()
        testTurnOffAndDeleteFromICloud()
        testAccountChangeTurnsSyncOff()
        testLocalChangesReachTheEngineOnlyWhileOn()
        testReplacedStoreStartsOverWithFullUpload()
        testUnreadyStoreDoesNotStartSync()
        testDeleteFromICloudWithoutEngineFails()
        testTurnOnCreatesTheZoneBeforeSyncing()
        testTurnOnStaysOffWhenICloudIsUnreachable()
        testTurnOnWaitsForAReadyStore()
        testTurnOnFailureKeepsWhySyncStopped()
        try testConfirmationsCountAudio()
        testSyncNowRunsOnceAtATime()
        testTurningOffStopsAudioDownloads()
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
        func deleteAllFromICloud() async throws { deletedFromICloud = true }
        func stop(forgetState: Bool) { stopped.append(forgetState) }
    }

    final class CallLog {
        var calls: [String] = []
        var zoneError: Error?
    }


    @MainActor
    static func make(
        enabled: Bool = false,
        unavailable: NoteSyncUnavailableReason? = nil,
        log: CallLog = CallLog()
    ) -> (NoteSyncController, FakeStore, () -> FakeEngine?, UserDefaults) {
        let defaults = UserDefaults(suiteName: "quill-sync-controller-tests-\(UUID().uuidString)")!
        defaults.set(enabled, forKey: NoteSyncController.enabledKey)
        var engines: [FakeEngine] = []
        let controller = NoteSyncController(
            defaults: defaults,
            unavailableReason: unavailable,
            createZone: {
                log.calls.append("createZone")
                if let error = log.zoneError { throw error }
            },
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
    }

    @MainActor
    static func testDeleteFromICloudWithoutEngineFails() {
        let (controller, store, _, _) = make(enabled: true)
        store.isReadyForSync = false
        controller.attach(store: store)
        var succeeded = true
        precondition(expectation { succeeded = await controller.turnOff(deleteFromICloud: true) })
        precondition(!succeeded && controller.isEnabled, "nothing was deleted, so sync stays on and says so")
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
}
