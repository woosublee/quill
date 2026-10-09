import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct AppStateNoteSyncTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func main() async throws {
        try await testLocalEditReachesTheEngine()
        try await testRemoteChangeShowsNoteAndWritesTranscript()
        try await testRemoteDeletionRemovesTheNote()
        try testWriteTranscriptRejectsUnsafeNames()
        try testSourceContracts()
        print("AppStateNoteSyncTests passed")
    }

    final class FakeEngine: NoteSyncEngineHandle {
        var saves: [UUID] = []
        var events: NoteSyncEngineEvents?
        weak var coordinator: NoteSyncCoordinator?
        func enqueueSaves(_ ids: [UUID]) { saves += ids }
        func enqueueDeletes(_ ids: [UUID]) {}
        func cancelDeletes(_ ids: [UUID]) {}
        func enqueueAudioSaves(_ parts: [NoteAudioPartID]) {}
        func enqueueAudioDeletes(_ parts: [NoteAudioPartID]) {}
        func pendingAudioSaves(noteID: UUID) -> [NoteAudioPartID] { [] }
        func cancelAudioSaves(noteID: UUID) {}
        func attach(_ coordinator: NoteSyncCoordinator) { self.coordinator = coordinator }
        func start() {}
        func fetchNow() {}
        func deleteAllFromICloud() async throws {}
        func stop(forgetState: Bool) {}
    }

    struct Fixture {
        let root: URL
        let layout: AppStateStorageLayout
        let store: PipelineHistoryStore
        let engine: FakeEngine
        let appState: AppState
    }

    static func makeItem(id: UUID = UUID(), title: String = "Synthetic", transcriptFile: String? = nil) -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: id,
            timestamp: t0,
            rawTranscript: "synthetic raw",
            postProcessedTranscript: "synthetic edited",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "succeeded",
            debugStatus: "",
            customVocabulary: "",
            transcriptFileName: transcriptFile,
            customTitle: title
        )
    }

    @MainActor
    static func makeFixture(items: [PipelineHistoryItem]) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-note-sync-app-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let layout = AppStateStorageLayout(rootDirectory: root)
        let store = PipelineHistoryStore(storeURL: layout.historyStoreURL)
        for item in items { _ = try store.append(item, maxCount: Int.max) }
        let engine = FakeEngine()
        let defaults = UserDefaults(suiteName: "quill-note-sync-app-state-\(UUID().uuidString)")!
        // Sync already on, as after a relaunch.
        defaults.set(true, forKey: NoteSyncController.enabledKey)
        var dependencies = AppStateDependencies.live
        dependencies.storageLayout = layout
        dependencies.makePipelineHistoryStore = { _ in store }
        dependencies.makeNoteSyncController = { _ in
            NoteSyncController(defaults: defaults, unavailableReason: nil, createZone: {}, makeEngine: { events in
                engine.events = events
                return engine
            })
        }
        let appState = AppState(dependencies: dependencies)
        appState.startNoteSync()
        engine.saves = []
        return Fixture(root: root, layout: layout, store: store, engine: engine, appState: appState)
    }

    static func testLocalEditReachesTheEngine() async throws {
        try await MainActor.run {
            let note = makeItem()
            let fixture = try makeFixture(items: [note])
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            precondition(fixture.appState.noteSyncController?.isEnabled == true)
            fixture.appState.updateHistoryItemTitle(id: note.id, title: "Renamed")
            precondition(fixture.engine.saves == [note.id], "a local edit is queued for iCloud")
        }
    }

    static func testRemoteChangeShowsNoteAndWritesTranscript() async throws {
        try await MainActor.run {
            let fixture = try makeFixture(items: [])
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let fileName = "\(UUID().uuidString).txt"
            let remote = NoteSyncRecord(item: PipelineHistoryItem(
                id: UUID(),
                timestamp: t0,
                rawTranscript: "remote raw",
                postProcessedTranscript: "remote edited",
                postProcessingPrompt: nil,
                contextSummary: "",
                contextScreenshotDataURL: nil,
                contextScreenshotStatus: "No screenshot",
                postProcessingStatus: "succeeded",
                debugStatus: "",
                customVocabulary: "",
                transcriptFileName: fileName,
                customTitle: "From another Mac",
                fieldClock: .uniform(t0)
            ))
            let change = fixture.engine.coordinator!.handleFetched(
                [NoteSyncFetched(noteID: remote.noteID, payload: try NoteSyncPayload.encode(remote), systemFields: Data([1]))],
                deletions: []
            )
            fixture.engine.events!.remoteChange(change)
            precondition(fixture.appState.pipelineHistory.map(\.customTitle) == ["From another Mac"])
            let text = try String(contentsOf: fixture.layout.transcriptDirectory.appendingPathComponent(fileName), encoding: .utf8)
            precondition(text == "remote edited", "the transcript file is written under the same name")
            precondition(fixture.engine.saves.isEmpty, "a received note is not sent back")
        }
    }

    static func testRemoteDeletionRemovesTheNote() async throws {
        try await MainActor.run {
            let note = makeItem()
            let fixture = try makeFixture(items: [note])
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            precondition(fixture.appState.pipelineHistory.count == 1)
            let change = fixture.engine.coordinator!.handleFetched([], deletions: [note.id])
            fixture.engine.events!.remoteChange(change)
            precondition(fixture.appState.pipelineHistory.isEmpty && fixture.appState.recentlyDeletedNotes.isEmpty)
            precondition(fixture.store.loadAllHistory().isEmpty)
        }
    }

    static func testWriteTranscriptRejectsUnsafeNames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-note-sync-assets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = NoteAssetStore(storageLayout: AppStateStorageLayout(rootDirectory: root))
        for name in ["../escape.txt", "\(UUID().uuidString).wav", "notes.txt", "a/\(UUID().uuidString).txt"] {
            do {
                try assets.writeTranscript(fileName: name, content: "synthetic")
                preconditionFailure("\(name) must be rejected")
            } catch {}
        }
        let good = "\(UUID().uuidString).txt"
        try assets.writeTranscript(fileName: good, content: "synthetic")
        let saved = try assets.loadTranscript(fileName: good)
        precondition(saved == "synthetic")
    }

    static func testSourceContracts() throws {
        let remoteChange = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        // Remote changes never overwrite the list mid-recovery.
        precondition(remoteChange.contains("    private func applyRemoteNoteChange(_ change: NoteSyncRemoteChange) {\n        guard !isHistoryRecoveryOperationInProgress, !isHistoryUnavailable else { return }"))
        let appState = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let settings = try String(contentsOfFile: "Sources/SettingsView.swift", encoding: .utf8)
        let delegate = try String(contentsOfFile: "Sources/AppDelegate.swift", encoding: .utf8)
        // A store replaced by history recovery keeps reporting to sync.
        precondition(appState.contains("private var pipelineHistoryStore: PipelineHistoryStore {\n        didSet { connectNoteSync(to: pipelineHistoryStore) }"))
        // Clearing every note would delete them from iCloud on every Mac.
        precondition(settings.contains(".disabled(appState.pipelineHistory.isEmpty || appState.isHistoryUnavailable || appState.noteSyncController?.isEnabled == true)"))
        precondition(delegate.contains("appState.startNoteSync()"))
    }
}
