import CloudKit
import Foundation
import QuillAudioFormatCore
import QuillNoteSyncCore

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
        try await testExpiredNoteRestoredElsewhereComesBack()
        try await testNoteDeletedAgainElsewhereWaitsForItsOwnDate()
        try await testExpiredNoteIsPurgedOnceICloudAgrees()
        try await testMissingNoteInAnotherAccountWaits()
        try await testPurgeWaitsWhenICloudCantBeAsked()
        try await testOlderLiveCopyDoesNotHoldBackTheDelete()
        try await testPurgeRunsAtOnceWhenSyncIsOff()
        try await testSavedNoticesShowAtLaunch()
        try await testMarkingANoteThatIsGoneDoesNothing()
        try await testDownloadStampsOnlyWhenTheAudioArrives()
        try await testRetranscriptionStampsOnlyWhenItFinishes()
        try await testFirstTranscriptionStampsOnlyWhenItFinishes()
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
        /// What iCloud answers for each note; unlisted notes get no answer.
        var copies: [UUID: NoteCopyInICloud] = [:]
        var copiesError: Error?
        var copyChecks = 0
        func noteCopiesInICloud(_ ids: Set<UUID>) async throws -> [UUID: NoteCopyInICloud] {
            copyChecks += 1
            if let copiesError { throw copiesError }
            return Dictionary(uniqueKeysWithValues: ids.compactMap { id in copies[id].map { (id, $0) } })
        }
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
        syncOn: Bool = true,
        signedInAccount: String = "synthetic-account",
        retryDependencies: @escaping @Sendable () -> CloudTranscriptionDependencies = { .live }
    ) throws -> Fixture {
        let syncAccount = "synthetic-account"
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
        defaults.set(syncAccount, forKey: NoteSyncController.syncAccountKey)
        var dependencies = AppStateDependencies.live
        dependencies.storageLayout = layout
        dependencies.credentialStorageLayout = .isolatedForTests()
        dependencies.makePipelineHistoryStore = { _ in store }
        dependencies.makeRetryCloudTranscriptionDependencies = retryDependencies
        dependencies.makeNoteSyncController = { _ in
            NoteSyncController(defaults: defaults, unavailableReason: nil, createZone: {}, accountID: { signedInAccount }, makeEngine: { events in
                engine.events = events
                return engine
            })
        }
        let appState = AppState(dependencies: dependencies)
        appState.startNoteSync()
        engine.saves = []
        return Fixture(root: root, layout: layout, store: store, engine: engine, appState: appState)
    }

    /// The notices saved with a note (dismissed, dismissed while a
    /// condition holds, and the same-result markers) show as soon as the
    /// app starts, not only after the history next reloads (#824). Built
    /// without `makeFixture`, which starts sync, so nothing but launch
    /// can read the notices.
    static func testSavedNoticesShowAtLaunch() async throws {
        try await MainActor.run {
            let note = makeItem()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("quill-launch-notices-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let layout = AppStateStorageLayout(rootDirectory: root)
            let store = PipelineHistoryStore(storeURL: layout.historyStoreURL)
            _ = try store.append(note, maxCount: Int.max)
            try store.dismissNotice("synthetic-notice", id: note.id)
            try store.dismissNotice("synthetic-conditional", condition: "synthetic-condition", id: note.id)
            try store.setUnchangedRetranscription(.matching(note.displayedTranscript, at: t0), id: note.id)
            try store.setUnchangedSummaryRegeneration(.matching(summaryGeneratedAt: t0, at: t0), id: note.id)
            let saved = store.noticeState()
            precondition(saved.dismissed[note.id] != nil && saved.unchanged[note.id] != nil
                && saved.conditionalDismissals[note.id] != nil && saved.unchangedSummaries[note.id] != nil,
                "the store kept all four")

            var dependencies = AppStateDependencies.live
            dependencies.storageLayout = layout
            dependencies.credentialStorageLayout = .isolatedForTests()
            dependencies.makePipelineHistoryStore = { _ in store }
            let appState = AppState(dependencies: dependencies)
            precondition(appState.dismissedNoticesByNoteID == saved.dismissed, "dismissed notices stay dismissed")
            precondition(appState.unchangedRetranscriptions == saved.unchanged, "the same-transcript notice shows")
            precondition(appState.noticeDismissalsByNoteID == saved.conditionalDismissals, "conditional dismissals apply")
            precondition(appState.unchangedMeetingSummaries == saved.unchangedSummaries, "the same-summary notice shows")
        }
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

    /// iCloud's copy of a note, as another device saved it just now.
    /// `savedAt`: when that device changed it (now by default).
    static func iCloudCopy(of id: UUID, deletedAt: Date?, savedAt: Date = Date().addingTimeInterval(60)) throws -> NoteCopyInICloud {
        let item = PipelineHistoryItem(
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
            customTitle: "Synthetic",
            deletedAt: deletedAt,
            fieldClock: .uniform(savedAt)
        )
        return .found(NoteSyncFetched(noteID: id, payload: try NoteSyncPayload.encode(NoteSyncRecord(item: item)), systemFields: Data([1])))
    }

    /// #562: a purge's delete reaches every device, so with sync running
    /// iCloud is asked first. A fetch can't tell: it reaches the server only
    /// when the engine knows of a change. What iCloud holds is applied, so a
    /// restore shows here at once.
    static func testExpiredNoteRestoredElsewhereComesBack() async throws {
        let note = makeItem()
        let fixture = try await MainActor.run { try makeFixture(items: [note], deleted: [note.id: expiredDeletion]) }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Restored on another device; this Mac missed the push.
        fixture.engine.copies[note.id] = try iCloudCopy(of: note.id, deletedAt: nil)
        try await purge(fixture)
        await MainActor.run {
            precondition(fixture.engine.copyChecks == 1, "iCloud is asked before deleting")
            precondition(fixture.appState.recentlyDeletedNotes.isEmpty, "the restore is applied")
            precondition(fixture.appState.pipelineHistory.map(\.id) == [note.id], "the note is back in the list")
            precondition(fixture.store.loadAllHistory().map(\.id) == [note.id])
        }
    }

    static func testNoteDeletedAgainElsewhereWaitsForItsOwnDate() async throws {
        let note = makeItem()
        let fixture = try await MainActor.run { try makeFixture(items: [note], deleted: [note.id: expiredDeletion]) }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let again = Date().addingTimeInterval(-24 * 60 * 60)
        fixture.engine.copies[note.id] = try iCloudCopy(of: note.id, deletedAt: again)
        try await purge(fixture)
        await MainActor.run {
            precondition(fixture.appState.recentlyDeletedNotes.map(\.id) == [note.id], "deleted again a day ago: not 30 days yet")
            let deletedAt = fixture.appState.recentlyDeletedNotes.first?.deletedAt
            precondition(deletedAt.map { abs($0.timeIntervalSince(again)) < 1 } == true, "iCloud's later deletion is applied")
        }
    }

    static func testExpiredNoteIsPurgedOnceICloudAgrees() async throws {
        let expired = makeItem(), gone = makeItem(), unknown = makeItem(), unreadable = makeItem(), unanswered = makeItem()
        let notes = [expired, gone, unknown, unreadable, unanswered]
        let fixture = try await MainActor.run {
            try makeFixture(items: notes, deleted: Dictionary(uniqueKeysWithValues: notes.map { ($0.id, expiredDeletion) }))
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.engine.copies = [
            expired.id: try iCloudCopy(of: expired.id, deletedAt: expiredDeletion),
            gone.id: .noNote,
            unknown.id: .failed,
            unreadable.id: .found(NoteSyncFetched(noteID: unreadable.id, payload: Data("{".utf8), systemFields: Data([1]))),
        ]
        try await purge(fixture)
        await MainActor.run {
            precondition(
                Set(fixture.appState.recentlyDeletedNotes.map(\.id)) == [unknown.id, unreadable.id, unanswered.id],
                "expired or gone in iCloud goes; a copy not fetched, not read or not answered for waits"
            )
        }
    }

    /// iCloud answers for the account signed in now; if that isn't the
    /// account sync uses, "no such note" says nothing about this one.
    static func testMissingNoteInAnotherAccountWaits() async throws {
        let note = makeItem()
        let fixture = try await MainActor.run {
            try makeFixture(items: [note], deleted: [note.id: expiredDeletion], signedInAccount: "another-account")
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.engine.copies[note.id] = .noNote
        try await purge(fixture)
        await MainActor.run {
            precondition(fixture.appState.recentlyDeletedNotes.map(\.id) == [note.id], "not gone in the account sync uses")
        }
    }

    static func testPurgeWaitsWhenICloudCantBeAsked() async throws {
        let note = makeItem()
        let fixture = try await MainActor.run { try makeFixture(items: [note], deleted: [note.id: expiredDeletion]) }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.engine.copiesError = URLError(.notConnectedToInternet)
        // A second purge while the first asks doesn't ask again.
        let check = await MainActor.run { () -> Task<Void, Never>? in
            fixture.appState.purgeExpiredRecentlyDeletedNotes()
            fixture.appState.purgeExpiredRecentlyDeletedNotes()
            return fixture.appState.recentlyDeletedPurgeCheck
        }
        await check?.value
        await MainActor.run {
            precondition(fixture.engine.copyChecks == 1, "one check at a time")
            precondition(fixture.appState.recentlyDeletedNotes.map(\.id) == [note.id], "nothing goes without an answer")
        }
        fixture.engine.copiesError = nil
        fixture.engine.copies[note.id] = .noNote
        try await purge(fixture)
        await MainActor.run {
            precondition(fixture.appState.recentlyDeletedNotes.isEmpty, "the next purge asks again")
        }
    }

    /// This Mac's delete is newer than iCloud's live copy (its upload kept
    /// failing): the merge keeps the delete, so the note goes, and its
    /// delete replaces the older copy in iCloud.
    static func testOlderLiveCopyDoesNotHoldBackTheDelete() async throws {
        let note = makeItem()
        let fixture = try await MainActor.run { try makeFixture(items: [note], deleted: [note.id: expiredDeletion]) }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.engine.copies[note.id] = try iCloudCopy(of: note.id, deletedAt: nil, savedAt: expiredDeletion.addingTimeInterval(-60 * 60))
        try await purge(fixture)
        await MainActor.run {
            precondition(fixture.appState.recentlyDeletedNotes.isEmpty && fixture.appState.pipelineHistory.isEmpty, "the later delete wins")
        }
    }

    /// Runs a purge and waits for its iCloud check.
    static func purge(_ fixture: Fixture) async throws {
        let check = await MainActor.run { () -> Task<Void, Never>? in
            fixture.appState.purgeExpiredRecentlyDeletedNotes()
            return fixture.appState.recentlyDeletedPurgeCheck
        }
        await check?.value
    }

    static func testPurgeRunsAtOnceWhenSyncIsOff() async throws {
        try await MainActor.run {
            let note = makeItem()
            let fixture = try makeFixture(items: [note], deleted: [note.id: expiredDeletion], syncOn: false)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            fixture.appState.purgeExpiredRecentlyDeletedNotes()
            precondition(fixture.appState.recentlyDeletedNotes.isEmpty, "with sync off the purge stays on this Mac")
            precondition(fixture.engine.copyChecks == 0)
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
    }

    // MARK: - When this Mac last used a recording

    /// Stamping a note that is gone (deleted for good meanwhile) does
    /// nothing; stamping one that is here keeps the date on this Mac only.
    @MainActor
    static func testMarkingANoteThatIsGoneDoesNothing() async throws {
        let note = makeItem(audioFile: "\(UUID().uuidString).wav")
        let fixture = try makeFixture(items: [note])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.appState.markNoteAudioUsed(UUID(), now: t0)
        precondition(fixture.store.audioLastUsedAt(id: note.id) == nil, "another note isn't stamped")
        fixture.appState.markNoteAudioUsed(note.id, now: t0)
        precondition(fixture.store.audioLastUsedAt(id: note.id) == t0)
        precondition(fixture.engine.saves.isEmpty, "the date isn't sent to iCloud")
    }

    /// Serves one synthetic audio part, fails offline, or waits until the
    /// download is cancelled.
    final class StampFetcher: NoteAudioPartFetching, @unchecked Sendable {
        enum Mode { case serve(Data), offline, waitForCancel }
        var mode: Mode = .offline
        let dir: URL
        init(dir: URL) { self.dir = dir }
        func fetchAudioPart(_ part: NoteAudioPartID, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
            switch mode {
            case .offline:
                throw NoteAudioFetchError.offline
            case .waitForCancel:
                try await Task.sleep(for: .seconds(30))
                throw NoteAudioFetchError.failed
            case .serve(let data):
                let url = dir.appendingPathComponent("served-\(UUID().uuidString)")
                try data.write(to: url)
                progress(1)
                return url
            }
        }
    }

    /// A download stamps the note once the audio is here; one that fails
    /// or is cancelled doesn't.
    @MainActor
    static func testDownloadStampsOnlyWhenTheAudioArrives() async throws {
        let note = makeItem(audioFile: "\(UUID().uuidString).wav")
        let fixture = try makeFixture(items: [note])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let appState = fixture.appState
        let bytes = Data((0..<10).map { UInt8($0) })
        let source = fixture.root.appendingPathComponent("source.wav")
        try bytes.write(to: source)
        let manifest = NoteAudioManifest(sha256: try NoteAudioParts.sha256(of: source), bytes: 10, partSize: 50_000_000, parts: 1)
        try fixture.store.setAudioManifest(manifest, id: note.id)
        let fetcher = StampFetcher(dir: fixture.root)
        appState.noteAudioDownloader = NoteAudioDownloader(
            downloadsDirectory: fixture.root.appendingPathComponent("downloads", isDirectory: true),
            fetcher: { fetcher },
            isSyncOn: { true }
        )

        fetcher.mode = .offline
        let offline = await appState.downloadNoteAudio(for: note)
        precondition(offline == nil)
        precondition(fixture.store.audioLastUsedAt(id: note.id) == nil, "a failed download doesn't stamp")

        fetcher.mode = .waitForCancel
        let cancelled = Task { @MainActor in await appState.downloadNoteAudio(for: note) }
        for _ in 0..<200 where !appState.noteAudioDownloader.downloadingNotes.contains(note.id) {
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(appState.noteAudioDownloader.downloadingNotes.contains(note.id), "the download started")
        appState.cancelNoteAudioDownload(for: note)
        let stopped = await cancelled.value
        precondition(stopped == nil)
        precondition(fixture.store.audioLastUsedAt(id: note.id) == nil, "a cancelled download doesn't stamp")

        fetcher.mode = .serve(bytes)
        let start = Date()
        let downloaded = await appState.downloadNoteAudio(for: note)
        precondition(downloaded != nil)
        precondition((fixture.store.audioLastUsedAt(id: note.id) ?? .distantPast) >= start, "a finished download stamps")
    }

    /// What the synthetic cloud transcription answers.
    final class StampUpload: @unchecked Sendable {
        enum Mode { case answer(String), fail, waitForCancel }
        private let lock = NSLock()
        private var _mode: Mode = .fail
        var mode: Mode {
            get { lock.withLock { _mode } }
            set { lock.withLock { _mode = newValue } }
        }

        func dependencies() -> CloudTranscriptionDependencies {
            CloudTranscriptionDependencies(
                encodedUploadCeilingBytes: 20_000_000,
                upload: { [self] request, _ in
                    switch mode {
                    case .fail:
                        throw URLError(.cannotConnectToHost)
                    case .waitForCancel:
                        try await Task.sleep(for: .seconds(30))
                        throw URLError(.cannotConnectToHost)
                    case .answer(let text):
                        let data = try JSONSerialization.data(withJSONObject: ["text": text])
                        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                    }
                },
                checkpointStore: InMemoryCloudTranscriptionCheckpointStore(),
                progress: { _ in },
                temporaryRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("quill-stamp-upload-\(UUID().uuidString)", isDirectory: true),
                sleep: { _ in }
            )
        }
    }

    @MainActor
    static func useSyntheticCloudTranscription(_ appState: AppState) {
        appState.transcriptionAPIKey = "synthetic-key"
        appState.transcriptionAPIURL = "https://provider.example/v1"
        appState.setNoteBrowserTranscriptionChoice(.apiStandard(modelID: "whisper-large-v3"))
        appState.disablePostProcessing = true
    }

    @MainActor
    static func waitUntilRetryEnds(_ appState: AppState, noteID: UUID) async throws {
        for _ in 0..<500 {
            if !appState.retryingItemIDs.contains(noteID) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("the retranscription didn't end")
    }

    /// Retranscribing stamps the note when it finishes: saved directly,
    /// saved because the result is the same, or waiting to be compared (and
    /// again when chosen). A failed or stopped one doesn't.
    @MainActor
    static func testRetranscriptionStampsOnlyWhenItFinishes() async throws {
        let note = makeItem(audioFile: "\(UUID().uuidString).mp3")
        let upload = StampUpload()
        let fixture = try makeFixture(items: [note], retryDependencies: { upload.dependencies() })
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let appState = fixture.appState
        guard let audioURL = appState.storedAudioURL(for: note) else { preconditionFailure("no audio path") }
        try FileManager.default.createDirectory(at: audioURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: audioURL)
        useSyntheticCloudTranscription(appState)
        func current() -> PipelineHistoryItem { appState.pipelineHistory.first { $0.id == note.id }! }
        func stamp() -> Date? { fixture.store.audioLastUsedAt(id: note.id) }

        upload.mode = .fail
        appState.retryTranscription(item: current())
        precondition(appState.retryingItemIDs.contains(note.id), "the retry started")
        try await waitUntilRetryEnds(appState, noteID: note.id)
        precondition(stamp() == nil, "a failed retranscription doesn't stamp")

        upload.mode = .waitForCancel
        appState.retryTranscription(item: current())
        for _ in 0..<200 where !appState.canCancelTranscriptionRetry(current()) {
            try await Task.sleep(for: .milliseconds(5))
        }
        appState.cancelTranscriptionRetry(item: current())
        try await waitUntilRetryEnds(appState, noteID: note.id)
        precondition(stamp() == nil, "a stopped retranscription doesn't stamp")

        // The same text, compared first: saved directly as unchanged.
        try fixture.store.setAudioLastUsedAt(.distantPast, id: note.id)
        upload.mode = .answer(current().displayedTranscript)
        var start = Date()
        appState.retryTranscription(item: current(), choice: nil, comparesFirst: true)
        try await waitUntilRetryEnds(appState, noteID: note.id)
        precondition(appState.transcriptionCandidates[note.id] == nil, "nothing to compare")
        precondition((stamp() ?? .distantPast) >= start, "an unchanged result stamps")

        // A new text waits to be compared, and is chosen.
        try fixture.store.setAudioLastUsedAt(.distantPast, id: note.id)
        upload.mode = .answer("Synthetic new transcript.")
        start = Date()
        appState.retryTranscription(item: current(), choice: nil, comparesFirst: true)
        try await waitUntilRetryEnds(appState, noteID: note.id)
        precondition(appState.transcriptionCandidates[note.id] != nil, "the new text waits")
        precondition((stamp() ?? .distantPast) >= start, "a result waiting to be compared stamps")
        try fixture.store.setAudioLastUsedAt(.distantPast, id: note.id)
        start = Date()
        precondition(appState.acceptTranscriptionCandidate(noteID: note.id) == .saved)
        precondition((stamp() ?? .distantPast) >= start, "choosing the new text stamps")

        // Saved directly.
        try fixture.store.setAudioLastUsedAt(.distantPast, id: note.id)
        upload.mode = .answer("Synthetic third transcript.")
        start = Date()
        appState.retryTranscription(item: current())
        try await waitUntilRetryEnds(appState, noteID: note.id)
        precondition(current().postProcessedTranscript == "Synthetic third transcript.")
        precondition((stamp() ?? .distantPast) >= start, "a saved retranscription stamps")
    }

    /// The first transcription of an imported recording stamps the note
    /// when it finishes; one that fails doesn't.
    @MainActor
    static func testFirstTranscriptionStampsOnlyWhenItFinishes() async throws {
        let upload = StampUpload()
        let original = AppState.audioImportCloudTranscriptionDependenciesFactory
        AppState.audioImportCloudTranscriptionDependenciesFactory = { upload.dependencies() }
        defer { AppState.audioImportCloudTranscriptionDependenciesFactory = original }
        let fixture = try makeFixture(items: [])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let appState = fixture.appState
        useSyntheticCloudTranscription(appState)
        var wav = try CanonicalPCM16WAV.header(dataByteCount: 8)
        wav.append(Data([1, 0, 1, 0, 2, 0, 2, 0]))

        func importAndWait(_ name: String) async throws -> PipelineHistoryItem {
            let source = fixture.root.appendingPathComponent(name)
            try wav.write(to: source)
            let known = Set(appState.pipelineHistory.map(\.id))
            appState.importAudioFile(source, choice: .apiStandard(modelID: "whisper-large-v3"))
            for _ in 0..<1000 {
                if !appState.isTranscribing,
                   let note = appState.pipelineHistory.first(where: { !known.contains($0.id) }),
                   note.postProcessingStatus != PipelineHistoryItem.cloudTranscribingStatus {
                    return note
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            preconditionFailure("the import didn't finish")
        }

        upload.mode = .fail
        let failed = try await importAndWait("failing.wav")
        precondition(failed.rawTranscript.isEmpty, "the transcription failed")
        precondition(fixture.store.audioLastUsedAt(id: failed.id) == nil, "a failed transcription doesn't stamp")

        upload.mode = .answer("Synthetic imported transcript.")
        let start = Date()
        let transcribed = try await importAndWait("working.wav")
        precondition(transcribed.rawTranscript == "Synthetic imported transcript.", "\(transcribed.postProcessingStatus)")
        precondition((fixture.store.audioLastUsedAt(id: transcribed.id) ?? .distantPast) >= start, "a finished transcription stamps")
    }
}
