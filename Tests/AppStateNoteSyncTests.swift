import CloudKit
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
        if #available(macOS 14.0, *) { testAudioFetchErrorsSayOffline() }
        try await testEmptyAudioFileCountsAsNoFile()
        try await testExpiredNoteRestoredElsewhereSurvivesThePurge()
        try await testExpiredNoteIsPurgedAfterAFetch()
        try await testFetchWhileOfflineDoesNotPurge()
        try await testPurgeRunsAtOnceWhenSyncIsOff()
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
        func pendingAudioSaves() -> [NoteAudioPartID] { [] }
        func pendingAudioDeletes() -> [NoteAudioPartID] { [] }
        func pendingNoteDeletes() -> [UUID] { [] }
        func pendingChangeCount() -> Int { 0 }
        func existingAudioParts(_ parts: [NoteAudioPartID]) async throws -> Set<NoteAudioPartID> { [] }
        func audioParts(ofNotes ids: Set<UUID>) async throws -> [NoteAudioPartID] { [] }
        func allAudioParts() async throws -> [NoteAudioPartInICloud] { [] }
        func audioOfNotesInICloud(_ ids: Set<UUID>) async throws -> [UUID: NoteAudioInICloud] { [:] }
        func cancelAudioSaves(noteID: UUID) {}
        func cancelAudioDeletes(noteID: UUID) {}
        func cancelAudioDeletes(_ parts: [NoteAudioPartID]) {}
        func attach(_ coordinator: NoteSyncCoordinator) { self.coordinator = coordinator }
        func start() {}
        func fetchNow() {}
        func syncNow() async {}
        func deleteAllFromICloud() async throws -> Bool { true }
        func stop(forgetState: Bool) {}
    }

    struct Fixture {
        let root: URL
        let layout: AppStateStorageLayout
        let store: PipelineHistoryStore
        let engine: FakeEngine
        let appState: AppState
    }

    static func makeItem(id: UUID = UUID(), title: String = "Synthetic", transcriptFile: String? = nil, audioFile: String? = nil) -> PipelineHistoryItem {
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
            audioFileName: audioFile,
            transcriptFileName: transcriptFile,
            customTitle: title
        )
    }

    /// `deleted`: notes put in Recently Deleted at these times before launch.
    @MainActor
    static func makeFixture(
        items: [PipelineHistoryItem],
        deleted: [UUID: Date] = [:],
        syncOn: Bool = true
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-note-sync-app-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let layout = AppStateStorageLayout(rootDirectory: root)
        let store = PipelineHistoryStore(storeURL: layout.historyStoreURL)
        for item in items { _ = try store.append(item, maxCount: Int.max) }
        for (id, date) in deleted { _ = try store.setDeletedAt(date, id: id) }
        let engine = FakeEngine()
        let defaults = UserDefaults(suiteName: "quill-note-sync-app-state-\(UUID().uuidString)")!
        // Sync already on, as after a relaunch.
        defaults.set(syncOn, forKey: NoteSyncController.enabledKey)
        var dependencies = AppStateDependencies.live
        dependencies.storageLayout = layout
        dependencies.credentialStorageLayout = .isolatedForTests()
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

    /// Offline, CloudKit fails the whole fetch without a per-part result;
    /// the download must say offline, not a plain failure.
    @available(macOS 14.0, *)
    static func testAudioFetchErrorsSayOffline() {
        func reason(_ part: Result<URL, Error>?, _ operationError: Error?) -> NoteAudioFetchError? {
            guard case .failure(let error) = NoteSyncCloudKitEngine.audioFetchResult(part: part, operationError: operationError) else { return nil }
            return error as? NoteAudioFetchError
        }
        let offline = CKError(.networkUnavailable)
        precondition(reason(nil, offline) == .offline, "no part result: the operation's error decides")
        precondition(reason(nil, URLError(.notConnectedToInternet)) == .offline)
        let id = CKRecord.ID(recordName: "synthetic")
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [id: CKError(.networkFailure)]])
        precondition(reason(nil, partial) == .offline, "a partial failure is read through to the part's error")
        precondition(reason(.failure(NoteAudioFetchError.missing), partial) == .missing, "the part's own result wins")
        precondition(reason(nil, nil) == .failed, "no result at all is a plain failure")
        precondition(reason(nil, CKError(.unknownItem)) == .missing)
        for busy in [CKError.Code.requestRateLimited, .zoneBusy, .serviceUnavailable] {
            precondition(reason(nil, CKError(busy)) == .failed, "a busy server isn't offline")
        }
    }

    /// An empty audio file here (a copy cut short) is no audio: nothing to
    /// play or retranscribe. With audio in iCloud it can be downloaded; on
    /// the recording Mac, with nothing in iCloud, the note shows no audio
    /// rather than waiting for an upload (an empty file isn't sent).
    static func testEmptyAudioFileCountsAsNoFile() async throws {
        try await MainActor.run {
            let note = makeItem(audioFile: "\(UUID().uuidString).wav")
            let fixture = try makeFixture(items: [note])
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let appState = fixture.appState
            guard let url = appState.storedAudioURL(for: note) else { preconditionFailure("no audio path") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            precondition(appState.noteBrowserStoredAudioURL(for: note) == nil)
            precondition(appState.noteAudioState(for: note) == .none, "\(appState.noteAudioState(for: note))")
            precondition(appState.noteBrowserRetryAvailability(for: note) == .noAudio)
            let marker = NoteAudioManifest(sha256: String(repeating: "ab", count: 32), bytes: 10, partSize: 50_000_000, parts: 1)
            try fixture.store.setAudioManifest(marker, id: note.id)
            precondition(appState.noteAudioState(for: note) == .downloadable, "\(appState.noteAudioState(for: note))")
            try Data([1, 2, 3]).write(to: url)
            precondition(appState.noteBrowserStoredAudioURL(for: note) == url && appState.noteAudioState(for: note) == .local)
            // A link is judged by its target: an empty or missing target is
            // no file here.
            let target = fixture.root.appendingPathComponent("target.wav")
            try Data().write(to: target)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            precondition(appState.noteBrowserStoredAudioURL(for: note) == nil, "a link to an empty file")
            try FileManager.default.removeItem(at: target)
            precondition(appState.noteBrowserStoredAudioURL(for: note) == nil, "a link to nothing")
        }
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

    /// Deleted 31 days ago here; past the 30 days Recently Deleted keeps it.
    static var expiredDeletion: Date { Date().addingTimeInterval(-31 * 24 * 60 * 60) }

    /// #562: a note restored on another device while this Mac wasn't
    /// fetching must not be purged here, or the delete reaches every device.
    static func testExpiredNoteRestoredElsewhereSurvivesThePurge() async throws {
        try await MainActor.run {
            let note = makeItem()
            let fixture = try makeFixture(items: [note], deleted: [note.id: expiredDeletion])
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let appState = fixture.appState
            precondition(appState.recentlyDeletedNotes.map(\.id) == [note.id])
            // The timer or Settings: no fetch yet, so nothing is purged.
            appState.purgeExpiredRecentlyDeletedNotes()
            precondition(appState.recentlyDeletedNotes.map(\.id) == [note.id], "no purge before a fetch")
            // The fetch brings the restore from another device, then ends.
            let restored = NoteSyncRecord(item: PipelineHistoryItem(
                id: note.id,
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
                customTitle: "Synthetic",
                fieldClock: .uniform(Date().addingTimeInterval(60))
            ))
            try fetch(fixture, [NoteSyncFetched(noteID: note.id, payload: try NoteSyncPayload.encode(restored), systemFields: Data([1]))])
            precondition(appState.pipelineHistory.map(\.id) == [note.id], "the restored note stays")
            precondition(appState.recentlyDeletedNotes.isEmpty)
            precondition(fixture.store.loadAllHistory().map(\.id) == [note.id])
        }
    }

    static func testExpiredNoteIsPurgedAfterAFetch() async throws {
        try await MainActor.run {
            let note = makeItem()
            let fixture = try makeFixture(items: [note], deleted: [note.id: expiredDeletion])
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try fetch(fixture, [])
            precondition(fixture.appState.recentlyDeletedNotes.isEmpty, "a whole fetch that changed nothing lets it go")
            precondition(fixture.store.loadAllHistory().isEmpty)
        }
    }

    static func testFetchWhileOfflineDoesNotPurge() async throws {
        try await MainActor.run {
            let note = makeItem()
            let fixture = try makeFixture(items: [note], deleted: [note.id: expiredDeletion])
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            fixture.engine.coordinator!.handleNetworkChange(isOnline: false)
            try fetch(fixture, [])
            precondition(fixture.appState.recentlyDeletedNotes.map(\.id) == [note.id], "a cut-off fetch may lack a restore")
            // The hourly timer still purges once a whole fetch has ended.
            fixture.engine.coordinator!.handleNetworkChange(isOnline: true)
            fixture.engine.coordinator!.handleFetchStarted()
            fixture.engine.coordinator!.handleFetchCompleted(pending: 0)
            fixture.appState.purgeExpiredRecentlyDeletedNotes()
            precondition(fixture.appState.recentlyDeletedNotes.isEmpty, "the timer purges after a whole fetch")
        }
    }

    /// What the engine does for one fetch: start, the records, the end.
    @MainActor
    static func fetch(_ fixture: Fixture, _ records: [NoteSyncFetched]) throws {
        let coordinator = fixture.engine.coordinator!
        coordinator.handleFetchStarted()
        let change = coordinator.handleFetched(records, deletions: [])
        if change != NoteSyncRemoteChange() { fixture.engine.events!.remoteChange(change) }
        coordinator.handleFetchCompleted(pending: 0)
        fixture.engine.events!.fetchFinished()
    }

    static func testPurgeRunsAtOnceWhenSyncIsOff() async throws {
        try await MainActor.run {
            let note = makeItem()
            let fixture = try makeFixture(items: [note], deleted: [note.id: expiredDeletion], syncOn: false)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            fixture.appState.purgeExpiredRecentlyDeletedNotes()
            precondition(fixture.appState.recentlyDeletedNotes.isEmpty, "with sync off nothing else can restore it")
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
        // The first purge must already know sync is on (#562).
        guard let syncStart = delegate.range(of: "appState.startNoteSync()"),
              let purgeStart = delegate.range(of: "appState.startRecentlyDeletedPurgeSchedule()") else {
            preconditionFailure("launch calls are missing")
        }
        precondition(syncStart.lowerBound < purgeStart.lowerBound)
        let engine = try String(contentsOfFile: "Sources/NoteSyncCloudKitEngine.swift", encoding: .utf8)
        // Fetches are bracketed for the coordinator; a send alone brings no restore.
        guard let willFetch = engine.range(of: "case .willFetchChanges:"),
              let didFetch = engine.range(of: "case .didFetchChanges:"),
              let didSend = engine.range(of: "case .didSendChanges:") else {
            preconditionFailure("fetch events are missing")
        }
        let fetchCase = engine[didFetch.upperBound..<didSend.lowerBound]
        precondition(engine[willFetch.upperBound..<didFetch.lowerBound].contains("handleFetchStarted()"))
        precondition(fetchCase.contains("handleFetchCompleted(pending:") && fetchCase.contains("events.fetchFinished()"))
    }
}
