import AppKit
import Combine
import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct AppStateAIProcessingBackendTests {
    static func main() async throws {
        let defaultsSnapshot = UserDefaultsSnapshot()
        resetCredentialStore()
        defer {
            defaultsSnapshot.restore()
            resetCredentialStore()
        }

        testResetDoesNotCreateCredentialDirectory()
        try await testDefaultModelAppStateUsesExplicitCredentialLayout()
        await testLegacyModelsMigrateToIndependentCloudChoices()
        await testCorruptedChoicesFallbackAndPersistNormalizedCloudChoices()
        await testWhitespaceCloudIDsFallbackToRememberedOrDefaultModels()
        await testStoredCloudChoicesReconcileRememberedModels()
        try await testSettingsDraftCommittersFlushBeforeRecordingStart()
        await testRetiredCloudChoiceRemainsVisibleForReplacement()
        await testStoredLocalChoicesPreserveRememberedCloudModels()
        await testIncompatibleLegacyContextSelectionIsPreservedAndDisabled()
        await testProviderlessQwenVisionCloudChoiceSupportsContext()
        await testLegacyUninstalledContextDownloadDoesNotQueueOrActivateIt()
        try await testStartupPreservesUnavailableCompatibleLocalChoiceWithoutCloudFallback()
        await testSettingsDismissalPreservesUnavailableLocalChoiceWithoutCloudFallback()
        try await testStartupPreservesRetiredLocalChoicesWithoutSubstitution()
        await testSelectingReadyQualityModelRecoversRetiredPostProcessingChoice()
        await testChangingCloudModelWhileLocalPreservesLocalChoice()
        await testDirectCloudChoiceSynchronizesRememberedModel()
        await testPostProcessingAndContextChoicesStayIndependent()
        await testMeetingSummaryUsesIndependentStoredChoice()
        await testMeetingSummaryDraftFallsBackOrTurnsOffOnDismissal()
        await testDiscardUndownloadedSelectionsRestoresActiveChoices()
        await testDiscardUndownloadedSelectionsPreservesStartedDownloads()
        await testSettingsDismissalDisablesAIWithoutReadyModels()
        await testSettingsDismissalFallsBackToReadyLocalAIModel()
        await testUninstalledContextModelNeverFallsBackToTextOnlyModel()
        await testBrokenSelectedLocalModelKeepsTheUsersChoice()
        await testSameModelDownloadCoalescesAndSelectsBothFeatures()
        await testLocalAIProgressCoalescesAndCompletionWins()
        await testChoosingCloudClearsOnlyOnePendingSelection()
        await testCancelPendingSelectionClearsOnlyOneConsumer()
        await testPendingSelectionChangesPublishObjectWillChange()
        await testCancellationWaitsForCompletionAndRetriesAfterQuiescence()
        try await testIdleShutdownMonitoringIsIdempotentAndStops()
        try await testTerminationWaitsForLocalAIQuiescenceAndSuppressesDuplicates()
        try await testCombinedNativeAndLocalTerminationWaitsForBothWorkers()
        await testTerminationCleanupBlocksNewModelInstalls()
        await testPendingRecordingTerminationCancelRepliesFalseOnce()
        await testPartialCleanupFailureSetsModelIssue()
        await testInstallerFailureClearsPendingSelectionAndMirrorsIssue()
        await testUnsupportedHardwareRejectsLocalSelection()
        await testLowMemoryPreservesStoredLocalChoiceWithoutStartingIt()
        await testAIProcessingChoiceDisplayMetadata()
        testManagedLocalAIModelResolutionReconcilesRetainedLifecycle()
        await testCloudSelectionPublishesContextChoiceOnce()
        await testSelectionWaitsForInitialStatusRefresh()
        await testAppStateInstancesKeepIndependentLocalAIEnvironments()
        await testExecutorUsesOriginatingLocalAIAvailability()
        try await testDeleteDuringInstallWaitsAndCannotAutoSelect()
        try await testDeleteFailurePreservesSelectedLocalChoice()
        try await testDeletingOnlyLocalModelDoesNotSubstituteCloud()
        try testEveryBackendExecutorConstructionUsesCentralFactory()
        try testEveryPostProcessingConstructionUsesCentralFactory()
        try testCloudResumeCapturesPostProcessingServiceBeforeTaskStarts()
        try testContextCaptureUsesServiceSnapshotAndKeepsCancellationGuards()
        try testContextModelObserverRebuildsOnlyThroughChoiceChanges()
        try testAppDelegateStartsIdleMonitoring()
        try testTerminationRoutesThroughUnifiedModelCleanup()
        await testWarningBannerDismissalIsScopedToNoteAndResetsOnRetryGeneration()
        try testDeletingNotesForgetsWarningBannerState()
        print("AppStateAIProcessingBackendTests passed")
    }

    private static let credentialStorageLayout = CredentialStorageLayout(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-app-state-ai-processing-credentials-\(UUID().uuidString)",
                isDirectory: true
            )
    )

    private static var credentialStore: CredentialStore {
        CredentialStore(layout: credentialStorageLayout)
    }

    private static func resetCredentialStore() {
        let directory = credentialStorageLayout.directory
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            preconditionFailure(
                "Could not reset isolated credential storage: \(error.localizedDescription)"
            )
        }
    }

    private static let successfulReadinessProbe: LocalAIServerManager.ReadinessProbe = { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data("{\"choices\":[{\"message\":{\"content\":\"OK\"}}]}".utf8), response)
    }

    private static func testLegacyModelsMigrateToIndependentCloudChoices() async {
        resetAIProcessingDefaults()
        UserDefaults.standard.set("custom/post", forKey: "post_processing_model")
        UserDefaults.standard.set("custom/context", forKey: "context_model")
        let appState = await makeRefreshedAppState()
        await MainActor.run {
            assert(appState.postProcessingBackendChoice == .cloud(modelID: "custom/post"))
            assert(appState.contextBackendChoice == .cloud(modelID: "custom/context"))
        }
    }

    private static func testCorruptedChoicesFallbackAndPersistNormalizedCloudChoices() async {
        resetAIProcessingDefaults()
        let defaults = UserDefaults.standard
        defaults.set("legacy/post", forKey: "post_processing_model")
        defaults.set("legacy/context", forKey: "context_model")
        defaults.set(Data([0xFF]), forKey: "post_processing_backend_choice")
        defaults.set(Data([0xFF]), forKey: "context_backend_choice")

        let appState = await makeRefreshedAppState()

        await MainActor.run {
            assert(appState.postProcessingBackendChoice == .cloud(modelID: "legacy/post"))
            assert(appState.contextBackendChoice == .cloud(modelID: "legacy/context"))
            assert(appState.postProcessingModel == "legacy/post")
            assert(appState.contextModel == "legacy/context")
        }
        assert(storedChoice(forKey: "post_processing_backend_choice") == .cloud(modelID: "legacy/post"))
        assert(storedChoice(forKey: "context_backend_choice") == .cloud(modelID: "legacy/context"))
    }

    private static func testWhitespaceCloudIDsFallbackToRememberedOrDefaultModels() async {
        resetAIProcessingDefaults()
        let defaults = UserDefaults.standard
        defaults.set("  legacy/post  ", forKey: "post_processing_model")
        defaults.set("   ", forKey: "context_model")
        storeChoice(.cloud(modelID: " \n "), forKey: "post_processing_backend_choice")
        storeChoice(.cloud(modelID: "\t"), forKey: "context_backend_choice")

        let appState = await makeRefreshedAppState()

        await MainActor.run {
            assert(appState.postProcessingBackendChoice == .cloud(modelID: "legacy/post"))
            assert(appState.contextBackendChoice == .cloud(modelID: AppState.defaultContextModel))
            assert(appState.postProcessingModel == "legacy/post")
            assert(appState.contextModel == AppState.defaultContextModel)
        }
        assert(defaults.string(forKey: "post_processing_model") == "legacy/post")
        assert(defaults.string(forKey: "context_model") == AppState.defaultContextModel)
        assert(storedChoice(forKey: "post_processing_backend_choice") == .cloud(modelID: "legacy/post"))
        assert(storedChoice(forKey: "context_backend_choice") == .cloud(modelID: AppState.defaultContextModel))
    }

    private static func testStoredCloudChoicesReconcileRememberedModels() async {
        resetAIProcessingDefaults()
        let defaults = UserDefaults.standard
        defaults.set("legacy/post", forKey: "post_processing_model")
        defaults.set("legacy/context", forKey: "context_model")
        storeChoice(.cloud(modelID: "  stored/post  "), forKey: "post_processing_backend_choice")
        storeChoice(.cloud(modelID: "  stored/context  "), forKey: "context_backend_choice")

        let appState = await makeRefreshedAppState()

        await MainActor.run {
            assert(appState.postProcessingBackendChoice == .cloud(modelID: "stored/post"))
            assert(appState.contextBackendChoice == .cloud(modelID: "stored/context"))
            assert(appState.postProcessingModel == "stored/post")
            assert(appState.contextModel == "stored/context")
        }
        assert(defaults.string(forKey: "post_processing_model") == "stored/post")
        assert(defaults.string(forKey: "context_model") == "stored/context")
        assert(storedChoice(forKey: "post_processing_backend_choice") == .cloud(modelID: "stored/post"))
        assert(storedChoice(forKey: "context_backend_choice") == .cloud(modelID: "stored/context"))
    }

    private static func testSettingsDraftCommittersFlushBeforeRecordingStart() async throws {
        resetAIProcessingDefaults()
        let appState = await makeRefreshedAppState()

        await MainActor.run {
            var commitCount = 0
            let registrationID = appState.registerSettingsDraftCommit {
                commitCount += 1
            }

            appState.commitSettingsDraftsBeforeRecordingStart()
            precondition(
                commitCount == 1,
                "recording start flushes the active Settings text draft"
            )

            appState.unregisterSettingsDraftCommit(registrationID)
            appState.commitSettingsDraftsBeforeRecordingStart()
            precondition(
                commitCount == 1,
                "a dismissed Settings view no longer receives recording-start flushes"
            )
        }

        let recordingStart = sourceBlock(
            in: try appStateSource(),
            from: "private func startRecording(",
            to: "/// Whether the configured recording flow will actually exercise Accessibility."
        )
        let flush = requiredRange(
            of: "commitSettingsDraftsBeforeRecordingStart()",
            in: recordingStart
        )
        let task = requiredRange(of: "Task { [weak self]", in: recordingStart)
        assert(
            flush.lowerBound < task.lowerBound,
            "recording flushes Settings text drafts before capturing Context or starting async work"
        )
    }

    private static func testRetiredCloudChoiceRemainsVisibleForReplacement() async {
        resetAIProcessingDefaults()
        let retiredModelID = "allam-2-7b"
        precondition(
            !ModelConfiguration.llmModels.contains(retiredModelID),
            "the retired Cloud model is no longer offered as a predefined choice"
        )
        storeChoice(
            .cloud(modelID: retiredModelID),
            forKey: "post_processing_backend_choice"
        )

        let appState = await makeRefreshedAppState()
        await MainActor.run {
            let matches = appState.aiProcessingChoiceDisplays(for: .postProcessing)
                .filter { $0.choice == .cloud(modelID: retiredModelID) }
            precondition(
                matches.count == 1 && matches[0].isAvailable,
                "a saved retired Cloud model remains visible exactly once so it can be replaced"
            )
            precondition(
                appState.postProcessingBackendChoice == .cloud(modelID: retiredModelID),
                "catalog cleanup does not reset the saved Cloud selection"
            )
        }
    }

    private static func testStoredLocalChoicesPreserveRememberedCloudModels() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .ready)
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }
        let defaults = UserDefaults.standard
        defaults.set("remembered/post", forKey: "post_processing_model")
        defaults.set("remembered/context", forKey: "context_model")
        let postChoice = AIProcessingBackendChoice.localAI(
            modelID: LocalAIModelCatalog.quality.id
        )
        let contextChoice = AIProcessingBackendChoice.localAI(
            modelID: LocalAIModelCatalog.quality.id
        )
        storeChoice(postChoice, forKey: "post_processing_backend_choice")
        storeChoice(contextChoice, forKey: "context_backend_choice")

        let appState = await makeRefreshedAppState(dependencies: dependencies)

        await MainActor.run {
            assert(appState.postProcessingBackendChoice == postChoice)
            assert(appState.contextBackendChoice == contextChoice)
            assert(appState.postProcessingModel == "remembered/post")
            assert(appState.contextModel == "remembered/context")
        }
        assert(defaults.string(forKey: "post_processing_model") == "remembered/post")
        assert(defaults.string(forKey: "context_model") == "remembered/context")
    }

    private static func testIncompatibleLegacyContextSelectionIsPreservedAndDisabled() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .ready)
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }

        let legacyChoice = AIProcessingBackendChoice.localAI(
            modelID: LocalAIModelCatalog.quality.id
        )
        storeChoice(legacyChoice, forKey: "context_backend_choice")
        UserDefaults.standard.set(false, forKey: "disable_context_capture")

        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            precondition(
                appState.disableContextCapture,
                "text-only legacy Context choice disables Context"
            )
            precondition(
                appState.contextBackendChoice == legacyChoice,
                "legacy choice is preserved instead of silently selecting Cloud"
            )
            precondition(
                appState.contextModelCapabilityWarning != nil,
                "Settings receives an explicit incompatibility reason"
            )
        }
    }

    private static func testProviderlessQwenVisionCloudChoiceSupportsContext() async {
        resetAIProcessingDefaults()
        let appState = await makeRefreshedAppState()
        let choice = AIProcessingBackendChoice.cloud(modelID: "qwen3.6-27b")

        await MainActor.run {
            precondition(
                appState.isAIProcessingChoiceAvailable(choice, for: .context),
                "the providerless Qwen vision alias is available for Context"
            )
            appState.selectAIProcessingBackendChoice(choice, for: .context)
            precondition(
                appState.contextBackendChoice == choice,
                "the providerless Qwen vision alias is retained as the Context choice"
            )
            precondition(
                appState.contextModelCapabilityWarning == nil,
                "the providerless Qwen vision alias does not show a Context capability warning"
            )
        }
    }

    private static func testLegacyUninstalledContextDownloadDoesNotQueueOrActivateIt() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }
        dependencies.localAI.startInstall = installHarness.start

        let legacyChoice = AIProcessingBackendChoice.localAI(
            modelID: LocalAIModelCatalog.quality.id
        )
        storeChoice(legacyChoice, forKey: "context_backend_choice")
        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            precondition(appState.disableContextCapture)
            precondition(appState.contextBackendChoice == legacyChoice)

            appState.installLocalAIModel(
                LocalAIModelCatalog.quality,
                autoSelectFor: .context
            )

            precondition(
                appState.pendingLocalAIModelID(for: .context) == nil,
                "incompatible legacy Context download is not queued for activation"
            )
            precondition(appState.localAIInstallState(for: LocalAIModelCatalog.quality).isInstalling)
        }

        statusHarness.set(.ready, for: LocalAIModelCatalog.quality)
        installHarness.complete(model: LocalAIModelCatalog.quality, with: .success(()))
        await waitUntil {
            !appState.localAIInstallState(for: LocalAIModelCatalog.quality).isInstalling
        }
        await MainActor.run {
            precondition(appState.contextBackendChoice == legacyChoice)
            precondition(appState.disableContextCapture)
        }
    }

    private static func testStartupPreservesUnavailableCompatibleLocalChoiceWithoutCloudFallback() async throws {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }

        let localChoice = AIProcessingBackendChoice.localAI(
            modelID: LocalAIModelCatalog.quality.id
        )
        storeChoice(localChoice, forKey: "post_processing_backend_choice")
        try credentialStore.save(
            "configured-key",
            account: "groq_api_key"
        )

        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            precondition(
                appState.postProcessingBackendChoice == localChoice,
                "unavailable Local backend is preserved instead of silently selecting Cloud"
            )
            precondition(appState.disablePostProcessing)
        }
        precondition(
            storedChoice(forKey: "post_processing_backend_choice") == localChoice
        )
    }

    private static func testSettingsDismissalPreservesUnavailableLocalChoiceWithoutCloudFallback() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }

        let localChoice = AIProcessingBackendChoice.localAI(
            modelID: LocalAIModelCatalog.quality.id
        )
        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            appState.apiKey = "configured-key"
            appState.postProcessingBackendChoice = localChoice
            appState.disablePostProcessing = false

            appState.reconcileModelSelectionsAfterSettingsDismissal()

            precondition(
                appState.postProcessingBackendChoice == localChoice,
                "Settings dismissal preserves an unavailable Local backend instead of selecting Cloud"
            )
            precondition(appState.disablePostProcessing)
        }
    }

    private static func testStartupPreservesRetiredLocalChoicesWithoutSubstitution() async throws {
        resetAIProcessingDefaults()
        let retiredModelID = "qwen2.5-1.5b-instruct"
        let retiredChoice = AIProcessingBackendChoice.localAI(modelID: retiredModelID)
        let statusHarness = LocalAIStatusHarness(
            statuses: [LocalAIModelCatalog.quality.id: .ready],
            defaultStatus: .notInstalled
        )
        let installHarness = LocalAIInstallHarness()
        let deletionHarness = LocalAIDeletionHarness()
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }
        dependencies.localAI.startInstall = installHarness.start
        dependencies.localAI.deleteModel = { model in
            deletionHarness.record(modelID: model.id, managerWasStopped: true)
        }

        UserDefaults.standard.set("remembered/post", forKey: "post_processing_model")
        UserDefaults.standard.set("remembered/context", forKey: "context_model")
        storeChoice(retiredChoice, forKey: "post_processing_backend_choice")
        storeChoice(retiredChoice, forKey: "context_backend_choice")
        try credentialStore.save(
            "configured-cloud-key",
            account: "groq_api_key"
        )

        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            precondition(appState.postProcessingBackendChoice == retiredChoice)
            precondition(appState.contextBackendChoice == retiredChoice)
            precondition(
                appState.meetingSummaryBackendChoice == retiredChoice,
                "first-run Meeting Summary retains its retired Post-processing choice"
            )
            precondition(appState.disablePostProcessing)
            precondition(appState.disableContextCapture)
            precondition(appState.disableMeetingSummary)
            precondition(appState.postProcessingModel == "remembered/post")
            precondition(appState.contextModel == "remembered/context")
            precondition(appState.meetingSummaryModel == "remembered/post")
            for feature in AIProcessingFeature.allCases {
                precondition(
                    !appState.isAIProcessingChoiceAvailable(retiredChoice, for: feature)
                )
                let display = appState.aiProcessingChoiceDisplays(for: feature).first {
                    $0.choice == retiredChoice
                }
                precondition(display?.isAvailable == false)
                precondition(display?.unavailableReason?.isEmpty == false)
                precondition(
                    display?.title == "Qwen2.5 1.5B Instruct",
                    "known retired models use their human-readable Settings label"
                )
            }
            let contextCloudDisplays = appState.aiProcessingChoiceDisplays(for: .context)
                .filter { $0.choice == .cloud(modelID: "qwen/qwen3.6-27b") }
            precondition(
                contextCloudDisplays.count == 1
                    && contextCloudDisplays[0].isAvailable,
                "a retired Context choice does not hide the compatible Cloud Context model"
            )
            let postLocalDisplays = appState.aiProcessingChoiceDisplays(for: .postProcessing)
                .filter { $0.choice.isLocal && $0.isAvailable }
            precondition(
                postLocalDisplays.map(\.choice)
                    == [
                        .localAI(modelID: LocalAIModelCatalog.quality.id),
                        .localAI(modelID: LocalAIModelCatalog.gemma4E4B.id)
                    ]
            )
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == nil)
            precondition(appState.pendingLocalAIModelID(for: .context) == nil)
            precondition(appState.pendingLocalAIModelID(for: .meetingSummary) == nil)
        }
        precondition(installHarness.starts(for: LocalAIModelCatalog.quality) == 0)
        precondition(deletionHarness.callCount == 0)
        for key in [
            "post_processing_backend_choice",
            "context_backend_choice",
            "meeting_summary_backend_choice"
        ] {
            precondition(storedChoice(forKey: key) == retiredChoice)
        }
    }

    private static func testSelectingReadyQualityModelRecoversRetiredPostProcessingChoice() async {
        resetAIProcessingDefaults()
        let retiredChoice = AIProcessingBackendChoice.localAI(
            modelID: "qwen2.5-1.5b-instruct"
        )
        let statusHarness = LocalAIStatusHarness(
            statuses: [LocalAIModelCatalog.quality.id: .ready],
            defaultStatus: .notInstalled
        )
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }
        storeChoice(retiredChoice, forKey: "post_processing_backend_choice")

        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            precondition(appState.postProcessingBackendChoice == retiredChoice)
            precondition(appState.disablePostProcessing)

            let qualityChoice = AIProcessingBackendChoice.localAI(
                modelID: LocalAIModelCatalog.quality.id
            )
            appState.selectAIProcessingBackendChoice(
                qualityChoice,
                for: .postProcessing
            )
            precondition(appState.postProcessingBackendChoice == qualityChoice)
            precondition(appState.postProcessingBackendChoice != .cloud(
                modelID: AppState.defaultPostProcessingModel
            ))
        }
        precondition(
            storedChoice(forKey: "post_processing_backend_choice")
                == .localAI(modelID: LocalAIModelCatalog.quality.id)
        )
    }

    private static func testChangingCloudModelWhileLocalPreservesLocalChoice() async {
        resetAIProcessingDefaults()
        let appState = await makeRefreshedAppState()
        await MainActor.run {
            appState.postProcessingBackendChoice = .localAI(
                modelID: LocalAIModelCatalog.quality.id
            )
            appState.contextBackendChoice = .localAI(
                modelID: LocalAIModelCatalog.quality.id
            )
            appState.postProcessingModel = "new/cloud-model"
            appState.contextModel = "new/context-cloud-model"
            assert(
                appState.postProcessingBackendChoice
                    == .localAI(modelID: LocalAIModelCatalog.quality.id)
            )
            assert(
                appState.contextBackendChoice
                    == .localAI(modelID: LocalAIModelCatalog.quality.id)
            )
        }
    }

    private static func testDirectCloudChoiceSynchronizesRememberedModel() async {
        resetAIProcessingDefaults()
        let appState = await makeRefreshedAppState()
        await MainActor.run {
            appState.postProcessingBackendChoice = .cloud(modelID: "direct/post")
            appState.contextBackendChoice = .cloud(modelID: "direct/context")
            assert(appState.postProcessingModel == "direct/post")
            assert(appState.contextModel == "direct/context")
            assert(appState.postProcessingBackendChoice == .cloud(modelID: "direct/post"))
            assert(appState.contextBackendChoice == .cloud(modelID: "direct/context"))
        }
        assert(UserDefaults.standard.string(forKey: "post_processing_model") == "direct/post")
        assert(UserDefaults.standard.string(forKey: "context_model") == "direct/context")
        assert(storedChoice(forKey: "post_processing_backend_choice") == .cloud(modelID: "direct/post"))
        assert(storedChoice(forKey: "context_backend_choice") == .cloud(modelID: "direct/context"))
    }

    private static func testPostProcessingAndContextChoicesStayIndependent() async {
        resetAIProcessingDefaults()
        let appState = await makeRefreshedAppState()
        await MainActor.run {
            appState.postProcessingBackendChoice = .localAI(
                modelID: LocalAIModelCatalog.quality.id
            )
            appState.contextBackendChoice = .cloud(modelID: "context/cloud")
            assert(appState.postProcessingBackendChoice.isLocal)
            assert(appState.contextBackendChoice == .cloud(modelID: "context/cloud"))
        }
    }

    private static func testMeetingSummaryUsesIndependentStoredChoice() async {
        resetAIProcessingDefaults()
        let appState = await makeRefreshedAppState()

        await MainActor.run {
            appState.apiKey = "configured-key"
            appState.selectAIProcessingBackendChoice(
                .cloud(modelID: "summary/model"),
                for: .meetingSummary
            )

            precondition(
                appState.meetingSummaryBackendChoice
                    == .cloud(modelID: "summary/model")
            )
            precondition(
                appState.postProcessingBackendChoice
                    != appState.meetingSummaryBackendChoice
            )
        }
    }

    private static func testMeetingSummaryDraftFallsBackOrTurnsOffOnDismissal() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }

        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            appState.apiKey = ""
            appState.disableMeetingSummary = false
            appState.commitModelSettingsDrafts(
                transcriptionEnabled: appState.transcriptionEnabled,
                transcriptionChoice: appState.currentNoteBrowserTranscriptionChoice,
                postProcessingEnabled: !appState.disablePostProcessing,
                postProcessingChoice: appState.postProcessingBackendChoice,
                contextEnabled: !appState.disableContextCapture,
                contextChoice: appState.contextBackendChoice,
                meetingSummaryEnabled: true,
                meetingSummaryChoice: .cloud(modelID: "summary/model")
            )

            precondition(appState.disableMeetingSummary)
        }
    }

    private static func testDiscardUndownloadedSelectionsRestoresActiveChoices() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }

        let model = LocalAIModelCatalog.quality
        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            appState.apiKey = "configured-key"
            appState.disablePostProcessing = false
            appState.disableContextCapture = false
            let originalPostChoice = appState.postProcessingBackendChoice
            let originalContextChoice = appState.contextBackendChoice
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .postProcessing
            )
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .context
            )
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == model.id)
            precondition(appState.pendingLocalAIModelID(for: .context) == nil)

            appState.commitModelSettingsDrafts(
                transcriptionEnabled: appState.transcriptionEnabled,
                transcriptionChoice: appState.currentNoteBrowserTranscriptionChoice,
                postProcessingEnabled: true,
                postProcessingChoice: .localAI(modelID: model.id),
                contextEnabled: true,
                contextChoice: .localAI(modelID: model.id),
                meetingSummaryEnabled: !appState.disableMeetingSummary,
                meetingSummaryChoice: appState.meetingSummaryBackendChoice
            )

            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == nil)
            precondition(appState.pendingLocalAIModelID(for: .context) == nil)
            precondition(appState.postProcessingBackendChoice == originalPostChoice)
            precondition(appState.contextBackendChoice == originalContextChoice)
            precondition(!appState.disablePostProcessing)
            precondition(appState.disableContextCapture)
        }
    }

    private static func testDiscardUndownloadedSelectionsPreservesStartedDownloads() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }
        dependencies.localAI.startInstall = installHarness.start

        let model = LocalAIModelCatalog.quality
        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .postProcessing
            )
            appState.installLocalAIModel(model, autoSelectFor: .postProcessing)
            precondition(appState.localAIInstallState(for: model).isInstalling)

            appState.discardUndownloadedLocalAISelections()

            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == model.id)
            precondition(appState.localAIInstallState(for: model).isInstalling)
            appState.cancelLocalAIInstall(model)
        }
        installHarness.complete(model: model, with: .failure(.cancelled))
        await waitUntil { !appState.localAIInstallState(for: model).isInstalling }
    }

    private static func testSettingsDismissalDisablesAIWithoutReadyModels() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }

        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            appState.apiKey = ""
            appState.disablePostProcessing = false
            appState.disableContextCapture = false

            appState.reconcileModelSelectionsAfterSettingsDismissal()

            precondition(appState.disablePostProcessing)
            precondition(appState.disableContextCapture)
        }
    }

    // With several local models, falling back from an uninstalled selection
    // must only pick a model that supports the feature (Context needs images).
    private static func testUninstalledContextModelNeverFallsBackToTextOnlyModel() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        statusHarness.set(.ready, for: LocalAIModelCatalog.quality)
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }
        let gemma = AIProcessingBackendChoice.localAI(modelID: LocalAIModelCatalog.gemma4E4B.id)
        storeChoice(gemma, forKey: "context_backend_choice")
        UserDefaults.standard.set(false, forKey: "disable_context_capture")

        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            precondition(
                appState.contextBackendChoice != .localAI(modelID: LocalAIModelCatalog.quality.id),
                "Context must not fall back to the text-only Qwen model"
            )
            precondition(appState.contextBackendChoice == gemma, "the Gemma Context choice is preserved")
            precondition(appState.disableContextCapture, "Context waits for Gemma instead of running without it")
        }
    }

    // A selected local model that is corrupt or partly downloaded must not be
    // silently and permanently replaced by another installed local model.
    private static func testBrokenSelectedLocalModelKeepsTheUsersChoice() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        statusHarness.set(.ready, for: LocalAIModelCatalog.quality)
        statusHarness.set(.corrupt("synthetic projector damage"), for: LocalAIModelCatalog.gemma4E4B)
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }
        let gemma = AIProcessingBackendChoice.localAI(modelID: LocalAIModelCatalog.gemma4E4B.id)
        storeChoice(gemma, forKey: "post_processing_backend_choice")

        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            precondition(appState.postProcessingBackendChoice == gemma, "the Gemma choice is kept for after repair")
            precondition(appState.disablePostProcessing, "post-processing waits for the selected model")
        }
    }

    private static func testSettingsDismissalFallsBackToReadyLocalAIModel() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        var dependencies = modelTestDependencies()
        let model = LocalAIModelCatalog.quality
        statusHarness.set(.ready, for: model)
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }

        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            appState.apiKey = ""
            appState.postProcessingBackendChoice = .cloud(
                modelID: AppState.defaultPostProcessingModel
            )
            appState.contextBackendChoice = .cloud(
                modelID: AppState.defaultContextModel
            )
            appState.disablePostProcessing = false
            appState.disableContextCapture = false

            appState.reconcileModelSelectionsAfterSettingsDismissal()

            let expectedPostProcessingChoice = AIProcessingBackendChoice.localAI(
                modelID: model.id
            )
            precondition(appState.postProcessingBackendChoice == expectedPostProcessingChoice)
            precondition(
                appState.contextBackendChoice
                    == .cloud(modelID: AppState.defaultContextModel)
            )
            precondition(!appState.disablePostProcessing)
            precondition(appState.disableContextCapture)
        }
    }

    private static func testSameModelDownloadCoalescesAndSelectsBothFeatures() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }
        dependencies.localAI.startInstall = installHarness.start

        let model = LocalAIModelCatalog.quality
        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            let originalPostChoice = appState.postProcessingBackendChoice
            let originalContextChoice = appState.contextBackendChoice
            let originalSummaryChoice = appState.meetingSummaryBackendChoice
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .postProcessing
            )
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .context
            )
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .meetingSummary
            )

            precondition(appState.postProcessingBackendChoice == originalPostChoice)
            precondition(appState.contextBackendChoice == originalContextChoice)
            precondition(appState.meetingSummaryBackendChoice == originalSummaryChoice)
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == model.id)
            precondition(appState.pendingLocalAIModelID(for: .context) == nil)
            precondition(appState.pendingLocalAIModelID(for: .meetingSummary) == model.id)
            precondition(appState.selectedOrPendingLocalAIModel(for: .postProcessing) == model)
            precondition(!appState.localAIInstallState(for: model).isInstalling)
        }
        precondition(installHarness.starts(for: model) == 0)

        await MainActor.run {
            appState.installLocalAIModel(model, autoSelectFor: .postProcessing)
            precondition(appState.localAIInstallState(for: model).isInstalling)
        }
        precondition(installHarness.starts(for: model) == 1)

        statusHarness.set(.ready, for: model)
        installHarness.complete(model: model, with: .success(()))
        await waitUntil {
            !appState.localAIInstallState(for: model).isInstalling
        }

        await MainActor.run {
            let expected = AIProcessingBackendChoice.localAI(modelID: model.id)
            precondition(appState.postProcessingBackendChoice == expected)
            precondition(
                appState.contextBackendChoice
                    == .cloud(modelID: AppState.defaultContextModel)
            )
            precondition(appState.meetingSummaryBackendChoice == expected)
            precondition(appState.disableContextCapture)
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == nil)
            precondition(appState.pendingLocalAIModelID(for: .context) == nil)
            precondition(appState.pendingLocalAIModelID(for: .meetingSummary) == nil)
            precondition(appState.localAIInstallState(for: model).status == .ready)
            precondition(appState.localAIInstallState(for: model).issue == nil)
        }
    }

    private static func testLocalAIProgressCoalescesAndCompletionWins() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let scheduler = ProgressScheduleHarness()
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }
        dependencies.localAI.startInstall = installHarness.start
        dependencies.localAI.progressSchedule = scheduler.schedule

        let model = LocalAIModelCatalog.quality
        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            appState.installLocalAIModel(model)
        }

        for value in 1...10_000 {
            installHarness.sendProgress(
                model: model,
                progress: LocalAIDownloadProgress(
                    downloadedBytes: Int64(value),
                    totalBytes: 10_000
                )
            )
        }

        precondition(scheduler.scheduledCount == 1)
        await MainActor.run { scheduler.runAll() }
        let coalescedBytes = await MainActor.run {
            appState.localAIInstallState(for: model).progress.downloadedBytes
        }
        precondition(coalescedBytes == 10_000)

        installHarness.sendProgress(
            model: model,
            progress: LocalAIDownloadProgress(
                downloadedBytes: 10_001,
                totalBytes: 20_000
            )
        )
        precondition(scheduler.scheduledCount == 1)
        statusHarness.set(.ready, for: model)
        installHarness.complete(model: model, with: .success(()))
        await appState.waitForLocalAIInstallsToQuiesce()
        await MainActor.run { scheduler.runAll() }
        let finalState = await MainActor.run {
            appState.localAIInstallState(for: model)
        }
        precondition(finalState.status == .ready)
        precondition(!finalState.isInstalling)
        precondition(finalState.progress.downloadedBytes == 10_000)
    }

    private static func testChoosingCloudClearsOnlyOnePendingSelection() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }
        dependencies.localAI.startInstall = installHarness.start

        let model = LocalAIModelCatalog.quality
        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .postProcessing
            )
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .meetingSummary
            )
            appState.installLocalAIModel(model, autoSelectFor: .meetingSummary)
            appState.selectAIProcessingBackendChoice(
                .cloud(modelID: "cloud/override"),
                for: .postProcessing
            )

            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == nil)
            precondition(appState.pendingLocalAIModelID(for: .meetingSummary) == model.id)
            precondition(
                appState.postProcessingBackendChoice
                    == .cloud(modelID: "cloud/override")
            )
            precondition(appState.localAIInstallState(for: model).isInstalling)
        }

        statusHarness.set(.ready, for: model)
        installHarness.complete(model: model, with: .success(()))
        await waitUntil {
            !appState.localAIInstallState(for: model).isInstalling
        }
        await MainActor.run {
            precondition(
                appState.postProcessingBackendChoice
                    == .cloud(modelID: "cloud/override")
            )
            precondition(
                appState.meetingSummaryBackendChoice
                    == .localAI(modelID: model.id)
            )
        }
    }

    private static func testCancelPendingSelectionClearsOnlyOneConsumer() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }
        dependencies.localAI.startInstall = installHarness.start

        let model = LocalAIModelCatalog.quality
        let appState = await makeRefreshedAppState(dependencies: dependencies)
        let originalPostChoice = await MainActor.run {
            let originalPostChoice = appState.postProcessingBackendChoice
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .postProcessing
            )
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .meetingSummary
            )
            appState.installLocalAIModel(model, autoSelectFor: .meetingSummary)
            appState.cancelPendingLocalAISelection(for: .postProcessing)
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == nil)
            precondition(appState.pendingLocalAIModelID(for: .meetingSummary) == model.id)
            precondition(appState.localAIInstallState(for: model).isInstalling)
            return originalPostChoice
        }

        statusHarness.set(.ready, for: model)
        installHarness.complete(model: model, with: .success(()))
        await waitUntil {
            !appState.localAIInstallState(for: model).isInstalling
        }
        await MainActor.run {
            precondition(appState.postProcessingBackendChoice == originalPostChoice)
            precondition(
                appState.meetingSummaryBackendChoice
                    == .localAI(modelID: model.id)
            )
        }
    }

    private static func testPendingSelectionChangesPublishObjectWillChange() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }
        dependencies.localAI.startInstall = installHarness.start

        let model = LocalAIModelCatalog.quality
        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .postProcessing
            )
        }

        await MainActor.run {
            var publications = 0
            let cancellable = appState.objectWillChange.sink {
                publications += 1
            }

            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .meetingSummary
            )
            precondition(publications > 0)
            publications = 0

            appState.cancelPendingLocalAISelection(for: .meetingSummary)
            precondition(publications > 0)
            publications = 0

            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .meetingSummary
            )
            publications = 0
            appState.selectAIProcessingBackendChoice(
                .cloud(modelID: "cloud/pending-clear"),
                for: .meetingSummary
            )
            precondition(publications > 0)
            withExtendedLifetime(cancellable) {}
        }
    }

    private static func testCancellationWaitsForCompletionAndRetriesAfterQuiescence() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let partialDeletionHarness = LocalAIDeletionHarness()
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }
        dependencies.localAI.startInstall = installHarness.start
        dependencies.localAI.deletePartialModel = { model in
            partialDeletionHarness.record(
                modelID: model.id,
                managerWasStopped: false
            )
        }

        let model = LocalAIModelCatalog.quality
        let appState = await makeRefreshedAppState(dependencies: dependencies)
        let originalChoices = await MainActor.run { () -> (AIProcessingBackendChoice, AIProcessingBackendChoice) in
            let choices = (
                appState.postProcessingBackendChoice,
                appState.contextBackendChoice
            )
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .postProcessing
            )
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .context
            )
            appState.installLocalAIModel(model, autoSelectFor: .postProcessing)
            appState.cancelLocalAIInstall(model)
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == nil)
            precondition(appState.pendingLocalAIModelID(for: .context) == nil)
            precondition(appState.localAIInstallState(for: model).isInstalling)
            precondition(appState.localAIInstallState(for: model).progress.isCancelled)
            return choices
        }
        precondition(installHarness.task(for: model, startIndex: 0)?.isCancelled == true)
        precondition(partialDeletionHarness.deletedModelIDs.isEmpty)

        installHarness.sendProgress(
            model: model,
            startIndex: 0,
            progress: LocalAIDownloadProgress(
                downloadedBytes: 777,
                totalBytes: model.approximateBytes
            )
        )
        await yieldMainActor()
        await MainActor.run {
            let cancellingState = appState.localAIInstallState(for: model)
            precondition(cancellingState.isInstalling)
            precondition(cancellingState.progress.isCancelled)
            precondition(cancellingState.progress.downloadedBytes == 0)

            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .postProcessing
            )
            appState.installLocalAIModel(model, autoSelectFor: .postProcessing)
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == model.id)
        }
        precondition(installHarness.starts(for: model) == 1)

        installHarness.complete(
            model: model,
            startIndex: 0,
            with: .failure(.cancelled)
        )
        await waitUntil { installHarness.starts(for: model) == 2 }
        precondition(partialDeletionHarness.deletedModelIDs == [model.id])
        await MainActor.run {
            let replacementState = appState.localAIInstallState(for: model)
            precondition(replacementState.isInstalling)
            precondition(!replacementState.progress.isCancelled)
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == model.id)
            precondition(appState.postProcessingBackendChoice == originalChoices.0)
            precondition(appState.contextBackendChoice == originalChoices.1)
        }

        statusHarness.set(.ready, for: model)
        installHarness.complete(
            model: model,
            startIndex: 1,
            with: .success(())
        )
        await waitUntil {
            !appState.localAIInstallState(for: model).isInstalling
        }
        await MainActor.run {
            precondition(
                appState.postProcessingBackendChoice
                    == .localAI(modelID: model.id)
            )
            precondition(appState.contextBackendChoice == originalChoices.1)
        }
    }

    private static func testIdleShutdownMonitoringIsIdempotentAndStops() async throws {
        resetAIProcessingDefaults()
        let sleepHarness = ControlledAsyncSleepHarness()
        let process = TestLocalAIServerProcess()
        let manager = LocalAIServerManager(
            idleTimeout: 0,
            launchProcess: { _, _, port, _ in (process, port) },
            pollHealth: { _ in true },
            readinessProbe: successfulReadinessProbe,
            validateModel: { _ in .ready },
            terminationGracePeriod: 0,
            waitForProcessExit: { _, _ in true }
        )
        var dependencies = modelTestDependencies()
        dependencies.localAI.makeServerManager = { manager }
        dependencies.localAI.idleShutdownSleep = { nanoseconds in
            try await sleepHarness.sleep(nanoseconds: nanoseconds)
        }

        _ = try await manager.withBaseURL(for: LocalAIModelCatalog.quality) { $0 }
        precondition(process.isRunning)
        let appState = await makeRefreshedAppState(dependencies: dependencies)

        await MainActor.run {
            appState.startLocalAIIdleShutdownMonitoring()
            appState.startLocalAIIdleShutdownMonitoring()
        }
        await waitUntil { sleepHarness.callCount == 1 }

        sleepHarness.resumeNext()
        await waitUntil { !process.isRunning }
        await waitUntil { sleepHarness.callCount == 2 }

        await MainActor.run {
            appState.stopLocalAIIdleShutdownMonitoring()
        }
        await waitUntil { sleepHarness.pendingCount == 0 }
        await yieldMainActor()
        precondition(sleepHarness.callCount == 2)
    }

    private static func testTerminationWaitsForLocalAIQuiescenceAndSuppressesDuplicates() async throws {
        let effects = ModelTerminationEffectSnapshot()
        defer { effects.restore() }
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let partialDeletionHarness = LocalAIDeletionHarness()
        let replyHarness = TerminationReplyHarness()
        let process = TestLocalAIServerProcess()
        let manager = LocalAIServerManager(
            launchProcess: { _, _, port, _ in (process, port) },
            pollHealth: { _ in true },
            readinessProbe: successfulReadinessProbe,
            validateModel: { _ in .ready },
            terminationGracePeriod: 0,
            waitForProcessExit: { _, _ in true }
        )
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }
        dependencies.localAI.startInstall = installHarness.start
        dependencies.localAI.deletePartialModel = { model in
            partialDeletionHarness.record(
                modelID: model.id,
                managerWasStopped: !process.isRunning
            )
        }
        dependencies.localAI.makeServerManager = { manager }
        AppState.modelDownloadQuitAlertPresenter = { .alertFirstButtonReturn }
        AppState.applicationTerminationReply = replyHarness.reply

        let model = LocalAIModelCatalog.quality
        let appState = await makeRefreshedAppState(dependencies: dependencies)
        _ = try await manager.withBaseURL(for: LocalAIModelCatalog.quality) { $0 }
        await MainActor.run {
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .postProcessing
            )
            appState.installLocalAIModel(model, autoSelectFor: .postProcessing)
            appState.cancelLocalAIInstall(model)
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .postProcessing
            )
            appState.installLocalAIModel(model, autoSelectFor: .postProcessing)
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == model.id)
        }

        let replies = await MainActor.run { () -> [NSApplication.TerminateReply] in
            let first = appState.requestTerminationAfterModelCleanup()
            let duplicate = appState.requestTerminationAfterModelCleanup()
            return [first, duplicate]
        }
        precondition(replies == [.terminateLater, .terminateLater])
        precondition(installHarness.task(for: model, startIndex: 0)?.isCancelled == true)
        await MainActor.run {
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == nil)
        }
        precondition(process.isRunning)
        precondition(replyHarness.values.isEmpty)

        installHarness.complete(model: model, with: .failure(.cancelled))
        await waitUntil { !process.isRunning }
        await waitUntil { replyHarness.values == [true] }
        precondition(partialDeletionHarness.deletedModelIDs == [model.id])
        precondition(partialDeletionHarness.managerWasStoppedValues == [false])
        precondition(installHarness.starts(for: model) == 1)
        await yieldMainActor()
        precondition(replyHarness.values == [true])
    }

    private static func testCombinedNativeAndLocalTerminationWaitsForBothWorkers() async throws {
        let effects = ModelTerminationEffectSnapshot()
        defer { effects.restore() }
        resetAIProcessingDefaults()
        let localStatusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let localInstallHarness = LocalAIInstallHarness()
        let nativeStatusHarness = NativeWhisperStatusHarness(status: .notInstalled)
        let nativeInstallHarness = ControlledNativeWhisperInstallHarness()
        let partialDeletionHarness = LocalAIDeletionHarness()
        let replyHarness = TerminationReplyHarness()
        let process = TestLocalAIServerProcess()
        let manager = LocalAIServerManager(
            launchProcess: { _, _, port, _ in (process, port) },
            pollHealth: { _ in true },
            readinessProbe: successfulReadinessProbe,
            validateModel: { _ in .ready },
            terminationGracePeriod: 0,
            waitForProcessExit: { _, _ in true }
        )
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { localStatusHarness.status(for: $0) }
        dependencies.localAI.startInstall = localInstallHarness.start
        dependencies.localAI.deletePartialModel = { model in
            partialDeletionHarness.record(
                modelID: model.id,
                managerWasStopped: !process.isRunning
            )
        }
        dependencies.nativeWhisper.installStatus = {
            nativeStatusHarness.installStatus(for: $0)
        }
        dependencies.nativeWhisper.startInstall = { model, progress, completion in
            nativeInstallHarness.start(
                model: model,
                progress: progress,
                completion: completion
            )
        }
        dependencies.localAI.makeServerManager = { manager }
        AppState.modelDownloadQuitAlertPresenter = { .alertFirstButtonReturn }
        AppState.applicationTerminationReply = replyHarness.reply

        let localModel = LocalAIModelCatalog.quality
        let appState = await makeRefreshedAppState(dependencies: dependencies)
        _ = try await manager.withBaseURL(for: LocalAIModelCatalog.quality) { $0 }
        await MainActor.run {
            appState.installNativeWhisperModel(autoSelectWhenReady: false)
            appState.installLocalAIModel(localModel)
            precondition(appState.isInstallingNativeWhisper)
            precondition(appState.localAIInstallState(for: localModel).isInstalling)
        }

        let terminationReply = await MainActor.run {
            appState.requestTerminationAfterModelCleanup()
        }
        precondition(terminationReply == .terminateLater)
        precondition(nativeInstallHarness.task?.isCancelled == true)
        precondition(
            localInstallHarness.task(for: localModel, startIndex: 0)?.isCancelled
                == true
        )

        localInstallHarness.complete(model: localModel, with: .failure(.cancelled))
        await waitUntil {
            !appState.localAIInstallState(for: localModel).isInstalling
        }
        precondition(partialDeletionHarness.deletedModelIDs == [localModel.id])
        precondition(partialDeletionHarness.managerWasStoppedValues == [false])
        precondition(process.isRunning)
        precondition(replyHarness.values.isEmpty)

        nativeInstallHarness.complete(with: .failure(.cancelled))
        await waitUntil { !appState.isInstallingNativeWhisper }
        await waitUntil { !process.isRunning }
        await waitUntil { replyHarness.values == [true] }
        await yieldMainActor()
        precondition(replyHarness.values == [true])
    }

    private static func testTerminationCleanupBlocksNewModelInstalls() async {
        let effects = ModelTerminationEffectSnapshot()
        defer { effects.restore() }
        resetAIProcessingDefaults()
        let localStatusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let localInstallHarness = LocalAIInstallHarness()
        let nativeStatusHarness = NativeWhisperStatusHarness(status: .notInstalled)
        let nativeInstallHarness = ControlledNativeWhisperInstallHarness()
        let replyHarness = TerminationReplyHarness()
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { localStatusHarness.status(for: $0) }
        dependencies.localAI.startInstall = localInstallHarness.start
        dependencies.localAI.deletePartialModel = { _ in }
        dependencies.nativeWhisper.installStatus = {
            nativeStatusHarness.installStatus(for: $0)
        }
        dependencies.nativeWhisper.startInstall = { model, progress, completion in
            nativeInstallHarness.start(
                model: model,
                progress: progress,
                completion: completion
            )
        }
        AppState.modelDownloadQuitAlertPresenter = { .alertFirstButtonReturn }
        AppState.applicationTerminationReply = replyHarness.reply

        let activeModel = LocalAIModelCatalog.quality
        let blockedModel = LocalAIModelCatalog.quality
        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            appState.installLocalAIModel(activeModel)
            precondition(
                appState.requestTerminationAfterModelCleanup() == .terminateLater
            )
            appState.installNativeWhisperModel(autoSelectWhenReady: true)
            appState.installLocalAIModel(
                blockedModel,
                autoSelectFor: .postProcessing
            )
        }

        precondition(nativeInstallHarness.startCount == 0)
        precondition(localInstallHarness.starts(for: blockedModel) == 1)
        await MainActor.run {
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == nil)
            precondition(!appState.willAutoSelectNativeWhisperWhenReady)
        }

        localInstallHarness.complete(model: activeModel, with: .failure(.cancelled))
        await waitUntil { replyHarness.values == [true] }
    }

    private static func testPendingRecordingTerminationCancelRepliesFalseOnce() async {
        let effects = ModelTerminationEffectSnapshot()
        defer { effects.restore() }
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let replyHarness = TerminationReplyHarness()
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }
        dependencies.localAI.startInstall = installHarness.start
        dependencies.localAI.deletePartialModel = { _ in }
        AppState.modelDownloadQuitAlertPresenter = { .alertSecondButtonReturn }
        AppState.applicationTerminationReply = replyHarness.reply

        let model = LocalAIModelCatalog.quality
        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            appState.installLocalAIModel(model)
            let reply = appState.requestTerminationAfterModelCleanup(
                replyIsAlreadyPending: true
            )
            precondition(reply == .terminateCancel)
        }
        precondition(replyHarness.values == [false])
        precondition(installHarness.task(for: model, startIndex: 0)?.isCancelled == false)

        await MainActor.run {
            appState.cancelLocalAIInstall(model)
        }
        installHarness.complete(model: model, with: .failure(.cancelled))
        await appState.waitForLocalAIInstallsToQuiesce()
        precondition(replyHarness.values == [false])
    }

    private static func testPartialCleanupFailureSetsModelIssue() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .partial(
            downloadedBytes: 10,
            expectedBytes: LocalAIModelCatalog.quality.approximateBytes
        ))
        let installHarness = LocalAIInstallHarness()
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }
        dependencies.localAI.startInstall = installHarness.start
        dependencies.localAI.deletePartialModel = { _ in
            throw TestLocalAILifecycleError.partialCleanupFailed
        }

        let model = LocalAIModelCatalog.quality
        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            appState.installLocalAIModel(model)
            appState.cancelLocalAIInstall(model)
        }
        installHarness.complete(model: model, with: .failure(.cancelled))
        await waitUntil {
            !appState.localAIInstallState(for: model).isInstalling
        }
        await MainActor.run {
            precondition(
                appState.localAIInstallState(for: model).issue?.code
                    == .localAIModelUnavailable
            )
            precondition(
                appState.localAIInstallState(for: model).status
                    == .partial(
                        downloadedBytes: 10,
                        expectedBytes: model.approximateBytes
                    )
            )
        }
    }

    private static func testInstallerFailureClearsPendingSelectionAndMirrorsIssue() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }
        dependencies.localAI.startInstall = installHarness.start

        let model = LocalAIModelCatalog.quality
        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .context
            )
            appState.installLocalAIModel(model, autoSelectFor: .context)
        }
        installHarness.complete(
            model: model,
            with: .failure(.downloadFailed("offline"))
        )
        await waitUntil {
            !appState.localAIInstallState(for: model).isInstalling
        }
        await MainActor.run {
            precondition(appState.pendingLocalAIModelID(for: .context) == nil)
            precondition(
                appState.localAIInstallState(for: model).issue?.code
                    == .localAIModelUnavailable
            )
        }
    }

    private static func testUnsupportedHardwareRejectsLocalSelection() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .ready)
        let installHarness = LocalAIInstallHarness()
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }
        dependencies.localAI.startInstall = installHarness.start
        dependencies.localAI.processingAvailability = unsupportedLocalAIAvailability

        let model = LocalAIModelCatalog.quality
        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            let originalChoice = appState.postProcessingBackendChoice
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .postProcessing
            )
            precondition(appState.postProcessingBackendChoice == originalChoice)
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == nil)
            precondition(
                !appState.isAIProcessingChoiceAvailable(
                    .localAI(modelID: model.id),
                    for: .postProcessing
                )
            )
            precondition(
                !appState.aiProcessingChoiceDisplays(for: .postProcessing)
                    .contains { $0.choice == .localAI(modelID: model.id) }
            )
            appState.postProcessingBackendChoice = .localAI(modelID: model.id)
            precondition(!appState.isAIProcessingBackendReady(for: .postProcessing))
        }
        precondition(installHarness.starts(for: model) == 0)
    }

    private static func testLowMemoryPreservesStoredLocalChoiceWithoutStartingIt() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .ready)
        let installHarness = LocalAIInstallHarness()
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }
        dependencies.localAI.startInstall = installHarness.start
        dependencies.localAI.processingAvailability = lowMemoryLocalAIAvailability

        let model = LocalAIModelCatalog.quality
        let storedChoice = AIProcessingBackendChoice.localAI(modelID: model.id)
        storeChoice(storedChoice, forKey: "post_processing_backend_choice")
        UserDefaults.standard.set(false, forKey: "disable_post_processing")
        let appState = await makeRefreshedAppState(dependencies: dependencies)

        await MainActor.run {
            precondition(appState.postProcessingBackendChoice == storedChoice)
            precondition(appState.disablePostProcessing)
            precondition(!appState.isAIProcessingChoiceAvailable(storedChoice, for: .postProcessing))
            precondition(!appState.isAIProcessingChoiceReady(storedChoice, for: .postProcessing))
            precondition(
                appState.aiProcessingChoiceDisplays(for: .postProcessing).contains {
                    $0.choice == storedChoice && !$0.isAvailable
                }
            )

            appState.selectAIProcessingBackendChoice(storedChoice, for: .postProcessing)
            appState.installLocalAIModel(model, autoSelectFor: .postProcessing)

            precondition(appState.postProcessingBackendChoice == storedChoice)
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == nil)
            precondition(!appState.localAIInstallState(for: model).isInstalling)
        }
        precondition(installHarness.starts(for: model) == 0)
    }

    private static func testAIProcessingChoiceDisplayMetadata() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }

        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            let displays = appState.aiProcessingChoiceDisplays(for: .postProcessing)
            let cloud = displays.first { display in
                if case .cloud = display.choice { return true }
                return false
            }
            precondition(cloud?.section == "Cloud")
            precondition(cloud?.isAvailable == true)
            precondition(cloud?.unavailableReason == nil)

            let quality = displays.first {
                $0.choice == .localAI(modelID: LocalAIModelCatalog.quality.id)
            }
            precondition(quality?.section == "On This Mac")
            precondition(quality?.title == LocalAIModelCatalog.quality.displayName)
            precondition(quality?.subtitle?.isEmpty == false)
            precondition(quality?.isAvailable == true)
            precondition(quality?.unavailableReason == nil)
            precondition(quality?.isRecommended == true)

            let contextDisplays = appState.aiProcessingChoiceDisplays(for: .context)
            precondition(
                !contextDisplays.contains {
                    $0.choice == .localAI(modelID: LocalAIModelCatalog.quality.id)
                }
            )
            let meetingSummaryDisplays = appState.aiProcessingChoiceDisplays(
                for: .meetingSummary
            )
            precondition(
                meetingSummaryDisplays.contains {
                    $0.choice == .localAI(modelID: LocalAIModelCatalog.quality.id)
                }
            )
            precondition(
                !appState.isAIProcessingChoiceAvailable(
                    .localAI(modelID: LocalAIModelCatalog.quality.id),
                    for: .context
                )
            )
            precondition(
                appState.isAIProcessingChoiceAvailable(
                    .localAI(modelID: LocalAIModelCatalog.quality.id),
                    for: .meetingSummary
                )
            )

            precondition(
                appState.isAIProcessingChoiceAvailable(
                    .localAI(modelID: LocalAIModelCatalog.quality.id),
                    for: .postProcessing
                )
            )
            precondition(
                appState.isAIProcessingChoiceAvailable(
                    .cloud(modelID: AppState.defaultPostProcessingModel),
                    for: .postProcessing
                )
            )
            precondition(
                !appState.isAIProcessingBackendReady(for: .postProcessing)
            )
            appState.apiKey = "test-key"
            precondition(
                appState.isAIProcessingChoiceAvailable(
                    .cloud(modelID: AppState.defaultPostProcessingModel),
                    for: .postProcessing
                )
            )
            precondition(
                appState.isAIProcessingBackendReady(for: .postProcessing)
            )
        }
    }

    private static func testManagedLocalAIModelResolutionReconcilesRetainedLifecycle() {
        let activeModel = LocalAIModelCatalog.quality
        let attemptedModel = activeModel
        let cloudChoice = AIProcessingBackendChoice.cloud(
            modelID: AppState.defaultPostProcessingModel
        )

        func resolve(
            pendingModelID: String? = nil,
            retainedModelID: String? = nil,
            currentChoice: AIProcessingBackendChoice = cloudChoice,
            isInstalling: Bool = false,
            isCancelled: Bool = false,
            hasIssue: Bool = false
        ) -> LocalAIManagedModelResolver.Resolution {
            LocalAIManagedModelResolver.resolve(
                LocalAIManagedModelResolver.Input(
                    pendingModelID: pendingModelID,
                    retainedModelID: retainedModelID,
                    currentChoice: currentChoice,
                    retainedIsInstalling: isInstalling,
                    retainedProgressIsCancelled: isCancelled,
                    retainedHasIssue: hasIssue
                )
            )
        }

        let pendingWins = resolve(
            pendingModelID: attemptedModel.id,
            retainedModelID: attemptedModel.id,
            currentChoice: .localAI(modelID: activeModel.id)
        )
        precondition(pendingWins.model?.id == attemptedModel.id)
        precondition(
            pendingWins.reconciledRetainedModelID == attemptedModel.id
        )

        let failedRetainedWins = resolve(
            retainedModelID: attemptedModel.id,
            currentChoice: .localAI(modelID: activeModel.id),
            hasIssue: true
        )
        precondition(failedRetainedWins.model?.id == attemptedModel.id)
        precondition(
            failedRetainedWins.reconciledRetainedModelID == attemptedModel.id
        )

        let installingRetainedStaysVisible = resolve(
            retainedModelID: attemptedModel.id,
            isInstalling: true
        )
        precondition(
            installingRetainedStaysVisible.model?.id == attemptedModel.id
        )
        precondition(
            installingRetainedStaysVisible.reconciledRetainedModelID
                == attemptedModel.id
        )

        let cancelledRetainedStaysVisible = resolve(
            retainedModelID: attemptedModel.id,
            isCancelled: true
        )
        precondition(
            cancelledRetainedStaysVisible.model?.id == attemptedModel.id
        )
        precondition(
            cancelledRetainedStaysVisible.reconciledRetainedModelID
                == attemptedModel.id
        )

        let cleanRetainedClearsForCloud = resolve(
            retainedModelID: attemptedModel.id
        )
        precondition(cleanRetainedClearsForCloud.model == nil)
        precondition(
            cleanRetainedClearsForCloud.reconciledRetainedModelID == nil
        )

        let activeLocalReplacesUnknownRetained = resolve(
            retainedModelID: "unknown-local-model",
            currentChoice: .localAI(modelID: activeModel.id)
        )
        precondition(activeLocalReplacesUnknownRetained.model?.id == activeModel.id)
        precondition(
            activeLocalReplacesUnknownRetained.reconciledRetainedModelID == nil
        )

        let selectedRetainedStaysManaged = resolve(
            retainedModelID: activeModel.id,
            currentChoice: .localAI(modelID: activeModel.id)
        )
        precondition(selectedRetainedStaysManaged.model?.id == activeModel.id)
        precondition(
            selectedRetainedStaysManaged.reconciledRetainedModelID
                == activeModel.id
        )

        let activeLocalFallback = resolve(
            currentChoice: .localAI(modelID: activeModel.id)
        )
        precondition(activeLocalFallback.model?.id == activeModel.id)
        precondition(activeLocalFallback.reconciledRetainedModelID == nil)

        let unknownRetainedClears = resolve(
            retainedModelID: "unknown-local-model"
        )
        precondition(unknownRetainedClears.model == nil)
        precondition(unknownRetainedClears.reconciledRetainedModelID == nil)
    }

    private static func testCloudSelectionPublishesContextChoiceOnce() async {
        resetAIProcessingDefaults()
        let appState = await makeRefreshedAppState()
        await MainActor.run {
            appState.contextBackendChoice = .cloud(modelID: "custom/context")
            var publications = 0
            let cancellable = appState.$contextBackendChoice
                .dropFirst()
                .sink { _ in publications += 1 }

            appState.selectAIProcessingBackendChoice(
                .cloud(modelID: "qwen/qwen3.6-27b"),
                for: .context
            )

            precondition(publications == 1)
            withExtendedLifetime(cancellable) {}
        }
    }

    private static func testSelectionWaitsForInitialStatusRefresh() async {
        resetAIProcessingDefaults()
        let statusHarness = ControlledLocalAIStatusHarness(
            blockedModelID: LocalAIModelCatalog.quality.id,
            blockedResult: .ready,
            subsequentResult: .ready
        )
        let installHarness = LocalAIInstallHarness()
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }
        dependencies.localAI.startInstall = installHarness.start
        defer {
            statusHarness.releaseBlockedCall()
        }

        let dependenciesSnapshot = dependencies
        let appState = await MainActor.run {
            AppState(dependencies: dependenciesSnapshot)
        }
        statusHarness.waitUntilBlockedCallEntered()
        await MainActor.run {
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: LocalAIModelCatalog.quality.id),
                for: .postProcessing
            )
            precondition(
                appState.pendingLocalAIModelID(for: .postProcessing)
                    == LocalAIModelCatalog.quality.id
            )
        }
        precondition(installHarness.starts(for: LocalAIModelCatalog.quality) == 0)

        statusHarness.releaseBlockedCall()
        await appState.waitForLocalAIInstallStateRefresh()
        await MainActor.run {
            precondition(
                appState.postProcessingBackendChoice
                    == .localAI(modelID: LocalAIModelCatalog.quality.id)
            )
        }
        precondition(installHarness.starts(for: LocalAIModelCatalog.quality) == 0)
        precondition(statusHarness.mainThreadCallCount == 0)
    }

    private static func testAppStateInstancesKeepIndependentLocalAIEnvironments() async {
        resetAIProcessingDefaults()
        let firstStatus = LocalAIStatusHarness(defaultStatus: .ready)
        let secondStatus = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let firstManager = LocalAIServerManager()
        let secondManager = LocalAIServerManager()
        var firstDependencies = modelTestDependencies()
        firstDependencies.localAI.installStatus = { firstStatus.status(for: $0) }
        firstDependencies.localAI.processingAvailability = supportedLocalAIAvailability
        firstDependencies.localAI.makeServerManager = { firstManager }
        var secondDependencies = modelTestDependencies()
        secondDependencies.localAI.installStatus = { secondStatus.status(for: $0) }
        secondDependencies.localAI.processingAvailability = unsupportedLocalAIAvailability
        secondDependencies.localAI.makeServerManager = { secondManager }
        let firstDependenciesSnapshot = firstDependencies
        let secondDependenciesSnapshot = secondDependencies

        let instances = await MainActor.run {
            (
                AppState(dependencies: firstDependenciesSnapshot),
                AppState(dependencies: secondDependenciesSnapshot)
            )
        }
        await instances.0.waitForLocalAIInstallStateRefresh()
        await instances.1.waitForLocalAIInstallStateRefresh()

        await MainActor.run {
            precondition(
                instances.0.localAIInstallState(for: LocalAIModelCatalog.quality).status
                    == .ready
            )
            precondition(
                instances.1.localAIInstallState(for: LocalAIModelCatalog.quality).status
                    == .notInstalled
            )
            precondition(instances.0.isLocalAIModelAvailable(LocalAIModelCatalog.quality))
            precondition(!instances.1.isLocalAIModelAvailable(LocalAIModelCatalog.quality))
            precondition(instances.0.localAIServerManager === firstManager)
            precondition(instances.1.localAIServerManager === secondManager)
        }
    }

    private static func testExecutorUsesOriginatingLocalAIAvailability() async {
        resetAIProcessingDefaults()
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { _ in .ready }
        dependencies.localAI.processingAvailability = unsupportedLocalAIAvailability
        let dependenciesSnapshot = dependencies
        let appState = await MainActor.run {
            AppState(dependencies: dependenciesSnapshot)
        }
        await appState.waitForLocalAIInstallStateRefresh()

        await MainActor.run {
            let executor = appState.makeAIProcessingBackendExecutor(
                choice: .localAI(modelID: LocalAIModelCatalog.quality.id)
            )
            precondition(!executor.isConfigured)
        }
    }

    private static func testDeleteDuringInstallWaitsAndCannotAutoSelect() async throws {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let partialDeletionHarness = LocalAIDeletionHarness()
        let deletionHarness = LocalAIDeletionHarness()
        var dependencies = modelTestDependencies()
        let manager = LocalAIServerManager(
            launchProcess: { _, _, port, _ in (TestLocalAIServerProcess(), port) },
            pollHealth: { _ in true },
            readinessProbe: successfulReadinessProbe,
            validateModel: { _ in .ready }
        )
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }
        dependencies.localAI.startInstall = installHarness.start
        dependencies.localAI.deletePartialModel = { model in
            partialDeletionHarness.record(modelID: model.id, managerWasStopped: false)
        }
        dependencies.localAI.deleteModel = { model in
            deletionHarness.record(modelID: model.id, managerWasStopped: true)
            statusHarness.set(.notInstalled, for: model)
        }
        dependencies.localAI.makeServerManager = { manager }

        let model = LocalAIModelCatalog.quality
        let appState = await makeRefreshedAppState(dependencies: dependencies)
        let originalChoices = await MainActor.run { () -> (AIProcessingBackendChoice, AIProcessingBackendChoice) in
            let choices = (
                appState.postProcessingBackendChoice,
                appState.contextBackendChoice
            )
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .postProcessing
            )
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .context
            )
            appState.installLocalAIModel(model, autoSelectFor: .postProcessing)
            appState.deleteLocalAIModel(model)
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == nil)
            precondition(appState.pendingLocalAIModelID(for: .context) == nil)
            precondition(appState.localAIInstallState(for: model).isInstalling)
            precondition(appState.localAIInstallState(for: model).progress.isCancelled)
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .postProcessing
            )
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == nil)
            return choices
        }
        precondition(installHarness.task(for: model, startIndex: 0)?.isCancelled == true)
        precondition(deletionHarness.callCount == 0)
        precondition(installHarness.starts(for: model) == 1)

        statusHarness.set(.ready, for: model)
        installHarness.complete(model: model, with: .success(()))
        await waitUntil { deletionHarness.callCount == 1 }
        await waitUntil {
            !appState.localAIInstallState(for: model).isInstalling
                && appState.localAIInstallState(for: model).status == .notInstalled
        }
        await MainActor.run {
            let state = appState.localAIInstallState(for: model)
            precondition(state.progress.downloadedBytes == 0)
            precondition(state.progress.totalBytes == model.approximateBytes)
            precondition(!state.progress.isCancelled)
            precondition(state.issue == nil)
            precondition(appState.postProcessingBackendChoice == originalChoices.0)
            precondition(appState.contextBackendChoice == originalChoices.1)
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == nil)
            precondition(appState.pendingLocalAIModelID(for: .context) == nil)
        }
        precondition(partialDeletionHarness.deletedModelIDs.isEmpty)
        precondition(installHarness.starts(for: model) == 1)
    }

    private static func testDeleteFailurePreservesSelectedLocalChoice() async throws {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .ready)
        var dependencies = modelTestDependencies()
        let manager = LocalAIServerManager(
            launchProcess: { _, _, port, _ in (TestLocalAIServerProcess(), port) },
            pollHealth: { _ in true },
            readinessProbe: successfulReadinessProbe,
            validateModel: { _ in .ready }
        )
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }
        dependencies.localAI.deleteModel = { _ in
            throw TestLocalAILifecycleError.fullDeleteFailed
        }
        dependencies.localAI.makeServerManager = { manager }

        let model = LocalAIModelCatalog.quality
        let appState = await makeRefreshedAppState(dependencies: dependencies)
        await MainActor.run {
            appState.postProcessingBackendChoice = .localAI(modelID: model.id)
            appState.deleteLocalAIModel(model)
        }
        await waitUntil {
            appState.localAIInstallState(for: model).issue?.code
                == .localAIModelUnavailable
        }
        await MainActor.run {
            precondition(
                appState.postProcessingBackendChoice
                    == .localAI(modelID: model.id)
            )
        }
    }

    private static func testDeletingOnlyLocalModelDoesNotSubstituteCloud() async throws {
        try await verifyDeletingOnlyLocalModelDisablesRetainedChoices(
            apiKey: "configured-cloud-key"
        )
    }

    private static func verifyDeletingOnlyLocalModelDisablesRetainedChoices(
        apiKey: String
    ) async throws {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(
            statuses: [LocalAIModelCatalog.quality.id: .ready],
            defaultStatus: .notInstalled
        )
        let deletionHarness = LocalAIDeletionHarness()
        var dependencies = modelTestDependencies()
        dependencies.localAI.installStatus = { statusHarness.status(for: $0) }
        dependencies.localAI.deleteModel = { model in
            deletionHarness.record(modelID: model.id, managerWasStopped: true)
            statusHarness.set(.notInstalled, for: model)
        }

        let appState = await makeRefreshedAppState(dependencies: dependencies)
        let retainedChoice = AIProcessingBackendChoice.localAI(
            modelID: LocalAIModelCatalog.quality.id
        )
        await MainActor.run {
            appState.postProcessingBackendChoice = retainedChoice
            appState.meetingSummaryBackendChoice = retainedChoice
            appState.disablePostProcessing = false
            appState.disableMeetingSummary = false
            appState.apiKey = apiKey
            appState.deleteLocalAIModel(LocalAIModelCatalog.quality)
        }
        await waitUntil { deletionHarness.callCount == 1 }
        await waitUntil {
            appState.postProcessingBackendChoice == retainedChoice
                && appState.meetingSummaryBackendChoice == retainedChoice
                && appState.disablePostProcessing
                && appState.disableMeetingSummary
        }

        await MainActor.run {
            precondition(
                appState.localAIInstallState(for: LocalAIModelCatalog.quality).status
                    == .notInstalled
            )
            precondition(appState.postProcessingBackendChoice == retainedChoice)
            precondition(appState.meetingSummaryBackendChoice == retainedChoice)
            precondition(appState.disablePostProcessing)
            precondition(appState.disableMeetingSummary)
        }
        precondition(
            storedChoice(forKey: "post_processing_backend_choice") == retainedChoice
        )
        precondition(
            storedChoice(forKey: "meeting_summary_backend_choice") == retainedChoice
        )
        precondition(deletionHarness.deletedModelIDs == [LocalAIModelCatalog.quality.id])
    }

    private static func testResetDoesNotCreateCredentialDirectory() {
        resetCredentialStore()
        resetAIProcessingDefaults()
        precondition(
            !FileManager.default.fileExists(
                atPath: credentialStorageLayout.directory.path
            )
        )
    }

    private static func testDefaultModelAppStateUsesExplicitCredentialLayout() async throws {
        resetCredentialStore()
        defer { resetCredentialStore() }
        try credentialStore.save(
            "suite-key",
            account: "groq_api_key"
        )

        let appState = await makeRefreshedAppState()

        await MainActor.run {
            precondition(appState.apiKey == "suite-key")
        }
    }

    private static func modelTestDependencies() -> AppStateDependencies {
        var dependencies = AppStateDependencies.live
        dependencies.credentialStorageLayout = credentialStorageLayout
        dependencies.localAI.installStatus = { _ in .notInstalled }
        dependencies.localAI.processingAvailability = supportedLocalAIAvailability
        dependencies.nativeWhisper.installStatus = { _ in .notInstalled }
        return dependencies
    }

    private static func makeRefreshedAppState() async -> AppState {
        await makeRefreshedAppState(dependencies: modelTestDependencies())
    }

    private static func makeRefreshedAppState(
        dependencies: AppStateDependencies
    ) async -> AppState {
        let appState = await MainActor.run {
            AppState(dependencies: dependencies)
        }
        await appState.waitForLocalAIInstallStateRefresh()
        return appState
    }

    @MainActor
    private static func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("Timed out waiting for AppState Local AI state")
    }

    @MainActor
    private static func yieldMainActor() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    private static var supportedLocalAIAvailability: () -> LocalAIProcessingAvailability {
        {
            LocalAIProcessingAvailability(
                isAppleSilicon: true,
                runnerIsExecutable: true,
                physicalMemory: 16 * 1024 * 1024 * 1024
            )
        }
    }

    private static var unsupportedLocalAIAvailability: () -> LocalAIProcessingAvailability {
        {
            LocalAIProcessingAvailability(
                isAppleSilicon: false,
                runnerIsExecutable: false
            )
        }
    }

    private static var lowMemoryLocalAIAvailability: () -> LocalAIProcessingAvailability {
        {
            LocalAIProcessingAvailability(
                isAppleSilicon: true,
                runnerIsExecutable: true,
                physicalMemory: 8 * 1024 * 1024 * 1024
            )
        }
    }

    private static func testEveryBackendExecutorConstructionUsesCentralFactory() throws {
        let source = try appStateSource()
        let factoryBody = sourceBlock(
            in: source,
            from: "static func makeAIProcessingBackendExecutor(",
            to: "func makeAIProcessingBackendExecutor("
        )
        assert(backendExecutorConstructorCount(in: factoryBody) == 1)
        assert(
            backendExecutorConstructorCount(
                in: source.replacingOccurrences(of: factoryBody, with: "")
            ) == 0
        )
    }

    private static func testEveryPostProcessingConstructionUsesCentralFactory() throws {
        let source = try appStateSource()
        let factoryBody = sourceBlock(
            in: source,
            from: "static func makePostProcessingService(",
            to: "func makePostProcessingService("
        )
        assert(constructorCount(in: factoryBody) == 1)
        assert(constructorCount(in: source.replacingOccurrences(of: factoryBody, with: "")) == 0)
    }

    private static func testCloudResumeCapturesPostProcessingServiceBeforeTaskStarts() throws {
        let source = try appStateSource()
        let scheduling = sourceBlock(
            in: source,
            from: "if let cloudReconciliation {",
            to: "speechRecognitionAuthorizationStatus ="
        )
        let serviceSnapshot = requiredRange(
            of: "let postProcessingService = makePostProcessingService()",
            in: scheduling
        )
        let schedulingTask = requiredRange(
            of: "Task { @MainActor",
            in: scheduling
        )
        assert(serviceSnapshot.lowerBound < schedulingTask.lowerBound)

        let body = sourceBlock(
            in: source,
            from: "private func scheduleCloudTranscriptionAutoResume(",
            to: "private func installCloudTranscriptionTask("
        )
        assert(body.contains("postProcessingService: PostProcessingService"))
        assert(body.contains("makeProcessingBehavior:"))
        assert(!body.contains("makePostProcessingService()"))
        assert(body.contains("postProcessingService: postProcessingService"))
    }

    private static func testContextCaptureUsesServiceSnapshotAndKeepsCancellationGuards() throws {
        let body = sourceBlock(
            in: try appStateSource(),
            from: "private func startContextCapture()",
            to: "private func fallbackContextAtStop()"
        )
        let compatibilityGuard = requiredRange(
            of: "guard isAIProcessingChoiceCompatible(contextBackendChoice, for: .context) else",
            in: body
        )
        let snapshot = requiredRange(of: "let contextService = contextService", in: body)
        let task = requiredRange(of: "contextCaptureTask = Task", in: body)
        assert(compatibilityGuard.lowerBound < snapshot.lowerBound)
        assert(snapshot.lowerBound < task.lowerBound)
        let taskBody = String(body[task.lowerBound...])
        assert(taskBody.contains("let context = await contextService.collectContext()"))
        assert(!taskBody.contains("self.contextService.collectContext()"))
        assert(taskBody.contains("guard !Task.isCancelled else { return nil }"))
        assert(taskBody.contains("guard !Task.isCancelled else { return }"))
    }

    private static func testContextModelObserverRebuildsOnlyThroughChoiceChanges() throws {
        let source = try appStateSource()
        let modelObserver = sourceBlock(
            in: source,
            from: "@Published var contextModel: String",
            to: "@Published var holdShortcut: ShortcutBinding"
        )
        assert(!modelObserver.contains("rebuildContextService()"))
        assert(modelObserver.contains("derivedChoice != contextBackendChoice"))

        let choiceObserver = sourceBlock(
            in: source,
            from: "@Published var contextBackendChoice: AIProcessingBackendChoice",
            to: "private var contextService: AppContextService"
        )
        assert(choiceObserver.components(separatedBy: "rebuildContextService()").count - 1 == 1)
    }

    private static func testAppDelegateStartsIdleMonitoring() throws {
        let source = try String(
            contentsOfFile: "Sources/AppDelegate.swift",
            encoding: .utf8
        )
        let launch = sourceBlock(
            in: source,
            from: "func applicationDidFinishLaunching",
            to: "func applicationShouldTerminate"
        )
        let monitor = requiredRange(
            of: "appState.startLocalAIIdleShutdownMonitoring()",
            in: launch
        )
        let setupConditional = requiredRange(
            of: "if !appState.hasCompletedSetup",
            in: launch
        )
        assert(
            launch.components(
                separatedBy: "appState.startLocalAIIdleShutdownMonitoring()"
            ).count - 1 == 1
        )
        assert(monitor.lowerBound < setupConditional.lowerBound)
    }

    private static func testTerminationRoutesThroughUnifiedModelCleanup() throws {
        let delegate = try String(
            contentsOfFile: "Sources/AppDelegate.swift",
            encoding: .utf8
        )
        let state = try appStateSource()
        let terminationCleanup = sourceBlock(
            in: state,
            from: "func requestTerminationAfterModelCleanup(",
            to: "private var shouldConfirmEscapeCancellation"
        )
        let localCancellation = sourceBlock(
            in: state,
            from: "private func cancelAllLocalAIInstalls()",
            to: "func requestTerminationAfterModelCleanup("
        )

        assert(delegate.contains("requestTerminationAfterModelCleanup()"))
        assert(!delegate.contains("requestTerminationWhileNativeWhisperInstalling()"))
        assert(
            terminationCleanup.contains(
                "guard !isModelTerminationCleanupPending else { return .terminateLater }"
            )
        )
        assert(terminationCleanup.contains("cancelAllLocalAIInstalls()"))
        assert(terminationCleanup.contains("nativeWhisperWorkflow.beginTerminationCleanup()"))
        assert(terminationCleanup.contains("localAIWorkflow.beginTerminationCleanup()"))
        assert(terminationCleanup.contains("waitForNativeWhisperInstallToQuiesce()"))
        assert(terminationCleanup.contains("waitForLocalAIInstallsToQuiesce()"))
        assert(terminationCleanup.contains("await manager.stop()"))
        assert(localCancellation.contains("pendingLocalAISelections.removeAll()"))
        assert(state.contains("isInstallingNativeWhisper || localAIWorkflow.hasActiveInstalls"))
        assert(
            state.contains(
                "requestTerminationAfterModelCleanup(replyIsAlreadyPending: true)"
            )
        )
        let nativeCancellation = sourceBlock(
            in: state,
            from: "func cancelNativeWhisperInstall()",
            to: "func deleteNativeWhisperModel()"
        )
        assert(nativeCancellation.contains("nativeWhisperWorkflow.cancelInstall()"))

        let cancelNative = requiredRange(
            of: "cancelNativeWhisperInstallIfNeeded()",
            in: terminationCleanup
        )
        let cancelLocal = requiredRange(
            of: "cancelAllLocalAIInstalls()",
            in: terminationCleanup
        )
        let stopIdleMonitoring = requiredRange(
            of: "stopLocalAIIdleShutdownMonitoring()",
            in: terminationCleanup
        )
        let appStateTerminationFlag = requiredRange(
            of: "isModelTerminationCleanupPending = true",
            in: terminationCleanup
        )
        let nativeWorkflowTerminationFlag = requiredRange(
            of: "nativeWhisperWorkflow.beginTerminationCleanup()",
            in: terminationCleanup
        )
        let localWorkflowTerminationFlag = requiredRange(
            of: "localAIWorkflow.beginTerminationCleanup()",
            in: terminationCleanup
        )
        let waitForNativeQuiescence = requiredRange(
            of: "await self.waitForNativeWhisperInstallToQuiesce()",
            in: terminationCleanup
        )
        let waitForLocalQuiescence = requiredRange(
            of: "await self.waitForLocalAIInstallsToQuiesce()",
            in: terminationCleanup
        )
        let stopServer = requiredRange(of: "await manager.stop()", in: terminationCleanup)
        let terminationReply = requiredRange(
            of: "Self.applicationTerminationReply(true)",
            in: terminationCleanup
        )
        assert(cancelNative.lowerBound < cancelLocal.lowerBound)
        assert(cancelLocal.lowerBound < stopIdleMonitoring.lowerBound)
        assert(stopIdleMonitoring.lowerBound < appStateTerminationFlag.lowerBound)
        assert(appStateTerminationFlag.lowerBound < nativeWorkflowTerminationFlag.lowerBound)
        assert(nativeWorkflowTerminationFlag.lowerBound < localWorkflowTerminationFlag.lowerBound)
        assert(localWorkflowTerminationFlag.lowerBound < waitForNativeQuiescence.lowerBound)
        assert(waitForNativeQuiescence.lowerBound < waitForLocalQuiescence.lowerBound)
        assert(waitForLocalQuiescence.lowerBound < stopServer.lowerBound)
        assert(stopServer.lowerBound < terminationReply.lowerBound)
    }

    // Dismissing a warning banner hides it for the note's current retry
    // generation only; a later retry bumps the generation and invalidates
    // the dismissal so the banner can reappear if the condition still holds.
    private static func testWarningBannerDismissalIsScopedToNoteAndResetsOnRetryGeneration() async {
        let appState = await makeRefreshedAppState()
        let noteID = UUID()
        let otherNoteID = UUID()
        let code = QuillUserIssueCode.contextUnavailable

        await MainActor.run {
            assert(!appState.isWarningBannerDismissed(noteID: noteID, code: code))

            appState.dismissWarningBanner(noteID: noteID, code: code)
            assert(appState.isWarningBannerDismissed(noteID: noteID, code: code))

            // Dismissal is scoped to this exact note + issue code.
            assert(!appState.isWarningBannerDismissed(noteID: otherNoteID, code: code))
            assert(!appState.isWarningBannerDismissed(noteID: noteID, code: .postProcessingFailed))

            appState.incrementNoteRetryGeneration(for: noteID)
            assert(!appState.isWarningBannerDismissed(noteID: noteID, code: code))

            // Dismissing again at the new generation hides it again.
            appState.dismissWarningBanner(noteID: noteID, code: code)
            assert(appState.isWarningBannerDismissed(noteID: noteID, code: code))
        }
    }

    // The dismissal side-store dictionaries would otherwise grow unbounded as
    // notes are deleted, so the delete/clear paths must forget that state.
    private static func testDeletingNotesForgetsWarningBannerState() throws {
        let source = try appStateSource()

        let deleteBody = sourceBlock(
            in: source,
            from: "func deleteHistoryEntry(id: UUID) {",
            to: "func updateHistoryItemTitle("
        )
        assert(deleteBody.contains("forgetWarningBannerState(for: id)"))

        let clearBody = sourceBlock(
            in: source,
            from: "func clearPipelineHistory() {",
            to: "func deleteHistoryEntry("
        )
        assert(clearBody.contains("forgetAllWarningBannerState()"))

        let forgetOne = sourceBlock(
            in: source,
            from: "private func forgetWarningBannerState(for noteID: UUID) {",
            to: "private func forgetAllWarningBannerState() {"
        )
        assert(forgetOne.contains("noteRetryGenerationByID.removeValue(forKey: noteID.uuidString)"))
        assert(forgetOne.contains("dismissedWarningBannerGeneration = dismissedWarningBannerGeneration.filter"))
        assert(forgetOne.contains("Self.saveIntDictionary(noteRetryGenerationByID"))
        assert(forgetOne.contains("Self.noteRetryGenerationDefaultsKey"))
        assert(forgetOne.contains("Self.dismissedWarningBannerGenerationDefaultsKey"))
    }

    private static func appStateSource() throws -> String {
        try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
    }

    private static func backendExecutorConstructorCount(in source: String) -> Int {
        constructorCount(named: "AIProcessingBackendExecutor", in: source)
    }

    private static func constructorCount(in source: String) -> Int {
        constructorCount(named: "PostProcessingService", in: source)
    }

    private static func constructorCount(named typeName: String, in source: String) -> Int {
        let escapedTypeName = NSRegularExpression.escapedPattern(for: typeName)
        let pattern = "(?<![A-Za-z0-9_])\(escapedTypeName)\\("
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.numberOfMatches(in: source, range: range)
    }

    private static func sourceBlock(
        in source: String,
        from startMarker: String,
        to endMarker: String
    ) -> String {
        guard let start = source.range(of: startMarker),
              let end = source.range(
                  of: endMarker,
                  range: start.upperBound..<source.endIndex
              ) else {
            preconditionFailure("Expected source block from \(startMarker) to \(endMarker)")
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private static func requiredRange(
        of text: String,
        in source: String
    ) -> Range<String.Index> {
        guard let range = source.range(of: text) else {
            preconditionFailure("Expected source to contain \(text)")
        }
        return range
    }

    private static func storeChoice(
        _ choice: AIProcessingBackendChoice,
        forKey key: String
    ) {
        AIProcessingBackendChoiceStore.save(
            choice,
            defaults: .standard,
            key: key
        )
    }

    private static func storedChoice(forKey key: String) -> AIProcessingBackendChoice? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AIProcessingBackendChoice.self, from: data)
    }

    private static func resetAIProcessingDefaults() {
        resetCredentialStore()
        for key in [
            "post_processing_model",
            "context_model",
            "post_processing_backend_choice",
            "context_backend_choice",
            "meeting_summary_model",
            "meeting_summary_fallback_model",
            "meeting_summary_backend_choice",
            "disable_post_processing",
            "disable_context_capture",
            "disable_meeting_summary",
            "meeting_summary_output_language",
            "meeting_summary_settings_initialized"
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

private struct ModelTerminationEffectSnapshot {
    let modelDownloadQuitAlertPresenter = AppState.modelDownloadQuitAlertPresenter
    let applicationTerminationReply = AppState.applicationTerminationReply

    func restore() {
        AppState.modelDownloadQuitAlertPresenter = modelDownloadQuitAlertPresenter
        AppState.applicationTerminationReply = applicationTerminationReply
    }
}

private final class NativeWhisperStatusHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStatus: NativeWhisperInstallStatus
    private var calls = 0

    init(status: NativeWhisperInstallStatus) {
        storedStatus = status
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func installStatus(for model: NativeWhisperModel) -> NativeWhisperInstallStatus {
        lock.withLock {
            calls += 1
            return storedStatus
        }
    }

    func set(_ status: NativeWhisperInstallStatus) {
        lock.withLock { storedStatus = status }
    }
}

private final class ControlledNativeWhisperInstallHarness: @unchecked Sendable {
    typealias Progress = (NativeWhisperDownloadProgress) -> Void
    typealias Completion = (Result<Void, NativeWhisperInstallerError>) -> Void

    private struct StartRecord {
        let progress: Progress
        let completion: Completion
        let task: NativeWhisperInstallTask
    }

    private let lock = NSLock()
    private var records: [StartRecord] = []

    var startCount: Int {
        lock.withLock { records.count }
    }

    var task: NativeWhisperInstallTask? {
        lock.withLock { records.last?.task }
    }

    func start(
        model: NativeWhisperModel,
        progress: @escaping Progress,
        completion: @escaping Completion
    ) -> NativeWhisperInstallTask {
        let task = NativeWhisperInstallTask()
        lock.withLock {
            records.append(
                StartRecord(
                    progress: progress,
                    completion: completion,
                    task: task
                )
            )
        }
        return task
    }

    func sendProgress(
        _ progress: NativeWhisperDownloadProgress,
        startIndex: Int = 0
    ) {
        let callback = lock.withLock {
            records[safe: startIndex]?.progress
        }
        callback?(progress)
    }

    func complete(
        startIndex: Int = 0,
        with result: Result<Void, NativeWhisperInstallerError>
    ) {
        let completion = lock.withLock {
            records[safe: startIndex]?.completion
        }
        completion?(result)
    }
}

private final class ProgressScheduleHarness: @unchecked Sendable {
    typealias Operation = @Sendable () -> Void

    private let lock = NSLock()
    private var scheduled: [(delay: TimeInterval, operation: Operation)] = []

    var schedule: LatestValueProgressCoalescer<Int>.Schedule {
        { [weak self] delay, operation in
            guard let self else { return }
            self.lock.withLock {
                self.scheduled.append((delay, operation))
            }
        }
    }

    var scheduledCount: Int {
        lock.withLock { scheduled.count }
    }

    func runNext() {
        let operation = lock.withLock {
            scheduled.isEmpty ? nil : scheduled.removeFirst().operation
        }
        operation?()
    }

    func runAll() {
        while scheduledCount > 0 {
            runNext()
        }
    }
}

private final class LocalAIStatusHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [String: LocalAIInstallStatus]
    private let defaultStatus: LocalAIInstallStatus

    init(
        statuses: [String: LocalAIInstallStatus] = [:],
        defaultStatus: LocalAIInstallStatus
    ) {
        self.statuses = statuses
        self.defaultStatus = defaultStatus
    }

    func status(for model: LocalAIModel) -> LocalAIInstallStatus {
        lock.withLock { statuses[model.id] ?? defaultStatus }
    }

    func set(_ status: LocalAIInstallStatus, for model: LocalAIModel) {
        lock.withLock { statuses[model.id] = status }
    }
}

private final class ControlledLocalAIStatusHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let blockedModelID: String
    private let blockedResult: LocalAIInstallStatus
    private let subsequentResult: LocalAIInstallStatus
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var claimedBlockedCall = false
    private var releasedBlockedCall = false
    private var calls = 0
    private var mainThreadCalls = 0

    init(
        blockedModelID: String,
        blockedResult: LocalAIInstallStatus,
        subsequentResult: LocalAIInstallStatus
    ) {
        self.blockedModelID = blockedModelID
        self.blockedResult = blockedResult
        self.subsequentResult = subsequentResult
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    var mainThreadCallCount: Int {
        lock.withLock { mainThreadCalls }
    }

    func status(for model: LocalAIModel) -> LocalAIInstallStatus {
        let shouldBlock = lock.withLock { () -> Bool in
            calls += 1
            if Thread.isMainThread {
                mainThreadCalls += 1
            }
            guard model.id == blockedModelID, !claimedBlockedCall else {
                return false
            }
            claimedBlockedCall = true
            return true
        }
        guard shouldBlock else { return subsequentResult }
        entered.signal()
        release.wait()
        return blockedResult
    }

    func waitUntilBlockedCallEntered() {
        precondition(
            entered.wait(timeout: .now() + 5) == .success,
            "status refresh did not enter the blocked provider"
        )
    }

    func releaseBlockedCall() {
        let shouldSignal = lock.withLock { () -> Bool in
            guard !releasedBlockedCall else { return false }
            releasedBlockedCall = true
            return true
        }
        if shouldSignal { release.signal() }
    }
}

private final class LocalAIInstallHarness: @unchecked Sendable {
    typealias ProgressCallback = (LocalAIDownloadProgress) -> Void
    typealias CompletionCallback = (Result<Void, LocalAIInstallerError>) -> Void

    private struct StartRecord {
        let progress: ProgressCallback
        let completion: CompletionCallback
        let task: LocalAIInstallTask
    }

    private let lock = NSLock()
    private var startsByModelID: [String: [StartRecord]] = [:]

    func start(
        model: LocalAIModel,
        progress: @escaping ProgressCallback,
        completion: @escaping CompletionCallback
    ) -> LocalAIInstallTask {
        let task = LocalAIInstallTask()
        lock.withLock {
            startsByModelID[model.id, default: []].append(
                StartRecord(
                    progress: progress,
                    completion: completion,
                    task: task
                )
            )
        }
        return task
    }

    func starts(for model: LocalAIModel) -> Int {
        lock.withLock { startsByModelID[model.id]?.count ?? 0 }
    }

    func task(
        for model: LocalAIModel,
        startIndex: Int
    ) -> LocalAIInstallTask? {
        lock.withLock {
            guard let records = startsByModelID[model.id],
                  records.indices.contains(startIndex) else {
                return nil
            }
            return records[startIndex].task
        }
    }

    func sendProgress(
        model: LocalAIModel,
        startIndex: Int = 0,
        progress: LocalAIDownloadProgress
    ) {
        let callback = lock.withLock {
            startsByModelID[model.id]?[safe: startIndex]?.progress
        }
        callback?(progress)
    }

    func complete(
        model: LocalAIModel,
        startIndex: Int = 0,
        with result: Result<Void, LocalAIInstallerError>
    ) {
        let callback = lock.withLock {
            startsByModelID[model.id]?[safe: startIndex]?.completion
        }
        callback?(result)
    }
}

private final class LocalAIDeletionHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var modelIDs: [String] = []
    private var stoppedValues: [Bool] = []

    var callCount: Int {
        lock.withLock { modelIDs.count }
    }

    var deletedModelIDs: [String] {
        lock.withLock { modelIDs }
    }

    var managerWasStoppedValues: [Bool] {
        lock.withLock { stoppedValues }
    }

    func record(modelID: String, managerWasStopped: Bool) {
        lock.withLock {
            modelIDs.append(modelID)
            stoppedValues.append(managerWasStopped)
        }
    }
}

