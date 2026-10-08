import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct MeetingSummaryAppStateTests {
    static func main() async throws {
        try await testAppStateInstancesUseIndependentSummaryGenerators()
        try await testCreatedAppStateKeepsItsSummaryDependencySnapshot()
        try await testGenerationPersistsOnlyAfterSuccess()
        try await testNonDurableHistoryWarningPreventsSummaryPersistence()
        try await testHistoryReadFailureMapsToPersistenceWarning()
        try await testLanguageMismatchPreservesSummaryAndRecordsAttempt()
        try await testSuccessfulAttemptSurvivesDurableReload()
        try await testFailedAttemptSurvivesDurableReload()
        try await testTranscriptChangeDiscardsInflightResult()
        try await testSuccessfulRetryInvalidatesInflightSummaryGeneration()
        try await testNoteBrowserRetryComparesBeforeSaving()
        try await testRetryWithMissingHistoryEntryKeepsSummaryGenerationActive()
        try await testDeleteWithMissingHistoryEntryKeepsSummaryGenerationActive()
        try await testClearWithSaveFailureKeepsSummaryGenerationActive()
        try await testDeleteDuringGenerationDoesNotRestoreSummary()
        try await testTranscriptReplacementReinfersDerivedSpokenLanguage()
        try await testTranscriptReplacementPreservesEngineDetectedLanguage()
        try await testTranscriptEditingPreservesNonEditedMetadata()
        try await testActionCompletionPersists()
        try await testSummaryEditPersistsAndReverts()
        try await testCandidateComparisonKeepsOrReplacesEditedSummary()
        try await testPostProcessingDisabledDoesNotBlockSummary()
        try await testDeleteMeetingSummaryRemovesEntireSummaryState()
        try await testDeleteMeetingSummaryRemovesFailedOnlyState()
        try await testDeleteMeetingSummaryRejectsStaleFailedAttempt()
        try await testDeleteFailedSummaryStatePersistsAndInvalidatesInflightGeneration()
        try await testFailedSummaryDeletePreservesStateWhenDurableWriteFails()
        try await testDeleteMeetingSummaryWithoutExistingSummaryThrows()
        try await testSuccessfulGenerationMarksPendingRevealConsumableOnce()
        print("MeetingSummaryAppStateTests passed")
    }

    private static func testAppStateInstancesUseIndependentSummaryGenerators() async throws {
        let firstFixture = try configuredAppStateFixture()
        defer { firstFixture.cleanup() }
        let secondFixture = try configuredAppStateFixture()
        defer { secondFixture.cleanup() }
        let firstItem = makeItem()
        let secondItem = makeItem()
        let firstGenerator = MeetingSummaryGeneratorStub { _ in
            makeGenerationResult(overview: "first generator")
        }
        let secondGenerator = MeetingSummaryGeneratorStub { _ in
            makeGenerationResult(overview: "second generator")
        }
        let firstState = try await configuredAppState(
            item: firstItem,
            store: firstFixture.store,
            generator: firstGenerator,
            storageLayout: firstFixture.storageLayout
        )
        let secondState = try await configuredAppState(
            item: secondItem,
            store: secondFixture.store,
            generator: secondGenerator,
            storageLayout: secondFixture.storageLayout
        )

        try await firstState.generateMeetingSummary(id: firstItem.id)
        try await secondState.generateMeetingSummary(id: secondItem.id)

        await MainActor.run {
            precondition(
                firstState.pipelineHistory[0].meetingSummary?.content.overview.text
                    == "first generator"
            )
            precondition(
                secondState.pipelineHistory[0].meetingSummary?.content.overview.text
                    == "second generator"
            )
        }
    }

    private static func testCreatedAppStateKeepsItsSummaryDependencySnapshot() async throws {
        let firstFixture = try configuredAppStateFixture()
        defer { firstFixture.cleanup() }
        let secondFixture = try configuredAppStateFixture()
        defer { secondFixture.cleanup() }
        let firstItem = makeItem()
        let secondItem = makeItem()
        _ = try firstFixture.store.upsert(
            firstItem,
            maxCount: 10,
            requiresDurableStore: true
        )
        _ = try secondFixture.store.upsert(
            secondItem,
            maxCount: 10,
            requiresDurableStore: true
        )
        let firstGenerator = MeetingSummaryGeneratorStub { _ in
            makeGenerationResult(overview: "first generator")
        }
        let secondGenerator = MeetingSummaryGeneratorStub { _ in
            makeGenerationResult(overview: "second generator")
        }
        let firstRecorder = MeetingSummaryGeneratorConfigurationRecorder()
        let secondRecorder = MeetingSummaryGeneratorConfigurationRecorder()
        var dependencies = AppStateDependencies.live
        dependencies.storageLayout = firstFixture.storageLayout
        dependencies.makePipelineHistoryStore = { _ in firstFixture.store }
        dependencies.makeMeetingSummaryGenerator = { configuration in
            firstRecorder.record(configuration)
            return firstGenerator
        }
        let firstDependencies = dependencies
        let firstState = await MainActor.run {
            let appState = AppState(dependencies: firstDependencies)
            configureSummaryGeneration(appState)
            return appState
        }

        dependencies.storageLayout = secondFixture.storageLayout
        dependencies.makePipelineHistoryStore = { _ in secondFixture.store }
        dependencies.makeMeetingSummaryGenerator = { configuration in
            secondRecorder.record(configuration)
            return secondGenerator
        }
        let secondDependencies = dependencies
        let secondState = await MainActor.run {
            let appState = AppState(dependencies: secondDependencies)
            configureSummaryGeneration(appState)
            return appState
        }
        let firstExpectedFallbackModelID = await MainActor.run {
            firstState.meetingSummaryFallbackModel
        }
        let secondExpectedFallbackModelID = await MainActor.run {
            secondState.meetingSummaryFallbackModel
        }

        try await firstState.generateMeetingSummary(id: firstItem.id)
        try await secondState.generateMeetingSummary(id: secondItem.id)

        await MainActor.run {
            precondition(
                firstState.pipelineHistory[0].meetingSummary?.content.overview.text
                    == "first generator"
            )
            precondition(
                secondState.pipelineHistory[0].meetingSummary?.content.overview.text
                    == "second generator"
            )
        }
        precondition(
            firstRecorder.recordedFallbackModelIDs
                == [firstExpectedFallbackModelID]
        )
        precondition(
            secondRecorder.recordedFallbackModelIDs
                == [secondExpectedFallbackModelID]
        )
    }

    private static func testSuccessfulGenerationMarksPendingRevealConsumableOnce() async throws {
        let item = makeItem()
        let fixture = try configuredAppStateFixture()
        defer { fixture.cleanup() }
        let appState = try await configuredAppState(
            item: item,
            store: fixture.store,
            generator: MeetingSummaryGeneratorStub { _ in generationResult },
            storageLayout: fixture.storageLayout
        )

        try await appState.generateMeetingSummary(id: item.id)

        await MainActor.run {
            precondition(
                appState.consumeMeetingSummaryPendingReveal(id: item.id),
                "pending reveal is set after a successful generation"
            )
            precondition(
                !appState.consumeMeetingSummaryPendingReveal(id: item.id),
                "pending reveal is consumed only once"
            )
        }
    }

    private static func testDeleteMeetingSummaryRemovesEntireSummaryState() async throws {
        let failedAttempt = MeetingSummaryAttempt(
            occurredAt: Date(timeIntervalSince1970: 2_000),
            outcome: .failed,
            backendKind: .cloud,
            modelID: "summary/model",
            providerHost: "api.example.com",
            language: nil,
            issue: QuillUserIssueRecord(code: .meetingSummaryInvalidResponse),
            sourceFingerprint: String(repeating: "a", count: 64)
        )
        let item = makeItem()
            .withMeetingSummary(envelope(completed: false))
            .withMeetingSummaryAttempt(failedAttempt)
        let fixture = try configuredAppStateFixture()
        defer { fixture.cleanup() }
        let appState = try await configuredAppState(
            item: item,
            store: fixture.store,
            storageLayout: fixture.storageLayout
        )

        try await MainActor.run {
            try appState.deleteMeetingSummary(noteID: item.id)
        }

        await MainActor.run {
            precondition(appState.pipelineHistory[0].meetingSummary == nil)
            precondition(
                appState.pipelineHistory[0].meetingSummaryAttempt == nil,
                "deleting a saved summary also clears a failed regeneration attempt"
            )
        }
    }

    private static func testDeleteMeetingSummaryRemovesFailedOnlyState() async throws {
        let item = makeItem()
        let fixture = try configuredAppStateFixture()
        defer { fixture.cleanup() }
        let appState = try await configuredAppState(
            item: item,
            store: fixture.store,
            storageLayout: fixture.storageLayout
        )
        let failedAttempt = await MainActor.run {
            MeetingSummaryAttempt(
                occurredAt: Date(timeIntervalSince1970: 2_000),
                outcome: .failed,
                backendKind: .cloud,
                modelID: "summary/model",
                providerHost: "api.example.com",
                language: nil,
                issue: QuillUserIssueRecord(code: .meetingSummaryInvalidResponse),
                sourceFingerprint: appState.meetingSummarySource(for: item).fingerprint
            )
        }
        let failedOnly = item.withMeetingSummaryAttempt(failedAttempt)
        let directoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = PipelineHistoryStore(
            storeURL: directoryURL.appendingPathComponent("PipelineHistory.sqlite")
        )
        _ = try store.upsert(failedOnly, maxCount: 10, requiresDurableStore: true)
        let layout = AppStateStorageLayout(rootDirectory: directoryURL)
        let persistedAppState = await configuredPersistedAppState(
            store: store,
            storageLayout: layout
        )

        try await MainActor.run {
            try persistedAppState.deleteMeetingSummary(noteID: item.id)
            precondition(persistedAppState.pipelineHistory[0].meetingSummary == nil)
            precondition(persistedAppState.pipelineHistory[0].meetingSummaryAttempt == nil)
        }
        guard let reloaded = store.loadAllHistory().first else {
            throw MeetingSummaryAppStateTestFailure("Missing deleted failed-only note")
        }
        precondition(reloaded.meetingSummary == nil)
        precondition(reloaded.meetingSummaryAttempt == nil)
    }

    private static func testDeleteMeetingSummaryRejectsStaleFailedAttempt() async throws {
        let item = makeItem()
        let fixture = try configuredAppStateFixture()
        defer { fixture.cleanup() }
        let appState = try await configuredAppState(
            item: item,
            store: fixture.store,
            storageLayout: fixture.storageLayout
        )
        let staleAttempt = MeetingSummaryAttempt(
            occurredAt: Date(timeIntervalSince1970: 2_000),
            outcome: .failed,
            backendKind: .cloud,
            modelID: "summary/model",
            providerHost: "api.example.com",
            language: nil,
            issue: QuillUserIssueRecord(code: .meetingSummaryInvalidResponse),
            sourceFingerprint: String(repeating: "b", count: 64)
        )
        await MainActor.run {
            appState.pipelineHistory[0] = item.withMeetingSummaryAttempt(staleAttempt)
        }

        do {
            try await MainActor.run {
                try appState.deleteMeetingSummary(noteID: item.id)
            }
            throw MeetingSummaryAppStateTestFailure(
                "Expected stale summary attempt rejection"
            )
        } catch let error as MeetingSummaryError {
            precondition(error == .invalidInput)
        }

        await MainActor.run {
            precondition(
                appState.pipelineHistory[0].meetingSummaryAttempt == staleAttempt,
                "a stale attempt is not deleted as a current hard failure"
            )
        }
    }

    private static func testDeleteFailedSummaryStatePersistsAndInvalidatesInflightGeneration() async throws {
        let directoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = PipelineHistoryStore(
            storeURL: directoryURL.appendingPathComponent("PipelineHistory.sqlite")
        )
        let item = makeItem()
        _ = try store.upsert(item, maxCount: 10, requiresDurableStore: true)
        let layout = AppStateStorageLayout(rootDirectory: directoryURL)
        let generator = MeetingSummaryControlledGenerator()
        let appState = await configuredPersistedAppState(
            store: store,
            generator: generator,
            storageLayout: layout
        )
        let failedAttempt = await MainActor.run {
            let attempt = MeetingSummaryAttempt(
                occurredAt: Date(timeIntervalSince1970: 2_000),
                outcome: .failed,
                backendKind: .cloud,
                modelID: "summary/model",
                providerHost: "api.example.com",
                language: nil,
                issue: QuillUserIssueRecord(code: .meetingSummaryInvalidResponse),
                sourceFingerprint: appState.meetingSummarySource(for: item).fingerprint
            )
            return attempt
        }
        let failedOnly = item.withMeetingSummaryAttempt(failedAttempt)
        try store.update(failedOnly, requiresDurableStore: true)
        await MainActor.run {
            appState.pipelineHistory = store.loadAllHistory()
        }

        let summaryTask = Task { @MainActor in
            try await appState.generateMeetingSummary(id: item.id)
        }
        await generator.waitUntilStarted()
        try await MainActor.run {
            try appState.deleteMeetingSummary(noteID: item.id)
            precondition(appState.pipelineHistory[0].meetingSummary == nil)
            precondition(appState.pipelineHistory[0].meetingSummaryAttempt == nil)
            precondition(
                !appState.meetingSummaryGeneratingNoteIDs.contains(item.id),
                "deleting a failed-only summary immediately invalidates generation"
            )
        }
        guard let reloaded = store.loadAllHistory().first else {
            throw MeetingSummaryAppStateTestFailure("Missing deleted history entry")
        }
        precondition(reloaded.meetingSummary == nil)
        precondition(reloaded.meetingSummaryAttempt == nil)

        generator.complete(with: .success(generationResult))
        try await expectSourceChanged(summaryTask)
        await MainActor.run {
            precondition(appState.pipelineHistory[0].meetingSummary == nil)
            precondition(appState.pipelineHistory[0].meetingSummaryAttempt == nil)
            precondition(!appState.consumeMeetingSummaryPendingReveal(id: item.id))
        }
    }

    private static func testFailedSummaryDeletePreservesStateWhenDurableWriteFails() async throws {
        let directoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        var shouldFailSave = false
        let store = PipelineHistoryStore(
            storeURL: directoryURL.appendingPathComponent("PipelineHistory.sqlite"),
            persistentStoreLoader: PipelineHistoryStore.loadPersistentStoresSynchronously,
            contextSaver: { context in
                if shouldFailSave {
                    throw MeetingSummaryAppStateTestFailure("Injected summary delete failure")
                }
                try context.save()
            }
        )
        let item = makeItem()
        _ = try store.upsert(item, maxCount: 10, requiresDurableStore: true)
        let layout = AppStateStorageLayout(rootDirectory: directoryURL)
        let generator = MeetingSummaryControlledGenerator()
        let appState = await configuredPersistedAppState(
            store: store,
            generator: generator,
            storageLayout: layout
        )
        let failedAttempt = await MainActor.run {
            MeetingSummaryAttempt(
                occurredAt: Date(timeIntervalSince1970: 2_000),
                outcome: .failed,
                backendKind: .cloud,
                modelID: "summary/model",
                providerHost: "api.example.com",
                language: nil,
                issue: QuillUserIssueRecord(code: .meetingSummaryInvalidResponse),
                sourceFingerprint: appState.meetingSummarySource(for: item).fingerprint
            )
        }
        let failedOnly = item.withMeetingSummaryAttempt(failedAttempt)
        try store.update(failedOnly, requiresDurableStore: true)
        await MainActor.run {
            appState.pipelineHistory = store.loadAllHistory()
        }
        let summaryTask = Task { @MainActor in
            try await appState.generateMeetingSummary(id: item.id)
        }
        await generator.waitUntilStarted()
        shouldFailSave = true

        do {
            try await MainActor.run {
                try appState.deleteMeetingSummary(noteID: item.id)
            }
            throw MeetingSummaryAppStateTestFailure("Expected durable summary delete failure")
        } catch let error as QuillUserIssueError {
            precondition(error.record.code == .historyPersistenceUnavailable)
        }

        await MainActor.run {
            precondition(
                appState.pipelineHistory[0].meetingSummaryAttempt == failedAttempt,
                "failed durable delete keeps its retryable diagnostic"
            )
            precondition(
                appState.meetingSummaryGeneratingNoteIDs.contains(item.id),
                "failed durable delete keeps the in-flight summary state"
            )
        }
        generator.complete(with: .failure(MeetingSummaryError.sourceChanged))
        try await expectSourceChanged(summaryTask)
    }

    private static func testDeleteMeetingSummaryWithoutExistingSummaryThrows() async throws {
        let item = makeItem()
        let fixture = try configuredAppStateFixture()
        defer { fixture.cleanup() }
        let appState = try await configuredAppState(
            item: item,
            store: fixture.store,
            storageLayout: fixture.storageLayout
        )

        do {
            try await MainActor.run {
                try appState.deleteMeetingSummary(noteID: item.id)
            }
            throw MeetingSummaryAppStateTestFailure("Expected invalidInput")
        } catch let error as MeetingSummaryError {
            precondition(error == .invalidInput)
        }
    }

    private static func testGenerationPersistsOnlyAfterSuccess() async throws {
        let generator = MeetingSummaryControlledGenerator()
        let fixture = try configuredAppStateFixture()
        defer { fixture.cleanup() }
        let appState = try await configuredAppState(
            item: makeItem(),
            store: fixture.store,
            generator: generator,
            storageLayout: fixture.storageLayout
        )

        let task = Task { @MainActor in
            try await appState.generateMeetingSummary(
                id: appState.pipelineHistory[0].id
            )
        }
        await generator.waitUntilStarted()
        await MainActor.run {
            precondition(appState.pipelineHistory[0].meetingSummary == nil)
            precondition(
                appState.meetingSummaryGeneratingNoteIDs.contains(
                    appState.pipelineHistory[0].id
                )
            )
        }

        generator.complete(with: .success(generationResult))
        try await task.value

        await MainActor.run {
            precondition(appState.pipelineHistory[0].meetingSummary != nil)
            precondition(appState.meetingSummaryGeneratingNoteIDs.isEmpty)
        }
    }

    private static func testNonDurableHistoryWarningPreventsSummaryPersistence() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = makeInMemoryFallbackStore(at: directoryURL)
        let layout = AppStateStorageLayout(rootDirectory: directoryURL)

        let item = makeItem()
        let appState = await configuredPersistedAppState(
            store: store,
            generator: MeetingSummaryGeneratorStub { _ in generationResult },
            storageLayout: layout
        )
        await MainActor.run {
            appState.apiKey = "configured-key"
            appState.selectAIProcessingBackendChoice(
                .cloud(modelID: "summary/model"),
                for: .meetingSummary
            )
            appState.disableMeetingSummary = false
            appState.pipelineHistory = [item]
            precondition(
                appState.historyPersistenceWarning?.code
                    == .historyPersistenceUnavailable,
                "in-memory history warns for this session"
            )
        }

        do {
            try await appState.generateMeetingSummary(id: item.id)
            throw MeetingSummaryAppStateTestFailure(
                "Expected non-durable history warning"
            )
        } catch let issue as QuillUserIssueError {
            await MainActor.run {
                precondition(
                    issue.record.code == .historyPersistenceUnavailable,
                    "summary persistence uses the non-durable history warning"
                )
                precondition(
                    appState.pipelineHistory[0].meetingSummary == nil,
                    "new summary is not claimed as durably saved"
                )
            }
        }
    }

    private static func testHistoryReadFailureMapsToPersistenceWarning() async throws {
        let directoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let failureToggle = MeetingSummaryFailureToggle()
        let store = PipelineHistoryStore(
            storeURL: directoryURL.appendingPathComponent(
                "PipelineHistory.sqlite"
            ),
            historyFetcher: { context, request in
                if failureToggle.isEnabled {
                    throw MeetingSummaryAppStateTestFailure(
                        "Injected history read failure"
                    )
                }
                return try context.fetch(request)
            }
        )
        let item = makeItem(
            spokenLanguageCode: "en",
            spokenLanguageResolution: .engineDetected
        )
        _ = try store.upsert(
            item,
            maxCount: 10,
            requiresDurableStore: true
        )
        let layout = AppStateStorageLayout(rootDirectory: directoryURL)
        let generator = MeetingSummaryControlledGenerator()
        let appState = await configuredPersistedAppState(
            store: store,
            generator: generator,
            storageLayout: layout
        )
        let task = Task { @MainActor in
            try await appState.generateMeetingSummary(id: item.id)
        }
        await generator.waitUntilStarted()
        failureToggle.isEnabled = true
        generator.complete(with: .success(generationResult))

        do {
            try await task.value
            throw MeetingSummaryAppStateTestFailure(
                "Expected history persistence warning"
            )
        } catch let issue as QuillUserIssueError {
            precondition(
                issue.record.code == .historyPersistenceUnavailable,
                "history read failure maps to the persistence warning"
            )
        } catch let failure as MeetingSummaryAppStateTestFailure {
            throw failure
        } catch {
            throw MeetingSummaryAppStateTestFailure(
                "Expected persistence warning, got \(error)"
            )
        }

        await MainActor.run {
            precondition(
                appState.pipelineHistory[0].meetingSummary == nil,
                "failed history read does not claim a saved Summary"
            )
            precondition(
                appState.meetingSummaryGeneratingNoteIDs.isEmpty,
                "history read failure clears generation state"
            )
        }
    }

    private static func testLanguageMismatchPreservesSummaryAndRecordsAttempt() async throws {
        let existing = envelope(completed: true)
        let item = makeItem(
            spokenLanguageCode: "ko",
            spokenLanguageResolution: .engineDetected
        ).withMeetingSummary(existing)
        let fixture = try configuredAppStateFixture()
        defer { fixture.cleanup() }
        let appState = try await configuredAppState(
            item: item,
            store: fixture.store,
            generator: MeetingSummaryGeneratorStub { _ in
                throw MeetingSummaryError.outputRejected(.languageMismatch)
            },
            storageLayout: fixture.storageLayout
        )

        do {
            try await appState.generateMeetingSummary(id: item.id)
            throw MeetingSummaryAppStateTestFailure("Expected language mismatch")
        } catch let error as MeetingSummaryError {
            precondition(error == .outputRejected(.languageMismatch))
        }

        await MainActor.run {
            let saved = appState.pipelineHistory[0]
            precondition(saved.meetingSummary == existing)
            precondition(saved.meetingSummary?.content.actionItems[0].isCompleted == true)
            precondition(saved.meetingSummaryAttempt?.outcome == .failed)
            precondition(saved.meetingSummaryAttempt?.language?.appliedLanguageCode == "ko")
        }
    }

    private static func testSuccessfulAttemptSurvivesDurableReload() async throws {
        let directoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let storeURL = directoryURL.appendingPathComponent("PipelineHistory.sqlite")
        let store = PipelineHistoryStore(storeURL: storeURL)
        let item = makeItem(
            spokenLanguageCode: "en",
            spokenLanguageResolution: .engineDetected
        )
        _ = try store.upsert(item, maxCount: 10, requiresDurableStore: true)

        let layout = AppStateStorageLayout(rootDirectory: directoryURL)
        let appState = await configuredPersistedAppState(
            store: store,
            generator: MeetingSummaryGeneratorStub { _ in generationResult },
            storageLayout: layout
        )

        try await appState.generateMeetingSummary(id: item.id)

        let reloaded = PipelineHistoryStore(storeURL: storeURL)
        guard let persisted = reloaded.loadAllHistory().first else {
            throw MeetingSummaryAppStateTestFailure("Missing reloaded success item")
        }
        precondition(persisted.meetingSummary != nil)
        precondition(persisted.meetingSummaryAttempt?.outcome == .succeeded)
        precondition(
            persisted.meetingSummary?.languageContext
                == persisted.meetingSummaryAttempt?.language
        )
    }

    private static func testFailedAttemptSurvivesDurableReload() async throws {
        let directoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let storeURL = directoryURL.appendingPathComponent("PipelineHistory.sqlite")
        let store = PipelineHistoryStore(storeURL: storeURL)
        let existing = envelope(completed: true)
        let item = makeItem(
            spokenLanguageCode: "en",
            spokenLanguageResolution: .engineDetected
        ).withMeetingSummary(existing)
        _ = try store.upsert(item, maxCount: 10, requiresDurableStore: true)

        let layout = AppStateStorageLayout(rootDirectory: directoryURL)
        let appState = await configuredPersistedAppState(
            store: store,
            generator: MeetingSummaryGeneratorStub { _ in
                throw MeetingSummaryError.outputRejected(.languageMismatch)
            },
            storageLayout: layout
        )

        do {
            try await appState.generateMeetingSummary(id: item.id)
            throw MeetingSummaryAppStateTestFailure("Expected summary failure")
        } catch let failure as MeetingSummaryAppStateTestFailure {
            throw failure
        } catch {}

        let reloaded = PipelineHistoryStore(storeURL: storeURL)
        guard let persisted = reloaded.loadAllHistory().first else {
            throw MeetingSummaryAppStateTestFailure("Missing reloaded failed item")
        }
        precondition(persisted.meetingSummary == existing)
        precondition(persisted.meetingSummaryAttempt?.outcome == .failed)
        precondition(persisted.meetingSummaryAttempt?.language?.appliedLanguageCode == "en")
    }

    private static func testTranscriptEditingPreservesNonEditedMetadata() async throws {
        let attempt = MeetingSummaryAttempt(
            occurredAt: Date(timeIntervalSince1970: 2_100),
            outcome: .failed,
            backendKind: .cloud,
            modelID: "summary/model",
            providerHost: "api.example.com",
            language: MeetingSummaryLanguageContext(
                requestedOutputLanguage: "",
                appliedLanguageCode: "ko",
                resolutionSource: .engineDetected
            ),
            issue: QuillUserIssueRecord(code: .meetingSummaryUnavailable)
        )
        let calendarMatch = CalendarEventMatch(
            accountID: "account-id",
            calendarID: "calendar-id",
            eventID: "event-id",
            title: "Design Review",
            start: Date(timeIntervalSince1970: 900),
            end: Date(timeIntervalSince1970: 1_800),
            attendees: [
                CalendarEventAttendee(
                    displayName: "Ada",
                    email: "ada@example.com"
                )
            ],
            matchSource: .overlapSuggestion,
            titleState: .applied
        )
        let item = PipelineHistoryItem(
            intent: .commandManual,
            selectedText: "command selection",
            capturedSelection: "captured context selection",
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_000),
            recordingStartedAt: Date(timeIntervalSince1970: 950),
            recordingEndedAt: Date(timeIntervalSince1970: 1_050),
            calendarMatch: calendarMatch,
            rawTranscript: "Original raw transcript.",
            postProcessedTranscript: "Original processed transcript.",
            postProcessingPrompt: "post-processing prompt",
            systemPrompt: "resolved system prompt",
            contextSummary: "captured context summary",
            contextSystemPrompt: "context system prompt",
            contextPrompt: "context prompt",
            contextScreenshotDataURL: "data:image/png;base64,c2NyZWVuc2hvdA==",
            contextScreenshotStatus: "available (image/png)",
            postProcessingStatus: QuillUserIssueRecord(
                code: .postProcessingFailed
            ).persistedStatus,
            aiProcessingOutcome: "raw-fallback:languageMismatch",
            debugStatus: "post-processing fallback",
            customVocabulary: "Quill",
            customSystemPrompt: "custom system prompt",
            audioFileName: "meeting.wav",
            usedLocalTranscription: true,
            usedContextCapture: true,
            usedPostProcessing: true,
            transcriptionLanguageCode: "ko",
            spokenLanguageCode: "ko",
            spokenLanguageResolution: .engineDetected,
            meetingSummaryAttempt: attempt,
            localTranscriptionModelID: "local/model",
            transcriptFileName: "meeting.txt",
            contextAppName: "Example App",
            contextBundleIdentifier: "com.example.app",
            contextWindowTitle: "Example Window",
            customTitle: "Edited Note",
            meetingSummaryJSON: try JSONEncoder().encode(envelope(completed: false))
        )
        let originalMetadata = try transcriptEditPreservedMetadata(item)
        let directoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let layout = AppStateStorageLayout(rootDirectory: directoryURL)
        let store = PipelineHistoryStore(storeURL: layout.historyStoreURL)
        _ = try store.upsert(item, maxCount: 10, requiresDurableStore: true)
        let appState = await configuredPersistedAppState(
            store: store,
            storageLayout: layout
        )

        let updated = await MainActor.run {
            appState.updateTranscript(id: item.id, text: "Edited transcript.")
            return appState.pipelineHistory[0]
        }

        precondition(updated.postProcessedTranscript == "Edited transcript.")
        precondition(
            updated.capturedSelection == "captured context selection",
            "Transcript editing must preserve captured selection"
        )
        precondition(
            updated.systemPrompt == "resolved system prompt",
            "Transcript editing must preserve the resolved system prompt"
        )
        precondition(
            updated.contextSystemPrompt == "context system prompt",
            "Transcript editing must preserve the Context system prompt"
        )
        precondition(
            updated.aiProcessingOutcome == "raw-fallback:languageMismatch",
            "Transcript editing must preserve the AI processing outcome"
        )
        let updatedMetadata = try transcriptEditPreservedMetadata(updated)
        precondition(
            updatedMetadata == originalMetadata,
            "Transcript editing must preserve every non-edited history field"
        )

        let reloaded = PipelineHistoryStore(storeURL: layout.historyStoreURL)
        guard let persisted = reloaded.loadAllHistory().first else {
            throw MeetingSummaryAppStateTestFailure("Missing reloaded persisted note")
        }
        precondition(
            persisted.postProcessedTranscript == "Edited transcript.",
            "Transcript editing must persist the edited transcript"
        )
        let persistedMetadata = try transcriptEditPreservedMetadata(persisted)
        precondition(
            persistedMetadata == originalMetadata,
            "Persisted transcript edits must preserve every non-edited history field"
        )
    }

    private static func testTranscriptChangeDiscardsInflightResult() async throws {
        let generator = MeetingSummaryControlledGenerator()
        let item = makeItem()
        let fixture = try configuredAppStateFixture()
        defer { fixture.cleanup() }
        let appState = try await configuredAppState(
            item: item,
            store: fixture.store,
            generator: generator,
            storageLayout: fixture.storageLayout
        )

        let task = Task { @MainActor in
            try await appState.generateMeetingSummary(id: item.id)
        }
        await generator.waitUntilStarted()
        await MainActor.run {
            appState.updateTranscript(id: item.id, text: "Transcript changed.")
            precondition(
                !appState.meetingSummaryGeneratingNoteIDs.contains(item.id),
                "source replacement immediately clears the invalidated generation state"
            )
        }
        generator.complete(with: .success(generationResult))

        do {
            try await task.value
            throw MeetingSummaryAppStateTestFailure("Expected source change")
        } catch let error as MeetingSummaryError {
            precondition(error == .sourceChanged)
        }
        await MainActor.run {
            precondition(appState.pipelineHistory[0].meetingSummary == nil)
            precondition(
                appState.pipelineHistory[0].meetingSummaryAttempt == nil,
                "source invalidation is not persisted as a provider failure"
            )
        }
    }

    /// #457: a Note Browser retry of a note with a transcript waits next to
    /// it; the saved transcript changes only when the new one is chosen.
    private static func testNoteBrowserRetryComparesBeforeSaving() async throws {
        let audioFileName = "retry-compare-\(UUID().uuidString).mp3"
        let directoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let layout = AppStateStorageLayout(rootDirectory: directoryURL)
        try FileManager.default.createDirectory(at: layout.audioDirectory, withIntermediateDirectories: true)
        try Data([0]).write(to: layout.audioDirectory.appendingPathComponent(audioFileName))
        let store = PipelineHistoryStore(storeURL: layout.historyStoreURL)
        let item = makeItem(audioFileName: audioFileName)
        _ = try store.upsert(item, maxCount: 10, requiresDurableStore: true)
        let appState = await configuredPersistedAppState(
            store: store,
            storageLayout: layout,
            retryDependencies: retryCloudDependencies(transcript: "Retry source C.")
        )
        await MainActor.run {
            appState.transcriptionAPIKey = "test-api-key"
            appState.transcriptionAPIURL = "https://provider.example/v1"
            appState.setNoteBrowserTranscriptionChoice(.apiStandard(modelID: "whisper-large-v3"))
            appState.disablePostProcessing = true
            appState.retryTranscription(item: item, choice: nil, comparesFirst: true)
        }
        for _ in 0..<200 {
            let waiting = await MainActor.run { appState.transcriptionCandidates[item.id] != nil }
            if waiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await MainActor.run {
            precondition(appState.transcriptionCandidates[item.id] == "Retry source C.", "the new transcript waits")
            precondition(
                appState.pipelineHistory[0].postProcessedTranscript == item.postProcessedTranscript,
                "the saved transcript is unchanged before choosing"
            )
            precondition(appState.acceptTranscriptionCandidate(noteID: item.id) == .saved)
            precondition(appState.pipelineHistory[0].postProcessedTranscript == "Retry source C.")
            precondition(appState.transcriptionCandidates[item.id] == nil)
        }
        let reloaded = PipelineHistoryStore(storeURL: layout.historyStoreURL)
        precondition(reloaded.loadAllHistory().first?.postProcessedTranscript == "Retry source C.", "the choice is saved")
    }

    private static func testSuccessfulRetryInvalidatesInflightSummaryGeneration() async throws {
        let audioFileName = "retry-summary-invalidation-\(UUID().uuidString).mp3"
        let directoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let layout = AppStateStorageLayout(rootDirectory: directoryURL)
        let audioURL = layout.audioDirectory.appendingPathComponent(audioFileName)
        try FileManager.default.createDirectory(
            at: layout.audioDirectory,
            withIntermediateDirectories: true
        )
        try Data([0]).write(to: audioURL)
        let store = PipelineHistoryStore(storeURL: layout.historyStoreURL)
        let item = makeItem(audioFileName: audioFileName)
        _ = try store.upsert(item, maxCount: 10, requiresDurableStore: true)
        let generator = MeetingSummaryControlledGenerator()
        let appState = await configuredPersistedAppState(
            store: store,
            generator: generator,
            storageLayout: layout,
            retryDependencies: retryCloudDependencies(
                transcript: "Retry source B."
            )
        )
        await MainActor.run {
            appState.apiKey = "configured-key"
            appState.transcriptionAPIKey = "test-api-key"
            appState.transcriptionAPIURL = "https://provider.example/v1"
            appState.setNoteBrowserTranscriptionChoice(
                .apiStandard(modelID: "whisper-large-v3")
            )
            appState.disablePostProcessing = true
            appState.selectAIProcessingBackendChoice(
                .cloud(modelID: "summary/model"),
                for: .meetingSummary
            )
            appState.disableMeetingSummary = false
            precondition(
                appState.meetingSummaryAvailability(for: appState.pipelineHistory[0])
                    == .available,
                "successful retry test requires an available summary source"
            )
        }

        let summaryTask = Task { @MainActor in
            try await appState.generateMeetingSummary(id: item.id)
        }
        await generator.waitUntilStarted()
        await MainActor.run {
            appState.retryTranscription(item: item)
        }
        try await waitUntilRetryCompletes(appState, noteID: item.id)

        await MainActor.run {
            let updated = appState.pipelineHistory[0]
            precondition(updated.postProcessedTranscript == "Retry source B.")
            precondition(
                !appState.meetingSummaryGeneratingNoteIDs.contains(item.id),
                "successful retry clears the invalidated summary generation state"
            )
        }
        generator.complete(with: .success(generationResult))

        do {
            try await summaryTask.value
            throw MeetingSummaryAppStateTestFailure("Expected source change")
        } catch let error as MeetingSummaryError {
            precondition(error == .sourceChanged)
        }
        await MainActor.run {
            let updated = appState.pipelineHistory[0]
            precondition(updated.meetingSummary == nil)
            precondition(updated.meetingSummaryAttempt == nil)
            precondition(!appState.consumeMeetingSummaryPendingReveal(id: item.id))
        }
    }

    private static func testRetryWithMissingHistoryEntryKeepsSummaryGenerationActive() async throws {
        let audioFileName = "retry-missing-history-\(UUID().uuidString).mp3"
        let directoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let layout = AppStateStorageLayout(rootDirectory: directoryURL)
        let audioURL = layout.audioDirectory.appendingPathComponent(audioFileName)
        try FileManager.default.createDirectory(
            at: layout.audioDirectory,
            withIntermediateDirectories: true
        )
        try Data([0]).write(to: audioURL)
        let store = PipelineHistoryStore(storeURL: layout.historyStoreURL)
        let item = makeItem(
            spokenLanguageCode: "en",
            spokenLanguageResolution: .engineDetected,
            audioFileName: audioFileName
        )
        let generator = MeetingSummaryControlledGenerator()
        let appState = await configuredPersistedAppState(
            store: store,
            generator: generator,
            storageLayout: layout,
            retryDependencies: retryCloudDependencies(
                transcript: "Retry source B."
            )
        )
        await MainActor.run {
            appState.pipelineHistory = [item]
            appState.transcriptionAPIKey = "test-api-key"
            appState.transcriptionAPIURL = "https://provider.example/v1"
            appState.setNoteBrowserTranscriptionChoice(
                .apiStandard(modelID: "whisper-large-v3")
            )
            appState.disablePostProcessing = true
        }

        let summaryTask = Task { @MainActor in
            try await appState.generateMeetingSummary(id: item.id)
        }
        await generator.waitUntilStarted()
        await MainActor.run {
            appState.retryTranscription(item: item)
        }
        try await waitUntilRetryCompletes(appState, noteID: item.id)

        await MainActor.run {
            precondition(appState.pipelineHistory[0].postProcessedTranscript == item.postProcessedTranscript)
            precondition(
                appState.meetingSummaryGeneratingNoteIDs.contains(item.id),
                "missing durable retry target leaves the existing summary generation active"
            )
        }
        generator.complete(with: .failure(MeetingSummaryError.sourceChanged))
        try await expectSourceChanged(summaryTask)
    }

    private static func testDeleteWithMissingHistoryEntryKeepsSummaryGenerationActive() async throws {
        let directoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = PipelineHistoryStore(
            storeURL: directoryURL.appendingPathComponent("PipelineHistory.sqlite")
        )
        let item = makeItem(
            spokenLanguageCode: "en",
            spokenLanguageResolution: .engineDetected
        )
        let generator = MeetingSummaryControlledGenerator()
        let layout = AppStateStorageLayout(rootDirectory: directoryURL)
        let appState = await configuredPersistedAppState(
            store: store,
            generator: generator,
            storageLayout: layout
        )
        await MainActor.run {
            appState.pipelineHistory = [item]
        }

        let summaryTask = Task { @MainActor in
            try await appState.generateMeetingSummary(id: item.id)
        }
        await generator.waitUntilStarted()
        await MainActor.run {
            appState.deleteHistoryEntry(id: item.id)
            precondition(appState.pipelineHistory.map(\.id) == [item.id])
            precondition(
                appState.meetingSummaryGeneratingNoteIDs.contains(item.id),
                "missing durable delete target leaves summary generation active"
            )
        }
        generator.complete(with: .failure(MeetingSummaryError.sourceChanged))
        try await expectSourceChanged(summaryTask)
    }

    private static func testClearWithSaveFailureKeepsSummaryGenerationActive() async throws {
        let directoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        var shouldFailSave = false
        let store = PipelineHistoryStore(
            storeURL: directoryURL.appendingPathComponent("PipelineHistory.sqlite"),
            persistentStoreLoader: PipelineHistoryStore.loadPersistentStoresSynchronously,
            contextSaver: { context in
                if shouldFailSave {
                    throw MeetingSummaryAppStateTestFailure("Injected clear failure")
                }
                try context.save()
            }
        )
        let item = makeItem(
            spokenLanguageCode: "en",
            spokenLanguageResolution: .engineDetected
        )
        _ = try store.upsert(item, maxCount: 10, requiresDurableStore: true)
        let layout = AppStateStorageLayout(rootDirectory: directoryURL)
        let generator = MeetingSummaryControlledGenerator()
        let appState = await configuredPersistedAppState(
            store: store,
            generator: generator,
            storageLayout: layout
        )

        let summaryTask = Task { @MainActor in
            try await appState.generateMeetingSummary(id: item.id)
        }
        await generator.waitUntilStarted()
        shouldFailSave = true
        await MainActor.run {
            appState.clearPipelineHistory()
            precondition(appState.pipelineHistory.map(\.id) == [item.id])
            precondition(
                appState.meetingSummaryGeneratingNoteIDs.contains(item.id),
                "failed durable clear leaves summary generation active"
            )
        }
        generator.complete(with: .failure(MeetingSummaryError.sourceChanged))
        try await expectSourceChanged(summaryTask)
    }

    private static func testDeleteDuringGenerationDoesNotRestoreSummary() async throws {
        let generator = MeetingSummaryControlledGenerator()
        let item = makeItem().withMeetingSummary(envelope(completed: false))
        let fixture = try configuredAppStateFixture()
        defer { fixture.cleanup() }
        let appState = try await configuredAppState(
            item: item,
            store: fixture.store,
            generator: generator,
            storageLayout: fixture.storageLayout
        )

        let task = Task { @MainActor in
            try await appState.generateMeetingSummary(id: item.id)
        }
        await generator.waitUntilStarted()
        try await MainActor.run {
            try appState.deleteMeetingSummary(noteID: item.id)
            precondition(
                !appState.meetingSummaryGeneratingNoteIDs.contains(item.id),
                "deletion immediately clears the invalidated generation state"
            )
        }
        generator.complete(with: .success(generationResult))

        do {
            try await task.value
            throw MeetingSummaryAppStateTestFailure("Expected deletion invalidation")
        } catch let error as MeetingSummaryError {
            precondition(error == .sourceChanged)
        }
        await MainActor.run {
            let saved = appState.pipelineHistory[0]
            precondition(saved.meetingSummary == nil)
            precondition(saved.meetingSummaryAttempt == nil)
            precondition(!appState.consumeMeetingSummaryPendingReveal(id: item.id))
        }
    }

    private static func testTranscriptReplacementReinfersDerivedSpokenLanguage() async throws {
        let item = makeItem(
            spokenLanguageCode: nil,
            spokenLanguageResolution: .unavailable,
            rawTranscript: "12345 ---",
            postProcessedTranscript: "12345 ---"
        )
        let fixture = try configuredAppStateFixture()
        defer { fixture.cleanup() }
        let appState = try await configuredAppState(
            item: item,
            store: fixture.store,
            generator: MeetingSummaryGeneratorStub { _ in generationResult },
            storageLayout: fixture.storageLayout
        )
        await MainActor.run {
            appState.updateTranscript(
                id: item.id,
                text: "회의에서 다음 주 화요일에 출시하기로 결정했습니다."
            )
        }

        try await appState.generateMeetingSummary(id: item.id)

        await MainActor.run {
            precondition(appState.pipelineHistory[0].spokenLanguage == SpokenLanguageResolution(
                languageCode: "ko",
                source: .transcriptInferred
            ))
        }
    }

    private static func testTranscriptReplacementPreservesEngineDetectedLanguage() async throws {
        let item = makeItem(
            spokenLanguageCode: "en",
            spokenLanguageResolution: .engineDetected
        )
        let fixture = try configuredAppStateFixture()
        defer { fixture.cleanup() }
        let appState = try await configuredAppState(
            item: item,
            store: fixture.store,
            storageLayout: fixture.storageLayout
        )

        await MainActor.run {
            appState.updateTranscript(
                id: item.id,
                text: "회의에서 다음 주 화요일에 출시하기로 결정했습니다."
            )
            precondition(appState.pipelineHistory[0].spokenLanguage == SpokenLanguageResolution(
                languageCode: "en",
                source: .engineDetected
            ))
        }
    }

    private static func testActionCompletionPersists() async throws {
        let item = makeItem().withMeetingSummary(envelope(completed: false))
        let fixture = try configuredAppStateFixture()
        defer { fixture.cleanup() }
        let appState = try await configuredAppState(
            item: item,
            store: fixture.store,
            storageLayout: fixture.storageLayout
        )
        let actionID = item.meetingSummary!.content.actionItems[0].id

        try await MainActor.run {
            try appState.setMeetingSummaryActionCompleted(
                noteID: item.id,
                actionID: actionID,
                isCompleted: true
            )
        }

        await MainActor.run {
            precondition(
                appState.pipelineHistory[0]
                    .meetingSummary?.content.actionItems[0].isCompleted == true
            )
        }
    }

    /// #262: an edited summary is saved durably, and reverting puts back
    /// the generated text while keeping a checked action checked.
    private static func testSummaryEditPersistsAndReverts() async throws {
        let item = makeItem().withMeetingSummary(envelope(completed: false))
        let fixture = try configuredAppStateFixture()
        defer { fixture.cleanup() }
        let appState = try await configuredAppState(
            item: item,
            store: fixture.store,
            storageLayout: fixture.storageLayout
        )
        let actionID = item.meetingSummary!.content.actionItems[0].id
        var edited = item.meetingSummary!.content
        edited.overview.text = "Synthetic overview, corrected"
        edited.decisions.append(MeetingSummaryPoint(id: UUID(), text: "Added decision", sourceQuote: nil))

        try await MainActor.run {
            try appState.updateMeetingSummaryContent(noteID: item.id, content: edited)
            try appState.setMeetingSummaryActionCompleted(
                noteID: item.id,
                actionID: actionID,
                isCompleted: true
            )
        }

        let reloaded = PipelineHistoryStore(storeURL: fixture.storageLayout.historyStoreURL)
        guard let persisted = reloaded.loadAllHistory().first?.meetingSummary else {
            throw MeetingSummaryAppStateTestFailure("Missing reloaded edited summary")
        }
        precondition(persisted.isEdited, "edit survives reload")
        precondition(persisted.content.overview.text == "Synthetic overview, corrected")
        precondition(persisted.content.decisions.map(\.text) == ["Added decision"])
        precondition(persisted.originalContent?.overview.text == "Release review")

        try await MainActor.run {
            try appState.revertMeetingSummaryToOriginal(noteID: item.id)
        }
        await MainActor.run {
            let reverted = appState.pipelineHistory[0].meetingSummary
            precondition(reverted?.isEdited == false, "revert clears the edit")
            precondition(reverted?.content.overview.text == "Release review")
            precondition(reverted?.content.decisions.isEmpty == true)
            precondition(
                reverted?.content.actionItems[0].isCompleted == true,
                "a checked action stays checked after revert"
            )
        }
    }

    /// #262: regenerating an edited summary to compare leaves it saved as
    /// is; keeping it drops the new one, and using the new one replaces the
    /// edits while a checked action stays checked.
    private static func testCandidateComparisonKeepsOrReplacesEditedSummary() async throws {
        let item = makeItem().withMeetingSummary(envelope(completed: false))
        let fixture = try configuredAppStateFixture()
        defer { fixture.cleanup() }
        let appState = try await configuredAppState(
            item: item,
            store: fixture.store,
            generator: MeetingSummaryGeneratorStub { _ in generationResult },
            storageLayout: fixture.storageLayout
        )
        let actionID = item.meetingSummary!.content.actionItems[0].id
        var edited = item.meetingSummary!.content
        edited.overview.text = "Synthetic edited overview"

        try await MainActor.run {
            try appState.updateMeetingSummaryContent(noteID: item.id, content: edited)
            try appState.setMeetingSummaryActionCompleted(
                noteID: item.id,
                actionID: actionID,
                isCompleted: true
            )
        }
        try await appState.generateMeetingSummary(id: item.id, asCandidate: true)
        await MainActor.run {
            let saved = appState.pipelineHistory[0].meetingSummary
            precondition(saved?.content.overview.text == "Synthetic edited overview", "the edited summary stays saved")
            precondition(appState.meetingSummaryCandidates[item.id] != nil, "the new summary waits")
            appState.discardMeetingSummaryCandidate(noteID: item.id)
            precondition(appState.meetingSummaryCandidates[item.id] == nil, "keeping the current summary drops the new one")
            precondition(appState.pipelineHistory[0].meetingSummary?.isEdited == true)
        }

        try await appState.generateMeetingSummary(id: item.id, asCandidate: true)
        try await MainActor.run {
            try appState.acceptMeetingSummaryCandidate(noteID: item.id)
            let saved = appState.pipelineHistory[0].meetingSummary
            precondition(appState.meetingSummaryCandidates[item.id] == nil)
            precondition(saved?.isEdited == false, "the new summary replaces the edits")
            precondition(saved?.content.overview.text == "Release review")
            precondition(
                saved?.content.actionItems.first?.isCompleted == true,
                "a checked action stays checked"
            )
            precondition(appState.pipelineHistory[0].meetingSummaryAttempt?.outcome == .succeeded)
        }
        let reloaded = PipelineHistoryStore(storeURL: fixture.storageLayout.historyStoreURL)
        precondition(reloaded.loadAllHistory().first?.meetingSummary?.isEdited == false, "the choice is saved")
    }

    private static func testPostProcessingDisabledDoesNotBlockSummary() async throws {
        let item = makeItem()
        let fixture = try configuredAppStateFixture()
        defer { fixture.cleanup() }
        let appState = try await configuredAppState(
            item: item,
            store: fixture.store,
            storageLayout: fixture.storageLayout
        )
        await MainActor.run {
            appState.disablePostProcessing = true
            precondition(
                appState.meetingSummaryAvailability(for: item) == .available
            )
        }
    }

    private static func makeInMemoryFallbackStore(
        at directoryURL: URL
    ) -> PipelineHistoryStore {
        var persistentLoadAttempts = 0
        return PipelineHistoryStore(
            storeURL: directoryURL.appendingPathComponent("PipelineHistory.sqlite"),
            persistentStoreLoader: { container in
                persistentLoadAttempts += 1
                if persistentLoadAttempts <= 2 {
                    return MeetingSummaryAppStateTestFailure(
                        "Injected persistent-store load failure"
                    )
                }
                return PipelineHistoryStore.loadPersistentStoresSynchronously(
                    container: container
                )
            }
        )
    }

    private static func temporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL
    }

    private static func dependencies(
        store: PipelineHistoryStore,
        generator: (any MeetingSummaryGenerating)? = nil,
        storageLayout: AppStateStorageLayout? = nil,
        retryDependencies: @escaping @Sendable () -> CloudTranscriptionDependencies = {
            .live
        }
    ) -> AppStateDependencies {
        var dependencies = AppStateDependencies.live
        if let storageLayout {
            dependencies.storageLayout = storageLayout
        }
        dependencies.makePipelineHistoryStore = { _ in store }
        if let generator {
            dependencies.makeMeetingSummaryGenerator = { _ in generator }
        }
        dependencies.makeRetryCloudTranscriptionDependencies = retryDependencies
        return dependencies
    }

    private static func configuredPersistedAppState(
        store: PipelineHistoryStore,
        generator: (any MeetingSummaryGenerating)? = nil,
        storageLayout: AppStateStorageLayout? = nil,
        retryDependencies: @escaping @Sendable () -> CloudTranscriptionDependencies = {
            .live
        }
    ) async -> AppState {
        let configuredDependencies = dependencies(
            store: store,
            generator: generator,
            storageLayout: storageLayout,
            retryDependencies: retryDependencies
        )
        return await MainActor.run {
            let appState = AppState(dependencies: configuredDependencies)
            configureSummaryGeneration(appState)
            return appState
        }
    }

    private static func configuredAppStateFixture() throws -> ConfiguredAppStateFixture {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-meeting-summary-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let storageLayout = AppStateStorageLayout(rootDirectory: rootDirectory)
        return ConfiguredAppStateFixture(
            rootDirectory: rootDirectory,
            storageLayout: storageLayout,
            store: PipelineHistoryStore(storeURL: storageLayout.historyStoreURL)
        )
    }

    private static func configuredAppState(
        item: PipelineHistoryItem,
        store: PipelineHistoryStore,
        generator: (any MeetingSummaryGenerating)? = nil,
        storageLayout: AppStateStorageLayout? = nil
    ) async throws -> AppState {
        _ = try store.upsert(item, maxCount: 10, requiresDurableStore: true)
        let appState = await configuredPersistedAppState(
            store: store,
            generator: generator,
            storageLayout: storageLayout
        )
        await MainActor.run {
            precondition(
                appState.meetingSummaryAvailability(for: appState.pipelineHistory[0])
                    == .available,
                "test requires an available summary source"
            )
        }
        return appState
    }

    private struct ConfiguredAppStateFixture {
        let rootDirectory: URL
        let storageLayout: AppStateStorageLayout
        let store: PipelineHistoryStore

        func cleanup() {
            try? store.detachForArchiveVerification()
            try? FileManager.default.removeItem(at: rootDirectory)
        }
    }

    @MainActor
    private static func configureSummaryGeneration(_ appState: AppState) {
        appState.apiKey = "configured-key"
        appState.selectAIProcessingBackendChoice(
            .cloud(modelID: "summary/model"),
            for: .meetingSummary
        )
        appState.disableMeetingSummary = false
    }

    private static func retryCloudDependencies(
        transcript: String
    ) -> @Sendable () -> CloudTranscriptionDependencies {
        {
            CloudTranscriptionDependencies(
                encodedUploadCeilingBytes: 10_000,
                upload: { request, _ in
                    let response = HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: nil
                    )!
                    return (Data(#"{"text":"\#(transcript)"}"#.utf8), response)
                },
                checkpointStore: InMemoryCloudTranscriptionCheckpointStore(),
                progress: { _ in },
                temporaryRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true),
                sleep: { _ in }
            )
        }
    }

    private static func expectSourceChanged(
        _ task: Task<Void, Error>
    ) async throws {
        do {
            try await task.value
            throw MeetingSummaryAppStateTestFailure("Expected source change")
        } catch let error as MeetingSummaryError {
            precondition(error == .sourceChanged)
        }
    }

    private static func waitUntilRetryCompletes(
        _ appState: AppState,
        noteID: UUID
    ) async throws {
        for _ in 0..<100 {
            let isRetrying = await MainActor.run {
                appState.retryingItemIDs.contains(noteID)
            }
            if !isRetrying {
                // A retry of a note with a transcript waits to be compared
                // (#457); these tests check the result of keeping it.
                await MainActor.run {
                    if appState.transcriptionCandidates[noteID] != nil {
                        appState.acceptTranscriptionCandidate(noteID: noteID)
                    }
                }
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MeetingSummaryAppStateTestFailure("Timed out waiting for retry")
    }

    private static func transcriptEditPreservedMetadata(
        _ item: PipelineHistoryItem
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(item)
        guard var object = try JSONSerialization.jsonObject(
            with: encoded
        ) as? [String: Any] else {
            throw MeetingSummaryAppStateTestFailure(
                "Unable to encode transcript-edit metadata snapshot"
            )
        }
        object.removeValue(forKey: "postProcessedTranscript")
        // The store advances the edited-transcript stamp of the field clock.
        object.removeValue(forKey: "fieldClock")
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }

    private static func makeItem(
        transcriptionLanguageCode: String = "auto",
        spokenLanguageCode: String? = nil,
        spokenLanguageResolution: SpokenLanguageResolutionSource? = nil,
        rawTranscript: String = "Decision: ship Friday.",
        postProcessedTranscript: String = "Decision: ship Friday.",
        audioFileName: String? = nil
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_000),
            rawTranscript: rawTranscript,
            postProcessedTranscript: postProcessedTranscript,
            postProcessingPrompt: nil,
            contextSummary: "Excluded context",
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "Post-processing succeeded",
            debugStatus: "Done",
            customVocabulary: "",
            audioFileName: audioFileName,
            usedPostProcessing: false,
            transcriptionLanguageCode: transcriptionLanguageCode,
            spokenLanguageCode: spokenLanguageCode,
            spokenLanguageResolution: spokenLanguageResolution
        )
    }

    private static func envelope(completed: Bool) -> MeetingSummaryEnvelope {
        MeetingSummaryEnvelope(
            schemaVersion: MeetingSummaryEnvelope.currentSchemaVersion,
            promptVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 2_000),
            sourceFingerprint: String(repeating: "c", count: 64),
            modelID: "summary/model",
            backendKind: .cloud,
            content: MeetingSummaryContent(
                overview: MeetingSummaryEvidenceText(
                    text: "Release review",
                    sourceQuotes: ["Decision: ship Friday."]
                ),
                keyPoints: [],
                decisions: [],
                actionItems: [
                    MeetingSummaryActionItem(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
                        task: "Write release notes",
                        owner: nil,
                        dueDate: nil,
                        sourceQuote: "Write release notes.",
                        isCompleted: completed
                    )
                ],
                openQuestions: []
            )
        )
    }

    private static let generationResult = MeetingSummaryGenerationResult(
        draft: MeetingSummaryDraftContentV2(
            overview: MeetingSummaryEvidenceText(
                text: "Release review",
                sourceQuotes: ["Decision: ship Friday."]
            ),
            keyPoints: [],
            decisions: [],
            actionItems: [
                MeetingSummaryActionItem(
                    id: UUID(),
                    task: "Write release notes",
                    owner: nil,
                    dueDate: nil,
                    sourceQuote: "Write release notes.",
                    isCompleted: false
                )
            ],
            openQuestions: []
        ),
        promptVersion: 1,
        modelID: "summary/model",
        backendKind: .cloud
    )

    private static func makeGenerationResult(
        overview: String
    ) -> MeetingSummaryGenerationResult {
        MeetingSummaryGenerationResult(
            draft: MeetingSummaryDraftContentV2(
                overview: MeetingSummaryEvidenceText(
                    text: overview,
                    sourceQuotes: generationResult.draft.overview.sourceQuotes
                ),
                keyPoints: generationResult.draft.keyPoints,
                decisions: generationResult.draft.decisions,
                actionItems: generationResult.draft.actionItems,
                openQuestions: generationResult.draft.openQuestions
            ),
            promptVersion: generationResult.promptVersion,
            modelID: generationResult.modelID,
            backendKind: generationResult.backendKind,
            evidenceVerification: generationResult.evidenceVerification
        )
    }
}

