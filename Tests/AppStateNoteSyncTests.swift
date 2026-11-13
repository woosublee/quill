import CloudKit
import Foundation
import QuillAudioFormatCore
import QuillNoteSyncCore
import SQLite3

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
        try await testOffloadWaitsForTheSetting()
        try await testOffloadWaitsForSyncToRun()
        try await testOffloadRemovesOnlyTheFile()
        try await testOffloadKeepsWhatICloudDoesNotConfirm()
        try await testOffloadAsksForTheLeastRecentlyUsedFive()
        try await testOffloadKeepsANoteUsedWhileICloudAnswers()
        try await testOffloadKeepsANoteBusyWhileICloudAnswers()
        try await testOffloadSkipsARecentlyDownloadedRecording()
        try await testOffloadFallsBackToWhenTheRecordingEnded()
        try await testOffloadRunsOneAtATime()
        try await testOffloadSkipsBusyAndSharedRecordings()
        try await testOffloadSkipsAFileNamedInAnotherCaseOrForm()
        try await testOffloadKeepsAFileWhoseSizeIsNotTheMarkers()
        try await testOffloadSkipsANoteWithARecordingJournal()
        try await testOffloadSkipsAnIDTwoRowsShare()
        testOffloadChoosesWhoGoesNext()
        try await testOffloadSkipsNotesICloudDidNotConfirmForADay()
        testOffloadRetentionOverrideIsForDevelopmentOnly()
        try await testDownloadThenDeleteBringsEveryRecordingHereFirst()
        try await testDownloadThenDeleteWithTooLittleSpaceDeletesNothing()
        try await testDownloadThenDeleteStopsWhenADownloadFails()
        try await testDownloadThenDeleteCancelKeepsSyncOn()
        try await testDownloadThenDeleteWithAFailedFetchDeletesNothing()
        try await testDownloadThenDeleteWhileSyncPausedWithNoEngineDeletesNothing()
        try await testSyncStoppingMidRunDeletesNothing()
        try await testOffloadWaitsWhileDownloadThenDeleteRuns()
        try await testOffloadKeepsFilesWhenDownloadThenDeleteStartsWhileICloudAnswers()
        try await testDownloadByIDOfAnUnknownNoteIsFalse()
        try await testDownloadThenDeleteBringsARecordingThisMacDidntKnowWasInICloud()
        try await testDownloadThenDeleteImportsANoteThisMacNeverSaw()
        try await testDownloadThenDeleteStopsWhenICloudCantBeListed()
        try await testDownloadThenDeleteStopsWhenANoteCantBeRead()
        try await testOffloadWaitsDuringTheICloudCheck()
        try await testDeleteWithoutRecordingsNeverListsICloud()
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
        /// The audio parts iCloud holds, the notes each check asked about,
        /// and whether a check waits before answering.
        var partsInICloud: Set<NoteAudioPartID> = []
        var audioChecks: [Set<UUID>] = []
        var holdsAudioChecks = false
        func existingAudioParts(_ parts: [NoteAudioPartID]) async throws -> Set<NoteAudioPartID> {
            audioChecks.append(Set(parts.map(\.noteID)))
            while holdsAudioChecks { try await Task.sleep(for: .milliseconds(5)) }
            return partsInICloud.intersection(parts)
        }
        func audioParts(ofNotes ids: Set<UUID>) async throws -> [NoteAudioPartID] { [] }
        /// Every audio part iCloud holds, as the check before Download,
        /// Then Delete lists them (#839); how many listings ran, and
        /// whether one waits before answering.
        var allParts: [NoteAudioPartInICloud] = []
        var partListingError: Error?
        var partListings = 0
        var holdsPartListing = false
        func allAudioParts() async throws -> [NoteAudioPartInICloud] {
            partListings += 1
            while holdsPartListing { try await Task.sleep(for: .milliseconds(5)) }
            if let partListingError { throw partListingError }
            return allParts
        }
        /// The marker iCloud's copy of each note names; unlisted notes
        /// aren't in iCloud.
        var markersInICloud: [UUID: NoteAudioManifest] = [:]
        func audioOfNotesInICloud(_ ids: Set<UUID>, timeLimited: Bool) async throws -> [UUID: NoteAudioInICloud] {
            Dictionary(uniqueKeysWithValues: ids.map { ($0, markersInICloud[$0].map(NoteAudioInICloud.marker) ?? .noNote) })
        }
        func cancelAudioSaves(noteID: UUID) {}
        func cancelAudioDeletes(noteID: UUID) {}
        func cancelAudioDeletes(_ parts: [NoteAudioPartID]) {}
        func attach(_ coordinator: NoteSyncCoordinator) { self.coordinator = coordinator }
        func start() {}
        func fetchNow() {}
        /// What an awaited fetch returns, and how many ran.
        var fetchSucceeds = true
        var awaitedFetches = 0
        func fetchChangesAndWait() async -> Bool {
            awaitedFetches += 1
            return fetchSucceeds
        }
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

    static func makeItem(id: UUID = UUID(), title: String = "Synthetic", transcriptFile: String? = nil, audioFile: String? = nil, recordingEndedAt: Date? = nil) -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: id,
            timestamp: t0,
            recordingEndedAt: recordingEndedAt,
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
    /// `resolvesLocalAudio`: sync finds the recordings in `audio/`, as the
    /// app does; otherwise it finds none.
    @MainActor
    static func makeFixture(
        items: [PipelineHistoryItem],
        deleted: [UUID: Date] = [:],
        syncOn: Bool = true,
        resolvesLocalAudio: Bool = false,
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
        let localAudioURL: (String) -> URL? = resolvesLocalAudio ? { fileName in
            guard let url = NoteAssetStore(storageLayout: layout).storedAudioURL(fileName: fileName),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        } : { _ in nil }
        dependencies.makeNoteSyncController = { _ in
            NoteSyncController(defaults: defaults, unavailableReason: nil, createZone: {}, accountID: { signedInAccount }, localAudioURL: localAudioURL, makeEngine: { events in
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

    /// Transcribes with the synthetic cloud provider and no cleanup; the
    /// returned closure puts the settings back.
    @MainActor
    static func useSyntheticCloudTranscription(_ appState: AppState) -> @MainActor () -> Void {
        let key = appState.transcriptionAPIKey, url = appState.transcriptionAPIURL
        let choice = appState.currentNoteBrowserTranscriptionChoice
        let disablesPostProcessing = appState.disablePostProcessing
        appState.transcriptionAPIKey = "synthetic-key"
        appState.transcriptionAPIURL = "https://provider.example/v1"
        appState.setNoteBrowserTranscriptionChoice(.apiStandard(modelID: "whisper-large-v3"))
        appState.disablePostProcessing = true
        return {
            appState.disablePostProcessing = disablesPostProcessing
            appState.setNoteBrowserTranscriptionChoice(choice)
            appState.transcriptionAPIURL = url
            appState.transcriptionAPIKey = key
        }
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
        let restoreSettings = useSyntheticCloudTranscription(appState)
        defer { restoreSettings() }
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
        let restoreSettings = useSyntheticCloudTranscription(appState)
        defer { restoreSettings() }
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

    // MARK: - Optimize Storage

    static let day: TimeInterval = 24 * 60 * 60

    /// Turns Optimize Storage on or off; the returned closure puts the
    /// setting back.
    static func setOptimizeStorage(_ isOn: Bool) -> () -> Void {
        let saved = UserDefaults.standard.object(forKey: NoteAudioOffload.isOnKey)
        UserDefaults.standard.set(isOn, forKey: NoteAudioOffload.isOnKey)
        return {
            if let saved {
                UserDefaults.standard.set(saved, forKey: NoteAudioOffload.isOnKey)
            } else {
                UserDefaults.standard.removeObject(forKey: NoteAudioOffload.isOnKey)
            }
        }
    }

    /// A transcribed note with an audio file name, for the offload tests.
    static func makeRecordedItem(recordingEndedAt: Date? = nil) -> PipelineHistoryItem {
        makeItem(audioFile: "\(UUID().uuidString).wav", recordingEndedAt: recordingEndedAt)
    }

    /// Puts the note's recording here and its marker in the store; with
    /// `inICloud`, iCloud holds every part and its note names the marker.
    @MainActor
    @discardableResult
    static func addRecording(_ fixture: Fixture, _ note: PipelineHistoryItem, inICloud: Bool = true) throws -> URL {
        guard let url = fixture.appState.storedAudioURL(for: note) else { preconditionFailure("no audio path") }
        let manifest = try writeRecording(of: note, to: url)
        try fixture.store.setAudioManifest(manifest, id: note.id)
        if inICloud {
            fixture.engine.partsInICloud.formUnion(NoteAudioPartID.parts(of: note.id, sha256: manifest.sha256, count: 1))
            fixture.engine.markersInICloud[note.id] = manifest
        }
        return url
    }

    /// Writes the note's synthetic recording and returns the marker that
    /// names it, its size included.
    static func writeRecording(of note: PipelineHistoryItem, to url: URL) throws -> NoteAudioManifest {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data("synthetic-\(note.id.uuidString)".utf8)
        try data.write(to: url)
        return NoteAudioManifest(sha256: try NoteAudioParts.sha256(of: url), bytes: Int64(data.count), partSize: 50_000_000, parts: 1)
    }

    /// Runs a pass and waits for its iCloud check.
    @MainActor
    static func offload(_ fixture: Fixture, now: Date) async {
        fixture.appState.removeUnusedNoteAudio(now: now)
        await fixture.appState.noteAudioOffloadCheck?.value
    }

    /// Waits, two seconds at most, until `condition` turns false.
    @MainActor
    static func waitWhile(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            guard condition() else { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    static func waitForAudioCheck(_ fixture: Fixture) async throws {
        try await waitWhile { fixture.engine.audioChecks.isEmpty }
        precondition(!fixture.engine.audioChecks.isEmpty, "iCloud was asked")
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @MainActor
    static func testOffloadWaitsForTheSetting() async throws {
        let restore = setOptimizeStorage(false)
        defer { restore() }
        let note = makeRecordedItem()
        let fixture = try makeFixture(items: [note])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let url = try addRecording(fixture, note)
        await offload(fixture, now: t0 + 30 * day)
        precondition(fixture.engine.audioChecks.isEmpty, "the setting is off: iCloud isn't asked")
        precondition(exists(url))
    }

    @MainActor
    static func testOffloadWaitsForSyncToRun() async throws {
        let restore = setOptimizeStorage(true)
        defer { restore() }
        let note = makeRecordedItem()
        let off = try makeFixture(items: [note], syncOn: false)
        defer { try? FileManager.default.removeItem(at: off.root) }
        let offURL = try addRecording(off, note)
        await offload(off, now: t0 + 30 * day)
        precondition(off.engine.audioChecks.isEmpty && exists(offURL), "sync off: nothing is asked or removed")

        let paused = try makeFixture(items: [note])
        defer { try? FileManager.default.removeItem(at: paused.root) }
        let pausedURL = try addRecording(paused, note)
        paused.engine.coordinator?.handleAudioSendFailures([.network])
        guard case .paused = paused.appState.noteSyncController?.status else { preconditionFailure("sync is paused") }
        await offload(paused, now: t0 + 30 * day)
        precondition(paused.engine.audioChecks.isEmpty && exists(pausedURL), "sync paused: nothing is asked or removed")
    }

    /// Only the file goes: the note's audio name, marker, upload key,
    /// clocks, and iCloud fields stay, nothing is reported as changed, and
    /// the note offers the download.
    @MainActor
    static func testOffloadRemovesOnlyTheFile() async throws {
        let restore = setOptimizeStorage(true)
        defer { restore() }
        let note = makeRecordedItem()
        let fixture = try makeFixture(items: [note])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let url = try addRecording(fixture, note)
        try fixture.store.setAudioUploadKey("synthetic-upload-key", id: note.id)
        try fixture.store.setSyncSystemFields(Data([7, 7]), id: note.id)
        let record = fixture.store.syncRecord(id: note.id)
        let manifest = fixture.store.audioManifest(id: note.id)
        precondition(record != nil && manifest != nil)
        let reported = fixture.store.onChange
        var changes: [PipelineHistoryChange] = []
        fixture.store.onChange = { changes += $0; reported?($0) }
        fixture.engine.saves = []

        await offload(fixture, now: t0 + 7 * day)
        precondition(fixture.engine.audioChecks == [[note.id]])
        precondition(!exists(url), "the recording is removed from this Mac")
        precondition(fixture.store.loadAllHistory().first?.audioFileName == note.audioFileName, "the audio name stays")
        precondition(fixture.store.audioManifest(id: note.id) == manifest, "the marker stays")
        precondition(fixture.store.audioUploadKey(id: note.id) == "synthetic-upload-key", "the upload key stays")
        precondition(fixture.store.syncRecord(id: note.id) == record, "the record and its clock stay")
        precondition(fixture.store.syncSystemFields(id: note.id) == Data([7, 7]), "the iCloud fields stay")
        precondition(changes.isEmpty && fixture.engine.saves.isEmpty, "nothing is reported or sent")
        let current = fixture.appState.pipelineHistory.first { $0.id == note.id }!
        precondition(fixture.appState.noteAudioState(for: current) == .downloadable, "\(fixture.appState.noteAudioState(for: current))")
    }

    /// The least recently used first, at most five; a note asked about and
    /// not confirmed waits a day; a wait ends early for a note no longer a
    /// candidate, and a wait dated ahead of the clock is over.
    static func testOffloadChoosesWhoGoesNext() {
        let ids = (0..<7).map { _ in UUID() }
        let now = t0 + 30 * day
        let candidates = ids.enumerated().map { (id: $0.element, lastUsed: t0 + Double($0.offset) * day) }
        let wait = NoteAudioOffload.unconfirmedWait
        precondition(wait == day && NoteAudioOffload.maxPerPass == 5)

        var next = NoteAudioOffload.notesToAsk(candidates: candidates.shuffled(), waiting: [:], now: now)
        precondition(next.ask == Array(ids.prefix(5)) && next.waiting.isEmpty, "\(next)")

        let gone = UUID()
        let waiting = [ids[0]: now, ids[1]: now - wait + 1, ids[2]: now - wait, ids[3]: now + 60, gone: now]
        next = NoteAudioOffload.notesToAsk(candidates: candidates, waiting: waiting, now: now)
        precondition(next.ask == [ids[2], ids[3], ids[4], ids[5], ids[6]], "\(next)")
        precondition(next.waiting == [ids[0]: now, ids[1]: now - wait + 1], "only waits still running, for candidates: \(next.waiting)")
    }

    /// Six old recordings; iCloud never confirms the five oldest (its notes
    /// can't be read, say). They don't hold the pass up: the next pass asks
    /// about the sixth and removes it, and the five are asked again a day
    /// later, when one confirmed since is removed as usual.
    @MainActor
    static func testOffloadSkipsNotesICloudDidNotConfirmForADay() async throws {
        let restore = setOptimizeStorage(true)
        defer { restore() }
        let notes = (0..<6).map { _ in makeRecordedItem() }
        let fixture = try makeFixture(items: notes)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var urls: [UUID: URL] = [:]
        for (index, note) in notes.enumerated() {
            urls[note.id] = try addRecording(fixture, note)
            fixture.appState.markNoteAudioUsed(note.id, now: t0 + Double(index) * day)
        }
        let unconfirmed = Array(notes.prefix(5))
        for note in unconfirmed { fixture.engine.markersInICloud[note.id] = nil }
        let sixth = notes[5]
        let now = t0 + 30 * day

        await offload(fixture, now: now)
        precondition(fixture.engine.audioChecks == [Set(unconfirmed.map(\.id))], "\(fixture.engine.audioChecks)")
        precondition(urls.values.allSatisfy(exists), "nothing confirmed: every file stays")

        await offload(fixture, now: now)
        precondition(fixture.engine.audioChecks.last == [sixth.id], "\(fixture.engine.audioChecks)")
        precondition(!exists(urls[sixth.id]!), "the sixth is removed")
        precondition(unconfirmed.allSatisfy { exists(urls[$0.id]!) })

        await offload(fixture, now: now + 23 * 60 * 60)
        precondition(fixture.engine.audioChecks.count == 2, "still waiting: \(fixture.engine.audioChecks)")

        let confirmedLater = unconfirmed[0]
        fixture.engine.markersInICloud[confirmedLater.id] = fixture.store.audioManifest(id: confirmedLater.id)
        await offload(fixture, now: now + day)
        precondition(fixture.engine.audioChecks.count == 3, "\(fixture.engine.audioChecks)")
        precondition(fixture.engine.audioChecks.last == Set(unconfirmed.map(\.id)), "a day later the five are asked again")
        precondition(!exists(urls[confirmedLater.id]!), "confirmed now: removed as usual")
        precondition(unconfirmed.dropFirst().allSatisfy { exists(urls[$0.id]!) })
    }

    @MainActor
    static func testOffloadKeepsWhatICloudDoesNotConfirm() async throws {
        let restore = setOptimizeStorage(true)
        defer { restore() }
        let note = makeRecordedItem()
        let fixture = try makeFixture(items: [note])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let url = try addRecording(fixture, note, inICloud: false)
        await offload(fixture, now: t0 + 30 * day)
        precondition(fixture.engine.audioChecks == [[note.id]], "iCloud was asked")
        precondition(exists(url), "a part iCloud doesn't hold keeps the file")
    }

    @MainActor
    static func testOffloadAsksForTheLeastRecentlyUsedFive() async throws {
        let restore = setOptimizeStorage(true)
        defer { restore() }
        let notes = (0..<8).map { _ in makeRecordedItem() }
        let fixture = try makeFixture(items: notes)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var urls: [UUID: URL] = [:]
        for (index, note) in notes.enumerated() {
            urls[note.id] = try addRecording(fixture, note)
            // Used one day apart; the first one longest ago.
            fixture.appState.markNoteAudioUsed(note.id, now: t0 + Double(index) * day)
        }
        await offload(fixture, now: t0 + 30 * day)
        let oldest = Set(notes.prefix(5).map(\.id))
        precondition(fixture.engine.audioChecks == [oldest], "the five used longest ago are asked for")
        for note in notes {
            precondition(exists(urls[note.id]!) != oldest.contains(note.id), "the other three wait")
        }
        await offload(fixture, now: t0 + 30 * day)
        precondition(fixture.engine.audioChecks.last == Set(notes.suffix(3).map(\.id)), "the next pass takes them")
        precondition(urls.values.allSatisfy { !exists($0) })
    }

    @MainActor
    static func testOffloadKeepsANoteUsedWhileICloudAnswers() async throws {
        let restore = setOptimizeStorage(true)
        defer { restore() }
        let played = makeRecordedItem(), other = makeRecordedItem()
        let fixture = try makeFixture(items: [played, other])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let playedURL = try addRecording(fixture, played)
        let otherURL = try addRecording(fixture, other)
        let now = t0 + 30 * day
        fixture.engine.holdsAudioChecks = true
        fixture.appState.removeUnusedNoteAudio(now: now)
        try await waitForAudioCheck(fixture)
        fixture.appState.markNoteAudioUsed(played.id, now: now)
        fixture.engine.holdsAudioChecks = false
        await fixture.appState.noteAudioOffloadCheck?.value
        precondition(fixture.engine.audioChecks == [[played.id, other.id]])
        precondition(exists(playedURL), "played while iCloud answered: it stays")
        precondition(!exists(otherURL))
    }

    @MainActor
    static func testOffloadKeepsANoteBusyWhileICloudAnswers() async throws {
        let restore = setOptimizeStorage(true)
        defer { restore() }
        let opened = makeRecordedItem(), exported = makeRecordedItem(), other = makeRecordedItem()
        let fixture = try makeFixture(items: [opened, exported, other])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let openedURL = try addRecording(fixture, opened)
        let exportedURL = try addRecording(fixture, exported)
        let otherURL = try addRecording(fixture, other)
        fixture.engine.holdsAudioChecks = true
        fixture.appState.removeUnusedNoteAudio(now: t0 + 30 * day)
        try await waitForAudioCheck(fixture)
        fixture.appState.noteAudioPlayerAppeared(opened.id)
        fixture.appState.noteAudioExportChanged(exported.id, isRunning: true)
        fixture.engine.holdsAudioChecks = false
        await fixture.appState.noteAudioOffloadCheck?.value
        precondition(fixture.engine.audioChecks == [[opened.id, exported.id, other.id]])
        precondition(exists(openedURL), "its player came on screen meanwhile: it stays")
        precondition(exists(exportedURL), "Save Files started meanwhile: it stays")
        precondition(!exists(otherURL))
    }

    @MainActor
    static func testOffloadSkipsARecentlyDownloadedRecording() async throws {
        let restore = setOptimizeStorage(true)
        defer { restore() }
        let note = makeRecordedItem(recordingEndedAt: t0)
        let fixture = try makeFixture(items: [note])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let url = try addRecording(fixture, note)
        let now = t0 + 90 * day
        fixture.appState.markNoteAudioUsed(note.id, now: now - 60 * 60)
        await offload(fixture, now: now)
        precondition(fixture.engine.audioChecks.isEmpty, "downloaded an hour ago: not asked for")
        precondition(exists(url))
    }

    /// With no last-used date, the time the recording ended counts.
    @MainActor
    static func testOffloadFallsBackToWhenTheRecordingEnded() async throws {
        let restore = setOptimizeStorage(true)
        defer { restore() }
        let now = t0 + 30 * day
        let weekOld = makeRecordedItem(recordingEndedAt: now - 7 * day)
        let older = makeRecordedItem(recordingEndedAt: now - 20 * day)
        let recent = makeRecordedItem(recordingEndedAt: now - 7 * day + 60)
        let fixture = try makeFixture(items: [weekOld, older, recent])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for note in [weekOld, older, recent] { try addRecording(fixture, note) }
        await offload(fixture, now: now)
        precondition(fixture.engine.audioChecks == [[weekOld.id, older.id]], "\(fixture.engine.audioChecks)")
    }

    @MainActor
    static func testOffloadRunsOneAtATime() async throws {
        let restore = setOptimizeStorage(true)
        defer { restore() }
        let note = makeRecordedItem()
        let fixture = try makeFixture(items: [note])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let url = try addRecording(fixture, note)
        fixture.engine.holdsAudioChecks = true
        fixture.appState.removeUnusedNoteAudio(now: t0 + 30 * day)
        let first = fixture.appState.noteAudioOffloadCheck
        try await waitForAudioCheck(fixture)
        fixture.appState.removeUnusedNoteAudio(now: t0 + 30 * day)
        precondition(fixture.appState.noteAudioOffloadCheck == first, "the second call starts nothing")
        fixture.engine.holdsAudioChecks = false
        await first?.value
        precondition(fixture.engine.audioChecks.count == 1, "one check at a time")
        precondition(!exists(url))
    }

    /// Busy before the pass, or a file another note also names: not asked for.
    @MainActor
    static func testOffloadSkipsBusyAndSharedRecordings() async throws {
        let restore = setOptimizeStorage(true)
        defer { restore() }
        let shared = "\(UUID().uuidString).wav"
        let first = makeItem(audioFile: shared), second = makeItem(audioFile: shared)
        let played = makeRecordedItem(), saved = makeRecordedItem(), resuming = makeRecordedItem()
        let fixture = try makeFixture(items: [first, second, played, saved, resuming])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sharedURL = try addRecording(fixture, first)
        try addRecording(fixture, second)
        for note in [played, saved, resuming] { try addRecording(fixture, note) }
        let appState = fixture.appState
        appState.noteAudioPlayerAppeared(played.id)
        appState.noteAudioPlayerAppeared(played.id)
        appState.noteAudioPlayerDisappeared(played.id)
        appState.noteAudioExportChanged(saved.id, isRunning: true)
        // A saved cloud job, even one that can't be read, resumes from the file.
        let jobs = fixture.layout.cloudTranscriptionJobsDirectory
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: jobs.appendingPathComponent("\(resuming.id.uuidString).json"))
        precondition(appState.isNoteAudioBusy(played.id), "one of its two players is still on screen")
        precondition(appState.isNoteAudioBusy(saved.id) && appState.isNoteAudioBusy(resuming.id))
        await offload(fixture, now: t0 + 30 * day)
        precondition(fixture.engine.audioChecks.isEmpty, "\(fixture.engine.audioChecks)")
        precondition(exists(sharedURL))

        appState.noteAudioPlayerDisappeared(played.id)
        appState.noteAudioExportChanged(saved.id, isRunning: false)
        precondition(!appState.isNoteAudioBusy(played.id) && !appState.isNoteAudioBusy(saved.id))
        await offload(fixture, now: t0 + 30 * day)
        precondition(fixture.engine.audioChecks == [[played.id, saved.id]], "\(fixture.engine.audioChecks)")
    }

    /// Another note names the same file in another case or Unicode form,
    /// which the Mac's disk usually doesn't tell apart: neither is asked
    /// for, and the file stays.
    @MainActor
    static func testOffloadSkipsAFileNamedInAnotherCaseOrForm() async throws {
        let restore = setOptimizeStorage(true)
        defer { restore() }
        let base = UUID().uuidString
        let upper = makeItem(audioFile: "\(base).WAV"), lower = makeItem(audioFile: "\(base.lowercased()).wav")
        let composed = makeItem(audioFile: "\(base)-\u{E9}.wav"), decomposed = makeItem(audioFile: "\(base)-e\u{301}.wav")
        let other = makeRecordedItem()
        let fixture = try makeFixture(items: [upper, lower, composed, decomposed, other])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var urls: [URL] = []
        for (named, alsoNaming) in [(upper, lower), (composed, decomposed)] {
            urls.append(try addRecording(fixture, named))
            guard let manifest = fixture.store.audioManifest(id: named.id) else { preconditionFailure("no marker") }
            try fixture.store.setAudioManifest(manifest, id: alsoNaming.id)
            fixture.engine.partsInICloud.formUnion(NoteAudioPartID.parts(of: alsoNaming.id, sha256: manifest.sha256, count: 1))
            fixture.engine.markersInICloud[alsoNaming.id] = manifest
        }
        let otherURL = try addRecording(fixture, other)
        await offload(fixture, now: t0 + 30 * day)
        precondition(fixture.engine.audioChecks == [[other.id]], "\(fixture.engine.audioChecks)")
        precondition(urls.allSatisfy(exists) && !exists(otherURL))
    }

    /// The file here must be the size its marker names: one that isn't is
    /// never asked for, and one whose size changes while iCloud answers
    /// stays.
    @MainActor
    static func testOffloadKeepsAFileWhoseSizeIsNotTheMarkers() async throws {
        let restore = setOptimizeStorage(true)
        defer { restore() }
        let differs = makeRecordedItem(), grows = makeRecordedItem(), other = makeRecordedItem()
        let fixture = try makeFixture(items: [differs, grows, other])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let differsURL = try addRecording(fixture, differs)
        guard let marked = fixture.store.audioManifest(id: differs.id) else { preconditionFailure("no marker") }
        try fixture.store.setAudioManifest(
            NoteAudioManifest(sha256: marked.sha256, bytes: marked.bytes + 1, partSize: marked.partSize, parts: marked.parts),
            id: differs.id
        )
        let growsURL = try addRecording(fixture, grows)
        let otherURL = try addRecording(fixture, other)
        fixture.engine.holdsAudioChecks = true
        fixture.appState.removeUnusedNoteAudio(now: t0 + 30 * day)
        try await waitForAudioCheck(fixture)
        let handle = try FileHandle(forWritingTo: growsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        fixture.engine.holdsAudioChecks = false
        await fixture.appState.noteAudioOffloadCheck?.value
        precondition(fixture.engine.audioChecks == [[grows.id, other.id]], "a size the marker doesn't name: not asked for")
        precondition(exists(differsURL), "its size isn't the marker's: it stays")
        precondition(exists(growsURL), "its size changed while iCloud answered: it stays")
        precondition(!exists(otherURL))
    }

    /// A note whose recording journal is still here: launch recovery reads
    /// the recording's file while the journal is around, so it stays.
    @MainActor
    static func testOffloadSkipsANoteWithARecordingJournal() async throws {
        let restore = setOptimizeStorage(true)
        defer { restore() }
        let journaled = makeRecordedItem(), other = makeRecordedItem()
        let fixture = try makeFixture(items: [journaled, other])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let journaledURL = try addRecording(fixture, journaled)
        let otherURL = try addRecording(fixture, other)
        let journal = RecordingJournalStore(audioDirectory: fixture.layout.audioDirectory)
            .recordingDirectory(recordingID: journaled.id)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        await offload(fixture, now: t0 + 30 * day)
        precondition(fixture.engine.audioChecks == [[other.id]], "\(fixture.engine.audioChecks)")
        precondition(exists(journaledURL) && !exists(otherURL))
    }

    /// Gives the row naming `file` the id of the row naming `idOf`, so two
    /// rows share an id. The store never writes that; a damaged one could.
    static func shareID(storeURL: URL, rowNaming file: String, withRowNaming idOf: String) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            preconditionFailure("the synthetic store doesn't open")
        }
        defer { sqlite3_close(db) }
        let sql = "UPDATE ZPIPELINEHISTORYENTRY SET ZID = (SELECT ZID FROM ZPIPELINEHISTORYENTRY WHERE ZAUDIOFILENAME = '\(idOf)') WHERE ZAUDIOFILENAME = '\(file)'"
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK && sqlite3_changes(db) == 1, "the row takes the other's id")
    }

    /// Two rows that share an id, made after launch (a launch with such
    /// rows stops earlier, in the cloud transcription reconcile): the pass
    /// runs on (it runs hourly and at launch) and asks for neither.
    @MainActor
    static func testOffloadSkipsAnIDTwoRowsShare() async throws {
        let restore = setOptimizeStorage(true)
        defer { restore() }
        let first = makeRecordedItem(), second = makeRecordedItem(), other = makeRecordedItem()
        let fixture = try makeFixture(items: [first, other])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstURL = try addRecording(fixture, first)
        let otherURL = try addRecording(fixture, other)
        // Written through a second store, so the app's store reads the new
        // row from disk.
        guard let secondURL = fixture.appState.storedAudioURL(for: second) else { preconditionFailure("no audio path") }
        let secondManifest = try writeRecording(of: second, to: secondURL)
        let writer = PipelineHistoryStore(storeURL: fixture.layout.historyStoreURL)
        _ = try writer.append(second, maxCount: Int.max)
        try writer.setAudioManifest(secondManifest, id: second.id)
        shareID(storeURL: fixture.layout.historyStoreURL, rowNaming: second.audioFileName!, withRowNaming: first.audioFileName!)
        fixture.engine.partsInICloud.formUnion(NoteAudioPartID.parts(of: first.id, sha256: secondManifest.sha256, count: 1))
        precondition(fixture.store.audioOffloadSnapshots().filter { $0.id == first.id && $0.manifest != nil }.count == 2, "two marked rows share the id")
        await offload(fixture, now: t0 + 30 * day)
        precondition(fixture.engine.audioChecks == [[other.id]], "\(fixture.engine.audioChecks)")
        precondition(exists(firstURL) && exists(secondURL) && !exists(otherURL))
    }

    /// The shortened period is for a development build's manual check only.
    static func testOffloadRetentionOverrideIsForDevelopmentOnly() {
        let week = NoteAudioOffloadPolicy.retention
        let arguments = ["Quill", NoteAudioOffload.retentionArgument, "60"]
        precondition(NoteAudioOffload.retention(bundleIdentifier: "com.woosublee.quill.dev", arguments: arguments) == 60)
        precondition(NoteAudioOffload.retention(bundleIdentifier: "com.woosublee.quill", arguments: arguments) == week, "never in the released app")
        precondition(NoteAudioOffload.retention(bundleIdentifier: nil, arguments: arguments) == week)
        precondition(NoteAudioOffload.retention(bundleIdentifier: "com.woosublee.quill.dev", arguments: ["Quill"]) == week)
        for bad in ["0", "-5", "nan", "inf", "soon"] {
            precondition(NoteAudioOffload.retention(bundleIdentifier: "com.woosublee.quill.dev", arguments: ["Quill", NoteAudioOffload.retentionArgument, bad]) == week, bad)
        }
        // The policy's `now`, moved so its week means the shorter period.
        let now = t0 + 30 * day
        precondition(NoteAudioOffload.policyNow(now, retention: week) == now)
        let note = NoteAudioOffloadPolicy.Note(
            hasMarker: true, hasTranscript: true, hasLocalAudio: true, isBusy: false,
            isRecentlyDeleted: false, hasUnrecoveredPieces: false,
            lastUsedAt: now - 61, recordingEndedAt: nil, createdAt: t0
        )
        precondition(NoteAudioOffloadPolicy.isCandidate(note, isOptimizeOn: true, isSyncRunning: true, now: NoteAudioOffload.policyNow(now, retention: 60)))
        var recent = note
        recent.lastUsedAt = now - 59
        precondition(!NoteAudioOffloadPolicy.isCandidate(recent, isOptimizeOn: true, isSyncRunning: true, now: NoteAudioOffload.policyNow(now, retention: 60)))
        recent.lastUsedAt = now + day
        precondition(!NoteAudioOffloadPolicy.isCandidate(recent, isOptimizeOn: true, isSyncRunning: true, now: NoteAudioOffload.policyNow(now, retention: 60)), "a date ahead never counts")
    }

    // MARK: Download, then Turn Off and Delete from iCloud

    /// Recordings only in iCloud: a marker for synthetic bytes and no file
    /// here. Downloads go through `fetcher`; free space is plenty.
    struct DownloadThenDeleteFixture {
        let fixture: Fixture
        let fetcher: StampFetcher
        let bytes: Data
        let manifest: NoteAudioManifest
        var downloadsDirectory: URL { fixture.root.appendingPathComponent("downloads", isDirectory: true) }
        @MainActor var runner: NoteAudioDownloadThenDelete { fixture.appState.noteAudioDownloadThenDelete }
    }

    @MainActor
    static func makeDownloadThenDeleteFixture(
        items: [PipelineHistoryItem],
        onlyInICloud: [PipelineHistoryItem],
        deleted: [UUID: Date] = [:]
    ) throws -> DownloadThenDeleteFixture {
        let fixture = try makeFixture(items: items, deleted: deleted, resolvesLocalAudio: true)
        let bytes = Data("synthetic-recording-only-in-icloud".utf8)
        let source = fixture.root.appendingPathComponent("source.wav")
        try bytes.write(to: source)
        let manifest = NoteAudioManifest(sha256: try NoteAudioParts.sha256(of: source), bytes: Int64(bytes.count), partSize: 50_000_000, parts: 1)
        try FileManager.default.removeItem(at: source)
        for note in onlyInICloud { try fixture.store.setAudioManifest(manifest, id: note.id) }
        let fetcher = StampFetcher(dir: fixture.root)
        fetcher.mode = .serve(bytes)
        let appState = fixture.appState
        appState.noteAudioDownloader = NoteAudioDownloader(
            downloadsDirectory: fixture.root.appendingPathComponent("downloads", isDirectory: true),
            fetcher: { fetcher },
            isSyncOn: { true }
        )
        appState.noteAudioFreeBytes = { 1 << 40 }
        return DownloadThenDeleteFixture(fixture: fixture, fetcher: fetcher, bytes: bytes, manifest: manifest)
    }

    @MainActor
    static func waitUntilDownloading(_ runner: NoteAudioDownloadThenDelete) async throws {
        func downloading() -> Bool { if case .downloading = runner.phase { return true }; return false }
        try await waitWhile { !downloading() }
        precondition(downloading(), "a download started")
    }

    /// Sync finds the recordings here: its launch check must end before a
    /// recording is added, or it reads the new file without its marker and
    /// holds the note back from the pass until the next sync.
    @MainActor
    static func settleAudio(_ fixture: Fixture) async {
        await fixture.engine.coordinator?.lastAudioCheck?.value
    }

    @MainActor
    static func audioURL(_ fixture: Fixture, _ note: PipelineHistoryItem) -> URL {
        guard let url = fixture.appState.storedAudioURL(for: note) else { preconditionFailure("no audio path") }
        return url
    }

    @MainActor
    static func testDownloadThenDeleteBringsEveryRecordingHereFirst() async throws {
        let listed = makeRecordedItem(), deleted = makeRecordedItem()
        let setup = try makeDownloadThenDeleteFixture(
            items: [listed, deleted], onlyInICloud: [listed, deleted], deleted: [deleted.id: t0]
        )
        let fixture = setup.fixture
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        precondition(fixture.appState.recentlyDeletedNotes.contains { $0.id == deleted.id }, "one note is in Recently Deleted")
        let start = Date()
        let outcome = await setup.runner.run()
        precondition(outcome == .deleted, "\(outcome)")
        precondition(fixture.engine.awaitedFetches == 2, "fetched first and before the delete: \(fixture.engine.awaitedFetches)")
        for note in [listed, deleted] {
            precondition((try? Data(contentsOf: audioURL(fixture, note))) == setup.bytes, "the recording is here")
            precondition((fixture.store.audioLastUsedAt(id: note.id) ?? .distantPast) >= start, "the download stamps the note")
        }
        precondition(fixture.appState.noteSyncController?.isEnabled == false, "sync is off")
        let names = Dictionary(uniqueKeysWithValues: fixture.store.loadAllHistory().map { ($0.id, $0.audioFileName) })
        precondition(names[listed.id] == listed.audioFileName && names[deleted.id] == deleted.audioFileName, "the audio names stay")
    }

    @MainActor
    static func testDownloadThenDeleteWithTooLittleSpaceDeletesNothing() async throws {
        let first = makeRecordedItem(), second = makeRecordedItem()
        let setup = try makeDownloadThenDeleteFixture(items: [first, second], onlyInICloud: [first, second])
        let fixture = setup.fixture
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.appState.noteAudioFreeBytes = { 0 }
        let outcome = await setup.runner.run()
        guard case .notEnoughSpace = outcome else { preconditionFailure("\(outcome)") }
        precondition(!exists(audioURL(fixture, first)) && !exists(audioURL(fixture, second)), "nothing was downloaded")
        precondition(fixture.appState.noteSyncController?.isEnabled == true, "sync stays on")
        precondition(fixture.store.audioManifest(id: first.id) == setup.manifest && fixture.store.audioManifest(id: second.id) == setup.manifest)
    }

    @MainActor
    static func testDownloadThenDeleteStopsWhenADownloadFails() async throws {
        let first = makeRecordedItem(), second = makeRecordedItem()
        let setup = try makeDownloadThenDeleteFixture(items: [first, second], onlyInICloud: [first, second])
        let fixture = setup.fixture
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        setup.fetcher.mode = .offline
        let outcome = await setup.runner.run()
        precondition(outcome == .downloadFailed, "\(outcome)")
        precondition(fixture.appState.noteSyncController?.isEnabled == true, "sync stays on")
        precondition(fixture.store.audioManifest(id: first.id) == setup.manifest && fixture.store.audioManifest(id: second.id) == setup.manifest)
    }

    @MainActor
    static func testDownloadThenDeleteCancelKeepsSyncOn() async throws {
        let note = makeRecordedItem()
        let setup = try makeDownloadThenDeleteFixture(items: [note], onlyInICloud: [note])
        let fixture = setup.fixture
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        setup.fetcher.mode = .waitForCancel
        let runner = setup.runner
        let running = Task { @MainActor in await runner.run() }
        try await waitUntilDownloading(runner)
        func partials() -> [URL] {
            let files = (try? FileManager.default.contentsOfDirectory(at: setup.downloadsDirectory, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "partial" }
        }
        try await waitWhile { partials().isEmpty }
        precondition(!partials().isEmpty, "the download writes a partial file while it waits")
        runner.cancel()
        let outcome = await running.value
        precondition(outcome == .cancelled, "\(outcome)")
        precondition(fixture.appState.noteSyncController?.isEnabled == true, "sync stays on")
        precondition(partials().isEmpty, "no partial download is left")
    }

    /// The fetch before reading the list fails: nothing is downloaded or
    /// deleted, and sync stays on.
    @MainActor
    static func testDownloadThenDeleteWithAFailedFetchDeletesNothing() async throws {
        let note = makeRecordedItem()
        let setup = try makeDownloadThenDeleteFixture(items: [note], onlyInICloud: [note])
        let fixture = setup.fixture
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.engine.fetchSucceeds = false
        let outcome = await setup.runner.run()
        precondition(outcome == .downloadFailed, "\(outcome)")
        precondition(fixture.engine.awaitedFetches == 1, "\(fixture.engine.awaitedFetches)")
        precondition(!exists(audioURL(fixture, note)), "nothing was downloaded")
        precondition(fixture.appState.noteSyncController?.isEnabled == true, "sync stays on")
        precondition(fixture.store.audioManifest(id: note.id) == setup.manifest, "the marker stays")
    }

    /// Sync paused for notes it couldn't save here runs no engine, so
    /// nothing can download (#838): the run says sync is paused, fetches
    /// and deletes nothing, and keeps the marker and sync on.
    @MainActor
    static func testDownloadThenDeleteWhileSyncPausedWithNoEngineDeletesNothing() async throws {
        let note = makeRecordedItem()
        let setup = try makeDownloadThenDeleteFixture(items: [note], onlyInICloud: [note])
        let fixture = setup.fixture
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        guard let controller = fixture.appState.noteSyncController else { preconditionFailure("no sync") }
        // A note that can't be saved here starts sync over (on the main
        // queue, after this returns); a second one soon after pauses it
        // with no engine.
        let first = fixture.engine.coordinator
        first?.onNeedsFullRefetch?()
        try await waitWhile { fixture.engine.coordinator === first }
        precondition(fixture.engine.coordinator !== first, "sync started over once")
        fixture.engine.coordinator?.onNeedsFullRefetch?()
        try await waitWhile { controller.isEngineRunning }
        precondition(controller.status == .paused(.couldNotSaveHere) && controller.isEnabled, "\(controller.status)")
        precondition(!controller.isEngineRunning, "no engine runs")
        await settleAudio(fixture)
        let fetchesBefore = fixture.engine.awaitedFetches
        // Starting over checks the markers against iCloud; the run itself
        // must change none.
        let markerBefore = fixture.store.audioManifest(id: note.id)
        let namesBefore = Dictionary(uniqueKeysWithValues: fixture.store.loadAllHistory().map { ($0.id, $0.audioFileName) })
        let outcome = await setup.runner.run()
        precondition(outcome == .syncPaused, "\(outcome)")
        precondition(setup.runner.notice == .syncPaused)
        precondition(fixture.engine.awaitedFetches == fetchesBefore, "nothing was fetched")
        precondition(!exists(audioURL(fixture, note)), "nothing was downloaded")
        precondition(controller.isEnabled, "sync stays on")
        precondition(fixture.store.audioManifest(id: note.id) == markerBefore, "the marker stays")
        let names = Dictionary(uniqueKeysWithValues: fixture.store.loadAllHistory().map { ($0.id, $0.audioFileName) })
        precondition(names == namesBefore && names[note.id] == note.audioFileName, "the audio names stay")
    }

    /// Sync stopping cancels every download (`onEngineStop`): the run
    /// stops as a failed download, and nothing is deleted.
    @MainActor
    static func testSyncStoppingMidRunDeletesNothing() async throws {
        let note = makeRecordedItem()
        let setup = try makeDownloadThenDeleteFixture(items: [note], onlyInICloud: [note])
        let fixture = setup.fixture
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        setup.fetcher.mode = .waitForCancel
        let runner = setup.runner
        let running = Task { @MainActor in await runner.run() }
        try await waitUntilDownloading(runner)
        fixture.appState.noteAudioDownloader.cancelAll()
        let outcome = await running.value
        precondition(outcome == .downloadFailed, "\(outcome)")
        precondition(fixture.store.audioManifest(id: note.id) == setup.manifest, "the marker stays")
    }

    @MainActor
    static func testOffloadWaitsWhileDownloadThenDeleteRuns() async throws {
        let restore = setOptimizeStorage(true)
        defer { restore() }
        let old = makeRecordedItem(), onlyInICloud = makeRecordedItem()
        let setup = try makeDownloadThenDeleteFixture(items: [old, onlyInICloud], onlyInICloud: [onlyInICloud])
        let fixture = setup.fixture
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await settleAudio(fixture)
        let url = try addRecording(fixture, old)
        setup.fetcher.mode = .waitForCancel
        let runner = setup.runner
        let running = Task { @MainActor in await runner.run() }
        try await waitUntilDownloading(runner)
        await offload(fixture, now: t0 + 30 * day)
        precondition(fixture.engine.audioChecks.isEmpty, "the pass waits: iCloud isn't asked")
        precondition(exists(url), "the recording stays")
        runner.cancel()
        _ = await running.value
    }

    @MainActor
    static func testOffloadKeepsFilesWhenDownloadThenDeleteStartsWhileICloudAnswers() async throws {
        let restore = setOptimizeStorage(true)
        defer { restore() }
        let old = makeRecordedItem(), onlyInICloud = makeRecordedItem()
        let setup = try makeDownloadThenDeleteFixture(items: [old, onlyInICloud], onlyInICloud: [onlyInICloud])
        let fixture = setup.fixture
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await settleAudio(fixture)
        let url = try addRecording(fixture, old)
        fixture.engine.holdsAudioChecks = true
        fixture.appState.removeUnusedNoteAudio(now: t0 + 30 * day)
        try await waitForAudioCheck(fixture)
        setup.fetcher.mode = .waitForCancel
        let runner = setup.runner
        let running = Task { @MainActor in await runner.run() }
        try await waitUntilDownloading(runner)
        fixture.engine.holdsAudioChecks = false
        await fixture.appState.noteAudioOffloadCheck?.value
        precondition(fixture.engine.audioChecks == [[old.id]], "\(fixture.engine.audioChecks)")
        precondition(exists(url), "started while iCloud answered: the recording stays")
        runner.cancel()
        _ = await running.value
    }

    @MainActor
    static func testDownloadByIDOfAnUnknownNoteIsFalse() async throws {
        let note = makeRecordedItem()
        let fixture = try makeFixture(items: [note])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let downloaded = await fixture.appState.downloadNoteAudio(noteID: UUID())
        precondition(!downloaded)
        // A note here with no marker in iCloud has nothing to download.
        precondition(fixture.store.audioManifest(id: note.id) == nil)
        let withoutMarker = await fixture.appState.downloadNoteAudio(noteID: note.id)
        precondition(!withoutMarker)
    }

    // MARK: Download, Then Delete asks iCloud's own list (#839)

    /// iCloud's copy of `note` with its recording marked, as another device
    /// saved it just now.
    static func markedICloudCopy(of note: PipelineHistoryItem, _ manifest: NoteAudioManifest) throws -> NoteCopyInICloud {
        var record = NoteSyncRecord(item: note)
        record.clock = NoteFieldClock.uniform(Date().addingTimeInterval(60)).roundedToMilliseconds()
        record.fields[NoteSyncField.audioManifest.rawValue] = .data(manifest.encoded())
        return .found(NoteSyncFetched(noteID: note.id, payload: try NoteSyncPayload.encode(record), systemFields: Data([1])))
    }

    static func partsInICloud(of id: UUID, _ manifest: NoteAudioManifest) -> [NoteAudioPartInICloud] {
        NoteAudioPartID.parts(of: id, sha256: manifest.sha256, count: manifest.parts).map {
            NoteAudioPartInICloud(part: $0, saved: Date())
        }
    }

    /// Another device made a recording iCloud-only, and this Mac never
    /// heard: no marker here, no file. The check finds it, it's downloaded
    /// under the name it had, and only then is iCloud deleted.
    @MainActor
    static func testDownloadThenDeleteBringsARecordingThisMacDidntKnowWasInICloud() async throws {
        let note = makeRecordedItem()
        let setup = try makeDownloadThenDeleteFixture(items: [note], onlyInICloud: [])
        let fixture = setup.fixture
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await settleAudio(fixture)
        precondition(fixture.store.audioManifest(id: note.id) == nil && !exists(audioURL(fixture, note)))
        fixture.engine.allParts = partsInICloud(of: note.id, setup.manifest)
        fixture.engine.copies[note.id] = try markedICloudCopy(of: note, setup.manifest)
        let outcome = await setup.runner.run()
        precondition(outcome == .deleted, "\(outcome)")
        precondition((try? Data(contentsOf: audioURL(fixture, note))) == setup.bytes, "the recording is here")
        let names = Dictionary(uniqueKeysWithValues: fixture.store.loadAllHistory().map { ($0.id, $0.audioFileName) })
        precondition(names[note.id] == note.audioFileName, "the audio name stays")
        precondition(fixture.appState.noteSyncController?.isEnabled == false, "sync is off")
    }

    /// The note itself never reached this Mac: the check brings it, the
    /// lists show it before its recording downloads, and the delete follows.
    @MainActor
    static func testDownloadThenDeleteImportsANoteThisMacNeverSaw() async throws {
        let note = makeRecordedItem()
        let setup = try makeDownloadThenDeleteFixture(items: [], onlyInICloud: [])
        let fixture = setup.fixture
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await settleAudio(fixture)
        fixture.engine.allParts = partsInICloud(of: note.id, setup.manifest)
        fixture.engine.copies[note.id] = try markedICloudCopy(of: note, setup.manifest)
        let outcome = await setup.runner.run()
        precondition(outcome == .deleted, "\(outcome)")
        precondition(fixture.appState.pipelineHistory.contains { $0.id == note.id }, "the note is listed")
        precondition((try? Data(contentsOf: audioURL(fixture, note))) == setup.bytes, "the recording is here")
    }

    /// iCloud's list can't be read: nothing is deleted, and sync stays on.
    @MainActor
    static func testDownloadThenDeleteStopsWhenICloudCantBeListed() async throws {
        let note = makeRecordedItem()
        let setup = try makeDownloadThenDeleteFixture(items: [note], onlyInICloud: [])
        let fixture = setup.fixture
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await settleAudio(fixture)
        try addRecording(fixture, note)
        let marker = fixture.store.audioManifest(id: note.id)
        fixture.engine.partListingError = CKError(.networkUnavailable)
        let outcome = await setup.runner.run()
        precondition(outcome == .cannotCheck, "\(outcome)")
        precondition(setup.runner.notice == .cannotCheck)
        precondition(fixture.appState.noteSyncController?.isEnabled == true, "sync stays on")
        precondition(fixture.store.audioManifest(id: note.id) == marker, "the marker stays")
    }

    /// iCloud holds parts of a note whose copy can't be read: nothing is
    /// deleted, and sync stays on.
    @MainActor
    static func testDownloadThenDeleteStopsWhenANoteCantBeRead() async throws {
        let note = makeRecordedItem()
        let setup = try makeDownloadThenDeleteFixture(items: [note], onlyInICloud: [])
        let fixture = setup.fixture
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await settleAudio(fixture)
        fixture.engine.allParts = partsInICloud(of: note.id, setup.manifest)
        fixture.engine.copies[note.id] = .failed
        let outcome = await setup.runner.run()
        precondition(outcome == .cannotCheck, "\(outcome)")
        precondition(fixture.appState.noteSyncController?.isEnabled == true, "sync stays on")
        precondition(!exists(audioURL(fixture, note)), "nothing was downloaded")
    }

    /// While iCloud's list is read, an offload pass asks nothing and
    /// removes nothing.
    @MainActor
    static func testOffloadWaitsDuringTheICloudCheck() async throws {
        let restore = setOptimizeStorage(true)
        defer { restore() }
        let old = makeRecordedItem()
        let setup = try makeDownloadThenDeleteFixture(items: [old], onlyInICloud: [])
        let fixture = setup.fixture
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await settleAudio(fixture)
        let url = try addRecording(fixture, old)
        let listingsBefore = fixture.engine.partListings
        fixture.engine.holdsPartListing = true
        let runner = setup.runner
        let running = Task { @MainActor in await runner.run() }
        try await waitWhile { fixture.engine.partListings == listingsBefore }
        precondition(fixture.engine.partListings > listingsBefore, "iCloud's list is being read")
        precondition(runner.phase == .checking)
        await offload(fixture, now: t0 + 30 * day)
        precondition(fixture.engine.audioChecks.isEmpty, "the pass waits: iCloud isn't asked")
        precondition(exists(url), "the recording stays")
        runner.cancel()
        fixture.engine.holdsPartListing = false
        let outcome = await running.value
        precondition(outcome == .cancelled, "\(outcome)")
        precondition(exists(url))
    }

    /// Delete Without Recordings deletes at once: iCloud's list isn't read.
    @MainActor
    static func testDeleteWithoutRecordingsNeverListsICloud() async throws {
        let note = makeRecordedItem()
        let setup = try makeDownloadThenDeleteFixture(items: [note], onlyInICloud: [note])
        let fixture = setup.fixture
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await settleAudio(fixture)
        let listingsBefore = fixture.engine.partListings
        guard let controller = fixture.appState.noteSyncController else { preconditionFailure("no sync") }
        let deleted = await controller.turnOff(deleteFromICloud: true)
        precondition(deleted)
        precondition(fixture.engine.partListings == listingsBefore, "\(fixture.engine.partListings)")
        precondition(!controller.isEnabled)
    }
}