private final class ControlledAsyncSleepHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]

    var callCount: Int {
        lock.withLock { calls }
    }

    var pendingCount: Int {
        lock.withLock { continuations.count }
    }

    func sleep(nanoseconds: UInt64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldCancel = lock.withLock { () -> Bool in
                    calls += 1
                    guard !Task.isCancelled else { return true }
                    continuations[id] = continuation
                    return false
                }
                if shouldCancel {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation = self.lock.withLock {
                self.continuations.removeValue(forKey: id)
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func resumeNext() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard let id = continuations.keys.first else { return nil }
            return continuations.removeValue(forKey: id)
        }
        continuation?.resume()
    }
}

private final class TerminationReplyHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Bool] = []

    var values: [Bool] {
        lock.withLock { replies }
    }

    func reply(_ shouldTerminate: Bool) {
        lock.withLock { replies.append(shouldTerminate) }
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        lock.withLock { storedValue }
    }

    func set(_ value: Value) {
        lock.withLock { storedValue = value }
    }
}

private final class TestLocalAIServerProcess: LocalAIServerProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var terminationHandler: (() -> Void)?

    var isRunning: Bool {
        lock.withLock { running }
    }

    func terminate() {
        stop()
    }

    func forceTerminate() {
        stop()
    }

    func setTerminationHandler(_ handler: @escaping () -> Void) {
        let shouldCall = lock.withLock { () -> Bool in
            terminationHandler = handler
            return !running
        }
        if shouldCall { handler() }
    }

    private func stop() {
        let handler = lock.withLock { () -> (() -> Void)? in
            guard running else { return nil }
            running = false
            return terminationHandler
        }
        handler?()
    }
}

private enum TestLocalAILifecycleError: LocalizedError {
    case partialCleanupFailed
    case fullDeleteFailed

    var errorDescription: String? {
        switch self {
        case .partialCleanupFailed:
            return "partial cleanup failed"
        case .fullDeleteFailed:
            return "full delete failed"
        }
    }
}

private struct UserDefaultsSnapshot {
    private let values = UserDefaults.standard.dictionaryRepresentation()

    func restore() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where values[key] == nil {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
    }
}

private extension NSLock {
    func withLock<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
