import Combine
import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct AppStateAIProcessingBackendTests {
    static func main() async throws {
        let defaultsSnapshot = UserDefaultsSnapshot()
        let originalSettingsDirectory = AppSettingsStorage.storageDirectoryOverride
        let isolatedSettingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-app-state-ai-processing-tests-\(ProcessInfo.processInfo.globallyUniqueString)",
                isDirectory: true
            )
        AppSettingsStorage.storageDirectoryOverride = isolatedSettingsDirectory
        defer {
            defaultsSnapshot.restore()
            AppSettingsStorage.storageDirectoryOverride = originalSettingsDirectory
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
        await testSameModelDownloadCoalescesAndSelectsBothFeatures()
        await testDifferentModelsStartIndependentDownloads()
        await testChoosingCloudClearsOnlyOnePendingSelection()
        await testCancelPendingSelectionClearsOnlyOneConsumer()
        await testCancelClearsEveryPendingConsumerForModel()
        await testInstallerSuccessRequiresReadyStatus()
        await testInstallerFailureClearsPendingAndSetsIssue()
        await testUnsupportedHardwareRejectsLocalSelection()
        await testAIProcessingChoiceDisplayMetadata()
        await testCloudSelectionPublishesContextChoiceOnce()
        try await testDeleteFallsBackToInstalledLocalThenCloudThenDisabled()
        try testEveryPostProcessingConstructionUsesCentralFactory()
        try testCloudResumeCapturesPostProcessingServiceBeforeTaskStarts()
        try testContextCaptureUsesServiceSnapshotAndKeepsCancellationGuards()
        try testContextModelObserverRebuildsOnlyThroughChoiceChanges()
        print("AppStateAIProcessingBackendTests passed")
    }

    private static func testLegacyModelsMigrateToIndependentCloudChoices() async {
        resetAIProcessingDefaults()
        UserDefaults.standard.set("custom/post", forKey: "post_processing_model")
        UserDefaults.standard.set("custom/context", forKey: "context_model")
        let appState = await MainActor.run { AppState() }
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

        let appState = await MainActor.run { AppState() }

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

        let appState = await MainActor.run { AppState() }

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

        let appState = await MainActor.run { AppState() }

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
        AppState.localAIInstallStatusProvider = statusHarness.status
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

        let appState = await MainActor.run { AppState() }

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
        AppState.localAIInstallStatusProvider = statusHarness.status
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

        let appState = await MainActor.run { AppState() }
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
        let appState = await MainActor.run { AppState() }
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
        let appState = await MainActor.run { AppState() }
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
        let appState = await MainActor.run { AppState() }
        await MainActor.run {
            appState.postProcessingBackendChoice = .localAI(
                modelID: LocalAIModelCatalog.fast.id
            )
            appState.contextBackendChoice = .cloud(modelID: "context/cloud")
            assert(appState.postProcessingBackendChoice.isLocal)
            assert(appState.contextBackendChoice == .cloud(modelID: "context/cloud"))
        }
    }

    private static func testSameModelDownloadCoalescesAndSelectsBothFeatures() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = statusHarness.status
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        let model = LocalAIModelCatalog.fast
        let appState = await MainActor.run { AppState() }
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
        AppState.localAIInstallStatusProvider = statusHarness.status
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIPartialModelDelete = { _ in }
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        let appState = await MainActor.run { AppState() }
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

        precondition(installHarness.starts(for: LocalAIModelCatalog.quality) == 1)
        precondition(installHarness.starts(for: LocalAIModelCatalog.fast) == 1)
        await MainActor.run {
            appState.cancelLocalAIInstall(LocalAIModelCatalog.quality)
            appState.cancelLocalAIInstall(LocalAIModelCatalog.fast)
        }
    }

    private static func testChoosingCloudClearsOnlyOnePendingSelection() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = statusHarness.status
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        let model = LocalAIModelCatalog.fast
        let appState = await MainActor.run { AppState() }
        await MainActor.run {
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .postProcessing
            )
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .context
            )
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
        AppState.localAIInstallStatusProvider = statusHarness.status
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        let model = LocalAIModelCatalog.fast
        let appState = await MainActor.run { AppState() }
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

    private static func testCancelClearsEveryPendingConsumerForModel() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let partialDeletionHarness = LocalAIDeletionHarness()
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = statusHarness.status
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
        let appState = await MainActor.run { AppState() }
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
            appState.cancelLocalAIInstall(model)
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == nil)
            precondition(appState.pendingLocalAIModelID(for: .context) == nil)
            precondition(!appState.localAIInstallState(for: model).isInstalling)
            precondition(appState.localAIInstallState(for: model).progress.isCancelled)
            return choices
        }
        precondition(installHarness.task(for: model, startIndex: 0)?.isCancelled == true)
        precondition(partialDeletionHarness.deletedModelIDs == [model.id])

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
            let cancelledState = appState.localAIInstallState(for: model)
            precondition(!cancelledState.isInstalling)
            precondition(cancelledState.progress.isCancelled)
            precondition(cancelledState.progress.downloadedBytes == 0)
        }

        await MainActor.run {
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .postProcessing
            )
            precondition(appState.localAIInstallState(for: model).isInstalling)
        }
        precondition(installHarness.starts(for: model) == 2)

        statusHarness.set(.ready, for: model)
        installHarness.sendProgress(
            model: model,
            startIndex: 0,
            progress: LocalAIDownloadProgress(
                downloadedBytes: 999,
                totalBytes: model.approximateBytes
            )
        )
        installHarness.complete(
            model: model,
            startIndex: 0,
            with: .success(())
        )
        await yieldMainActor()
        await MainActor.run {
            let state = appState.localAIInstallState(for: model)
            precondition(state.isInstalling)
            precondition(state.progress.downloadedBytes == 0)
            precondition(appState.pendingLocalAIModelID(for: .postProcessing) == model.id)
            precondition(appState.postProcessingBackendChoice == originalChoices.0)
            precondition(appState.contextBackendChoice == originalChoices.1)
        }

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

    private static func testInstallerSuccessRequiresReadyStatus() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = statusHarness.status
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        let model = LocalAIModelCatalog.quality
        let appState = await MainActor.run { AppState() }
        let originalChoice = await MainActor.run { () -> AIProcessingBackendChoice in
            let originalChoice = appState.postProcessingBackendChoice
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .postProcessing
            )
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

    private static func testInstallerFailureClearsPendingAndSetsIssue() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let installHarness = LocalAIInstallHarness()
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = statusHarness.status
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        let model = LocalAIModelCatalog.fast
        let appState = await MainActor.run { AppState() }
        await MainActor.run {
            appState.selectAIProcessingBackendChoice(
                .localAI(modelID: model.id),
                for: .context
            )
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
        AppState.localAIInstallStatusProvider = statusHarness.status
        AppState.localAIInstallStarter = installHarness.start
        AppState.localAIProcessingAvailabilityProvider = unsupportedLocalAIAvailability
        defer { seams.restore() }

        let model = LocalAIModelCatalog.fast
        let appState = await MainActor.run { AppState() }
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

    private static func testAIProcessingChoiceDisplayMetadata() async {
        resetAIProcessingDefaults()
        let statusHarness = LocalAIStatusHarness(defaultStatus: .notInstalled)
        let seams = LocalAISeamSnapshot()
        AppState.localAIInstallStatusProvider = statusHarness.status
        AppState.localAIProcessingAvailabilityProvider = supportedLocalAIAvailability
        defer { seams.restore() }

        let appState = await MainActor.run { AppState() }
        await MainActor.run {
            let displays = appState.aiProcessingChoiceDisplays(for: .postProcessing)
            let cloud = displays.first { display in
                if case .cloud = display.choice { return true }
                return false
            }
            precondition(cloud?.section == "Cloud")
            precondition(cloud?.isAvailable == false)
            precondition(cloud?.unavailableReason == "API key is not configured")

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
                !appState.isAIProcessingChoiceAvailable(
                    .cloud(modelID: AppState.defaultPostProcessingModel)
                )
            )
            appState.apiKey = "test-key"
            precondition(
                appState.isAIProcessingChoiceAvailable(
                    .cloud(modelID: AppState.defaultPostProcessingModel)
                )
            )
        }
    }

    private static func testCloudSelectionPublishesContextChoiceOnce() async {
        resetAIProcessingDefaults()
        let appState = await MainActor.run { AppState() }
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
            expectedPostDisabled: true,
            expectedContextDisabled: true,
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
        AppState.localAIInstallStatusProvider = statusHarness.status
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

        let appState = await MainActor.run { () -> AppState in
            let appState = AppState()
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
            return appState
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
    let installStatusProvider = AppState.localAIInstallStatusProvider
    let installStarter = AppState.localAIInstallStarter
    let modelDelete = AppState.localAIModelDelete
    let partialModelDelete = AppState.localAIPartialModelDelete
    let availabilityProvider = AppState.localAIProcessingAvailabilityProvider
    let serverManagerFactory = AppState.localAIServerManagerFactory

    func restore() {
        AppState.localAIInstallStatusProvider = installStatusProvider
        AppState.localAIInstallStarter = installStarter
        AppState.localAIModelDelete = modelDelete
        AppState.localAIPartialModelDelete = partialModelDelete
        AppState.localAIProcessingAvailabilityProvider = availabilityProvider
        AppState.localAIServerManagerFactory = serverManagerFactory
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