private final class MeetingSummaryGeneratorStub:
    MeetingSummaryGenerating,
    @unchecked Sendable
{
    typealias Operation = @Sendable (
        MeetingSummarySource
    ) async throws -> MeetingSummaryGenerationResult

    private let operation: Operation

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    func generate(
        source: MeetingSummarySource
    ) async throws -> MeetingSummaryGenerationResult {
        try await operation(source)
    }
}

private final class MeetingSummaryFailureToggle: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isEnabled: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class MeetingSummaryGeneratorConfigurationRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var fallbackModelIDs: [String?] = []

    func record(_ configuration: MeetingSummaryGeneratorConfiguration) {
        lock.withLock {
            fallbackModelIDs.append(configuration.cloudFallbackModelID)
        }
    }

    var recordedFallbackModelIDs: [String?] {
        lock.withLock { fallbackModelIDs }
    }
}

private final class MeetingSummaryControlledGenerator:
    MeetingSummaryGenerating,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<MeetingSummaryGenerationResult, Error>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false

    func generate(
        source: MeetingSummarySource
    ) async throws -> MeetingSummaryGenerationResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            hasStarted = true
            let waiters = startedWaiters
            startedWaiters.removeAll()
            lock.unlock()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilStarted() async {
        if lock.withLock({ hasStarted }) { return }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if hasStarted { return true }
                startedWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func complete(
        with result: Result<MeetingSummaryGenerationResult, Error>
    ) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private extension NSLock {
    func withLock<Value>(
        _ body: () throws -> Value
    ) rethrows -> Value {
        lock()
        defer { unlock() }
        return try body()
    }
}

private struct MeetingSummaryAppStateTestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
