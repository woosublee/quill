import AppKit
import Combine
import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct AppStateAIProcessingBackendTests {
    static func main() async throws {
        let defaultsSnapshot = UserDefaultsSnapshot()
        let originalSettingsDirectory = AppSettingsStorage.storageDirectoryOverride
        let originalLocalAIInstallStatusProvider =
            AppState.localAIInstallStatusProvider
        let suiteStatusHarness = LocalAIStatusHarness(
            defaultStatus: .notInstalled
        )
        AppState.localAIInstallStatusProvider = {
            suiteStatusHarness.status(for: $0)
        }
        let isolatedSettingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-app-state-ai-processing-tests-\(ProcessInfo.processInfo.globallyUniqueString)",
                isDirectory: true
            )
        AppSettingsStorage.storageDirectoryOverride = isolatedSettingsDirectory
        defer {
            defaultsSnapshot.restore()
            AppSettingsStorage.storageDirectoryOverride = originalSettingsDirectory
            AppState.localAIInstallStatusProvider =
                originalLocalAIInstallStatusProvider
            try? FileManager.default.removeItem(at: isolatedSettingsDirectory)
        }

        await testLegacyModelsMigrateToIndependentCloudChoices()
        await testCorruptedChoicesFallbackAndPersistNormalizedCloudChoices()
        await testWhitespaceCloudIDsFallbackToRememberedOrDefaultModels()
        await testStoredCloudChoicesReconcileRememberedModels()
        await testStoredLocalChoicesPreserveRememberedCloudModels()
        await testStartupNormalizesUnavailableLocalChoices()
        await testChangingCloudModelWhileLocalPreservesLocalChoice()
        await testDirectCloudChoiceSynchronizesRememberedModel()
        await testPostProcessingAndContextChoicesStayIndependent()
        await testDiscardUndownloadedSelectionsRestoresActiveChoices()
        await testDiscardUndownloadedSelectionsPreservesStartedDownloads()
        await testSettingsDismissalDisablesAIWithoutReadyModels()
        await testSettingsDismissalFallsBackToReadyLocalAIModel()
        await testSameModelDownloadCoalescesAndSelectsBothFeatures()
        await testDifferentModelsStartIndependentDownloads()
        await testNativeWhisperProgressCoalescesAndCancellationWins()
        await testLocalAIProgressCoalescesPerModelAndCompletionWins()
        await testChoosingCloudClearsOnlyOnePendingSelection()
        await testCancelPendingSelectionClearsOnlyOneConsumer()
        await testPendingSelectionChangesPublishObjectWillChange()
        await testCancellationWaitsForCompletionAndRetriesAfterQuiescence()
        try await testIdleShutdownMonitoringIsIdempotentAndStops()
        await testLocalAIInstallQuiescenceWaitsForEveryWorker()
        try await testTerminationWaitsForLocalAIQuiescenceAndSuppressesDuplicates()
        try await testNativeWhisperTerminationWaitsForWorkerQuiescence()
        try await testCombinedNativeAndLocalTerminationWaitsForBothWorkers()
        await testTerminationCleanupBlocksNewModelInstalls()
        await testPendingRecordingTerminationCancelRepliesFalseOnce()
        await testPartialCleanupFailureSetsModelIssue()
        await testInstallerSuccessRequiresReadyStatus()
        await testInstallerSuccessRechecksHardwareAvailability()
        await testInstallerFailureClearsPendingAndSetsIssue()
        await testUnsupportedHardwareRejectsLocalSelection()
        await testCanonicalModelValidationRejectsForgedModels()
        await testAIProcessingChoiceDisplayMetadata()
        testManagedLocalAIModelResolutionReconcilesRetainedLifecycle()
        await testCloudSelectionPublishesContextChoiceOnce()
        await testSelectionWaitsForInitialStatusRefresh()
        await testBackgroundStatusRefreshIgnoresStaleGeneration()
        try await testDeleteDuringInstallWaitsAndCannotAutoSelect()
        try await testDeleteFailureAndSuccessStateReset()
        try await testDeleteFallsBackToInstalledLocalThenCloudThenDisabled()
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

    private static func testStoredLocalChoicesPreserveRememberedCloudModels() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .ready)
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }
        let defaults = UserDefaults.standard
        defaults.set("remembered/post", forKey: "post_processing_model")
        defaults.set("remembered/context", forKey: "context_model")
        let postChoice = AIProcessingBackendChoice.localAI(
            modelID: LocalAIModelCatalog.fast.id
        )
        let contextChoice = AIProcessingBackendChoice.localAI(
            modelID: LocalAIModelCatalog.quality.id
        )
        storeChoice(postChoice, forKey: "post_processing_backend_choice")
        storeChoice(contextChoice, forKey: "context_backend_choice")

        let appState = await makeRefreshedAppState()

        await MainActor.run {
            assert(appState.postProcessingBackendChoice == postChoice)
            assert(appState.contextBackendChoice == contextChoice)
            assert(appState.postProcessingModel == "remembered/post")
            assert(appState.contextModel == "remembered/context")
        }
        assert(defaults.string(forKey: "post_processing_model") == "remembered/post")
        assert(defaults.string(forKey: "context_model") == "remembered/context")
    }

    private static func testStartupNormalizesUnavailableLocalChoices() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(
            statuses: [
                LocalAIModelCatalog.quality.id: .notInstalled,
                LocalAIModelCatalog.fast.id: .ready
            ],
            defaultStatus: .notInstalled
        )
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        UserDefaults.standard.set("remembered/post", forKey: "post_processing_model")
        UserDefaults.standard.set("remembered/context", forKey: "context_model")
        storeChoice(
            .localAI(modelID: LocalAIModelCatalog.quality.id),
            forKey: "post_processing_backend_choice"
        )
        storeChoice(
            .localAI(modelID: LocalAIModelCatalog.quality.id),
            forKey: "context_backend_choice"
        )

        let appState = await makeRefreshedAppState()
        let expected = AIProcessingBackendChoice.localAI(
            modelID: LocalAIModelCatalog.fast.id
        )
        await MainActor.run {
            precondition(appState.postProcessingBackendChoice == expected)
            precondition(appState.contextBackendChoice == expected)
            precondition(appState.postProcessingModel == "remembered/post")
            precondition(appState.contextModel == "remembered/context")
        }
        precondition(storedChoice(forKey: "post_processing_backend_choice") == expected)
        precondition(storedChoice(forKey: "context_backend_choice") == expected)
    }

    private static func testChangingCloudModelWhileLocalPreservesLocalChoice() async {
        resetAIProcessingDefaults()
        let appState = await makeRefreshedAppState()
        await MainActor.run {
            appState.postProcessingBackendChoice = .localAI(
                modelID: LocalAIModelCatalog.fast.id
            )
            appState.contextBackendChoice = .localAI(
                modelID: LocalAIModelCatalog.quality.id
            )
            appState.postProcessingModel = "new/cloud-model"
            appState.contextModel = "new/context-cloud-model"
            assert(
                appState.postProcessingBackendChoice
                    == .localAI(modelID: LocalAIModelCatalog.fast.id)
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
                modelID: LocalAIModelCatalog.fast.id
            )
            appState.contextBackendChoice = .cloud(modelID: "context/cloud")
            assert(appState.postProcessingBackendChoice.isLocal)
            assert(appState.contextBackendChoice == .cloud(modelID: "context/cloud"))
        }
    }

    private static func testDiscardUndownloadedSelectionsRestoresActiveChoices() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        let model = LocalAIModelCatalog.fast
        let appState = await makeRefreshedAppState()
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
            precondition(appState.pendingLocalAIModelID(for: .context) == model.id)

            appState.commitModelSettingsDrafts(
                transcriptionEnabled: appState.transcriptionEnabled,
                transcriptionChoice: appState.currentNoteBrowserTranscriptionChoice,
                postProcessingEnabled: true,
                postProcessingChoice: .localAI(modelID: model.id),
                contextEnabled: true,
                contextChoice: .localAI(modelID: model.id)
            )

            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == nil)
            precondition(appState.pendingLocalAIModelID(for: .context) == nil)
            precondition(appState.postProcessingBackendChoice == originalPostChoice)
            precondition(appState.contextBackendChoice == originalContextChoice)
            precondition(!appState.disablePostProcessing)
            precondition(!appState.disableContextCapture)
        }
    }

    private static func testDiscardUndownloadedSelectionsPreservesStartedDownloads() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        let model = LocalAIModelCatalog.fast
        let appState = await makeRefreshedAppState()
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
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        let appState = await makeRefreshedAppState()
        await MainActor.run {
            appState.apiKey = ""
            appState.disablePostProcessing = false
            appState.disableContextCapture = false

            appState.reconcileModelSelectionsAfterSettingsDismissal()

            precondition(appState.disablePostProcessing)
            precondition(appState.disableContextCapture)
        }
    }

    private static func testSettingsDismissalFallsBackToReadyLocalAIModel() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let seams = LocalAISeamSnapshot()
        let model = LocalAIModelCatalog.fast
        statusHarness.set(.ready, for: model)
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        let appState = await makeRefreshedAppState()
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

            let expected = AIProcessingBackendChoice.localAI(modelID: model.id)
            precondition(appState.postProcessingBackendChoice == expected)
            precondition(appState.contextBackendChoice == expected)
            precondition(!appState.disablePostProcessing)
            precondition(!appState.disableContextCapture)
        }
    }

    private static func testSameModelDownloadCoalescesAndSelectsBothFeatures() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        let model = LocalAIModelCatalog.fast
        let appState = await makeRefreshedAppState()
        await MainActor.run {
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

            precondition(appState.postProcessingBackendChoice == originalPostChoice)
            precondition(appState.contextBackendChoice == originalContextChoice)
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == model.id)
            precondition(appState.pendingLocalAIModelID(for: .context) == model.id)
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
            precondition(appState.contextBackendChoice == expected)
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == nil)
            precondition(appState.pendingLocalAIModelID(for: .context) == nil)
            precondition(appState.localAIInstallState(for: model).status == .ready)
            precondition(appState.localAIInstallState(for: model).issue == nil)
        }
    }

    private static func testDifferentModelsStartIndependentDownloads() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIPartialModelDelete = { _ in }
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        let appState = await makeRefreshedAppState()
        await MainActor.run {
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: LocalAIModelCatalog.quality.id),
                for: .postProcessing
            )
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: LocalAIModelCatalog.fast.id),
                for: .context
            )
            precondition(
                appState.pendingLocalAIModelID(for: .postProcessing)
                    == LocalAIModelCatalog.quality.id
            )
            precondition(
                appState.pendingLocalAIModelID(for: .context)
                    == LocalAIModelCatalog.fast.id
            )
        }

        precondition(installHarness.starts(for: LocalAIModelCatalog.quality) == 0)
        precondition(installHarness.starts(for: LocalAIModelCatalog.fast) == 0)
        await MainActor.run {
            appState.installLocalAIModel(
                LocalAIModelCatalog.quality,
                autoSelectFor: .postProcessing
            )
            appState.installLocalAIModel(
                LocalAIModelCatalog.fast,
                autoSelectFor: .context
            )
        }
        precondition(installHarness.starts(for: LocalAIModelCatalog.quality) == 1)
        precondition(installHarness.starts(for: LocalAIModelCatalog.fast) == 1)
        await MainActor.run {
            appState.cancelLocalAIInstall(LocalAIModelCatalog.quality)
            appState.cancelLocalAIInstall(LocalAIModelCatalog.fast)
        }
    }

    private static func testNativeWhisperProgressCoalescesAndCancellationWins() async {
        resetAIProcessingDefaults()
        let statusHarness = NativeWhisperStatusHarness(status: .notInstalled)
        let installHarness = ControlledNativeWhisperInstallHarness()
        let scheduler = ProgressScheduleHarness()
        let seams = LocalAISeamSnapshot()
        AppState.nativeWhisperInstallStatusProvider = {
            statusHarness.installStatus(for: $0)
        }
        AppState.nativeWhisperInstallStarter = { model, progress, completion in
            installHarness.start(
                model: model,
                progress: progress,
                completion: completion
            )
        }
        AppState.nativeWhisperProgressSchedule = scheduler.schedule
        defer { seams.restore() }

        let appState = await MainActor.run { AppState() }
        await MainActor.run {
            appState.installNativeWhisperModel()
        }
        for value in 1...10_000 {
            installHarness.sendProgress(
                NativeWhisperDownloadProgress(
                    downloadedBytes: Int64(value),
                    totalBytes: 10_000
                )
            )
        }

        precondition(scheduler.scheduledCount == 1)
        await MainActor.run { scheduler.runNext() }
        let firstBytes = await MainActor.run {
            appState.nativeWhisperInstallProgress.downloadedBytes
        }
        precondition(firstBytes == 1)
        precondition(scheduler.scheduledCount == 1)
        await MainActor.run { scheduler.runNext() }
        let latestBytes = await MainActor.run {
            appState.nativeWhisperInstallProgress.downloadedBytes
        }
        precondition(latestBytes == 10_000)

        installHarness.sendProgress(
            NativeWhisperDownloadProgress(
                downloadedBytes: 10_001,
                totalBytes: 20_000
            )
        )
        precondition(scheduler.scheduledCount == 1)
        await MainActor.run {
            appState.cancelNativeWhisperInstall()
        }
        await MainActor.run { scheduler.runAll() }
        let cancelledProgress = await MainActor.run {
            appState.nativeWhisperInstallProgress
        }
        precondition(cancelledProgress.isCancelled)
        precondition(cancelledProgress.downloadedBytes == 10_000)

        installHarness.complete(with: .failure(.cancelled))
        await appState.waitForNativeWhisperInstallToQuiesce()
    }

    private static func testLocalAIProgressCoalescesPerModelAndCompletionWins() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let scheduler = ProgressScheduleHarness()
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        AppState.localAIProgressSchedule = scheduler.schedule
        defer { seams.restore() }

        let first = LocalAIModelCatalog.fast
        let second = LocalAIModelCatalog.quality
        let appState = await makeRefreshedAppState()
        await MainActor.run {
            appState.installLocalAIModel(first)
            appState.installLocalAIModel(second)
        }

        for value in 1...10_000 {
            installHarness.sendProgress(
                model: first,
                progress: LocalAIDownloadProgress(
                    downloadedBytes: Int64(value),
                    totalBytes: 10_000
                )
            )
            installHarness.sendProgress(
                model: second,
                progress: LocalAIDownloadProgress(
                    downloadedBytes: Int64(value * 2),
                    totalBytes: 20_000
                )
            )
        }

        precondition(scheduler.scheduledCount == 2)
        await MainActor.run { scheduler.runAll() }
        let coalescedBytes = await MainActor.run {
            (
                appState.localAIInstallState(for: first).progress.downloadedBytes,
                appState.localAIInstallState(for: second).progress.downloadedBytes
            )
        }
        precondition(coalescedBytes.0 == 10_000)
        precondition(coalescedBytes.1 == 20_000)

        installHarness.sendProgress(
            model: first,
            progress: LocalAIDownloadProgress(
                downloadedBytes: 10_001,
                totalBytes: 20_000
            )
        )
        installHarness.sendProgress(
            model: second,
            progress: LocalAIDownloadProgress(
                downloadedBytes: 20_001,
                totalBytes: 30_000
            )
        )
        precondition(scheduler.scheduledCount == 2)
        statusHarness.set(.ready, for: first)
        statusHarness.set(.ready, for: second)
        installHarness.complete(model: first, with: .success(()))
        installHarness.complete(model: second, with: .success(()))
        await appState.waitForLocalAIInstallsToQuiesce()
        await MainActor.run { scheduler.runAll() }
        let finalStates = await MainActor.run {
            (
                appState.localAIInstallState(for: first),
                appState.localAIInstallState(for: second)
            )
        }
        precondition(finalStates.0.status == .ready)
        precondition(finalStates.1.status == .ready)
        precondition(!finalStates.0.isInstalling)
        precondition(!finalStates.1.isInstalling)
        precondition(finalStates.0.progress.downloadedBytes == 10_000)
        precondition(finalStates.1.progress.downloadedBytes == 20_000)
    }

    private static func testChoosingCloudClearsOnlyOnePendingSelection() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        let model = LocalAIModelCatalog.fast
        let appState = await makeRefreshedAppState()
        await MainActor.run {
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .postProcessing
            )
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .context
            )
            appState.installLocalAIModel(model, autoSelectFor: .context)
            appState.selectAIProcessingBackendChoice(
                .cloud(modelID: "cloud/override"),
                for: .postProcessing
            )

            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == nil)
            precondition(appState.pendingLocalAIModelID(for: .context) == model.id)
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
                appState.contextBackendChoice
                    == .localAI(modelID: model.id)
            )
        }
    }

    private static func testCancelPendingSelectionClearsOnlyOneConsumer() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        let model = LocalAIModelCatalog.fast
        let appState = await makeRefreshedAppState()
        let originalPostChoice = await MainActor.run {
            let originalPostChoice = appState.postProcessingBackendChoice
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .postProcessing
            )
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .context
            )
            appState.installLocalAIModel(model, autoSelectFor: .context)
            appState.cancelPendingLocalAISelection(for: .postProcessing)
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == nil)
            precondition(appState.pendingLocalAIModelID(for: .context) == model.id)
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
                appState.contextBackendChoice
                    == .localAI(modelID: model.id)
            )
        }
    }

    private static func testPendingSelectionChangesPublishObjectWillChange() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        let model = LocalAIModelCatalog.fast
        let appState = await makeRefreshedAppState()
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
                for: .context
            )
            precondition(publications > 0)
            publications = 0

            appState.cancelPendingLocalAISelection(for: .context)
            precondition(publications > 0)
            publications = 0

            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .context
            )
            publications = 0
            appState.selectAIProcessingBackendChoice(
                .cloud(modelID: "cloud/pending-clear"),
                for: .context
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
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIPartialModelDelete = { model in
            partialDeletionHarness.record(
                modelID: model.id,
                managerWasStopped: false
            )
        }
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        let model = LocalAIModelCatalog.fast
        let appState = await makeRefreshedAppState()
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
            validateModel: { _ in .ready },
            terminationGracePeriod: 0,
            waitForProcessExit: { _, _ in true }
        )
        let seams = LocalAISeamSnapshot()
        AppState.localAIServerManagerFactory = { manager }
        AppState.localAIIdleShutdownSleep = { nanoseconds in
            try await sleepHarness.sleep(nanoseconds: nanoseconds)
        }
        defer { seams.restore() }

        _ = try await manager.withBaseURL(for: LocalAIModelCatalog.fast) { $0 }
        precondition(process.isRunning)
        let appState = await makeRefreshedAppState()

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

    private static func testLocalAIInstallQuiescenceWaitsForEveryWorker() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let completion = LockedBox(false)
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIPartialModelDelete = { _ in }
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        let appState = await makeRefreshedAppState()
        await MainActor.run {
            appState.installLocalAIModel(LocalAIModelCatalog.fast)
            appState.installLocalAIModel(LocalAIModelCatalog.quality)
        }
        let waiter = Task {
            await appState.waitForLocalAIInstallsToQuiesce()
            completion.set(true)
        }
        await yieldMainActor()
        precondition(!completion.value)

        await MainActor.run {
            appState.cancelLocalAIInstall(LocalAIModelCatalog.fast)
            appState.cancelLocalAIInstall(LocalAIModelCatalog.quality)
        }
        precondition(
            installHarness.task(for: LocalAIModelCatalog.fast, startIndex: 0)?.isCancelled
                == true
        )
        precondition(
            installHarness.task(for: LocalAIModelCatalog.quality, startIndex: 0)?.isCancelled
                == true
        )

        installHarness.complete(
            model: LocalAIModelCatalog.fast,
            with: .failure(.cancelled)
        )
        await waitUntil {
            !appState.localAIInstallState(for: LocalAIModelCatalog.fast).isInstalling
        }
        precondition(!completion.value)

        installHarness.complete(
            model: LocalAIModelCatalog.quality,
            with: .failure(.cancelled)
        )
        await waiter.value
        precondition(completion.value)
    }

    private static func testTerminationWaitsForLocalAIQuiescenceAndSuppressesDuplicates() async throws {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let partialDeletionHarness = LocalAIDeletionHarness()
        let replyHarness = TerminationReplyHarness()
        let process = TestLocalAIServerProcess()
        let manager = LocalAIServerManager(
            launchProcess: { _, _, port, _ in (process, port) },
            pollHealth: { _ in true },
            validateModel: { _ in .ready },
            terminationGracePeriod: 0,
            waitForProcessExit: { _, _ in true }
        )
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIPartialModelDelete = { model in
            partialDeletionHarness.record(
                modelID: model.id,
                managerWasStopped: !process.isRunning
            )
        }
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        AppState.localAIServerManagerFactory = { manager }
        AppState.modelDownloadQuitAlertPresenter = { .alertFirstButtonReturn }
        AppState.applicationTerminationReply = replyHarness.reply
        defer { seams.restore() }

        let model = LocalAIModelCatalog.fast
        let appState = await makeRefreshedAppState()
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

    private static func testNativeWhisperTerminationWaitsForWorkerQuiescence() async throws {
        resetAIProcessingDefaults()
        let nativeStatusHarness = NativeWhisperStatusHarness(status: .notInstalled)
        let nativeInstallHarness = ControlledNativeWhisperInstallHarness()
        let replyHarness = TerminationReplyHarness()
        let process = TestLocalAIServerProcess()
        let manager = LocalAIServerManager(
            launchProcess: { _, _, port, _ in (process, port) },
            pollHealth: { _ in true },
            validateModel: { _ in .ready },
            terminationGracePeriod: 0,
            waitForProcessExit: { _, _ in true }
        )
        let seams = LocalAISeamSnapshot()
        AppState.nativeWhisperInstallStatusProvider = {
            nativeStatusHarness.installStatus(for: $0)
        }
        AppState.nativeWhisperInstallStarter = { model, progress, completion in
            nativeInstallHarness.start(
                model: model,
                progress: progress,
                completion: completion
            )
        }
        AppState.localAIServerManagerFactory = { manager }
        AppState.modelDownloadQuitAlertPresenter = { .alertFirstButtonReturn }
        AppState.applicationTerminationReply = replyHarness.reply
        defer { seams.restore() }

        let appState = await makeRefreshedAppState()
        _ = try await manager.withBaseURL(for: LocalAIModelCatalog.fast) { $0 }
        await MainActor.run {
            appState.installNativeWhisperModel(autoSelectWhenReady: true)
        }
        let statusCallsBeforeCancellation = nativeStatusHarness.callCount

        let terminationReply = await MainActor.run {
            appState.requestTerminationAfterModelCleanup()
        }
        precondition(terminationReply == .terminateLater)
        precondition(nativeInstallHarness.task?.isCancelled == true)
        precondition(process.isRunning)
        precondition(replyHarness.values.isEmpty)
        precondition(nativeStatusHarness.callCount == statusCallsBeforeCancellation)

        nativeInstallHarness.complete(with: .failure(.cancelled))
        await waitUntil { !appState.isInstallingNativeWhisper }
        await waitUntil { !process.isRunning }
        await waitUntil { replyHarness.values == [true] }
        precondition(nativeStatusHarness.callCount == statusCallsBeforeCancellation + 1)
        await yieldMainActor()
        precondition(replyHarness.values == [true])
    }

    private static func testCombinedNativeAndLocalTerminationWaitsForBothWorkers() async throws {
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
            validateModel: { _ in .ready },
            terminationGracePeriod: 0,
            waitForProcessExit: { _, _ in true }
        )
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { localStatusHarness.status(for: $0) }
        AppState.localAIInstallStarter = localInstallHarness.start
        AppState.localAIPartialModelDelete = { model in
            partialDeletionHarness.record(
                modelID: model.id,
                managerWasStopped: !process.isRunning
            )
        }
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        AppState.nativeWhisperInstallStatusProvider = {
            nativeStatusHarness.installStatus(for: $0)
        }
        AppState.nativeWhisperInstallStarter = { model, progress, completion in
            nativeInstallHarness.start(
                model: model,
                progress: progress,
                completion: completion
            )
        }
        AppState.localAIServerManagerFactory = { manager }
        AppState.modelDownloadQuitAlertPresenter = { .alertFirstButtonReturn }
        AppState.applicationTerminationReply = replyHarness.reply
        defer { seams.restore() }

        let localModel = LocalAIModelCatalog.fast
        let appState = await makeRefreshedAppState()
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
        resetAIProcessingDefaults()
        let localStatusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let localInstallHarness = LocalAIInstallHarness()
        let nativeStatusHarness = NativeWhisperStatusHarness(status: .notInstalled)
        let nativeInstallHarness = ControlledNativeWhisperInstallHarness()
        let replyHarness = TerminationReplyHarness()
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { localStatusHarness.status(for: $0) }
        AppState.localAIInstallStarter = localInstallHarness.start
        AppState.localAIPartialModelDelete = { _ in }
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        AppState.nativeWhisperInstallStatusProvider = {
            nativeStatusHarness.installStatus(for: $0)
        }
        AppState.nativeWhisperInstallStarter = { model, progress, completion in
            nativeInstallHarness.start(
                model: model,
                progress: progress,
                completion: completion
            )
        }
        AppState.modelDownloadQuitAlertPresenter = { .alertFirstButtonReturn }
        AppState.applicationTerminationReply = replyHarness.reply
        defer { seams.restore() }

        let activeModel = LocalAIModelCatalog.fast
        let blockedModel = LocalAIModelCatalog.quality
        let appState = await makeRefreshedAppState()
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
        precondition(localInstallHarness.starts(for: blockedModel) == 0)
        await MainActor.run {
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == nil)
            precondition(!appState.willAutoSelectNativeWhisperWhenReady)
        }

        localInstallHarness.complete(model: activeModel, with: .failure(.cancelled))
        await waitUntil { replyHarness.values == [true] }
    }

    private static func testPendingRecordingTerminationCancelRepliesFalseOnce() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let replyHarness = TerminationReplyHarness()
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIPartialModelDelete = { _ in }
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        AppState.modelDownloadQuitAlertPresenter = { .alertSecondButtonReturn }
        AppState.applicationTerminationReply = replyHarness.reply
        defer { seams.restore() }

        let model = LocalAIModelCatalog.fast
        let appState = await makeRefreshedAppState()
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
            expectedBytes: LocalAIModelCatalog.fast.approximateBytes
        ))
        let installHarness = LocalAIInstallHarness()
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIPartialModelDelete = { _ in
            throw TestLocalAILifecycleError.partialCleanupFailed
        }
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        let model = LocalAIModelCatalog.fast
        let appState = await makeRefreshedAppState()
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

    private static func testInstallerSuccessRequiresReadyStatus() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        let model = LocalAIModelCatalog.quality
        let appState = await makeRefreshedAppState()
        let originalChoice = await MainActor.run { () -> AIProcessingBackendChoice in
            let originalChoice = appState.postProcessingBackendChoice
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .postProcessing
            )
            appState.installLocalAIModel(model, autoSelectFor: .postProcessing)
            return originalChoice
        }

        installHarness.complete(model: model, with: .success(()))
        await waitUntil {
            !appState.localAIInstallState(for: model).isInstalling
        }
        await MainActor.run {
            precondition(appState.postProcessingBackendChoice == originalChoice)
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == nil)
            precondition(
                appState.localAIInstallState(for: model).issue?.code
                    == .localAIModelUnavailable
            )
            precondition(appState.localAIInstallState(for: model).status == .notInstalled)
        }
    }

    private static func testInstallerSuccessRechecksHardwareAvailability() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let availability = LockedBox(supportedLocalAIAvailability())
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIProcessingAvailabilityProvider = { availability.value }
        defer { seams.restore() }

        let model = LocalAIModelCatalog.fast
        let appState = await makeRefreshedAppState()
        let originalChoice = await MainActor.run { () -> AIProcessingBackendChoice in
            let originalChoice = appState.contextBackendChoice
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .context
            )
            appState.installLocalAIModel(model, autoSelectFor: .context)
            return originalChoice
        }

        statusHarness.set(.ready, for: model)
        availability.set(unsupportedLocalAIAvailability())
        installHarness.complete(model: model, with: .success(()))
        await waitUntil {
            !appState.localAIInstallState(for: model).isInstalling
        }
        await MainActor.run {
            precondition(appState.contextBackendChoice == originalChoice)
            precondition(appState.pendingLocalAIModelID(for: .context) == nil)
            precondition(
                appState.localAIInstallState(for: model).issue?.code
                    == .localAIModelUnavailable
            )
        }
    }

    private static func testInstallerFailureClearsPendingAndSetsIssue() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        let model = LocalAIModelCatalog.fast
        let appState = await makeRefreshedAppState()
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
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIProcessingAvailabilityProvider = unsupportedLocalAIAvailability
        defer { seams.restore() }

        let model = LocalAIModelCatalog.fast
        let appState = await makeRefreshedAppState()
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
                    .localAI(modelID: model.id)
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

    private static func testCanonicalModelValidationRejectsForgedModels() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let deletionHarness = LocalAIDeletionHarness()
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIModelDelete = { model in
            deletionHarness.record(modelID: model.id, managerWasStopped: true)
        }
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        let canonical = LocalAIModelCatalog.fast
        let forged = LocalAIModel(
            id: canonical.id,
            displayName: "Forged",
            description: canonical.description,
            artifacts: canonical.artifacts,
            approximateResidentRAMBytes: canonical.approximateResidentRAMBytes
        )
        let appState = await makeRefreshedAppState()
        await MainActor.run {
            precondition(
                !appState.isAIProcessingChoiceAvailable(
                    .localAI(modelID: "unknown-local-model")
                )
            )
            appState.installLocalAIModel(forged, autoSelectFor: .postProcessing)
            appState.deleteLocalAIModel(forged)
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == nil)
        }
        await yieldMainActor()
        precondition(installHarness.starts(for: canonical) == 0)
        precondition(deletionHarness.callCount == 0)
    }

    private static func testAIProcessingChoiceDisplayMetadata() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        let appState = await makeRefreshedAppState()
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

            precondition(
                appState.isAIProcessingChoiceAvailable(
                    .localAI(modelID: LocalAIModelCatalog.fast.id)
                )
            )
            precondition(
                appState.isAIProcessingChoiceAvailable(
                    .cloud(modelID: AppState.defaultPostProcessingModel)
                )
            )
            precondition(
                !appState.isAIProcessingBackendReady(for: .postProcessing)
            )
            appState.apiKey = "test-key"
            precondition(
                appState.isAIProcessingChoiceAvailable(
                    .cloud(modelID: AppState.defaultPostProcessingModel)
                )
            )
            precondition(
                appState.isAIProcessingBackendReady(for: .postProcessing)
            )
        }
    }

    private static func testManagedLocalAIModelResolutionReconcilesRetainedLifecycle() {
        let activeModel = LocalAIModelCatalog.quality
        let attemptedModel = LocalAIModelCatalog.fast
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

        let activeLocalReplacesCleanRetained = resolve(
            retainedModelID: attemptedModel.id,
            currentChoice: .localAI(modelID: activeModel.id)
        )
        precondition(activeLocalReplacesCleanRetained.model?.id == activeModel.id)
        precondition(
            activeLocalReplacesCleanRetained.reconciledRetainedModelID == nil
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
            var publications = 0
            let cancellable = appState.$contextBackendChoice
                .dropFirst()
                .sink { _ in publications += 1 }

            appState.selectAIProcessingBackendChoice(
                .cloud(modelID: "cloud/single-rebuild"),
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
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer {
            statusHarness.releaseBlockedCall()
            seams.restore()
        }

        let appState = await MainActor.run { AppState() }
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

    private static func testBackgroundStatusRefreshIgnoresStaleGeneration() async {
        resetAIProcessingDefaults()
        let statusHarness = ControlledLocalAIStatusHarness(
            blockedModelID: LocalAIModelCatalog.quality.id,
            blockedResult: .ready,
            subsequentResult: .notInstalled
        )
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer {
            statusHarness.releaseBlockedCall()
            seams.restore()
        }

        let appState = await MainActor.run { AppState() }
        statusHarness.waitUntilBlockedCallEntered()
        await MainActor.run {
            appState.refreshAllLocalAIInstallStates()
        }
        await appState.waitForLocalAIInstallStateRefresh()
        statusHarness.releaseBlockedCall()
        await yieldMainActor()

        let callsBeforeReads = statusHarness.callCount
        await MainActor.run {
            precondition(
                appState.localAIInstallState(for: LocalAIModelCatalog.quality).status
                    == .notInstalled
            )
            precondition(!appState.isAIProcessingBackendReady(for: .postProcessing))
            _ = appState.aiProcessingChoiceDisplays(for: .postProcessing)
        }
        precondition(statusHarness.callCount == callsBeforeReads)
        precondition(statusHarness.mainThreadCallCount == 0)
    }

    private static func testDeleteDuringInstallWaitsAndCannotAutoSelect() async throws {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let partialDeletionHarness = LocalAIDeletionHarness()
        let deletionHarness = LocalAIDeletionHarness()
        let seams = LocalAISeamSnapshot()
        let manager = LocalAIServerManager(
            launchProcess: { _, _, port, _ in (TestLocalAIServerProcess(), port) },
            pollHealth: { _ in true },
            validateModel: { _ in .ready }
        )
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIPartialModelDelete = { model in
            partialDeletionHarness.record(modelID: model.id, managerWasStopped: false)
        }
        AppState.localAIModelDelete = { model in
            deletionHarness.record(modelID: model.id, managerWasStopped: true)
            statusHarness.set(.notInstalled, for: model)
        }
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        AppState.localAIServerManagerFactory = { manager }
        defer { seams.restore() }

        let model = LocalAIModelCatalog.fast
        let appState = await makeRefreshedAppState()
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

    private static func testDeleteFailureAndSuccessStateReset() async throws {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .ready)
        let deletionHarness = LocalAIDeletionHarness()
        let seams = LocalAISeamSnapshot()
        let manager = LocalAIServerManager(
            launchProcess: { _, _, port, _ in (TestLocalAIServerProcess(), port) },
            pollHealth: { _ in true },
            validateModel: { _ in .ready }
        )
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIModelDelete = { model in
            deletionHarness.record(modelID: model.id, managerWasStopped: true)
            throw TestLocalAILifecycleError.fullDeleteFailed
        }
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        AppState.localAIServerManagerFactory = { manager }
        defer { seams.restore() }

        let model = LocalAIModelCatalog.quality
        let appState = await makeRefreshedAppState()
        await MainActor.run {
            appState.postProcessingBackendChoice = .localAI(modelID: model.id)
            appState.deleteLocalAIModel(model)
        }
        await waitUntil { deletionHarness.callCount == 1 }
        await waitUntil {
            appState.localAIInstallState(for: model).issue?.code
                == .localAIModelUnavailable
        }
        await MainActor.run {
            precondition(
                appState.postProcessingBackendChoice
                    == .localAI(modelID: model.id)
            )
            precondition(appState.localAIInstallState(for: model).status == .ready)
        }
    }

    private static func testDeleteFallsBackToInstalledLocalThenCloudThenDisabled() async throws {
        try await verifyDeletionFallback(
            fastStatus: .ready,
            apiKey: "",
            expectedPostChoice: .localAI(modelID: LocalAIModelCatalog.fast.id),
            expectedContextChoice: .localAI(modelID: LocalAIModelCatalog.fast.id),
            expectedPostDisabled: false,
            expectedContextDisabled: false,
            verifyManagerStopsBeforeDelete: true
        )
        try await verifyDeletionFallback(
            fastStatus: .notInstalled,
            apiKey: "test-key",
            expectedPostChoice: .cloud(modelID: "remembered/post"),
            expectedContextChoice: .cloud(modelID: "remembered/context"),
            expectedPostDisabled: false,
            expectedContextDisabled: false,
            verifyManagerStopsBeforeDelete: false
        )
        try await verifyDeletionFallback(
            fastStatus: .notInstalled,
            apiKey: "",
            expectedPostChoice: .cloud(modelID: "remembered/post"),
            expectedContextChoice: .cloud(modelID: "remembered/context"),
            expectedPostDisabled: false,
            expectedContextDisabled: false,
            verifyManagerStopsBeforeDelete: false
        )
    }

    private static func verifyDeletionFallback(
        fastStatus: LocalAIInstallStatus,
        apiKey: String,
        expectedPostChoice: AIProcessingBackendChoice,
        expectedContextChoice: AIProcessingBackendChoice,
        expectedPostDisabled: Bool,
        expectedContextDisabled: Bool,
        verifyManagerStopsBeforeDelete: Bool
    ) async throws {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(
            statuses: [
                LocalAIModelCatalog.quality.id: .ready,
                LocalAIModelCatalog.fast.id: fastStatus
            ],
            defaultStatus: .notInstalled
        )
        let process = TestLocalAIServerProcess()
        let lifecycle = LockedBox<LocalAIServerManager.LifecycleSnapshot?>(nil)
        let manager = LocalAIServerManager(
            launchProcess: { _, _, port, _ in (process, port) },
            pollHealth: { _ in true },
            validateModel: { _ in .ready },
            terminationGracePeriod: 0,
            waitForProcessExit: { _, _ in true },
            observeLifecycle: { lifecycle.set($0) }
        )
        let deletionHarness = LocalAIDeletionHarness()
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = { statusHarness.status(for: $0) }
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        AppState.localAIServerManagerFactory = { manager }
        AppState.localAIModelDelete = { model in
            deletionHarness.record(
                modelID: model.id,
                managerWasStopped: lifecycle.value?.phase == .idle
            )
            statusHarness.set(.notInstalled, for: model)
        }
        defer { seams.restore() }

        let appState = await makeRefreshedAppState()
        await MainActor.run {
            appState.postProcessingModel = "remembered/post"
            appState.contextModel = "remembered/context"
            appState.postProcessingBackendChoice = .localAI(
                modelID: LocalAIModelCatalog.quality.id
            )
            appState.contextBackendChoice = .localAI(
                modelID: LocalAIModelCatalog.quality.id
            )
            appState.disablePostProcessing = false
            appState.disableContextCapture = false
            appState.apiKey = apiKey
        }

        if verifyManagerStopsBeforeDelete {
            _ = try await manager.withBaseURL(for: LocalAIModelCatalog.quality) { url in
                url
            }
            precondition(lifecycle.value?.phase == .running)
        }

        await MainActor.run {
            appState.deleteLocalAIModel(LocalAIModelCatalog.quality)
        }
        await waitUntil { deletionHarness.callCount == 1 }
        await waitUntil {
            appState.postProcessingBackendChoice == expectedPostChoice
                && appState.contextBackendChoice == expectedContextChoice
                && appState.disablePostProcessing == expectedPostDisabled
                && appState.disableContextCapture == expectedContextDisabled
        }
        await MainActor.run {
            precondition(
                appState.localAIInstallState(for: LocalAIModelCatalog.quality).status
                    == .notInstalled
            )
            precondition(
                appState.localAIInstallState(for: LocalAIModelCatalog.quality).issue
                    == nil
            )
        }
        precondition(
            storedChoice(forKey: "post_processing_backend_choice")
                == expectedPostChoice
        )
        precondition(
            storedChoice(forKey: "context_backend_choice")
                == expectedContextChoice
        )
        precondition(deletionHarness.deletedModelIDs == [LocalAIModelCatalog.quality.id])
        if verifyManagerStopsBeforeDelete {
            precondition(deletionHarness.managerWasStoppedValues == [true])
            precondition(!process.isRunning)
        }
    }

    private static func makeRefreshedAppState() async -> AppState {
        let appState = await MainActor.run { AppState() }
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
                physicalMemory: LocalAIProcessingAvailability.qualityMemoryThreshold
            )
        }
    }

    private static var unsupportedLocalAIAvailability: () -> LocalAIProcessingAvailability {
        {
            LocalAIProcessingAvailability(
                isAppleSilicon: false,
                runnerIsExecutable: false,
                physicalMemory: LocalAIProcessingAvailability.qualityMemoryThreshold
            )
        }
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
        let body = sourceBlock(
            in: try appStateSource(),
            from: "private func resumeCloudTranscriptionAfterLaunch(",
            to: "private func installCloudTranscriptionTask("
        )
        let snapshot = requiredRange(
            of: "let postProcessingService = makePostProcessingService()",
            in: body
        )
        let task = requiredRange(of: "let task = Task", in: body)
        assert(snapshot.lowerBound < task.lowerBound)
        let taskBody = String(body[task.lowerBound...])
        assert(!taskBody.contains("makePostProcessingService()"))
        assert(taskBody.contains("postProcessingService: postProcessingService"))
    }

    private static func testContextCaptureUsesServiceSnapshotAndKeepsCancellationGuards() throws {
        let body = sourceBlock(
            in: try appStateSource(),
            from: "private func startContextCapture()",
            to: "private func fallbackContextAtStop()"
        )
        let snapshot = requiredRange(of: "let contextService = contextService", in: body)
        let task = requiredRange(of: "contextCaptureTask = Task", in: body)
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
        assert(delegate.contains("requestTerminationAfterModelCleanup()"))
        assert(!delegate.contains("requestTerminationWhileNativeWhisperInstalling()"))
        assert(state.contains("await manager.stop()"))
        assert(state.contains("cancelAllLocalAIInstalls()"))
        assert(state.contains("localAIDeferredInstallModelIDs.removeAll()"))
        assert(state.contains("localAIRestartAfterCancellationModelIDs.removeAll()"))
        assert(state.contains("pendingLocalAISelections.removeAll()"))
        assert(state.contains("nativeWhisperInstallTask != nil"))
        assert(state.contains("!localAIInstallTasks.isEmpty"))
        assert(state.contains("waitForNativeWhisperInstallToQuiesce()"))
        assert(state.contains("waitForLocalAIInstallsToQuiesce()"))
        assert(
            state.components(
                separatedBy: "guard !isModelTerminationCleanupPending else { return }"
            ).count - 1 >= 2
        )
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
        assert(!nativeCancellation.contains("deletePartialModel"))
        assert(!nativeCancellation.contains("refreshNativeWhisperInstallStatus()"))
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

    private static func constructorCount(in source: String) -> Int {
        let pattern = #"(?<![A-Za-z0-9_])PostProcessingService\("#
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
        AppSettingsStorage.delete(account: "groq_api_key")
        for key in [
            "post_processing_model",
            "context_model",
            "post_processing_backend_choice",
            "context_backend_choice",
            "disable_post_processing",
            "disable_context_capture"
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

private struct LocalAISeamSnapshot {
    let nativeWhisperInstallStatusProvider = AppState.nativeWhisperInstallStatusProvider
    let nativeWhisperInstallStarter = AppState.nativeWhisperInstallStarter
    let nativeWhisperProgressSchedule = AppState.nativeWhisperProgressSchedule
    let installStatusProvider = AppState.localAIInstallStatusProvider
    let installStarter = AppState.localAIInstallStarter
    let localAIProgressSchedule = AppState.localAIProgressSchedule
    let modelDelete = AppState.localAIModelDelete
    let partialModelDelete = AppState.localAIPartialModelDelete
    let availabilityProvider = AppState.localAIProcessingAvailabilityProvider
    let serverManagerFactory = AppState.localAIServerManagerFactory
    let idleShutdownSleep = AppState.localAIIdleShutdownSleep
    let modelDownloadQuitAlertPresenter = AppState.modelDownloadQuitAlertPresenter
    let applicationTerminationReply = AppState.applicationTerminationReply

    func restore() {
        AppState.nativeWhisperInstallStatusProvider = nativeWhisperInstallStatusProvider
        AppState.nativeWhisperInstallStarter = nativeWhisperInstallStarter
        AppState.nativeWhisperProgressSchedule = nativeWhisperProgressSchedule
        AppState.localAIInstallStatusProvider = installStatusProvider
        AppState.localAIInstallStarter = installStarter
        AppState.localAIProgressSchedule = localAIProgressSchedule
        AppState.localAIModelDelete = modelDelete
        AppState.localAIPartialModelDelete = partialModelDelete
        AppState.localAIProcessingAvailabilityProvider = availabilityProvider
        AppState.localAIServerManagerFactory = serverManagerFactory
        AppState.localAIIdleShutdownSleep = idleShutdownSleep
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
