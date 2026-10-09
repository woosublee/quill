import Foundation

@main
struct NoteSyncControllerTests {
    @MainActor
    static func main() {
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
        testOnlyTurningOnMarksAUserTurnOn()
        print("NoteSyncControllerTests passed")
    }

    final class FakeStore: NoteSyncLocalStore {
        var ids: [UUID] = []
        var cleared = false
        var isReadyForSync = true
        func syncRecord(id: UUID) -> NoteSyncRecord? {
            ids.contains(id) ? NoteSyncRecord(noteID: id, fields: [:], clock: NoteFieldClock(stamps: [:]), deletedAt: nil) : nil
        }
        func syncSystemFields(id: UUID) -> Data? { nil }
        func setSyncSystemFields(_ data: Data?, id: UUID) {}
        func clearAllSyncSystemFields() { cleared = true }
        func syncableNoteIDs() -> [UUID] { ids }
        func isSyncable(id: UUID) -> Bool { ids.contains(id) }
        func applySynced(_ record: NoteSyncRecord, systemFields: Data?) throws -> NoteSyncApplyResult { .inserted }
        func removeSynced(id: UUID) throws -> DeletedPipelineHistoryAssets? { nil }
    }

    final class FakeEngine: NoteSyncEngineHandle {
        var saves: [UUID] = []
        var deletes: [UUID] = []
        var started = 0
        var fetches = 0
        var stopped: [Bool] = []
        var deletedFromICloud = false
        var calls: [String] = []
        weak var coordinator: NoteSyncCoordinator?
        func enqueueSaves(_ ids: [UUID]) { saves += ids }
        func enqueueDeletes(_ ids: [UUID]) { deletes += ids }
        func attach(_ coordinator: NoteSyncCoordinator) { self.coordinator = coordinator }
        func start() { started += 1; calls.append("start") }
        func noteTurnedOnByUser() { calls.append("turnedOnByUser") }
        func fetchNow() { fetches += 1 }
        func deleteAllFromICloud() async throws { deletedFromICloud = true }
        func stop(forgetState: Bool) { stopped.append(forgetState) }
    }

    @MainActor
    static func make(
        enabled: Bool = false,
        unavailable: NoteSyncUnavailableReason? = nil
    ) -> (NoteSyncController, FakeStore, () -> FakeEngine?, UserDefaults) {
        let defaults = UserDefaults(suiteName: "quill-sync-controller-tests-\(UUID().uuidString)")!
        defaults.set(enabled, forKey: NoteSyncController.enabledKey)
        var engines: [FakeEngine] = []
        let controller = NoteSyncController(
            defaults: defaults,
            unavailableReason: unavailable,
            makeEngine: { _ in
                let engine = FakeEngine()
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
        controller.turnOn()
        precondition(!controller.isEnabled && engine() == nil, "sync can't turn on without iCloud")
    }

    @MainActor
    static func testTurnOnUploadsEverySyncableNote() {
        let (controller, store, engine, defaults) = make()
        controller.attach(store: store)
        precondition(controller.syncableNoteCount == 2)
        controller.turnOn()
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
        controller.turnOn()
        let before = engine()?.saves.count ?? 0
        controller.handleLocalChanges([.saved(store.ids[0])])
        precondition(engine()?.saves.count == before + 1)
        controller.fetchSoon()
        precondition(engine()?.fetches == 1)
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

    /// Only the user's own turn-on tells the engine that an old iCloud
    /// deletion is history, and before its first fetch. A relaunch or a
    /// replaced store doesn't, so another Mac's deletion still stops sync.
    @MainActor
    static func testOnlyTurningOnMarksAUserTurnOn() {
        let (controller, store, engine, _) = make()
        controller.attach(store: store)
        controller.turnOn()
        precondition(engine()?.calls == ["turnedOnByUser", "start"], "marked before the first fetch")
        let replacement = FakeStore()
        controller.attach(store: replacement)
        precondition(engine()?.calls == ["start"], "history recovery is not a turn-on")

        let (relaunched, relaunchStore, relaunchEngine, _) = make(enabled: true)
        relaunched.attach(store: relaunchStore)
        precondition(relaunchEngine()?.calls == ["start"], "a relaunch is not a turn-on")
    }
}
