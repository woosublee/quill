import Combine
import Darwin
import Foundation

private final class ControlledRetryCloudUpload: @unchecked Sendable {
    private let condition = NSCondition()
    private let transcript: String
    private var didEnterUpload = false
    private var didFinishUpload = false
    private var isReleased = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(transcript: String) {
        self.transcript = transcript
    }

    func dependencies() -> CloudTranscriptionDependencies {
        CloudTranscriptionDependencies(
            encodedUploadCeilingBytes: 20_000_000,
            upload: { [self] request, _ in
                defer { markUploadFinished() }
                await waitForRelease()
                try Task.checkCancellation()
                let data = try JSONSerialization.data(withJSONObject: [
                    "text": transcript,
                    "language": "en",
                    "segments": []
                ])
                return (
                    data,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            },
            checkpointStore: InMemoryCloudTranscriptionCheckpointStore(),
            progress: { _ in },
            temporaryRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "quill-controlled-retry-\(UUID().uuidString)",
                    isDirectory: true
                ),
            sleep: { _ in }
        )
    }

    var hasEnteredUpload: Bool {
        condition.lock()
        defer { condition.unlock() }
        return didEnterUpload
    }

    var hasFinishedUpload: Bool {
        condition.lock()
        defer { condition.unlock() }
        return didFinishUpload
    }

    func release() {
        condition.lock()
        isReleased = true
        let continuations = continuations
        self.continuations.removeAll()
        condition.unlock()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func markUploadFinished() {
        condition.lock()
        didFinishUpload = true
        condition.broadcast()
        condition.unlock()
    }

    private func waitForRelease() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            didEnterUpload = true
            if isReleased {
                condition.unlock()
                continuation.resume()
                return
            }
            continuations.append(continuation)
            condition.unlock()
        }
    }
}

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct AppStateTranscriptionConfigurationTests {
    static func main() async throws {
        try testDefaultAppStateUsesExplicitCredentialLayout()
        try testMakeTranscriptionServiceUsesLocalConfiguration()
        try testMakeTranscriptionServiceMapsEmptyLocalWhisperPathToNil()
        try testMakeTranscriptionServiceDefaultsLegacyMlxWhisperOff()
        try testMakeTranscriptionServicePassesLegacyMlxWhisperToggle()
        try testMakeTranscriptionServiceUsesOriginatingNativeWhisperExecution()
        try testExecutionSnapshotKeepsCloudServiceConfigurationImmutable()
        try testExecutionSnapshotKeepsLocalServiceConfigurationImmutable()
        await testLocalAIChoiceRoundTripsThroughSettings()
        await testLocalAIListsOnlyTranscriptionCapableModels()
        await testUninstalledLocalAIChoiceIsUnavailableNotSwitched()
        await testUnknownStoredLocalAIModelResolvesUnavailable()
        await testLocalModeKeepsSelectedLocalAIModel()
        testTranscriptionResponseFormatUsesVerboseJSONForKnownWhisperModels()
        testTranscriptionResponseFormatUsesJSONForOtherModels()
        testTranscriptionHTTP400UsesConfigurationIssue()
        testQwen36ModelConfiguration()
        testQwen36ContextReasoningIsStripped()
        testContextSummaryPreservesNonReasoningModelOutput()
        testContextModelDefaultsToQwen36()
        testDeprecatedDefaultContextModelMigratesToQwen36()
        testCustomContextModelIsPreserved()
        testLLMTransportTimeoutNormalization()
        testPostProcessingCooldownDispositionDefaultsToProcessed()
        testPostProcessingCooldownDispositionCanBeMarkedSkipped()
        testNoteBrowserDefaultsOnWhenPreferenceIsMissing()
        testNoteBrowserPreservesExplicitOptOut()
        await testExistingInstallMigratesMissingTranscriptionPreferenceOn()
        await testStoredTranscriptionPreferenceIsPreserved()
        await testRecordOnlyDoesNotRequireAccessibility()
        await testTranscriptionOffPreservesRememberedBackend()
        await testTranscriptionOnPreservesRememberedBackendReadiness()
        await testNoteBrowserSelectionControlsTranscriptionWithoutForgettingModel()
        await testNoteBrowserSelectionRejectsUnreadyChoice()
        await testSettingsTranscriptionToggleRequiresReadyRememberedChoice()
        await testSettingsDraftPreservesPreviousReadyTranscriptionChoice()
        await testSettingsDismissalTurnsOffTranscriptionWithoutReadyModel()
        await testSettingsDismissalFallsBackToReadyTranscriptionModel()
        await testFreshInstallSeedsNewHiddenDefaultsOnce()
        await testCompletedInstallKeepsLegacyFallbacksWhenKeysAreMissing()
        await testStoredUserDefaultsBeatFirstInstallSeed()
        try testPreserveExactWordingIsRemovedFromSettingsAndPipeline()
        testLegacyMlxWhisperOptionsDefaultToOff()
        testLegacyMlxWhisperOptionsPersistIndependentlyFromEngine()
        testLegacyMlxWhisperOptionsFallBackToLegacyEnginePreference()
        testLegacyMlxWhisperOptionsStayVisibleWhenEngineIsTurnedOff()
        testPermissionStatusUpdateSkipsUnchangedValues()
        testRecordingOverlayLayoutPersistsWithoutCompactOverlayBoolean()
        testRecordingCancelShortcutDefaultsToEscape()
        testRecordingCancelShortcutPersistsDisabled()
        testRecordingCancelShortcutPersistsCustomShortcut()
        testRecordingCancelShortcutDisablesDefaultWhenStoredHoldUsesEscape()
        testRecordingCancelShortcutRejectsHoldConflict()
        testRecordingCancelShortcutRejectsPasteAgainConflict()
        testPasteAgainShortcutRejectsRecordingCancelConflict()
        testPasteAgainShortcutReportsManualModifierCollision()
        testHoldShortcutRejectsCancelConflict()
        testHoldShortcutRejectsMoreSpecificCancelOverlap()
        testRecordingCancelShortcutRejectsModifierOnlyOverlapWithKeyCombo()
        testRecordingCancelShortcutRejectsMoreSpecificHoldOverlap()
        testRecordingCancelShortcutRejectsManualModifierRuntimeOverlap()
        testCommandModeManualModifierReportsCancelOverlap()
        testStoppedTranscriptionCompletionSummaryTrimsFinalTranscript()
        testStoppedTranscriptionCompletionSummaryShowsFallbackIndicatorForNonEmptyRawFallback()
        testStoppedTranscriptionCompletionSummaryHidesFallbackIndicatorForEmptyRawFallback()
        testTimeoutFailureReasonOverridesCommandFallback()
        testStoppedTranscriptionSettingsSnapshotCapturesHistoryMetadata()
        try testAppStateCreatedTranscriptionServicesPassLegacyMlxWhisperToggle()
        try testRetryRequestGatesStoredContextByCurrentToggleAndUsability()
        try testAppStateCapturesNativeWhisperExecutionBeforeImportAndRetryTasks()
        try testNoteBrowserTranscriptionMenuUsesFlatNativeCheckedItems()
        await testAudioImportConfigurationUsesChoiceDerivedBackend()
        try testInitialAudioImportUsesChoiceConfiguration()
        try testAudioImportSheetUsesChoiceDisplayRows()
        try testCloudTranscriptionActionsRequireProviderConfiguration()
        try testRecordingStartRequiresProviderConfigurationBeforePermissions()
        await testNoteBrowserTranscriptionChoiceDisplayIncludesResolvedModels()
        try testNoteBrowserTranscriptionChoiceSetterUpdatesLocalBackend()
        await testNativeWhisperInstallLeavesAppleActiveUntilCompletion()
        await testInstallCallWhileAlreadyInstallingStillArmsAutoSelection()
        await testNativeWhisperInstallAutoSelectsOnSuccess()
        await testExplicitBackendChoiceCancelsAutoSelectionOnly()
        await testNativeWhisperCancellationClearsAutoSelection()
        await testAppStateInstancesKeepIndependentNativeWhisperEnvironments()
        await testNativeWhisperDeletionUsesOriginatingDependency()
        await testSetupProcessingPresetsPreserveProviderConfiguration()
        try testSetupProcessingPresetUsesExistingChoiceSetter()
        try testNormalizationGuardsStayInsideMainActorIsolation()
        await testAPITranscriptionModesRemainSelectableWithoutResolvedAPIKey()
        try testSettingsModelFirstTranscriptionUsesExistingChoiceSetter()
        try testSettingsLegacyManagementKeepsExistingModelRows()
        try testSettingsGlobalAPIKeyCanBeCleared()
        await testTranscriptionAPIKeyEnablesAPIModesWithoutGlobalAPIKey()
        await testEmptyTranscriptionAPIKeyFallsBackToGlobalAPIKey()
        await testRemovingAPIKeyPreservesSelectedAPIMode()
        await testRemovingAPIKeyPreservesSelectedAPIModeWhileRecording()
        await testSystemDefaultAndSystemAudioConvertsAPIRealtimeToStandard()
        await testSystemDefaultAndSystemAudioTurnsOffWithoutReadyFallback()
        await testSystemDefaultAndSystemAudioRejectsLiveModeSelections()
        await testCombinedSourceDisabledWhenQueuedLiveOnlyChoiceNotRecording()
        await testLegacyMicrophoneSelectionSeedsDevicePreference()
        await testMicrophoneSelectionPersistsAcrossSourceChanges()
        try await testSystemDefaultAndSystemAudioNormalizesStoredAPIRealtimeOnStartup()
        await testSystemDefaultAndSystemAudioStartupTurnsOffStoredRealtimeWithoutKey()
        await testSystemDefaultAndSystemAudioStartupTurnsOffStoredAppleLiveWithoutWhisper()
        await testSystemDefaultAndSystemAudioFallsBackFromStoredAppleLiveToInstalledNativeWhisperWithoutReentry()
        await testRepeatedNativeWhisperSelectionRemainsStable()
        await testLegacyAndNativeWhisperTransitionsRemainStable()
        await testLegacyToAppleLiveClearsLegacyEnginePreference()
        await testLegacyOnlyStoredConfigurationRemainsLegacyWithoutNativeWhisper()
        try testGoogleCalendarConnectionMetadataRestoresStartupState()
        testGoogleCalendarConnectionMetadataClearsCorruptValue()
        testCalendarRecordingReminderLeadMinutesMigrateLegacyValue()
        testCalendarRecordingReminderLeadMinutesNormalizesStoredSelection()
        testCalendarRecordingReminderLeadMinutesDefaultsStoredEmptySelection()
        testCalendarRecordingReminderLeadMinutesPersistNormalizedSelection()
        await testGoogleCalendarStoredCustomOAuthCredentialsAreIgnored()
        await testGoogleCalendarRefreshMarksNeedsReconnectWhenTokenMissing()
        await testGoogleCalendarRefreshMarksNeedsReconnectWhenRefreshTokenIsMissing()
        testGoogleCalendarReconnectErrorClassificationSeparatesClientConfigurationFailures()
        await testGoogleCalendarHealthyDoesNotClearDifferentFeatureFailure()
        await testGoogleCalendarHealthCheckRunsForConnectedMetadataWithoutSelectedCalendars()
        await testGoogleCalendarRefreshMarksTemporaryFailureWhenCalendarListFails()
        await testGoogleCalendarRefreshMarksHealthyWhenCalendarListLoads()
        await testRetryAvailabilityRequiresStoredAudio()
        await testRetryAvailabilityOffersSelectableCloudAlternative()
        await testRetryAvailabilityRequiresModelSelection()
        await testRetryAvailabilityRequiresProviderConfiguration()
        await testRetryAvailabilityAcceptsConfiguredAPIStandard()
        try await testRetryPreservesMeetingSummaryMetadata()
        try await testAudioImportTimeoutPreservesRawTranscriptAndFailedOutcome()
        try await testRetryTimeoutPreservesRawTranscriptAndFailedOutcome()
        try await testCreatedAppStateKeepsItsRetryDependencySnapshot()
        try await testRetryTranscriptionFailurePreservesExistingAIOutcome()
        try await testTranscriptEditInvalidatesActiveRetryAfterDurableSave()
        try await testDeleteFailureCancelsActiveRetryWithoutResurrection()
        try testRetryWorkflowMutationRoutes()
        try testRetryUsesCurrentPostProcessingAndAudioOnlyMetadata()
        try testAudioOnlyRetryCreatesTranscriptFileAndPreservesMetadata()
        try testHistoryReconstructionPreservesMeetingSummaryMetadata()
        try testSuccessfulTranscriptionHistoryReceivesSpokenLanguage()
        try await testResumedRetryPersistsAIOutcomeAndCommandFallbackWhitespace()
        try testHistoryDeletionForgetsSummaryGenerationStateAfterPersistence()
        try testRealtimeConfiguredLanguageUsesOneRequestAndResolutionValue()
        try testAudioOnlyRetryDeletesNewTranscriptFileWhenStale()
        print("AppStateTranscriptionConfigurationTests passed")
    }

    private static let credentialStorageLayout = CredentialStorageLayout(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-app-state-transcription-credentials-\(UUID().uuidString)",
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

    private static func testDefaultAppStateUsesExplicitCredentialLayout() throws {
        resetCredentialStore()
        defer { resetCredentialStore() }
        try credentialStore.save(
            "suite-key",
            account: "groq_api_key"
        )

        let appState = makeAppState()

        precondition(appState.apiKey == "suite-key")
    }

    private static func transcriptionTestDependencies(
        from base: AppStateDependencies = .live,
        status: @escaping @Sendable (NativeWhisperModel) -> NativeWhisperInstallStatus = {
            _ in .notInstalled
        }
    ) -> AppStateDependencies {
        var dependencies = base
        dependencies.credentialStorageLayout = credentialStorageLayout
        dependencies.nativeWhisper.installStatus = status
        return dependencies
    }

    private static func makeAppState() -> AppState {
        makeAppState(dependencies: transcriptionTestDependencies())
    }

    private static func makeAppState(
        dependencies: AppStateDependencies
    ) -> AppState {
        AppState(dependencies: dependencies)
    }

    private static func localAITranscriptionDependencies(
        installStatus: LocalAIInstallStatus,
        nativeWhisperStatus: NativeWhisperInstallStatus = .notInstalled
    ) -> AppStateDependencies {
        var dependencies = transcriptionTestDependencies(status: { _ in nativeWhisperStatus })
        dependencies.localAI.installStatus = { _ in installStatus }
        dependencies.localAI.processingAvailability = {
            LocalAIProcessingAvailability(
                isAppleSilicon: true,
                runnerIsExecutable: true,
                physicalMemory: 64 * 1024 * 1024 * 1024
            )
        }
        return dependencies
    }

    private static func makeLocalAIAppState(
        installStatus: LocalAIInstallStatus,
        nativeWhisperStatus: NativeWhisperInstallStatus = .notInstalled
    ) async -> AppState {
        let appState = await MainActor.run {
            AppState(dependencies: localAITranscriptionDependencies(
                installStatus: installStatus,
                nativeWhisperStatus: nativeWhisperStatus
            ))
        }
        await appState.waitForLocalAIInstallStateRefresh()
        return appState
    }

    private static func testLocalAIChoiceRoundTripsThroughSettings() async {
        resetDefaults()
        let appState = await makeLocalAIAppState(installStatus: .ready)
        await MainActor.run {
            appState.setNoteBrowserTranscriptionChoice(.localAI(modelID: "gemma-4-e4b-it"))
            precondition(appState.localAITranscriptionModelID == "gemma-4-e4b-it", "model id stored")
            precondition(appState.useLocalTranscription, "local flag")
            precondition(!appState.useLegacyMlxWhisper, "legacy cleared")
            precondition(!appState.realtimeStreamingEnabled, "realtime cleared")
            precondition(
                appState.currentNoteBrowserTranscriptionChoice == .localAI(modelID: "gemma-4-e4b-it"),
                "choice derived"
            )
            precondition(
                UserDefaults.standard.string(forKey: "local_ai_transcription_model") == "gemma-4-e4b-it",
                "persisted key"
            )
            precondition(
                appState.isNoteBrowserTranscriptionChoiceReady(.localAI(modelID: "gemma-4-e4b-it")),
                "installed model is ready"
            )

            // Cloud Standard is always available, so normalization keeps it.
            appState.setNoteBrowserTranscriptionChoice(
                .apiStandard(modelID: "whisper-large-v3")
            )
            precondition(appState.localAITranscriptionModelID == nil, "cleared by other choice")
            precondition(!appState.useLocalTranscription, "cloud choice applied")
        }
    }

    private static func testLocalAIListsOnlyTranscriptionCapableModels() async {
        resetDefaults()
        let appState = await makeLocalAIAppState(installStatus: .ready)
        await MainActor.run {
            let ids = appState.noteBrowserTranscriptionChoiceDisplays.compactMap { display -> String? in
                if case .localAI(let id) = display.choice { return id }
                return nil
            }
            precondition(ids == ["gemma-4-e4b-it"], "gemma listed, qwen not: \(ids)")
        }
    }

    private static func testUninstalledLocalAIChoiceIsUnavailableNotSwitched() async {
        resetDefaults()
        let appState = await makeLocalAIAppState(installStatus: .notInstalled)
        await MainActor.run {
            let choice = TranscriptionBackendChoice.localAI(modelID: "gemma-4-e4b-it")
            let display = appState.noteBrowserTranscriptionDisplay(for: choice)
            precondition(!display.isAvailable, "unavailable without package")
            precondition(display.unavailableReason != nil, "has a reason")
            precondition(!appState.isNoteBrowserTranscriptionChoiceReady(choice), "not ready")
        }
    }

    private static func testUnknownStoredLocalAIModelResolvesUnavailable() async {
        resetDefaults()
        UserDefaults.standard.set("retired-model", forKey: "local_ai_transcription_model")
        UserDefaults.standard.set(true, forKey: "use_local_transcription")
        let appState = await makeLocalAIAppState(installStatus: .ready)
        await MainActor.run {
            precondition(
                appState.currentNoteBrowserTranscriptionChoice == .localAI(modelID: "retired-model"),
                "keeps the user's choice"
            )
            precondition(
                !appState.noteBrowserTranscriptionDisplay(for: .localAI(modelID: "retired-model")).isAvailable,
                "unknown model unavailable"
            )
        }
    }

    private static func testLocalModeKeepsSelectedLocalAIModel() async {
        resetDefaults()
        // Native Whisper is also ready, so without the Local AI preference the
        // local mode would switch to Native Whisper.
        let appState = await makeLocalAIAppState(
            installStatus: .ready,
            nativeWhisperStatus: .ready
        )
        await MainActor.run {
            let choice = TranscriptionBackendChoice.localAI(modelID: "gemma-4-e4b-it")
            appState.setNoteBrowserTranscriptionChoice(choice)
            appState.setNoteBrowserTranscriptionMode(.localWhisper)
            precondition(
                appState.currentNoteBrowserTranscriptionChoice == choice,
                "local mode keeps the Local AI choice"
            )
        }
    }

    private static func testMakeTranscriptionServiceUsesLocalConfiguration() throws {
        resetDefaults()
        let appState = makeAppState()
        appState.useLocalTranscription = true
        appState.localTranscriptionModel = .find(id: "apple-speech")
        appState.transcriptionLanguage = .find(code: "en")
        appState.localWhisperPath = "/tmp/quill-test-mlx-whisper"

        let service = try appState.makeTranscriptionService()
        let configuration = mirroredTranscriptionConfiguration(service)

        assert(configuration.useLocalTranscription)
        assert(configuration.localTranscriptionModelID == "apple-speech")
        assert(configuration.transcriptionLanguageCode == "en")
        assert(configuration.localWhisperPath == "/tmp/quill-test-mlx-whisper")
        let execution = Mirror(reflecting: service)
            .descendant("nativeWhisperExecution")
            as? NativeWhisperExecutionSnapshot
        assert(execution == nil)
    }

    private static func testMakeTranscriptionServiceMapsEmptyLocalWhisperPathToNil() throws {
        resetDefaults()
        let appState = makeAppState()
        appState.useLocalTranscription = true
        appState.localWhisperPath = ""

        let service = try appState.makeTranscriptionService()
        let configuration = mirroredTranscriptionConfiguration(service)

        assert(configuration.localWhisperPath == nil)
    }

    private static func testMakeTranscriptionServiceDefaultsLegacyMlxWhisperOff() throws {
        resetDefaults()
        let appState = makeAppState()
        appState.useLocalTranscription = true
        appState.localTranscriptionModel = .find(id: "mlx-community/whisper-large-v3-turbo")

        let service = try appState.makeTranscriptionService()
        let configuration = mirroredTranscriptionConfiguration(service)

        assert(configuration.useLegacyMlxWhisper == false)
    }

    private static func testMakeTranscriptionServicePassesLegacyMlxWhisperToggle() throws {
        resetDefaults()
        let appState = makeAppState()
        appState.isRecording = true
        appState.useLocalTranscription = true
        appState.useLegacyMlxWhisper = true

        let service = try appState.makeTranscriptionService()
        let configuration = mirroredTranscriptionConfiguration(service)

        assert(configuration.useLegacyMlxWhisper == true)
    }

    private static func testMakeTranscriptionServiceUsesOriginatingNativeWhisperExecution()
        throws {
        resetDefaults()
        var dependencies = transcriptionTestDependencies(status: { _ in .ready })
        dependencies.nativeWhisper.makeExecutionSnapshot = {
            markerNativeWhisperExecution(modelID: "originating-app-state")
        }
        let appState = makeAppState(dependencies: dependencies)
        appState.useLocalTranscription = true
        appState.useLegacyMlxWhisper = false
        appState.localTranscriptionModel = .find(
            id: "mlx-community/whisper-large-v3-turbo"
        )

        let service = try appState.makeTranscriptionService()
        let execution = Mirror(reflecting: service)
            .descendant("nativeWhisperExecution")
            as? NativeWhisperExecutionSnapshot

        assert(execution?.modelID == "originating-app-state")
    }

    private static func testExecutionSnapshotKeepsCloudServiceConfigurationImmutable() throws {
        let cloud = try CloudTranscriptionExecutionSnapshot(
            baseURL: "https://original.example.com/openai/v1/",
            apiKey: "original-key",
            model: "whisper-large-v3",
            language: "ko",
            encodedUploadCeilingBytes: 19_000_000
        )
        let completion = TranscriptionCompletionSnapshot(
            postProcessingEnabled: true,
            outputLanguage: "ko",
            pressEnterCommandEnabled: false
        )
        let snapshot = TranscriptionExecutionSnapshot.cloud(cloud, completion)

        let service = try snapshot.makeTranscriptionService()
        let configuration = mirroredCompleteTranscriptionConfiguration(service)

        assert(configuration.apiKey == "original-key")
        assert(configuration.baseURL == "https://original.example.com/openai/v1")
        assert(!configuration.useLocalTranscription)
        assert(configuration.transcriptionModel == "whisper-large-v3")
        assert(configuration.language == "ko")
        assert(configuration.encodedUploadCeilingBytes == 19_000_000)
    }

    private static func testExecutionSnapshotKeepsLocalServiceConfigurationImmutable() throws {
        let local = LocalTranscriptionExecutionSnapshot(
            model: .find(id: "mlx-community/whisper-large-v3-turbo"),
            localWhisperPath: "/tmp/original-mlx-whisper",
            useLegacyMlxWhisper: true,
            language: .find(code: "ja"),
            nativeWhisperExecution: markerNativeWhisperExecution(
                modelID: "retry-origin"
            )
        )
        let completion = TranscriptionCompletionSnapshot(
            postProcessingEnabled: false,
            outputLanguage: "ja",
            pressEnterCommandEnabled: true
        )
        let snapshot = TranscriptionExecutionSnapshot.local(local, completion)

        let service = try snapshot.makeTranscriptionService()
        let configuration = mirroredCompleteTranscriptionConfiguration(service)

        assert(configuration.useLocalTranscription)
        assert(configuration.localTranscriptionModelID == "mlx-community/whisper-large-v3-turbo")
        assert(configuration.localWhisperPath == "/tmp/original-mlx-whisper")
        assert(configuration.useLegacyMlxWhisper)
        assert(configuration.transcriptionLanguageCode == "ja")
        let execution = Mirror(reflecting: service)
            .descendant("nativeWhisperExecution")
            as? NativeWhisperExecutionSnapshot
        assert(execution?.modelID == "retry-origin")
    }

    private static func testTranscriptionResponseFormatUsesVerboseJSONForKnownWhisperModels() {
        for model in ["whisper-1", "whisper-large-v3", "whisper-large-v3-turbo", " WHISPER-LARGE-V3 "] {
            assert(TranscriptionService.responseFormat(forModel: model) == "verbose_json")
        }
    }

    private static func testTranscriptionResponseFormatUsesJSONForOtherModels() {
        for model in ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "custom-whisper-compatible-model", ""] {
            assert(TranscriptionService.responseFormat(forModel: model) == "json")
        }
    }

    private static func testTranscriptionHTTP400UsesConfigurationIssue() {
        let issue = QuillUserIssueError.cloudHTTP(
            status: 400,
            providerHost: "api.example.com",
            modelID: "provider/model"
        )

        assert(issue.record.code == .providerConfigurationInvalid)
        assert(issue.record.context.httpStatus == 400)
        assert(issue.record.context.providerHost == "api.example.com")
        assert(issue.record.context.modelID == "provider/model")
    }

    private static func testQwen36ModelConfiguration() {
        assert(ModelConfiguration.llmModels.contains("qwen/qwen3.6-27b"))
        assert(ModelConfiguration.config(for: "qwen/qwen3.6-27b").reasoningEffort == "none")
        assert(ModelConfiguration.config(for: "qwen/qwen3.6-27b").includeReasoning == false)
        assert(ModelConfiguration.config(for: "qwen3.6-27b").shouldStripThinkTags)
    }

    private static func testQwen36ContextReasoningIsStripped() {
        let output = """
        <think>Hidden reasoning must not reach the context summary.</think>
        The user is replying to an email about a launch. They likely intend to confirm the next steps. This sentence should be dropped.
        """

        let summary = AppContextService.activitySummary(from: output, model: "qwen/qwen3.6-27b")

        assert(summary == "The user is replying to an email about a launch. They likely intend to confirm the next steps.")
    }

    private static func testContextSummaryPreservesNonReasoningModelOutput() {
        let output = "<think>Visible for this model.</think> The user is writing a status update."

        let summary = AppContextService.activitySummary(
            from: output,
            model: "meta-llama/llama-4-scout-17b-16e-instruct"
        )

        assert(summary == output)
    }

    private static func testContextModelDefaultsToQwen36() {
        resetDefaults()
        let appState = makeAppState()

        assert(AppState.defaultContextModel == "qwen/qwen3.6-27b")
        assert(appState.contextModel == "qwen/qwen3.6-27b")
    }

    private static func testDeprecatedDefaultContextModelMigratesToQwen36() {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set("meta-llama/llama-4-scout-17b-16e-instruct", forKey: "context_model")

        let appState = makeAppState()

        assert(appState.contextModel == "qwen/qwen3.6-27b")
        assert(defaults.string(forKey: "context_model") == "qwen/qwen3.6-27b")
    }

    private static func testCustomContextModelIsPreserved() {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set("custom/context-model", forKey: "context_model")

        let appState = makeAppState()

        assert(appState.contextModel == "custom/context-model")
    }

    private static func testLLMTransportTimeoutNormalization() {
        assert(LLMAPITransport.timeout(for: 45) == 45)
        assert(LLMAPITransport.timeout(for: 0) == 60)
        assert(LLMAPITransport.timeout(for: -1) == 60)
        assert(LLMAPITransport.timeout(for: .infinity) == 60)
        assert(LLMAPITransport.timeout(for: .nan) == 60)
    }

    private static func testPostProcessingCooldownDispositionDefaultsToProcessed() {
        let result = PostProcessingResult(transcript: "processed", prompt: "prompt")

        assert(!result.skippedDueToCooldown)
    }

    private static func testPostProcessingCooldownDispositionCanBeMarkedSkipped() {
        let result = PostProcessingResult(
            transcript: "raw",
            prompt: "",
            skippedDueToCooldown: true
        )

        assert(result.skippedDueToCooldown)
    }

    private static func testNoteBrowserDefaultsOnWhenPreferenceIsMissing() {
        resetDefaults()
        let defaults = UserDefaults.standard

        assert(defaults.object(forKey: "note_browser_enabled") == nil)
        assert(makeAppState().noteBrowserEnabled)
    }

    private static func testNoteBrowserPreservesExplicitOptOut() {
        resetDefaults()
        let defaults = UserDefaults.standard
        let appState = makeAppState()

        appState.noteBrowserEnabled = false

        assert(defaults.object(forKey: "note_browser_enabled") as? Bool == false)
        assert(!makeAppState().noteBrowserEnabled)
    }

    private static func testExistingInstallMigratesMissingTranscriptionPreferenceOn() async {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "hasCompletedSetup")
        defaults.removeObject(forKey: "transcription_enabled")

        let appState = await MainActor.run { makeAppState() }

        await MainActor.run {
            precondition(appState.transcriptionEnabled)
        }
        precondition(defaults.object(forKey: "transcription_enabled") != nil)
        precondition(defaults.bool(forKey: "transcription_enabled"))
    }

    private static func testStoredTranscriptionPreferenceIsPreserved() async {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "hasCompletedSetup")
        defaults.set(false, forKey: "transcription_enabled")

        let appState = await MainActor.run { makeAppState() }

        await MainActor.run {
            precondition(!appState.transcriptionEnabled)
            appState.transcriptionEnabled = true
        }
        precondition(defaults.bool(forKey: "transcription_enabled"))
    }

    private static func testRecordOnlyDoesNotRequireAccessibility() async {
        resetDefaults()
        let appState = await MainActor.run { makeAppState() }
        await MainActor.run {
            appState.disableAutoPaste = false
            appState.isCommandModeEnabled = true
            appState.transcriptionEnabled = false
            precondition(!appState.requiresAccessibility)

            appState.transcriptionEnabled = true
            precondition(appState.requiresAccessibility)
        }
    }

    private static func testTranscriptionOffPreservesRememberedBackend() async {
        resetDefaults()
        let appState = await MainActor.run { makeAppState() }

        await MainActor.run {
            appState.apiKey = "global-key"
            appState.setNoteBrowserTranscriptionChoice(.apiStandard(modelID: "remembered-model"))
            appState.transcriptionEnabled = false
            appState.apiKey = ""

            precondition(!appState.transcriptionEnabled)
            precondition(appState.currentNoteBrowserTranscriptionChoice == .apiStandard(modelID: "remembered-model"))
        }
    }

    private static func testTranscriptionOnPreservesRememberedBackendReadiness() async {
        resetDefaults()
        let appState = await MainActor.run { makeAppState() }

        await MainActor.run {
            appState.apiKey = "global-key"
            appState.setNoteBrowserTranscriptionChoice(.apiStandard(modelID: "remembered-model"))
            appState.transcriptionEnabled = false
            appState.apiKey = ""
            appState.transcriptionEnabled = true

            precondition(appState.currentNoteBrowserTranscriptionMode == .apiStandard)
            precondition(
                !appState.isNoteBrowserTranscriptionChoiceReady(
                    appState.currentNoteBrowserTranscriptionChoice
                )
            )
        }
    }

    private static func testNoteBrowserSelectionControlsTranscriptionWithoutForgettingModel() async {
        resetDefaults()
        let appState = await MainActor.run { makeAppState() }

        await MainActor.run {
            appState.apiKey = "configured-key"
            let choice = TranscriptionBackendChoice.apiStandard(
                modelID: "remembered-model"
            )
            appState.setNoteBrowserTranscriptionSelection(choice)
            precondition(appState.transcriptionEnabled)
            precondition(appState.currentNoteBrowserTranscriptionChoice == choice)

            appState.setNoteBrowserTranscriptionSelection(nil)
            precondition(!appState.transcriptionEnabled)
            precondition(appState.currentNoteBrowserTranscriptionChoice == choice)
        }
    }

    private static func testNoteBrowserSelectionRejectsUnreadyChoice() async {
        resetDefaults()
        let appState = await MainActor.run { makeAppState() }

        await MainActor.run {
            appState.transcriptionEnabled = false
            let originalChoice = appState.currentNoteBrowserTranscriptionChoice

            appState.setNoteBrowserTranscriptionSelection(
                .apiStandard(modelID: "missing-key-model")
            )

            precondition(!appState.transcriptionEnabled)
            precondition(appState.currentNoteBrowserTranscriptionChoice == originalChoice)
        }
    }

    private static func testSettingsTranscriptionToggleRequiresReadyRememberedChoice() async {
        resetDefaults()
        let appState = await MainActor.run { makeAppState() }

        await MainActor.run {
            appState.selectedMicrophoneID =
                AudioInputDevice.systemDefaultAndSystemAudioID
            appState.setNoteBrowserTranscriptionChoice(
                .apiStandard(modelID: "remembered-model")
            )
            appState.transcriptionEnabled = false

            appState.setSettingsTranscriptionEnabled(true)

            precondition(!appState.transcriptionEnabled)
            precondition(
                appState.currentNoteBrowserTranscriptionChoice
                    == .apiStandard(modelID: "remembered-model")
            )

            appState.apiKey = "configured-key"
            appState.setSettingsTranscriptionEnabled(true)
            precondition(appState.transcriptionEnabled)

            appState.setSettingsTranscriptionEnabled(false)
            precondition(!appState.transcriptionEnabled)
        }
    }

    private static func testSettingsDraftPreservesPreviousReadyTranscriptionChoice() async {
        resetDefaults()
        var dependencies = transcriptionTestDependencies(status: { _ in .ready })
        let appState = await MainActor.run { makeAppState(dependencies: dependencies) }

        await MainActor.run {
            let previousChoice = TranscriptionBackendChoice.nativeWhisper(
                modelID: NativeWhisperModelCatalog.recommended.id
            )
            appState.setNoteBrowserTranscriptionChoice(previousChoice)
            appState.transcriptionEnabled = true

            appState.commitModelSettingsDrafts(
                transcriptionEnabled: true,
                transcriptionChoice: .apiStandard(modelID: "missing-key-model"),
                postProcessingEnabled: false,
                postProcessingChoice: appState.postProcessingBackendChoice,
                contextEnabled: false,
                contextChoice: appState.contextBackendChoice,
                meetingSummaryEnabled: !appState.disableMeetingSummary,
                meetingSummaryChoice: appState.meetingSummaryBackendChoice
            )

            precondition(appState.transcriptionEnabled)
            precondition(appState.currentNoteBrowserTranscriptionChoice == previousChoice)
        }
    }

    private static func testSettingsDismissalTurnsOffTranscriptionWithoutReadyModel() async {
        resetDefaults()
        let appState = await MainActor.run { makeAppState() }

        await MainActor.run {
            appState.selectedMicrophoneID =
                AudioInputDevice.systemDefaultAndSystemAudioID
            appState.setNoteBrowserTranscriptionChoice(
                .apiStandard(modelID: "remembered-model")
            )
            appState.transcriptionEnabled = true

            appState.reconcileModelSelectionsAfterSettingsDismissal()

            precondition(!appState.transcriptionEnabled)
            precondition(
                appState.currentNoteBrowserTranscriptionChoice
                    == .apiStandard(modelID: "remembered-model")
            )
        }
    }

    private static func testSettingsDismissalFallsBackToReadyTranscriptionModel() async {
        resetDefaults()
        var dependencies = transcriptionTestDependencies(status: { _ in .ready })
        let appState = await MainActor.run { makeAppState(dependencies: dependencies) }

        await MainActor.run {
            appState.selectedMicrophoneID =
                AudioInputDevice.systemDefaultAndSystemAudioID
            appState.setNoteBrowserTranscriptionChoice(
                .apiStandard(modelID: "remembered-model")
            )
            appState.transcriptionEnabled = true

            appState.reconcileModelSelectionsAfterSettingsDismissal()

            precondition(appState.transcriptionEnabled)
            precondition(
                appState.currentNoteBrowserTranscriptionChoice
                    == .nativeWhisper(
                        modelID: NativeWhisperModelCatalog.recommended.id
                    )
            )
        }
    }

    private static func testFreshInstallSeedsNewHiddenDefaultsOnce() async {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "hasCompletedSetup")
        defaults.removeObject(forKey: "first_install_defaults_version")

        _ = await MainActor.run { makeAppState() }

        precondition(defaults.bool(forKey: "disable_auto_paste"))
        precondition(defaults.string(forKey: "transcription_language") == "auto")
        precondition(defaults.string(forKey: "recording_overlay_layout") == "notchSides")
        precondition(defaults.string(forKey: "overlay_waveform_display_mode") == "hoverTime")
        precondition(!defaults.bool(forKey: "press_enter_voice_command_enabled"))
        precondition(defaults.integer(forKey: "first_install_defaults_version") == 1)
    }

    private static func testCompletedInstallKeepsLegacyFallbacksWhenKeysAreMissing() async {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "hasCompletedSetup")
        defaults.removeObject(forKey: "first_install_defaults_version")

        let appState = await MainActor.run { makeAppState() }

        await MainActor.run {
            precondition(!appState.disableAutoPaste)
            precondition(appState.transcriptionLanguage.code == "ko")
            precondition(appState.recordingOverlayLayout == .centered)
            precondition(appState.overlayWaveformDisplayMode == .waveformOnly)
            precondition(appState.isPressEnterVoiceCommandEnabled)
        }
        precondition(defaults.integer(forKey: "first_install_defaults_version") == 1)
    }

    private static func testStoredUserDefaultsBeatFirstInstallSeed() async {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "hasCompletedSetup")
        defaults.set(false, forKey: "disable_auto_paste")
        defaults.set("en", forKey: "transcription_language")
        defaults.set("centered", forKey: "recording_overlay_layout")
        defaults.set("timeOnly", forKey: "overlay_waveform_display_mode")
        defaults.set(true, forKey: "press_enter_voice_command_enabled")

        let appState = await MainActor.run { makeAppState() }

        await MainActor.run {
            precondition(!appState.disableAutoPaste)
            precondition(appState.transcriptionLanguage.code == "en")
            precondition(appState.recordingOverlayLayout == .centered)
            precondition(appState.overlayWaveformDisplayMode == .timeOnly)
            precondition(appState.isPressEnterVoiceCommandEnabled)
        }
    }

    private static func testPreserveExactWordingIsRemovedFromSettingsAndPipeline() throws {
        let settings = try String(contentsOfFile: "Sources/SettingsView.swift", encoding: .utf8)
        let appState = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let postProcessing = try String(contentsOfFile: "Sources/PostProcessingService.swift", encoding: .utf8)

        for obsoleteReference in [
            "Preserve Exact Wording",
            "preserveExactWording",
            "preserve_exact_wording"
        ] {
            precondition(!settings.contains(obsoleteReference), "Settings still contains \(obsoleteReference)")
            precondition(!appState.contains(obsoleteReference), "AppState still contains \(obsoleteReference)")
        }
        precondition(!postProcessing.contains("translateVerbatim"))
        precondition(!postProcessing.contains("verbatimTranslationSystemPrompt"))
    }

    private static func testLegacyMlxWhisperOptionsDefaultToOff() {
        resetDefaults()
        let appState = makeAppState()

        assert(appState.showLegacyMlxWhisperOptions == false)
        assert(appState.useLegacyMlxWhisper == false)
    }

    private static func testLegacyMlxWhisperOptionsPersistIndependentlyFromEngine() {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "show_legacy_mlx_whisper_options")
        defaults.set(false, forKey: "use_legacy_mlx_whisper")

        let appState = makeAppState()

        assert(appState.showLegacyMlxWhisperOptions == true)
        assert(appState.useLegacyMlxWhisper == false)

        appState.showLegacyMlxWhisperOptions = false

        assert(defaults.bool(forKey: "show_legacy_mlx_whisper_options") == false)
    }

    private static func testLegacyMlxWhisperOptionsFallBackToLegacyEnginePreference() {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "use_legacy_mlx_whisper")

        let appState = makeAppState()

        assert(appState.useLegacyMlxWhisper == true)
        assert(appState.showLegacyMlxWhisperOptions == true)
        assert(defaults.bool(forKey: "show_legacy_mlx_whisper_options") == true)
    }

    private static func testLegacyMlxWhisperOptionsStayVisibleWhenEngineIsTurnedOff() {
        resetDefaults()
        let appState = makeAppState()
        appState.showLegacyMlxWhisperOptions = true
        appState.useLegacyMlxWhisper = true

        appState.useLegacyMlxWhisper = false

        assert(appState.showLegacyMlxWhisperOptions == true)
        assert(appState.useLegacyMlxWhisper == false)
    }

    private static func testPermissionStatusUpdateSkipsUnchangedValues() {
        resetDefaults()
        let appState = makeAppState()
        appState.updatePermissionStatus(accessibility: true, screenRecording: true)

        var changeCount = 0
        let cancellable = appState.objectWillChange.sink { _ in
            changeCount += 1
        }

        appState.updatePermissionStatus(accessibility: true, screenRecording: true)
        cancellable.cancel()

        assert(changeCount == 0, "Expected unchanged permission status to skip publishing, got \(changeCount) updates")
    }

    private static func testRecordingOverlayLayoutPersistsWithoutCompactOverlayBoolean() {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "recording_overlay_layout")
        defaults.removeObject(forKey: "use_compact_overlay")

        let appState = makeAppState()
        appState.recordingOverlayLayout = .notchSides

        assert(defaults.string(forKey: "recording_overlay_layout") == "notchSides")
        assert(defaults.object(forKey: "use_compact_overlay") == nil)
    }

    private static func testRecordingCancelShortcutDefaultsToEscape() {
        resetDefaults()
        UserDefaults.standard.removeObject(forKey: "recording_cancel_shortcut")

        let appState = makeAppState()

        assert(appState.recordingCancelShortcut == .defaultRecordingCancel)
    }

    private static func testRecordingCancelShortcutPersistsDisabled() {
        resetDefaults()
        var appState = makeAppState()
        let validation = appState.setRecordingCancelShortcut(.disabled)
        assert(validation == nil)

        appState = makeAppState()

        assert(appState.recordingCancelShortcut == .disabled)
    }

    private static func testRecordingCancelShortcutPersistsCustomShortcut() {
        resetDefaults()
        let custom = ShortcutBinding(
            keyCode: 47,
            keyDisplay: ".",
            modifiers: .command,
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [55]
        )
        var appState = makeAppState()
        let validation = appState.setRecordingCancelShortcut(custom)
        assert(validation == nil)

        appState = makeAppState()

        assert(appState.recordingCancelShortcut == custom)
        assert(appState.savedRecordingCancelCustomShortcut == custom)
    }

    private static func testRecordingCancelShortcutDisablesDefaultWhenStoredHoldUsesEscape() {
        resetDefaults()
        let defaults = UserDefaults.standard
        let escHold = ShortcutBinding.defaultRecordingCancel
        defaults.set(try! JSONEncoder().encode(escHold), forKey: "hold_shortcut")
        defaults.removeObject(forKey: "recording_cancel_shortcut")

        let appState = makeAppState()
        let storedCancel = try! JSONDecoder().decode(
            ShortcutBinding.self,
            from: defaults.data(forKey: "recording_cancel_shortcut")!
        )

        assert(appState.holdShortcut == escHold)
        assert(appState.recordingCancelShortcut == .disabled)
        assert(storedCancel == .disabled)
    }

    private static func testRecordingCancelShortcutRejectsHoldConflict() {
        resetDefaults()
        let appState = makeAppState()

        let validation = appState.setRecordingCancelShortcut(appState.holdShortcut)

        assert(validation == "Cancel shortcut must be distinct from dictation shortcuts.")
        assert(appState.recordingCancelShortcut == .defaultRecordingCancel)
    }

    private static func testRecordingCancelShortcutRejectsPasteAgainConflict() {
        resetDefaults()
        let appState = makeAppState()
        let f5 = ShortcutPreset.f5.binding

        assert(appState.setShortcut(f5, for: .copyAgain) == nil)
        let validation = appState.setRecordingCancelShortcut(f5)

        assert(validation == "Cancel shortcut must be distinct from Paste Again.")
        assert(appState.recordingCancelShortcut == .defaultRecordingCancel)
    }

    private static func testPasteAgainShortcutRejectsRecordingCancelConflict() {
        resetDefaults()
        let appState = makeAppState()

        let validation = appState.setShortcut(.defaultRecordingCancel, for: .copyAgain)

        assert(validation == "Paste Again cannot share a shortcut with Cancel Recording.")
        assert(appState.copyAgainShortcut == .disabled)
    }

    private static func testPasteAgainShortcutReportsManualModifierCollision() {
        resetDefaults()
        let appState = makeAppState()
        _ = appState.setCommandModeEnabled(true)
        _ = appState.setCommandModeStyle(.manual)
        _ = appState.setCommandModeManualModifier(.option)

        let validation = appState.setShortcut(ShortcutPreset.rightOption.binding, for: .copyAgain)

        assert(validation == "That modifier is already the Paste Again shortcut.")
        assert(appState.copyAgainShortcut == .disabled)
    }

    private static func testHoldShortcutRejectsCancelConflict() {
        resetDefaults()
        let appState = makeAppState()

        let validation = appState.setShortcut(.defaultRecordingCancel, for: .hold)

        assert(validation == "Dictation shortcuts must be distinct from the cancel shortcut.")
        assert(appState.holdShortcut == .defaultHold)
    }

    private static func testHoldShortcutRejectsMoreSpecificCancelOverlap() {
        resetDefaults()
        let appState = makeAppState()
        let commandEsc = ShortcutBinding(
            keyCode: 53,
            keyDisplay: "Esc",
            modifiers: .command,
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [55]
        )

        let validation = appState.setShortcut(commandEsc, for: .hold)

        assert(validation == "Dictation shortcuts must be distinct from the cancel shortcut.")
        assert(appState.holdShortcut == .defaultHold)
    }

    private static func testRecordingCancelShortcutRejectsModifierOnlyOverlapWithKeyCombo() {
        resetDefaults()
        let appState = makeAppState()
        let commandOnly = ShortcutBinding(
            keyCode: 55,
            keyDisplay: "Command",
            modifiers: [],
            kind: .modifierKey,
            preset: nil,
            exactModifierKeyCodes: [55]
        )
        let commandA = ShortcutBinding(
            keyCode: 0,
            keyDisplay: "A",
            modifiers: .command,
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [55]
        )

        assert(appState.setRecordingCancelShortcut(.disabled) == nil)
        assert(appState.setShortcut(commandA, for: .hold) == nil)

        let validation = appState.setRecordingCancelShortcut(commandOnly)

        assert(validation == "Cancel shortcut must be distinct from dictation shortcuts.")
        assert(appState.recordingCancelShortcut == .disabled)
    }

    private static func testRecordingCancelShortcutRejectsMoreSpecificHoldOverlap() {
        resetDefaults()
        let appState = makeAppState()
        let commandEsc = ShortcutBinding(
            keyCode: 53,
            keyDisplay: "Esc",
            modifiers: .command,
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [55]
        )
        assert(appState.setRecordingCancelShortcut(.disabled) == nil)
        assert(appState.setShortcut(commandEsc, for: .hold) == nil)

        let validation = appState.setRecordingCancelShortcut(.defaultRecordingCancel)

        assert(validation == "Cancel shortcut must be distinct from dictation shortcuts.")
        assert(appState.recordingCancelShortcut != .defaultRecordingCancel)
    }

    private static func testRecordingCancelShortcutRejectsManualModifierRuntimeOverlap() {
        resetDefaults()
        let appState = makeAppState()
        _ = appState.setCommandModeEnabled(true)
        _ = appState.setCommandModeStyle(.manual)
        _ = appState.setCommandModeManualModifier(.option)
        let commandEsc = ShortcutBinding(
            keyCode: 53,
            keyDisplay: "Esc",
            modifiers: .command,
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [55]
        )
        let commandOptionEsc = ShortcutBinding(
            keyCode: 53,
            keyDisplay: "Esc",
            modifiers: [.command, .option],
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [55, 58]
        )

        assert(appState.setRecordingCancelShortcut(.disabled) == nil)
        assert(appState.setShortcut(commandEsc, for: .hold) == nil)

        let validation = appState.setRecordingCancelShortcut(commandOptionEsc)

        assert(validation == "Cancel shortcut must be distinct from dictation shortcuts.")
        assert(appState.recordingCancelShortcut == .disabled)
    }

    private static func testCommandModeManualModifierReportsCancelOverlap() {
        resetDefaults()
        let appState = makeAppState()
        let commandEsc = ShortcutBinding(
            keyCode: 53,
            keyDisplay: "Esc",
            modifiers: .command,
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [55]
        )
        let commandOptionEsc = ShortcutBinding(
            keyCode: 53,
            keyDisplay: "Esc",
            modifiers: [.command, .option],
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [55, 58]
        )

        assert(appState.setRecordingCancelShortcut(.disabled) == nil)
        assert(appState.setShortcut(commandEsc, for: .hold) == nil)
        assert(appState.setRecordingCancelShortcut(commandOptionEsc) == nil)
        _ = appState.setCommandModeEnabled(true)

        let validation = appState.setCommandModeStyle(.manual)

        assert(validation == "Cancel shortcut must be distinct from dictation shortcuts.")
        assert(appState.commandModeManualModifierValidationMessage == "Cancel shortcut must be distinct from dictation shortcuts.")
    }

    private static func testStoppedTranscriptionCompletionSummaryTrimsFinalTranscript() {
        let summary = StoppedTranscriptionCompletionSummary(
            rawTranscript: "raw transcript",
            finalTranscript: "  final transcript\n",
            prompt: "prompt",
            processingStatus: "Post-processing succeeded",
            shouldPressEnterAfterPaste: false,
            outcomeWasPostProcessingFailedFallback: false
        )

        precondition(summary.rawTranscript == "raw transcript")
        precondition(summary.finalTranscript == "final transcript")
        precondition(summary.prompt == "prompt")
        precondition(summary.processingStatus == "Post-processing succeeded")
        precondition(!summary.shouldPressEnterAfterPaste)
        precondition(!summary.shouldPersistRawDictationFallback)
    }

    private static func testStoppedTranscriptionCompletionSummaryShowsFallbackIndicatorForNonEmptyRawFallback() {
        let summary = StoppedTranscriptionCompletionSummary(
            rawTranscript: "raw transcript",
            finalTranscript: "raw transcript",
            prompt: "",
            processingStatus: "Post-processing failed, using raw transcript",
            shouldPressEnterAfterPaste: false,
            outcomeWasPostProcessingFailedFallback: true
        )

        precondition(summary.shouldPersistRawDictationFallback)
    }

    private static func testStoppedTranscriptionCompletionSummaryHidesFallbackIndicatorForEmptyRawFallback() {
        let summary = StoppedTranscriptionCompletionSummary(
            rawTranscript: "",
            finalTranscript: "  \n",
            prompt: "",
            processingStatus: "Skipped macros and post-processing for empty raw transcript",
            shouldPressEnterAfterPaste: true,
            outcomeWasPostProcessingFailedFallback: true
        )

        precondition(summary.finalTranscript.isEmpty)
        precondition(summary.shouldPressEnterAfterPaste)
        precondition(!summary.shouldPersistRawDictationFallback)
    }

    private static func testTimeoutFailureReasonOverridesCommandFallback() {
        let timeoutReason = AppState.aiProcessingFailureReason(
            for: PostProcessingError.requestTimedOut(20),
            fallback: "command-transform-failed"
        )
        let genericReason = AppState.aiProcessingFailureReason(
            for: URLError(.cannotConnectToHost),
            fallback: "command-transform-failed"
        )

        precondition(timeoutReason == "request-timed-out")
        precondition(genericReason == "command-transform-failed")
    }

    private static func testAppStateCreatedTranscriptionServicesPassLegacyMlxWhisperToggle() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let importBody = sourceBlock(
            in: source,
            from: "func importAudioFile(_ fileURL: URL, mode: NoteBrowserTranscriptionMode)",
            to: "\n    @MainActor\n    func retryTranscription"
        )
        let retryRequest = sourceBlock(
            in: source,
            from: "private func transcriptionRetryWorkflowRequest(",
            to: "\n    @MainActor\n    private func transcriptionRetryWorkflowRuntime"
        )
        let stoppedRecordingBody = sourceBlock(
            in: source,
            from: "let capturedUseLocalTranscription = useLocalTranscription",
            to: "\n    @MainActor\n    private func createLiveNote"
        )

        precondition(source.contains("let useLegacyMlxWhisper: Bool"))
        precondition(source.contains("useLegacyMlxWhisper: useLegacyMlxWhisper,"))
        precondition(importBody.contains("func importAudioFile(_ fileURL: URL, choice: TranscriptionBackendChoice)"))
        precondition(importBody.contains("transcriptionConfiguration: audioImportConfiguration(for: choice)"))
        precondition(importBody.contains("let transcriptionService = try configuration.makeTranscriptionService("))
        precondition(importBody.contains("cloudExecutionContext: cloudExecutionContext"))
        precondition(source.contains("self.useLegacyMlxWhisper = transcriptionConfiguration.useLegacyMlxWhisper"))
        precondition(
            retryRequest.contains(
                "useLegacyMlxWhisper: configuration.useLegacyMlxWhisper"
            )
        )
        precondition(
            retryRequest.contains(
                "nativeWhisperExecution: nativeWhisperExecutionSnapshot("
            )
        )
        precondition(stoppedRecordingBody.contains("let capturedUseLegacyMlxWhisper = useLegacyMlxWhisper"))
        precondition(stoppedRecordingBody.contains("useLegacyMlxWhisper: capturedUseLegacyMlxWhisper,"))
        guard let capture = stoppedRecordingBody.range(
            of: "let capturedNativeWhisperExecution = nativeWhisperExecutionSnapshot("
        ), let task = stoppedRecordingBody.range(
            of: "let task = Task { [weak self] in"
        ) else {
            preconditionFailure("Expected stopped Native Whisper execution capture")
        }
        precondition(capture.lowerBound < task.lowerBound)
        precondition(
            stoppedRecordingBody.contains(
                "nativeWhisperExecution: capturedNativeWhisperExecution,"
            )
        )
        precondition(
            !stoppedRecordingBody.contains(
                "capturedNativeWhisperExecution ?? .live()"
            )
        )
    }

    // Retry never re-captures context; it reuses the note's stored
    // contextSummary, gated by the CURRENT context-capture toggle and by
    // whether the stored summary is actually usable (old notes may still
    // carry the stop-time placeholder sentence).
    private static func testRetryRequestGatesStoredContextByCurrentToggleAndUsability() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let requestBody = sourceBlock(
            in: source,
            from: "private func transcriptionRetryWorkflowRequest(",
            to: "\n    @MainActor\n    private func transcriptionRetryWorkflowRuntime"
        )

        precondition(
            requestBody.contains("disableContextCapture"),
            "retry gates stored context injection by the current context toggle"
        )
        precondition(
            requestBody.contains("Self.isPlaceholderContextSummary(item.contextSummary)"),
            "retry treats a placeholder/empty stored summary as unusable"
        )
        precondition(
            requestBody.contains("QuillUserIssueRecord(code: .contextUnavailable)"),
            "retry attaches the context-unavailable warning when stored context is enabled but unusable"
        )
        guard let restoredContextRange = requestBody.range(
            of: "let restoredContext = AppContext("
        ) else {
            preconditionFailure("Expected restoredContext construction in Retry request")
        }
        guard let restoredContextEnd = requestBody.range(
            of: "let restoredIntent =",
            range: restoredContextRange.upperBound..<requestBody.endIndex
        ) else {
            preconditionFailure("Expected restoredContext to precede restoredIntent")
        }
        let restoredContextBody = String(
            requestBody[restoredContextRange.lowerBound..<restoredContextEnd.lowerBound]
        )
        precondition(
            restoredContextBody.contains("userIssueRecord:"),
            "restoredContext threads a userIssueRecord for the warning banner"
        )

        let processingBody = sourceBlock(
            in: source,
            from: "private static func processRetryTranscription(",
            to: "\n    func updatePermissionStatus"
        )
        guard let postProcessingIssueRange = processingBody.range(
            of: "result.userIssueRecord?.persistedStatus"
        ), let contextIssueRange = processingBody.range(
            of: "context.userIssueRecord?.persistedStatus",
            range: postProcessingIssueRange.upperBound..<processingBody.endIndex
        ), let normalStatusRange = processingBody.range(
            of: "statusMessage(",
            range: contextIssueRange.upperBound..<processingBody.endIndex
        ) else {
            preconditionFailure("Expected retry status fallback chain: post-processing issue, then context issue, then normal status")
        }
        precondition(postProcessingIssueRange.lowerBound < contextIssueRange.lowerBound)
        precondition(contextIssueRange.lowerBound < normalStatusRange.lowerBound)
    }

    private static func testAppStateCapturesNativeWhisperExecutionBeforeImportAndRetryTasks()
        throws {
        let source = try String(
            contentsOfFile: "Sources/AppState.swift",
            encoding: .utf8
        )
        let importBody = sourceBlock(
            in: source,
            from: "func importAudioFile(_ fileURL: URL, choice:",
            to: "\n    @MainActor\n    func retryTranscription"
        )
        let retryRequest = sourceBlock(
            in: source,
            from: "private func transcriptionRetryWorkflowRequest(",
            to: "\n    @MainActor\n    private func transcriptionRetryWorkflowRuntime"
        )

        guard let importCapture = importBody.range(
            of: "nativeWhisperExecution: nativeWhisperExecutionSnapshot(for: choice)"
        ), let importTask = importBody.range(of: "Task { [weak self] in") else {
            preconditionFailure("Expected Native Whisper import capture before Task")
        }
        precondition(importCapture.lowerBound < importTask.lowerBound)
        precondition(
            retryRequest.contains(
                "nativeWhisperExecution: nativeWhisperExecutionSnapshot("
            )
        )
    }

    private static func testNoteBrowserTranscriptionMenuUsesFlatNativeCheckedItems() throws {
        let source = try String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)
        guard let itemStart = source.range(of: "private func transcriptionChoiceMenuItem")?.lowerBound,
              let itemEnd = source.range(of: "\n    private func transcriptionChoiceDisplays", range: itemStart..<source.endIndex)?.lowerBound else {
            preconditionFailure("Expected transcription choice menu item block")
        }
        let menuItemSource = String(source[itemStart..<itemEnd])

        precondition(source.contains("ForEach(transcriptionChoiceDisplays(in: \"Cloud\"))"))
        precondition(source.contains("ForEach(transcriptionChoiceDisplays(in: \"On This Mac\"))"))
        precondition(!source.contains("transcriptionChoiceDisplays(in: \"Legacy mlx-whisper\")"))
        precondition(menuItemSource.contains("Toggle(isOn: Binding<Bool>("))
        precondition(menuItemSource.contains("appState.transcriptionEnabled"))
        precondition(menuItemSource.contains("appState.currentNoteBrowserTranscriptionChoice == display.choice"))
        precondition(menuItemSource.contains("appState.setNoteBrowserTranscriptionSelection(display.choice)"))
        precondition(
            menuItemSource.contains(
                ".disabled(!appState.isNoteBrowserTranscriptionChoiceReady(display.choice))"
            )
        )
        precondition(!menuItemSource.contains(".disabled(!display.isAvailable)"))
        precondition(source.contains("appState.setNoteBrowserTranscriptionSelection(nil)"))
        precondition(source.contains("localizedCatalogString(\"Off\")"))
        precondition(!menuItemSource.contains("Picker(\"Transcription\", selection:"))
        precondition(!menuItemSource.contains("Image(systemName: \"checkmark\")"))
    }

    private static func testAudioImportConfigurationUsesChoiceDerivedBackend() async {
        resetDefaults()
        await MainActor.run {
            let appState = makeAppState()
            let legacyModel = TranscriptionModel.find(id: "mlx-community/whisper-medium-mlx")

            let nativeConfiguration = appState.audioImportConfiguration(for: .nativeWhisper(modelID: NativeWhisperModelCatalog.recommended.id))
            precondition(nativeConfiguration.mode == .localWhisper)
            precondition(nativeConfiguration.useLocalTranscription)
            precondition(!nativeConfiguration.useLegacyMlxWhisper)
            precondition(nativeConfiguration.localTranscriptionModel.id == "mlx-community/whisper-large-v3-turbo")

            let legacyConfiguration = appState.audioImportConfiguration(for: .legacyMlxWhisper(model: legacyModel))
            precondition(legacyConfiguration.mode == .localWhisper)
            precondition(legacyConfiguration.useLocalTranscription)
            precondition(legacyConfiguration.useLegacyMlxWhisper)
            precondition(legacyConfiguration.localTranscriptionModel.id == legacyModel.id)
        }
    }

    private static func testInitialAudioImportUsesChoiceConfiguration() throws {
        let appStateSource = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let importBody = sourceBlock(
            in: appStateSource,
            from: "func importAudioFile(_ fileURL: URL, mode: NoteBrowserTranscriptionMode)",
            to: "\n    @MainActor\n    func retryTranscription"
        )
        precondition(importBody.contains("func importAudioFile(_ fileURL: URL, choice: TranscriptionBackendChoice)"))
        precondition(importBody.contains("transcriptionConfiguration: audioImportConfiguration(for: choice)"))
        precondition(!importBody.contains("useLegacyMlxWhisper: useLegacyMlxWhisper,"))
        precondition(!importBody.contains("allowsNativeWhisper"))

        let noteBrowserSource = try String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)
        let pickerBody = sourceBlock(
            in: noteBrowserSource,
            from: "private func showAudioImportPicker()",
            to: "\n    private var emptyListState"
        )
        precondition(pickerBody.contains("currentChoice: appState.currentNoteBrowserTranscriptionChoice"))
        precondition(pickerBody.contains("hasNativeLocalWhisperModel: appState.hasNativeLocalWhisperModel"))
        precondition(pickerBody.contains("legacyLocalWhisperModels: appState.installedLegacyLocalWhisperModels"))
        precondition(!pickerBody.contains("hasLocalWhisperModel: appState.hasInstalledLocalWhisperModel"))
    }

    private static func testAudioImportSheetUsesChoiceDisplayRows() throws {
        let source = try String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)
        let sheetBody = sourceBlock(
            in: source,
            from: "private struct AudioImportSheet",
            to: "private func transcriptionChoiceMenuItem"
        )

        precondition(sheetBody.contains("ForEach(options.displayRows)"))
        precondition(sheetBody.contains("@State private var selectedChoice: TranscriptionBackendChoice"))
        precondition(sheetBody.contains("onImport: (TranscriptionBackendChoice) -> Void"))
        precondition(sheetBody.contains("Text(display.localizedTitle())"))
        precondition(sheetBody.contains("Text(display.localizedUnavailableReason() ?? unavailableReason)"))
        precondition(sheetBody.contains("onOpenProviderSettings: () -> Void"))
        precondition(sheetBody.contains("options.isChoiceReady(selectedChoice)"))
        precondition(sheetBody.contains("Open Provider Settings"))
        precondition(!sheetBody.contains("[NoteBrowserTranscriptionMode.apiStandard, .localWhisper]"))
        precondition(!sheetBody.contains("appState.audioImportLabel(for:"))
    }

    private static func testCloudTranscriptionActionsRequireProviderConfiguration() throws {
        let source = try String(
            contentsOfFile: "Sources/AppState.swift",
            encoding: .utf8
        )
        let importBody = sourceBlock(
            in: source,
            from: "func importAudioFile(_ fileURL: URL, choice: TranscriptionBackendChoice)",
            to: "\n    @MainActor\n    func noteBrowserStoredAudioURL"
        )
        let retryBody = sourceBlock(
            in: source,
            from: "func retryTranscription(item: PipelineHistoryItem)",
            to: "\n    @MainActor\n    private func copyRetryTranscriptToPasteboardIfNeeded"
        )

        guard let importGuard = importBody.range(
            of: "guard !choice.usesCloudAPI || hasTranscriptionAPIKey else"
        ), let importConfiguration = importBody.range(
            of: "let configuration = AudioImportTaskConfiguration("
        ) else {
            preconditionFailure("Expected import provider readiness guard")
        }
        precondition(importGuard.lowerBound < importConfiguration.lowerBound)
        precondition(importBody.contains("openProviderSettings()"))

        guard let retryGuard = retryBody.range(
            of: "guard noteBrowserRetryAvailability(for: item) == .ready else"
        ), let retryRequest = retryBody.range(
            of: "let request = try transcriptionRetryWorkflowRequest(for: item)"
        ) else {
            preconditionFailure("Expected retry readiness guard")
        }
        precondition(retryGuard.lowerBound < retryRequest.lowerBound)
        precondition(!retryBody.contains("openProviderSettings()"))
    }

    private static func testRecordingStartRequiresProviderConfigurationBeforePermissions() throws {
        let source = try String(
            contentsOfFile: "Sources/AppState.swift",
            encoding: .utf8
        )
        let preflight = sourceBlock(
            in: source,
            from: "private func prepareRecordingStart(",
            to: "\n    static func currentSpeechRecognitionAuthorizationStatus"
        )

        guard let providerChoiceCheck = preflight.range(
            of: "guard !currentNoteBrowserTranscriptionChoice.usesCloudAPI"
        ), let providerKeyCheck = preflight.range(
            of: "|| hasTranscriptionAPIKey else"
        ), let accessibilityCheck = preflight.range(
            of: "let isAccessibilityTrusted = AXIsProcessTrusted()"
        ) else {
            preconditionFailure("Expected recording provider readiness guard")
        }
        precondition(providerChoiceCheck.lowerBound < providerKeyCheck.lowerBound)
        precondition(providerKeyCheck.lowerBound < accessibilityCheck.lowerBound)
        precondition(preflight.contains("QuillUserIssueRecord(code: .providerConfigurationInvalid)"))
        precondition(preflight.contains("openProviderSettings()"))
        precondition(preflight.contains("return false"))
    }

    private static func testNoteBrowserTranscriptionChoiceDisplayIncludesResolvedModels() async {
        resetDefaults()
        await MainActor.run {
            let appState = makeAppState()
            appState.transcriptionModel = "whisper-large-v3-turbo"
            appState.realtimeStreamingModel = ""

            let apiDisplay = appState.noteBrowserTranscriptionDisplay(for: .apiStandard(modelID: appState.transcriptionModel))
            precondition(apiDisplay.section == "Cloud")
            precondition(apiDisplay.title == "Standard")
            precondition(apiDisplay.currentLabel == "Cloud · Standard · whisper-large-v3-turbo")

            let realtimeDisplay = appState.noteBrowserTranscriptionDisplay(for: .apiRealtime(modelID: nil))
            precondition(realtimeDisplay.section == "Cloud")
            precondition(realtimeDisplay.title == "Realtime")
            precondition(realtimeDisplay.currentLabel == "Cloud · Realtime · Provider default")

            let nativeDisplay = appState.noteBrowserTranscriptionDisplay(for: .nativeWhisper(modelID: NativeWhisperModelCatalog.recommended.id))
            precondition(nativeDisplay.section == "On This Mac")
            precondition(nativeDisplay.title == "Native Whisper")
            precondition(nativeDisplay.currentLabel == "On This Mac · Native Whisper · Whisper Large v3 Turbo")

            let legacyModel = TranscriptionModel.find(id: "mlx-community/whisper-medium-mlx")
            let legacyDisplay = appState.noteBrowserTranscriptionDisplay(for: .legacyMlxWhisper(model: legacyModel))
            precondition(legacyDisplay.section == "On This Mac")
            precondition(legacyDisplay.title == "Legacy mlx-whisper")
            precondition(legacyDisplay.currentLabel == "On This Mac · Legacy · Whisper Medium")

            let appleDisplay = appState.noteBrowserTranscriptionDisplay(for: .appleLive)
            precondition(appleDisplay.section == "On This Mac")
            precondition(appleDisplay.title == "Apple Live")
            precondition(appleDisplay.currentLabel == "On This Mac · Apple Live · Apple Speech")

            appState.useLocalTranscription = false
            appState.realtimeStreamingEnabled = false
            precondition(appState.noteBrowserTranscriptionChoiceLabel == "Standard")
            precondition(appState.noteBrowserTranscriptionChoiceDetailLabel == "Cloud · Standard · whisper-large-v3-turbo")
        }
    }

    private static func testNoteBrowserTranscriptionChoiceSetterUpdatesLocalBackend() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let applyChoiceBody = sourceBlock(
            in: source,
            from: "private func applyNoteBrowserTranscriptionChoice(_ choice: TranscriptionBackendChoice)",
            to: "\n    @MainActor\n    func setGoogleCalendarSelected"
        )
        let nativeBranch = sourceBlock(
            in: applyChoiceBody,
            from: "case .nativeWhisper:",
            to: "        case .legacyMlxWhisper"
        )
        let legacyBranch = sourceBlock(
            in: applyChoiceBody,
            from: "case .legacyMlxWhisper(let model):",
            to: "        case .appleLive:"
        )

        precondition(nativeBranch.contains("update(\\AppState.useLocalTranscription, to: true)"))
        precondition(nativeBranch.contains("update(\\AppState.realtimeStreamingEnabled, to: false)"))
        precondition(nativeBranch.contains("update(\\AppState.localTranscriptionModel, to: nativeLocalWhisperSelectionModel)"))
        precondition(nativeBranch.contains("update(\\AppState.useLegacyMlxWhisper, to: false)"))
        precondition(legacyBranch.contains("update(\\AppState.useLocalTranscription, to: true)"))
        precondition(legacyBranch.contains("update(\\AppState.realtimeStreamingEnabled, to: false)"))
        precondition(legacyBranch.contains("update(\\AppState.localTranscriptionModel, to: model)"))
        precondition(legacyBranch.contains("update(\\AppState.useLegacyMlxWhisper, to: true)"))
        precondition(legacyBranch.contains("update(\\AppState.showLegacyMlxWhisperOptions, to: true)"))
    }

    private final class NativeWhisperModelDependencyHarness: @unchecked Sendable {
        private let lock = NSLock()
        private var status: NativeWhisperInstallStatus
        private var deleted: [NativeWhisperModel] = []

        init(status: NativeWhisperInstallStatus) {
            self.status = status
        }

        var deletedModels: [NativeWhisperModel] {
            lock.withLock { deleted }
        }

        func installStatus(
            for model: NativeWhisperModel
        ) -> NativeWhisperInstallStatus {
            lock.withLock { status }
        }

        func setStatus(_ status: NativeWhisperInstallStatus) {
            lock.withLock { self.status = status }
        }

        func deleteModel(_ model: NativeWhisperModel) throws {
            lock.withLock {
                deleted.append(model)
                status = .notInstalled
            }
        }
    }

    private final class NativeWhisperInstallHarness: @unchecked Sendable {
        var progress: ((NativeWhisperDownloadProgress) -> Void)?
        var completion: ((Result<Void, NativeWhisperInstallerError>) -> Void)?
        private(set) var task = NativeWhisperInstallTask()

        func start(
            model: NativeWhisperModel,
            progress: @escaping (NativeWhisperDownloadProgress) -> Void,
            completion: @escaping (Result<Void, NativeWhisperInstallerError>) -> Void
        ) -> NativeWhisperInstallTask {
            self.progress = progress
            self.completion = completion
            return task
        }
    }

    private struct NativeWhisperInstallFixture {
        let installer: NativeWhisperInstallHarness
        let status: NativeWhisperModelDependencyHarness
        let appState: AppState
    }

    private static func makeNativeWhisperInstallFixture()
        -> NativeWhisperInstallFixture {
        let installer = NativeWhisperInstallHarness()
        let status = NativeWhisperModelDependencyHarness(
            status: .notInstalled
        )
        var dependencies = transcriptionTestDependencies(
            status: { status.installStatus(for: $0) }
        )
        dependencies.nativeWhisper.startInstall = {
            installer.start(
                model: $0,
                progress: $1,
                completion: $2
            )
        }
        return NativeWhisperInstallFixture(
            installer: installer,
            status: status,
            appState: makeAppState(dependencies: dependencies)
        )
    }

    private static func testNativeWhisperInstallLeavesAppleActiveUntilCompletion() async {
        resetDefaults()
        let fixture = makeNativeWhisperInstallFixture()

        await MainActor.run {
            fixture.appState.setNoteBrowserTranscriptionChoice(.appleLive)
            fixture.appState.installNativeWhisperModel(autoSelectWhenReady: true)

            precondition(fixture.appState.currentNoteBrowserTranscriptionChoice == .appleLive)
            precondition(fixture.appState.willAutoSelectNativeWhisperWhenReady)
            precondition(fixture.appState.isInstallingNativeWhisper)
        }
    }

    private static func testInstallCallWhileAlreadyInstallingStillArmsAutoSelection() async {
        resetDefaults()
        let fixture = makeNativeWhisperInstallFixture()

        await MainActor.run {
            fixture.appState.setNoteBrowserTranscriptionChoice(.appleLive)
            fixture.appState.installNativeWhisperModel(autoSelectWhenReady: false)
            fixture.appState.cancelNativeWhisperAutoSelection()
            precondition(fixture.appState.isInstallingNativeWhisper)
            precondition(!fixture.appState.willAutoSelectNativeWhisperWhenReady)

            fixture.appState.installNativeWhisperModel(autoSelectWhenReady: true)

            precondition(fixture.appState.isInstallingNativeWhisper)
            precondition(fixture.appState.willAutoSelectNativeWhisperWhenReady)
        }
    }

    private static func testNativeWhisperInstallAutoSelectsOnSuccess() async {
        resetDefaults()
        let fixture = makeNativeWhisperInstallFixture()

        await MainActor.run {
            fixture.appState.setNoteBrowserTranscriptionChoice(.appleLive)
            fixture.appState.installNativeWhisperModel(autoSelectWhenReady: true)
        }

        fixture.status.setStatus(.ready)
        fixture.installer.completion?(.success(()))
        await waitUntil { !fixture.appState.isInstallingNativeWhisper }

        await MainActor.run {
            precondition(
                fixture.appState.currentNoteBrowserTranscriptionChoice
                    == .nativeWhisper(modelID: NativeWhisperModelCatalog.recommended.id)
            )
            precondition(!fixture.appState.willAutoSelectNativeWhisperWhenReady)
        }
    }

    private static func testExplicitBackendChoiceCancelsAutoSelectionOnly() async {
        resetDefaults()
        let fixture = makeNativeWhisperInstallFixture()

        await MainActor.run {
            fixture.appState.apiKey = "test-api-key"
            fixture.appState.setNoteBrowserTranscriptionChoice(.appleLive)
            fixture.appState.installNativeWhisperModel(autoSelectWhenReady: true)
            fixture.appState.cancelNativeWhisperAutoSelection()
            fixture.appState.setNoteBrowserTranscriptionChoice(
                .apiStandard(modelID: "custom-model")
            )

            precondition(fixture.appState.isInstallingNativeWhisper)
            precondition(!fixture.appState.willAutoSelectNativeWhisperWhenReady)
        }

        fixture.status.setStatus(.ready)
        fixture.installer.completion?(.success(()))
        await waitUntil { !fixture.appState.isInstallingNativeWhisper }

        await MainActor.run {
            precondition(
                fixture.appState.currentNoteBrowserTranscriptionChoice
                    == .apiStandard(modelID: "custom-model")
            )
            precondition(!fixture.appState.willAutoSelectNativeWhisperWhenReady)
        }
    }

    private static func testNativeWhisperCancellationClearsAutoSelection() async {
        resetDefaults()
        let fixture = makeNativeWhisperInstallFixture()

        await MainActor.run {
            fixture.appState.setNoteBrowserTranscriptionChoice(.appleLive)
            fixture.appState.installNativeWhisperModel(autoSelectWhenReady: true)
            precondition(fixture.appState.willAutoSelectNativeWhisperWhenReady)

            fixture.appState.cancelNativeWhisperInstall()

            precondition(!fixture.appState.willAutoSelectNativeWhisperWhenReady)
            precondition(fixture.appState.nativeWhisperInstallProgress.isCancelled)
        }
    }

    private static func testAppStateInstancesKeepIndependentNativeWhisperEnvironments() async {
        resetDefaults()
        var readyDependencies = transcriptionTestDependencies()
        readyDependencies.nativeWhisper.installStatus = { _ in .ready }
        var missingDependencies = transcriptionTestDependencies()
        missingDependencies.nativeWhisper.installStatus = { _ in .notInstalled }

        let instances = await MainActor.run {
            (
                AppState(dependencies: readyDependencies),
                AppState(dependencies: missingDependencies)
            )
        }

        await MainActor.run {
            precondition(instances.0.hasNativeLocalWhisperModel)
            precondition(!instances.1.hasNativeLocalWhisperModel)
        }
    }

    private static func testNativeWhisperDeletionUsesOriginatingDependency() async {
        resetDefaults()
        let harness = NativeWhisperModelDependencyHarness(status: .ready)
        var dependencies = transcriptionTestDependencies()
        dependencies.nativeWhisper.installStatus = harness.installStatus
        dependencies.nativeWhisper.deleteModel = harness.deleteModel

        let appState = await MainActor.run {
            AppState(dependencies: dependencies)
        }
        await MainActor.run {
            precondition(appState.hasNativeLocalWhisperModel)
            appState.deleteNativeWhisperModel()
            precondition(!appState.hasNativeLocalWhisperModel)
        }
        precondition(harness.deletedModels == [.recommended])
    }

    private static func testSetupProcessingPresetsPreserveProviderConfiguration() async {
        resetDefaults()
        var dependencies = transcriptionTestDependencies(status: { _ in .ready })

        await MainActor.run {
            let appState = makeAppState(dependencies: dependencies)
            appState.apiKey = "shared-api-key"
            appState.apiBaseURL = "https://provider.example.com/openai/v1"
            appState.transcriptionAPIKey = "transcription-override"
            appState.transcriptionAPIURL = "https://transcription.example.com/v1"
            appState.transcriptionModel = "custom-transcription-model"
            appState.postProcessingModel = "custom-post-processing-model"
            appState.postProcessingFallbackModel = "custom-fallback-model"
            appState.contextModel = "custom-context-model"
            appState.customVocabulary = "preserve this"
            appState.holdShortcut = .disabled

            let expectedProviderState = (
                apiKey: appState.apiKey,
                apiBaseURL: appState.apiBaseURL,
                transcriptionAPIKey: appState.transcriptionAPIKey,
                transcriptionAPIURL: appState.transcriptionAPIURL,
                transcriptionModel: appState.transcriptionModel,
                postProcessingModel: appState.postProcessingModel,
                postProcessingFallbackModel: appState.postProcessingFallbackModel,
                contextModel: appState.contextModel,
                customVocabulary: appState.customVocabulary,
                holdShortcut: appState.holdShortcut
            )

            appState.applySetupProcessingPreset(.localAppleSpeech)
            precondition(appState.currentNoteBrowserTranscriptionChoice == .appleLive)
            precondition(appState.disablePostProcessing)
            precondition(appState.disableContextCapture)
            assertProviderState(appState, equals: expectedProviderState)

            appState.applySetupProcessingPreset(.localNativeWhisper)
            precondition(
                appState.currentNoteBrowserTranscriptionChoice
                    == .nativeWhisper(modelID: NativeWhisperModelCatalog.recommended.id)
            )
            precondition(appState.disablePostProcessing)
            precondition(appState.disableContextCapture)
            assertProviderState(appState, equals: expectedProviderState)

            appState.applySetupProcessingPreset(.apiStandard)
            precondition(
                appState.currentNoteBrowserTranscriptionChoice
                    == .apiStandard(modelID: "custom-transcription-model")
            )
            precondition(!appState.disablePostProcessing)
            precondition(!appState.disableContextCapture)
            assertProviderState(appState, equals: expectedProviderState)

            appState.disablePostProcessing = false
            appState.disableContextCapture = true
            appState.applySetupProcessingPreset(.recordOnly)
            precondition(!appState.transcriptionEnabled)
            precondition(!appState.disablePostProcessing)
            precondition(appState.disableContextCapture)
        }
    }

    private static func assertProviderState(
        _ appState: AppState,
        equals expected: (
            apiKey: String,
            apiBaseURL: String,
            transcriptionAPIKey: String,
            transcriptionAPIURL: String,
            transcriptionModel: String,
            postProcessingModel: String,
            postProcessingFallbackModel: String,
            contextModel: String,
            customVocabulary: String,
            holdShortcut: ShortcutBinding
        )
    ) {
        precondition(appState.apiKey == expected.apiKey)
        precondition(appState.apiBaseURL == expected.apiBaseURL)
        precondition(appState.transcriptionAPIKey == expected.transcriptionAPIKey)
        precondition(appState.transcriptionAPIURL == expected.transcriptionAPIURL)
        precondition(appState.transcriptionModel == expected.transcriptionModel)
        precondition(appState.postProcessingModel == expected.postProcessingModel)
        precondition(appState.postProcessingFallbackModel == expected.postProcessingFallbackModel)
        precondition(appState.contextModel == expected.contextModel)
        precondition(appState.customVocabulary == expected.customVocabulary)
        precondition(appState.holdShortcut == expected.holdShortcut)
    }

    private static func testSetupProcessingPresetUsesExistingChoiceSetter() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let body = sourceBlock(
            in: source,
            from: "func applySetupProcessingPreset(_ preset: SetupFlow.ProcessingPreset)",
            to: "\n\n    private func scheduleNoteBrowserTranscriptionModeNormalizationForSelectedInput()"
        )

        precondition(body.contains("setNoteBrowserTranscriptionChoice(.appleLive)"))
        precondition(body.contains("setNoteBrowserTranscriptionChoice("))
        precondition(body.contains(".nativeWhisper(modelID: NativeWhisperModelCatalog.recommended.id)"))
        precondition(body.contains(".apiStandard(modelID: transcriptionModel)"))
        precondition(!body.contains("apiKey = \"\""))
        precondition(!body.contains("transcriptionAPIKey = \"\""))
        precondition(!body.contains("transcriptionAPIURL = \"\""))
    }

    private static func testNormalizationGuardsStayInsideMainActorIsolation() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let selectedInputScheduler = sourceBlock(
            in: source,
            from: "private func scheduleNoteBrowserTranscriptionModeNormalizationForSelectedInput()",
            to: "\n    private func scheduleNoteBrowserTranscriptionModeNormalizationForProviderConfiguration()"
        )
        let providerScheduler = sourceBlock(
            in: source,
            from: "private func scheduleNoteBrowserTranscriptionModeNormalizationForProviderConfiguration()",
            to: "\n    @MainActor\n    private func normalizeNoteBrowserTranscriptionMode()"
        )
        let legacyObserver = sourceBlock(
            in: source,
            from: "@Published var useLegacyMlxWhisper: Bool",
            to: "\n\n    @Published var showLegacyMlxWhisperOptions"
        )

        precondition(!selectedInputScheduler.contains("guard !isApplyingNoteBrowserTranscriptionChoice else { return }\n        if Thread.isMainThread"))
        precondition(selectedInputScheduler.contains("MainActor.assumeIsolated {\n                guard transcriptionEnabled,\n                      !isApplyingNoteBrowserTranscriptionChoice else { return }"))
        precondition(selectedInputScheduler.contains("guard let self,\n                      self.transcriptionEnabled,\n                      !self.isApplyingNoteBrowserTranscriptionChoice else { return }"))
        precondition(!providerScheduler.contains("guard !isApplyingNoteBrowserTranscriptionChoice else { return }\n        if Thread.isMainThread"))
        precondition(providerScheduler.contains("MainActor.assumeIsolated {\n                guard transcriptionEnabled,\n                      !isApplyingNoteBrowserTranscriptionChoice,"))
        precondition(providerScheduler.contains("guard let self,\n                      self.transcriptionEnabled,\n                      !self.isApplyingNoteBrowserTranscriptionChoice,"))
        precondition(!legacyObserver.contains("!isApplyingNoteBrowserTranscriptionChoice"))
    }

    private static func testAPITranscriptionModesRemainSelectableWithoutResolvedAPIKey() async {
        resetDefaults()
        await MainActor.run {
            let appState = makeAppState()

            precondition(appState.isNoteBrowserTranscriptionModeAvailable(.apiStandard))
            precondition(appState.isNoteBrowserTranscriptionModeAvailable(.apiRealtime))
            precondition(!appState.isNoteBrowserTranscriptionModeAvailable(.localWhisper))
            precondition(appState.isNoteBrowserTranscriptionModeAvailable(.localAppleLive))

            appState.setNoteBrowserTranscriptionMode(.apiStandard)
            precondition(appState.currentNoteBrowserTranscriptionMode == .apiStandard)
            precondition(
                !appState.isNoteBrowserTranscriptionChoiceReady(
                    appState.currentNoteBrowserTranscriptionChoice
                )
            )

            appState.setNoteBrowserTranscriptionMode(.apiRealtime)
            precondition(appState.currentNoteBrowserTranscriptionMode == .apiRealtime)
            precondition(
                !appState.isNoteBrowserTranscriptionChoiceReady(
                    appState.currentNoteBrowserTranscriptionChoice
                )
            )
        }
    }

    private static func testSettingsModelFirstTranscriptionUsesExistingChoiceSetter() throws {
        let source = try String(contentsOfFile: "Sources/SettingsView.swift", encoding: .utf8)
        let models = sourceBlock(
            in: source,
            from: "struct ModelsSettingsView",
            to: "// MARK: - Shortcuts Settings"
        )

        precondition(!models.contains("showingLocalTranscriptionSettings"))
        precondition(!models.contains("Picker(\"Transcription Mode\""))
        precondition(models.contains("private var transcriptionChoiceDisplays: [TranscriptionChoiceDisplay]"))
        precondition(models.contains("appState.standardAPIModelIDs.map"))
        precondition(models.contains("appState.showRealtimeTranscriptionOption || appState.realtimeStreamingEnabled"))
        precondition(models.contains("appState.showLegacyMlxWhisperOptions"))
        precondition(models.contains("appState.noteBrowserTranscriptionDisplay(for: .apiStandard(modelID: modelID))"))
        precondition(models.contains("private var transcriptionChoice: Binding<TranscriptionBackendChoice>"))
        precondition(models.contains("get: { transcriptionEnabledDraft }"))
        precondition(models.contains("transcriptionEnabledDraft = newValue"))
        precondition(models.contains("get: { settingsTranscriptionChoice }"))
        precondition(models.contains("set: { handleTranscriptionChoiceSelection($0) }"))
        precondition(models.contains("Picker(\"Model\", selection: transcriptionChoice)"))
        precondition(models.contains("@State private var pendingNativeModelID: String?"))
        precondition(models.contains("NativeWhisperModelCatalog.all.map"))
        precondition(models.contains("handleTranscriptionChoiceSelection($0)"))
        precondition(!models.contains("private var transcriptionChoiceMenu"))
        let customStandardAPI = sourceBlock(
            in: models,
            from: "private var standardAPITranscriptionSetting: some View",
            to: "\n    private var realtimeTranscriptionSetting"
        )
        precondition(customStandardAPI.contains("TextField(\"e.g. custom-transcription-model\", text: $transcriptionModelDraft)"))
        precondition(models.contains("transcriptionModelDraft = customStandardAPIModelDraft(for: appState.transcriptionModel)"))
        precondition(models.contains(".onChange(of: appState.transcriptionModel)"))
        precondition(models.contains("transcriptionModelDraft = customStandardAPIModelDraft(for: resolved)"))
        precondition(!customStandardAPI.contains("TextField(AppState.defaultTranscriptionModel"))
        precondition(!customStandardAPI.contains("ModelDropdownView("))
        precondition(!models.contains("Required · Always On"))
        precondition(!models.contains("isOn: $appState.realtimeStreamingEnabled"))
        precondition(!models.contains("appState.useLocalTranscription ="))
        precondition(!models.contains("appState.useLegacyMlxWhisper ="))
    }

    private static func testSettingsLegacyManagementKeepsExistingModelRows() throws {
        let source = try String(contentsOfFile: "Sources/SettingsView.swift", encoding: .utf8)
        let models = sourceBlock(
            in: source,
            from: "struct ModelsSettingsView",
            to: "// MARK: - Shortcuts Settings"
        )

        precondition(models.contains("isOn: $appState.showLegacyMlxWhisperOptions"))
        precondition(models.contains("ForEach(TranscriptionModel.all.filter { !$0.isAppleSpeech })"))
        precondition(models.contains("appState.setNoteBrowserTranscriptionChoice(.legacyMlxWhisper(model: model))"))
        precondition(models.contains("showsSelectionControl: false"))
        precondition(models.contains("onDeleted:"))
        precondition(models.contains(".nativeWhisper(modelID: NativeWhisperModelCatalog.recommended.id)"))
        precondition(!models.contains("TranscriptionModel.find(id: \"apple-speech\")"))
    }

    private static func testSettingsGlobalAPIKeyCanBeCleared() throws {
        let source = try String(contentsOfFile: "Sources/SettingsView.swift", encoding: .utf8)
        let providerSection = sourceBlock(
            in: source,
            from: "private var cloudProviderSection: some View",
            to: "\n    private var transcriptionFeatureSection"
        )
        let saveKeyBody = sourceBlock(
            in: source,
            from: "private func validateAndSaveKey()",
            to: "\n    // MARK: System Prompt"
        )
        guard let emptyKeyRange = saveKeyBody.range(of: "if key.isEmpty"),
              let validationRange = saveKeyBody.range(of: "TranscriptionService.validateAPIKey") else {
            preconditionFailure("Expected global API key clear branch before validation")
        }

        precondition(emptyKeyRange.lowerBound < validationRange.lowerBound)
        precondition(saveKeyBody.contains("appState.apiKey = \"\""))
        precondition(providerSection.contains(".disabled(isValidatingKey)"))
        precondition(!providerSection.contains(".disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidatingKey)"))
        precondition(providerSection.contains("API Key configured"))
        precondition(!providerSection.contains("API Key not configured"))
        precondition(providerSection.contains("Validating..."))
    }

    private static func testTranscriptionAPIKeyEnablesAPIModesWithoutGlobalAPIKey() async {
        resetDefaults()
        await MainActor.run {
            let appState = makeAppState()
            appState.transcriptionAPIKey = "transcription-key"

            precondition(appState.isNoteBrowserTranscriptionModeAvailable(.apiStandard))
            precondition(appState.isNoteBrowserTranscriptionModeAvailable(.apiRealtime))

            appState.setNoteBrowserTranscriptionMode(.apiRealtime)
            precondition(appState.currentNoteBrowserTranscriptionMode == .apiRealtime)
            precondition(
                appState.isNoteBrowserTranscriptionChoiceReady(
                    appState.currentNoteBrowserTranscriptionChoice
                )
            )
        }
    }

    private static func testEmptyTranscriptionAPIKeyFallsBackToGlobalAPIKey() async {
        resetDefaults()
        await MainActor.run {
            let appState = makeAppState()
            appState.apiKey = "global-key"
            appState.transcriptionAPIKey = "  "

            precondition(appState.isNoteBrowserTranscriptionModeAvailable(.apiStandard))
            precondition(appState.isNoteBrowserTranscriptionModeAvailable(.apiRealtime))
            precondition(
                appState.isNoteBrowserTranscriptionChoiceReady(
                    .apiStandard(modelID: AppState.defaultTranscriptionModel)
                )
            )
        }
    }

    private static func testRemovingAPIKeyPreservesSelectedAPIMode() async {
        resetDefaults()
        await MainActor.run {
            let appState = makeAppState()
            appState.apiKey = "global-key"
            appState.setNoteBrowserTranscriptionMode(.apiStandard)
            precondition(appState.currentNoteBrowserTranscriptionMode == .apiStandard)
            precondition(
                appState.isNoteBrowserTranscriptionChoiceReady(
                    appState.currentNoteBrowserTranscriptionChoice
                )
            )

            appState.apiKey = ""

            precondition(appState.currentNoteBrowserTranscriptionMode == .apiStandard)
            precondition(!appState.useLocalTranscription)
            precondition(
                !appState.isNoteBrowserTranscriptionChoiceReady(
                    appState.currentNoteBrowserTranscriptionChoice
                )
            )
        }
    }

    private static func testRemovingAPIKeyPreservesSelectedAPIModeWhileRecording() async {
        resetDefaults()
        await MainActor.run {
            let appState = makeAppState()
            appState.apiKey = "global-key"
            appState.setNoteBrowserTranscriptionMode(.apiRealtime)
            precondition(appState.currentNoteBrowserTranscriptionMode == .apiRealtime)

            appState.isRecording = true
            appState.apiKey = ""

            precondition(appState.currentNoteBrowserTranscriptionMode == .apiRealtime)
            precondition(!appState.useLocalTranscription)
            precondition(appState.realtimeStreamingEnabled)
            precondition(
                !appState.isNoteBrowserTranscriptionChoiceReady(
                    appState.currentNoteBrowserTranscriptionChoice
                )
            )
        }
    }

    private static func testSystemDefaultAndSystemAudioConvertsAPIRealtimeToStandard() async {
        resetDefaults()
        await MainActor.run {
            let appState = makeAppState()
            appState.apiKey = "global-key"
            appState.setNoteBrowserTranscriptionMode(.apiRealtime)
            precondition(appState.currentNoteBrowserTranscriptionMode == .apiRealtime)

            appState.selectedMicrophoneID = AudioInputDevice.systemDefaultAndSystemAudioID

            precondition(appState.currentNoteBrowserTranscriptionMode == .apiStandard)
            precondition(!appState.useLocalTranscription)
            precondition(!appState.realtimeStreamingEnabled)
        }
    }

    private static func testSystemDefaultAndSystemAudioTurnsOffWithoutReadyFallback() async {
        resetDefaults()
        await MainActor.run {
            let appState = makeAppState()
            appState.setNoteBrowserTranscriptionMode(.localAppleLive)
            appState.transcriptionEnabled = true
            precondition(appState.currentNoteBrowserTranscriptionMode == .localAppleLive)

            appState.selectedMicrophoneID = AudioInputDevice.systemDefaultAndSystemAudioID

            precondition(!appState.transcriptionEnabled)
            precondition(appState.currentNoteBrowserTranscriptionMode == .localAppleLive)
            precondition(appState.useLocalTranscription)
        }
    }

    private static func testSystemDefaultAndSystemAudioRejectsLiveModeSelections() async {
        resetDefaults()
        await MainActor.run {
            let appState = makeAppState()
            appState.apiKey = "global-key"
            appState.selectedMicrophoneID = AudioInputDevice.systemDefaultAndSystemAudioID
            precondition(!appState.isNoteBrowserTranscriptionModeAvailable(.apiRealtime))
            precondition(!appState.isNoteBrowserTranscriptionModeAvailable(.localAppleLive))
            precondition(appState.isNoteBrowserTranscriptionModeAvailable(.apiStandard))
            precondition(!appState.isNoteBrowserTranscriptionModeAvailable(.localWhisper))
            precondition(
                !appState.noteBrowserTranscriptionDisplay(
                    for: .apiRealtime(modelID: nil)
                ).isAvailable
            )
            precondition(
                !appState.noteBrowserTranscriptionDisplay(for: .appleLive).isAvailable
            )
            precondition(
                appState.noteBrowserTranscriptionDisplay(
                    for: .apiStandard(modelID: AppState.defaultTranscriptionModel)
                ).isAvailable
            )

            appState.setNoteBrowserTranscriptionMode(.apiRealtime)
            precondition(appState.currentNoteBrowserTranscriptionMode == .apiStandard)

            appState.setNoteBrowserTranscriptionMode(.localAppleLive)
            precondition(appState.currentNoteBrowserTranscriptionMode == .apiStandard)
        }
    }

    private static func testCombinedSourceDisabledWhenQueuedLiveOnlyChoiceNotRecording() async {
        resetDefaults()
        await MainActor.run {
            let appState = makeAppState()
            appState.apiKey = "global-key"
            appState.setNoteBrowserTranscriptionMode(.apiRealtime)
            appState.transcriptionEnabled = true
            precondition(!appState.isRecording)

            precondition(
                appState.isAudioSourceSelectable(.microphoneAndSystemAudio),
                "idle combined selection must remain available so transcription can normalize"
            )
            appState.selectAudioSource(.microphoneAndSystemAudio)
            precondition(
                appState.selectedMicrophoneID
                    == AudioInputDevice.systemDefaultAndSystemAudioID
            )
            precondition(appState.currentNoteBrowserTranscriptionMode == .apiStandard)
            precondition(appState.isAudioSourceSelectable(.microphone))
            precondition(appState.isAudioSourceSelectable(.systemAudio))
        }
    }

    private static func testLegacyMicrophoneSelectionSeedsDevicePreference() async {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set("legacy-device-uid", forKey: "selected_microphone_id")

        await MainActor.run {
            let appState = makeAppState()
            precondition(appState.selectedMicrophoneDeviceID == "legacy-device-uid")
            precondition(appState.selectedMicrophoneID == "legacy-device-uid")
            precondition(appState.selectedAudioSourceID == AudioInputDevice.defaultMicrophoneID)
            precondition(
                UserDefaults.standard.string(forKey: "selected_microphone_device_id")
                    == "legacy-device-uid"
            )
        }
    }

    private static func testMicrophoneSelectionPersistsAcrossSourceChanges() async {
        resetDefaults()

        await MainActor.run {
            let appState = makeAppState()
            appState.transcriptionEnabled = false
            appState.selectMicrophoneDevice("external-device-uid")
            precondition(appState.selectedMicrophoneDeviceID == "external-device-uid")
            precondition(appState.selectedMicrophoneID == "external-device-uid")

            appState.selectAudioSource(.systemAudio)
            precondition(appState.selectedMicrophoneID == AudioInputDevice.systemAudioID)
            precondition(appState.selectedMicrophoneDeviceID == "external-device-uid")

            appState.selectAudioSource(.microphoneAndSystemAudio)
            precondition(
                appState.selectedMicrophoneID
                    == AudioInputDevice.systemDefaultAndSystemAudioID
            )
            precondition(appState.selectedMicrophoneDeviceID == "external-device-uid")

            appState.selectAudioSource(.microphone)
            precondition(appState.selectedMicrophoneID == "external-device-uid")
            precondition(appState.selectedAudioSourceID == AudioInputDevice.defaultMicrophoneID)
            precondition(
                UserDefaults.standard.string(forKey: "selected_microphone_device_id")
                    == "external-device-uid"
            )
        }
    }

    private static func testSystemDefaultAndSystemAudioNormalizesStoredAPIRealtimeOnStartup() async throws {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set(AudioInputDevice.systemDefaultAndSystemAudioID, forKey: "selected_microphone_id")
        defaults.set(false, forKey: "use_local_transcription")
        defaults.set(true, forKey: "realtime_streaming_enabled")
        try credentialStore.save(
            "global-key",
            account: "groq_api_key"
        )

        await MainActor.run {
            let appState = makeAppState()

            precondition(appState.currentNoteBrowserTranscriptionMode == .apiStandard)
            precondition(!appState.useLocalTranscription)
            precondition(!appState.realtimeStreamingEnabled)
        }
    }

    private static func testSystemDefaultAndSystemAudioStartupTurnsOffStoredRealtimeWithoutKey() async {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set(AudioInputDevice.systemDefaultAndSystemAudioID, forKey: "selected_microphone_id")
        defaults.set(false, forKey: "use_local_transcription")
        defaults.set(true, forKey: "realtime_streaming_enabled")

        await MainActor.run {
            let appState = makeAppState()

            precondition(!appState.transcriptionEnabled)
            precondition(appState.currentNoteBrowserTranscriptionMode == .apiRealtime)
            precondition(!appState.useLocalTranscription)
            precondition(appState.realtimeStreamingEnabled)
        }
    }

    private static func testSystemDefaultAndSystemAudioStartupTurnsOffStoredAppleLiveWithoutWhisper() async {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set(AudioInputDevice.systemDefaultAndSystemAudioID, forKey: "selected_microphone_id")
        defaults.set(true, forKey: "use_local_transcription")
        defaults.set("apple-speech", forKey: "local_transcription_model")

        await MainActor.run {
            let appState = makeAppState()

            precondition(!appState.transcriptionEnabled)
            precondition(appState.currentNoteBrowserTranscriptionMode == .localAppleLive)
            precondition(appState.useLocalTranscription)
        }
    }

    private static func testSystemDefaultAndSystemAudioFallsBackFromStoredAppleLiveToInstalledNativeWhisperWithoutReentry() async {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set(AudioInputDevice.systemDefaultAndSystemAudioID, forKey: "selected_microphone_id")
        defaults.set(true, forKey: "use_local_transcription")
        defaults.set("apple-speech", forKey: "local_transcription_model")
        defaults.set(false, forKey: "use_legacy_mlx_whisper")

        var dependencies = transcriptionTestDependencies(status: { _ in .ready })

        let finalState = await MainActor.run {
            let appState = makeAppState(dependencies: dependencies)
            let expectedChoice = TranscriptionBackendChoice.nativeWhisper(
                modelID: NativeWhisperModelCatalog.recommended.id
            )

            precondition(appState.currentNoteBrowserTranscriptionChoice == expectedChoice)
            precondition(appState.useLocalTranscription)
            precondition(!appState.realtimeStreamingEnabled)
            precondition(!appState.useLegacyMlxWhisper)
            precondition(appState.localTranscriptionModel.id == "mlx-community/whisper-large-v3-turbo")
            return (appState.localTranscriptionModel.id, appState.useLegacyMlxWhisper)
        }

        precondition(finalState.0 == "mlx-community/whisper-large-v3-turbo")
        precondition(!finalState.1)
        precondition(defaults.string(forKey: "local_transcription_model") == "mlx-community/whisper-large-v3-turbo")
        precondition(defaults.bool(forKey: "use_legacy_mlx_whisper") == false)
    }

    private static func testRepeatedNativeWhisperSelectionRemainsStable() async {
        resetDefaults()
        var dependencies = transcriptionTestDependencies(status: { _ in .ready })

        await MainActor.run {
            let appState = makeAppState(dependencies: dependencies)
            let nativeChoice = TranscriptionBackendChoice.nativeWhisper(
                modelID: NativeWhisperModelCatalog.recommended.id
            )

            appState.setNoteBrowserTranscriptionChoice(nativeChoice)
            appState.setNoteBrowserTranscriptionChoice(nativeChoice)

            precondition(appState.currentNoteBrowserTranscriptionChoice == nativeChoice)
            precondition(!appState.useLegacyMlxWhisper)
            precondition(appState.localTranscriptionModel.id == "mlx-community/whisper-large-v3-turbo")
        }
    }

    private static func testLegacyAndNativeWhisperTransitionsRemainStable() async {
        resetDefaults()
        let legacyModel = TranscriptionModel.find(id: "mlx-community/whisper-medium-mlx")
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-legacy-model-transition-\(UUID().uuidString)", isDirectory: true)
        let snapshot = legacyModel.cacheDirectory(in: cacheRoot)
            .appendingPathComponent("snapshots/revision", isDirectory: true)
        try! FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: snapshot.appendingPathComponent("weights.npz").path,
            contents: Data()
        )
        setenv("HUGGINGFACE_HUB_CACHE", cacheRoot.path, 1)
        defer {
            unsetenv("HUGGINGFACE_HUB_CACHE")
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        var dependencies = transcriptionTestDependencies(status: { _ in .ready })

        await MainActor.run {
            let appState = makeAppState(dependencies: dependencies)
            let legacyChoice = TranscriptionBackendChoice.legacyMlxWhisper(model: legacyModel)
            let nativeChoice = TranscriptionBackendChoice.nativeWhisper(
                modelID: NativeWhisperModelCatalog.recommended.id
            )

            appState.setNoteBrowserTranscriptionChoice(legacyChoice)
            precondition(appState.currentNoteBrowserTranscriptionChoice == legacyChoice)
            precondition(appState.useLegacyMlxWhisper)

            appState.setNoteBrowserTranscriptionChoice(nativeChoice)
            precondition(appState.currentNoteBrowserTranscriptionChoice == nativeChoice)
            precondition(!appState.useLegacyMlxWhisper)

            appState.setNoteBrowserTranscriptionChoice(legacyChoice)
            precondition(appState.currentNoteBrowserTranscriptionChoice == legacyChoice)
            precondition(appState.useLegacyMlxWhisper)
        }
    }

    private static func testLegacyToAppleLiveClearsLegacyEnginePreference() async {
        resetDefaults()
        let legacyModel = TranscriptionModel.find(id: "mlx-community/whisper-medium-mlx")
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-legacy-to-apple-live-\(UUID().uuidString)", isDirectory: true)
        let snapshot = legacyModel.cacheDirectory(in: cacheRoot)
            .appendingPathComponent("snapshots/revision", isDirectory: true)
        try! FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: snapshot.appendingPathComponent("weights.npz").path,
            contents: Data()
        )
        setenv("HUGGINGFACE_HUB_CACHE", cacheRoot.path, 1)
        defer {
            unsetenv("HUGGINGFACE_HUB_CACHE")
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        await MainActor.run {
            let appState = makeAppState()
            appState.useLocalTranscription = true
            appState.localTranscriptionModel = legacyModel
            appState.useLegacyMlxWhisper = true
            precondition(appState.currentNoteBrowserTranscriptionChoice == .legacyMlxWhisper(model: legacyModel))

            appState.setNoteBrowserTranscriptionChoice(.appleLive)

            precondition(appState.currentNoteBrowserTranscriptionChoice == .appleLive)
            precondition(appState.localTranscriptionModel.isAppleSpeech)
            precondition(!appState.useLegacyMlxWhisper)
        }
    }

    private static func testLegacyOnlyStoredConfigurationRemainsLegacyWithoutNativeWhisper() async {
        resetDefaults()
        let defaults = UserDefaults.standard
        let legacyModel = TranscriptionModel.find(id: "mlx-community/whisper-medium-mlx")
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-legacy-only-startup-\(UUID().uuidString)", isDirectory: true)
        let snapshot = legacyModel.cacheDirectory(in: cacheRoot)
            .appendingPathComponent("snapshots/revision", isDirectory: true)
        try! FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: snapshot.appendingPathComponent("weights.npz").path,
            contents: Data()
        )
        setenv("HUGGINGFACE_HUB_CACHE", cacheRoot.path, 1)
        defer {
            unsetenv("HUGGINGFACE_HUB_CACHE")
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        defaults.set(true, forKey: "use_local_transcription")
        defaults.set(legacyModel.id, forKey: "local_transcription_model")
        defaults.set(true, forKey: "use_legacy_mlx_whisper")

        var dependencies = transcriptionTestDependencies(status: { _ in .notInstalled })

        await MainActor.run {
            let appState = makeAppState(dependencies: dependencies)

            precondition(appState.currentNoteBrowserTranscriptionChoice == .legacyMlxWhisper(model: legacyModel))
            precondition(appState.useLocalTranscription)
            precondition(appState.useLegacyMlxWhisper)
            precondition(appState.localTranscriptionModel == legacyModel)
        }
    }

    private static func testGoogleCalendarConnectionMetadataRestoresStartupState() throws {
        resetDefaults()
        let selectedCalendarIDs: Set<String> = ["primary"]
        UserDefaults.standard.set(try JSONEncoder().encode(Array(selectedCalendarIDs).sorted()), forKey: "google_calendar_selected_ids")
        let metadata = GoogleCalendarConnectionMetadata(accountEmail: "user@example.com")
        UserDefaults.standard.set(try JSONEncoder().encode(metadata), forKey: GoogleCalendarConnectionMetadata.storageKey)

        let appState = makeAppState()

        assert(appState.googleCalendarConnection.isConnected)
        assert(appState.googleCalendarConnection.accountEmail == "user@example.com")
        assert(appState.googleCalendarConnection.selectedCalendarIDs == selectedCalendarIDs)
        assert(appState.googleCalendarConnection.health.status == .unknown)
        assert(appState.googleCalendarConnection.health.checkedAt == nil)
    }

    private static func testGoogleCalendarConnectionMetadataClearsCorruptValue() {
        resetDefaults()
        UserDefaults.standard.set(Data("not-json".utf8), forKey: GoogleCalendarConnectionMetadata.storageKey)

        let appState = makeAppState()

        assert(!appState.googleCalendarConnection.isConnected)
        assert(UserDefaults.standard.data(forKey: GoogleCalendarConnectionMetadata.storageKey) == nil)
    }

    private static func testCalendarRecordingReminderLeadMinutesMigrateLegacyValue() {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set(30, forKey: "calendar_recording_reminder_lead_minutes")
        defaults.removeObject(forKey: "calendar_recording_reminder_lead_minutes_list")

        let appState = makeAppState()

        assert(appState.calendarRecordingReminderLeadMinutes == [30])
        assert(defaults.array(forKey: "calendar_recording_reminder_lead_minutes_list") as? [Int] == [30])
    }

    private static func testCalendarRecordingReminderLeadMinutesNormalizesStoredSelection() {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set([120, 14, 14], forKey: "calendar_recording_reminder_lead_minutes_list")

        let appState = makeAppState()

        assert(appState.calendarRecordingReminderLeadMinutes == [15, 60])
        assert(defaults.array(forKey: "calendar_recording_reminder_lead_minutes_list") as? [Int] == [15, 60])
    }

    private static func testCalendarRecordingReminderLeadMinutesDefaultsStoredEmptySelection() {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set([], forKey: "calendar_recording_reminder_lead_minutes_list")

        let appState = makeAppState()

        assert(appState.calendarRecordingReminderLeadMinutes == [CalendarRecordingReminderScheduler.defaultLeadMinutes])
        assert(defaults.array(forKey: "calendar_recording_reminder_lead_minutes_list") as? [Int] == [CalendarRecordingReminderScheduler.defaultLeadMinutes])
    }

    private static func testCalendarRecordingReminderLeadMinutesPersistNormalizedSelection() {
        resetDefaults()
        let defaults = UserDefaults.standard
        let appState = makeAppState()

        appState.calendarRecordingReminderLeadMinutes = [60, 5, 5, -1, 14, 500]

        assert(appState.calendarRecordingReminderLeadMinutes == [1, 5, 15, 60])
        assert(defaults.array(forKey: "calendar_recording_reminder_lead_minutes_list") as? [Int] == [1, 5, 15, 60])

        appState.calendarRecordingReminderLeadMinutes = []

        assert(appState.calendarRecordingReminderLeadMinutes == [CalendarRecordingReminderScheduler.defaultLeadMinutes])
        assert(defaults.array(forKey: "calendar_recording_reminder_lead_minutes_list") as? [Int] == [CalendarRecordingReminderScheduler.defaultLeadMinutes])
    }

    private static func testGoogleCalendarStoredCustomOAuthCredentialsAreIgnored() async {
        resetDefaults()
        let customClientID = "custom-client-id.apps.googleusercontent.com"
        UserDefaults.standard.set(customClientID, forKey: "google_calendar_client_id")

        let configuration = await MainActor.run {
            makeAppState().googleCalendarOAuthConfiguration
        }

        assert(!configuration.usesCustomCredentials)
        assert(configuration.clientID != customClientID)
    }

    private static func testGoogleCalendarRefreshMarksNeedsReconnectWhenTokenMissing() async {
        resetDefaults()
        let selectedCalendarIDs: Set<String> = ["primary"]
        UserDefaults.standard.set(try! JSONEncoder().encode(Array(selectedCalendarIDs).sorted()), forKey: "google_calendar_selected_ids")
        UserDefaults.standard.set(
            try! JSONEncoder().encode(GoogleCalendarConnectionMetadata(accountEmail: "user@example.com")),
            forKey: GoogleCalendarConnectionMetadata.storageKey
        )
        let originalTokenLoader = AppState.googleCalendarTokenLoader
        defer {
            AppState.googleCalendarTokenLoader = originalTokenLoader
        }
        AppState.googleCalendarTokenLoader = { _ in nil }

        let appState = makeAppState()
        await appState.loadGoogleCalendars(force: true)

        assert(appState.googleCalendarConnection.isConnected)
        assert(appState.googleCalendarConnection.accountEmail == "user@example.com")
        assert(appState.googleCalendarConnection.selectedCalendarIDs == selectedCalendarIDs)
        assert(appState.googleCalendarConnection.health.status == .needsReconnect)
        assert(appState.googleCalendarConnection.health.affectedFeature == .calendarList)
    }

    private static func testGoogleCalendarRefreshMarksNeedsReconnectWhenRefreshTokenIsMissing() async {
        resetDefaults()
        UserDefaults.standard.set("client-id.apps.googleusercontent.com", forKey: "google_calendar_client_id")
        UserDefaults.standard.set(
            try! JSONEncoder().encode(GoogleCalendarConnectionMetadata(accountEmail: "user@example.com")),
            forKey: GoogleCalendarConnectionMetadata.storageKey
        )
        let originalTokenLoader = AppState.googleCalendarTokenLoader
        defer {
            AppState.googleCalendarTokenLoader = originalTokenLoader
        }
        AppState.googleCalendarTokenLoader = { _ in
            GoogleCalendarOAuthToken(accessToken: "expired-token", refreshToken: nil, expiresAt: Date(timeIntervalSince1970: 0), accountEmail: "user@example.com")
        }

        let appState = makeAppState()
        await appState.loadGoogleCalendars(force: true)

        assert(appState.googleCalendarConnection.isConnected)
        assert(appState.googleCalendarConnection.health.status == .needsReconnect)
        assert(appState.googleCalendarConnection.health.affectedFeature == .calendarList)
    }

    private static func testGoogleCalendarReconnectErrorClassificationSeparatesClientConfigurationFailures() {
        assert(AppState.isGoogleCalendarReconnectError(GoogleCalendarAuthService.OAuthError.response("invalid_grant", "Bad refresh token")))
        assert(!AppState.isGoogleCalendarReconnectError(GoogleCalendarAuthService.OAuthError.response("invalid_client", "Bad client")))
        assert(!AppState.isGoogleCalendarReconnectError(GoogleCalendarAuthService.OAuthError.response("unauthorized_client", "Unauthorized client")))
    }

    private static func testGoogleCalendarHealthyDoesNotClearDifferentFeatureFailure() async {
        resetDefaults()
        UserDefaults.standard.set(
            try! JSONEncoder().encode(GoogleCalendarConnectionMetadata(accountEmail: "user@example.com")),
            forKey: GoogleCalendarConnectionMetadata.storageKey
        )
        let appState = makeAppState()
        await MainActor.run {
            appState.markGoogleCalendarTemporarilyUnavailable(
                feature: .recordingReminders,
                message: "Reminder refresh failed"
            )
            appState.markGoogleCalendarHealthy(feature: .recordingMatch)
        }

        assert(appState.googleCalendarConnection.health.status == .temporaryFailure)
        assert(appState.googleCalendarConnection.health.affectedFeature == .recordingReminders)
        assert(appState.googleCalendarConnection.lastErrorMessage == "Reminder refresh failed")
    }

    private static func testGoogleCalendarHealthCheckRunsForConnectedMetadataWithoutSelectedCalendars() async {
        resetDefaults()
        UserDefaults.standard.set(
            try! JSONEncoder().encode(GoogleCalendarConnectionMetadata(accountEmail: "user@example.com")),
            forKey: GoogleCalendarConnectionMetadata.storageKey
        )
        let originalTokenLoader = AppState.googleCalendarTokenLoader
        defer {
            AppState.googleCalendarTokenLoader = originalTokenLoader
        }
        AppState.googleCalendarTokenLoader = { _ in nil }

        let appState = makeAppState()
        await appState.startGoogleCalendarHealthCheck()
        await waitUntil { appState.googleCalendarConnection.health.status == .needsReconnect }

        assert(appState.googleCalendarConnection.health.status == .needsReconnect)
    }

    private static func testGoogleCalendarRefreshMarksTemporaryFailureWhenCalendarListFails() async {
        resetDefaults()
        UserDefaults.standard.set("client-id.apps.googleusercontent.com", forKey: "google_calendar_client_id")
        UserDefaults.standard.set(
            try! JSONEncoder().encode(GoogleCalendarConnectionMetadata(accountEmail: "user@example.com")),
            forKey: GoogleCalendarConnectionMetadata.storageKey
        )
        let originalTokenLoader = AppState.googleCalendarTokenLoader
        let originalServiceFactory = AppState.googleCalendarServiceFactory
        defer {
            AppState.googleCalendarTokenLoader = originalTokenLoader
            AppState.googleCalendarServiceFactory = originalServiceFactory
        }
        AppState.googleCalendarTokenLoader = { _ in
            GoogleCalendarOAuthToken(accessToken: "access-token", refreshToken: "refresh-token", expiresAt: Date().addingTimeInterval(3600), accountEmail: "user@example.com")
        }
        AppState.googleCalendarServiceFactory = {
            GoogleCalendarService { _ in throw CalendarListFailure() }
        }

        let appState = makeAppState()
        await appState.loadGoogleCalendars(force: true)

        assert(appState.googleCalendarConnection.isConnected)
        assert(appState.googleCalendarConnection.health.status == .temporaryFailure)
        assert(appState.googleCalendarConnection.health.affectedFeature == .calendarList)
    }

    private static func testGoogleCalendarRefreshMarksHealthyWhenCalendarListLoads() async {
        resetDefaults()
        UserDefaults.standard.set("client-id.apps.googleusercontent.com", forKey: "google_calendar_client_id")
        UserDefaults.standard.set(
            try! JSONEncoder().encode(GoogleCalendarConnectionMetadata(accountEmail: "user@example.com")),
            forKey: GoogleCalendarConnectionMetadata.storageKey
        )
        let originalTokenLoader = AppState.googleCalendarTokenLoader
        let originalServiceFactory = AppState.googleCalendarServiceFactory
        defer {
            AppState.googleCalendarTokenLoader = originalTokenLoader
            AppState.googleCalendarServiceFactory = originalServiceFactory
        }
        AppState.googleCalendarTokenLoader = { _ in
            GoogleCalendarOAuthToken(accessToken: "access-token", refreshToken: "refresh-token", expiresAt: Date().addingTimeInterval(3600), accountEmail: "user@example.com")
        }
        AppState.googleCalendarServiceFactory = {
            GoogleCalendarService { request in
                let data = Data("""
                {"items":[{"id":"primary","summary":"Work","primary":true,"accessRole":"owner"}]}
                """.utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }

        let appState = makeAppState()
        await appState.loadGoogleCalendars(force: true)

        assert(appState.googleCalendarConnection.isConnected)
        assert(appState.googleCalendarConnection.health.status == .healthy)
        assert(appState.googleCalendarConnection.health.affectedFeature == .calendarList)
        assert(appState.googleCalendarConnection.lastErrorMessage == nil)
        assert(appState.availableGoogleCalendars.map(\.id) == ["primary"])
    }

    private static func requireHistoryItem(
        withID id: UUID,
        in history: [PipelineHistoryItem]
    ) throws -> PipelineHistoryItem {
        guard let item = history.first(where: { $0.id == id }) else {
            throw AppStateTranscriptionConfigurationTestError.missingHistoryItem
        }
        return item
    }

    private static func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assertionFailure("Timed out waiting for condition")
    }

    private enum AppStateTranscriptionConfigurationTestError: Error {
        case missingHistoryItem
    }

    private struct CalendarListFailure: Error {}

    private static func testStoppedTranscriptionSettingsSnapshotCapturesHistoryMetadata() {
        let snapshot = StoppedTranscriptionSettingsSnapshot(
            customVocabulary: "team terms",
            customSystemPrompt: "custom prompt",
            useLocalTranscription: true,
            usesJobStore: false,
            historyLocalTranscriptionModelID: "apple-speech",
            localTranscriptionModel: .find(id: "apple-speech"),
            transcriptionLanguage: .find(code: "en"),
            usedContextCapture: true,
            usedPostProcessing: false
        )

        precondition(snapshot.customVocabulary == "team terms")
        precondition(snapshot.customSystemPrompt == "custom prompt")
        precondition(snapshot.useLocalTranscription)
        precondition(snapshot.localTranscriptionModel.id == "apple-speech")
        precondition(snapshot.transcriptionLanguage.code == "en")
        precondition(snapshot.usedContextCapture)
        precondition(!snapshot.usedPostProcessing)
    }

    private static func testRetryAvailabilityRequiresStoredAudio() async {
        resetDefaults()
        await MainActor.run {
            let appState = makeAppState()
            let item = retryHistoryItem(audioFileName: nil)
            precondition(appState.noteBrowserStoredAudioURL(for: item) == nil)
            precondition(appState.noteBrowserRetryAvailability(for: item) == .noAudio)
        }
    }

    private static func testRetryAvailabilityOffersSelectableCloudAlternative() async {
        resetDefaults()
        await MainActor.run {
            let appState = makeAppState()
            let fileName = "retry-model-setup-\(UUID().uuidString).wav"
            let audioURL = appState.storageLayout.audioDirectory.appendingPathComponent(fileName)
            try! Data([0]).write(to: audioURL)
            defer { try? FileManager.default.removeItem(at: audioURL) }
            let item = retryHistoryItem(audioFileName: fileName)

            appState.useLocalTranscription = true
            appState.realtimeStreamingEnabled = false
            appState.useLegacyMlxWhisper = false
            appState.localTranscriptionModel = .find(
                id: "mlx-community/whisper-large-v3-turbo"
            )
            precondition(appState.currentNoteBrowserTranscriptionChoice.mode == .localWhisper)
            precondition(
                appState.noteBrowserRetryAvailability(for: item)
                    == .needsModelSelection
            )
        }
    }

    private static func testRetryAvailabilityRequiresModelSelection() async {
        resetDefaults()
        await MainActor.run {
            let appState = makeAppState()
            appState.apiKey = "test-api-key"
            appState.setNoteBrowserTranscriptionChoice(.appleLive)
            let fileName = "retry-model-selection-\(UUID().uuidString).wav"
            let audioURL = appState.storageLayout.audioDirectory.appendingPathComponent(fileName)
            try! Data([0]).write(to: audioURL)
            defer { try? FileManager.default.removeItem(at: audioURL) }
            let item = retryHistoryItem(audioFileName: fileName)

            precondition(appState.currentNoteBrowserTranscriptionChoice == .appleLive)
            precondition(appState.noteBrowserRetryAvailability(for: item) == .needsModelSelection)
        }
    }

    private static func testRetryAvailabilityRequiresProviderConfiguration() async {
        resetDefaults()
        await MainActor.run {
            let appState = makeAppState()
            appState.setNoteBrowserTranscriptionChoice(
                .apiStandard(modelID: "whisper-large-v3")
            )
            let fileName = "retry-provider-setup-\(UUID().uuidString).wav"
            let audioURL = appState.storageLayout.audioDirectory.appendingPathComponent(fileName)
            try! Data([0]).write(to: audioURL)
            defer { try? FileManager.default.removeItem(at: audioURL) }
            let item = retryHistoryItem(audioFileName: fileName)

            precondition(
                appState.noteBrowserRetryAvailability(for: item)
                    == .needsProviderConfiguration
            )
        }
    }

    private static func testRetryAvailabilityAcceptsConfiguredAPIStandard() async {
        resetDefaults()
        await MainActor.run {
            let appState = makeAppState()
            appState.apiKey = "test-api-key"
            appState.setNoteBrowserTranscriptionChoice(
                .apiStandard(modelID: "whisper-large-v3")
            )
            let fileName = "retry-ready-\(UUID().uuidString).wav"
            let audioURL = appState.storageLayout.audioDirectory.appendingPathComponent(fileName)
            try! Data([0]).write(to: audioURL)
            defer { try? FileManager.default.removeItem(at: audioURL) }
            let item = retryHistoryItem(audioFileName: fileName)

            precondition(appState.noteBrowserStoredAudioURL(for: item) == audioURL)
            precondition(appState.noteBrowserRetryAvailability(for: item) == .ready)
        }
    }

    private static func testRetryPreservesMeetingSummaryMetadata() async throws {
        resetDefaults()
        let store = PipelineHistoryStore(inMemory: true)
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-retry-summary-metadata-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let storageLayout = AppStateStorageLayout(rootDirectory: rootDirectory)
        try FileManager.default.createDirectory(
            at: storageLayout.audioDirectory,
            withIntermediateDirectories: true
        )
        let fileName = "retry-summary-metadata-\(UUID().uuidString).wav"
        let audioURL = storageLayout.audioDirectory.appendingPathComponent(fileName)
        try Data([0]).write(to: audioURL)

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
        let item = retryHistoryItem(
            audioFileName: fileName,
            spokenLanguageCode: "ko",
            spokenLanguageResolution: .engineDetected,
            meetingSummaryAttempt: attempt
        )
        _ = try store.append(item, maxCount: 10)

        var dependencies = transcriptionTestDependencies()
        dependencies.storageLayout = storageLayout
        dependencies.makePipelineHistoryStore = { _ in store }
        let configuredDependencies = dependencies
        let appState = await MainActor.run {
            AppState(dependencies: configuredDependencies)
        }

        await MainActor.run {
            appState.transcriptionAPIKey = "test-api-key"
            appState.transcriptionAPIURL = "http://127.0.0.1:1"
            appState.setNoteBrowserTranscriptionChoice(
                .apiStandard(modelID: "whisper-large-v3")
            )
            precondition(appState.noteBrowserRetryAvailability(for: item) == .ready)
            appState.retryTranscription(item: item)
        }

        await waitUntil { !appState.retryingItemIDs.contains(item.id) }

        let updated = try requireHistoryItem(withID: item.id, in: appState.pipelineHistory)
        precondition(updated.spokenLanguageCode == "ko")
        precondition(updated.spokenLanguageResolution == .engineDetected)
        precondition(updated.meetingSummaryAttempt == attempt)

        let persisted = try requireHistoryItem(
            withID: item.id,
            in: store.loadAllHistory()
        )
        precondition(persisted.spokenLanguageCode == "ko")
        precondition(persisted.spokenLanguageResolution == .engineDetected)
        precondition(persisted.meetingSummaryAttempt == attempt)
    }

    private static func testAudioImportTimeoutPreservesRawTranscriptAndFailedOutcome() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try FileManager.default.createDirectory(
                at: environment.storageLayout.audioDirectory,
                withIntermediateDirectories: true
            )
            resetDefaults()
            let rawTranscript = "가져온 원본 전사문"
            let replacementTranscript = "뒤늦게 설치된 다른 전사문"
            let store = PipelineHistoryStore(storeURL: environment.storageLayout.historyStoreURL)
            var dependencies = environment.dependencies
            dependencies.makePipelineHistoryStore = { _ in store }
            let sourceURL = environment.rootDirectory.appendingPathComponent(
                "import-timeout-\(UUID().uuidString).wav"
            )
            try writeTestWAV(at: sourceURL)

            let originalImportDependencies =
                AppState.audioImportCloudTranscriptionDependenciesFactory
            let originalTransport = AppState.postProcessingTransport
            defer {
                AppState.audioImportCloudTranscriptionDependenciesFactory =
                    originalImportDependencies
                AppState.postProcessingTransport = originalTransport
            }
            AppState.audioImportCloudTranscriptionDependenciesFactory = {
                successfulCloudDependencies(transcript: rawTranscript)
            }
            AppState.postProcessingTransport = { _ in
                throw URLError(.timedOut)
            }

            let configuredDependencies = dependencies
        let appState = await MainActor.run {
            AppState(dependencies: configuredDependencies)
        }
            await MainActor.run {
                appState.apiKey = "post-processing-key"
                appState.transcriptionAPIKey = "transcription-key"
                appState.transcriptionAPIURL = "https://api.example.com/openai/v1"
                appState.postProcessingBackendChoice = .cloud(
                    modelID: "provider/model"
                )
                appState.importAudioFile(
                    sourceURL,
                    choice: .apiStandard(modelID: "whisper-large-v3")
                )
                AppState.audioImportCloudTranscriptionDependenciesFactory = {
                    successfulCloudDependencies(
                        transcript: replacementTranscript
                    )
                }
                AppState.postProcessingTransport = { request in
                    let data = try JSONSerialization.data(withJSONObject: [
                        "choices": [[
                            "message": ["content": replacementTranscript]
                        ]]
                    ])
                    return (
                        data,
                        HTTPURLResponse(
                            url: request.url!,
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: nil
                        )!
                    )
                }
            }

            await waitUntil {
                appState.pipelineHistory.contains {
                    !$0.rawTranscript.isEmpty
                }
            }
            guard let item = appState.pipelineHistory.first(where: {
                !$0.rawTranscript.isEmpty
            }) else {
                throw AppStateTranscriptionConfigurationTestError
                    .missingHistoryItem
            }
            try assertTimeoutFallbackHistory(
                item,
                rawTranscript: rawTranscript
            )
            let persisted = try requireHistoryItem(
                withID: item.id,
                in: store.loadAllHistory()
            )
            try assertTimeoutFallbackHistory(
                persisted,
                rawTranscript: rawTranscript
            )
        }
    }

    private static func testRetryTimeoutPreservesRawTranscriptAndFailedOutcome() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try FileManager.default.createDirectory(
                at: environment.storageLayout.audioDirectory,
                withIntermediateDirectories: true
            )
            resetDefaults()
            let rawTranscript = "재시도 원본 전사문"
            let store = PipelineHistoryStore(storeURL: environment.storageLayout.historyStoreURL)
            var dependencies = environment.dependencies
            dependencies.makePipelineHistoryStore = { _ in store }
            dependencies.makeRetryCloudTranscriptionDependencies = {
                successfulCloudDependencies(transcript: rawTranscript)
            }
            let fileName = "retry-timeout-\(UUID().uuidString).wav"
            let audioURL = environment.storageLayout.audioDirectory
                .appendingPathComponent(fileName)
            try writeTestWAV(at: audioURL)
            let originalItem = retryHistoryItem(
                audioFileName: fileName,
                aiProcessingOutcome: "failed:previous-processing-error"
            )
            _ = try store.append(originalItem, maxCount: 10)

            let originalTransport = AppState.postProcessingTransport
            defer {
                AppState.postProcessingTransport = originalTransport
            }
            AppState.postProcessingTransport = { _ in
                throw URLError(.timedOut)
            }

            let configuredDependencies = dependencies
            let appState = await MainActor.run {
                AppState(dependencies: configuredDependencies)
            }
            await MainActor.run {
                appState.apiKey = "post-processing-key"
                appState.transcriptionAPIKey = "transcription-key"
                appState.transcriptionAPIURL = "https://api.example.com/openai/v1"
                appState.postProcessingBackendChoice = .cloud(
                    modelID: "provider/model"
                )
                appState.setNoteBrowserTranscriptionChoice(
                    .apiStandard(modelID: "whisper-large-v3")
                )
                precondition(
                    appState.noteBrowserRetryAvailability(for: originalItem)
                        == .ready
                )
                appState.retryTranscription(item: originalItem)
                precondition(
                    appState.retryingItemIDs.contains(originalItem.id)
                )
            }

            await waitUntil {
                !appState.retryingItemIDs.contains(originalItem.id)
            }
            let item = try requireHistoryItem(
                withID: originalItem.id,
                in: store.loadAllHistory()
            )
            try assertTimeoutFallbackHistory(
                item,
                rawTranscript: rawTranscript
            )
            await MainActor.run {
                precondition(
                    appState.lastTranscript == rawTranscript,
                    "Manual fallback delivers the durable transcript through the AppState adapter"
                )
                precondition(
                    appState.noteRetryGeneration(for: originalItem.id) == 1,
                    "durable Manual fallback advances the warning generation"
                )
            }
        }
    }

    private static func testCreatedAppStateKeepsItsRetryDependencySnapshot() async throws {
        try await AppStateTestStorage.withIsolatedStorage { firstEnvironment in
            try await AppStateTestStorage.withIsolatedStorage { secondEnvironment in
                resetDefaults()
                let firstTranscript = "첫 인스턴스의 재시도 전사문"
                let secondTranscript = "두 번째 인스턴스의 재시도 전사문"
                let firstStore = PipelineHistoryStore(
                    storeURL: firstEnvironment.storageLayout.historyStoreURL
                )
                let secondStore = PipelineHistoryStore(
                    storeURL: secondEnvironment.storageLayout.historyStoreURL
                )
                var dependencies = firstEnvironment.dependencies
                dependencies.makePipelineHistoryStore = { _ in firstStore }
                dependencies.makeRetryCloudTranscriptionDependencies = {
                    successfulCloudDependencies(transcript: firstTranscript)
                }
                let firstItem = try retryHistoryItem(
                    in: firstEnvironment.storageLayout,
                    filePrefix: "first-retry-dependency"
                )
                _ = try firstStore.append(firstItem, maxCount: 10)

                let firstDependencies = dependencies
                let firstState = await MainActor.run {
                    AppState(dependencies: firstDependencies)
                }

                dependencies.storageLayout = secondEnvironment.storageLayout
                dependencies.makePipelineHistoryStore = { _ in secondStore }
                dependencies.makeRetryCloudTranscriptionDependencies = {
                    successfulCloudDependencies(transcript: secondTranscript)
                }
                let secondItem = try retryHistoryItem(
                    in: secondEnvironment.storageLayout,
                    filePrefix: "second-retry-dependency"
                )
                _ = try secondStore.append(secondItem, maxCount: 10)
                let secondDependencies = dependencies
                let secondState = await MainActor.run {
                    AppState(dependencies: secondDependencies)
                }

                await MainActor.run {
                    for (appState, item) in [
                        (firstState, firstItem),
                        (secondState, secondItem)
                    ] {
                        appState.transcriptionAPIKey = "transcription-key"
                        appState.transcriptionAPIURL = "https://api.example.com/openai/v1"
                        appState.setNoteBrowserTranscriptionChoice(
                            .apiStandard(modelID: "whisper-large-v3")
                        )
                        appState.disablePostProcessing = true
                        precondition(
                            appState.noteBrowserRetryAvailability(for: item)
                                == .ready
                        )
                        appState.retryTranscription(item: item)
                        precondition(
                            appState.retryingItemIDs.contains(item.id)
                        )
                    }
                }

                await waitUntil {
                    !firstState.retryingItemIDs.contains(firstItem.id)
                        && !secondState.retryingItemIDs.contains(secondItem.id)
                }
                let firstPersisted = try requireHistoryItem(
                    withID: firstItem.id,
                    in: firstStore.loadAllHistory()
                )
                let secondPersisted = try requireHistoryItem(
                    withID: secondItem.id,
                    in: secondStore.loadAllHistory()
                )
                precondition(firstPersisted.rawTranscript == firstTranscript)
                precondition(secondPersisted.rawTranscript == secondTranscript)
            }
        }
    }

    private static func retryHistoryItem(
        in storageLayout: AppStateStorageLayout,
        filePrefix: String
    ) throws -> PipelineHistoryItem {
        try FileManager.default.createDirectory(
            at: storageLayout.audioDirectory,
            withIntermediateDirectories: true
        )
        let fileName = "\(filePrefix)-\(UUID().uuidString).wav"
        try writeTestWAV(
            at: storageLayout.audioDirectory.appendingPathComponent(fileName)
        )
        return retryHistoryItem(audioFileName: fileName)
    }

    private static func testRetryTranscriptionFailurePreservesExistingAIOutcome() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try FileManager.default.createDirectory(
                at: environment.storageLayout.audioDirectory,
                withIntermediateDirectories: true
            )
            resetDefaults()
            let previousOutcome = "failed:previous-processing-error"
            let store = PipelineHistoryStore(storeURL: environment.storageLayout.historyStoreURL)
            var dependencies = environment.dependencies
            dependencies.makePipelineHistoryStore = { _ in store }
            dependencies.makeRetryCloudTranscriptionDependencies = {
                failingCloudDependencies()
            }
            let fileName = "retry-failure-\(UUID().uuidString).wav"
            let audioURL = environment.storageLayout.audioDirectory
                .appendingPathComponent(fileName)
            try writeTestWAV(at: audioURL)
            let originalItem = retryHistoryItem(
                audioFileName: fileName,
                aiProcessingOutcome: previousOutcome
            )
            _ = try store.append(originalItem, maxCount: 10)

            let configuredDependencies = dependencies
            let appState = await MainActor.run {
                AppState(dependencies: configuredDependencies)
            }
            await MainActor.run {
                appState.transcriptionAPIKey = "transcription-key"
                appState.transcriptionAPIURL =
                    "https://api.example.com/openai/v1"
                appState.setNoteBrowserTranscriptionChoice(
                    .apiStandard(modelID: "whisper-large-v3")
                )
                precondition(
                    appState.noteBrowserRetryAvailability(for: originalItem)
                        == .ready
                )
                appState.retryTranscription(item: originalItem)
                precondition(
                    appState.retryingItemIDs.contains(originalItem.id)
                )
            }

            await waitUntil {
                !appState.retryingItemIDs.contains(originalItem.id)
            }
            let item = try requireHistoryItem(
                withID: originalItem.id,
                in: store.loadAllHistory()
            )
            precondition(item.aiProcessingOutcome == previousOutcome)
        }
    }

    private static func testTranscriptEditInvalidatesActiveRetryAfterDurableSave()
        async throws
    {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try FileManager.default.createDirectory(
                at: environment.storageLayout.audioDirectory,
                withIntermediateDirectories: true
            )
            resetDefaults()
            let store = PipelineHistoryStore(
                storeURL: environment.storageLayout.historyStoreURL
            )
            let upload = ControlledRetryCloudUpload(
                transcript: "late provider transcript"
            )
            var dependencies = environment.dependencies
            dependencies.makePipelineHistoryStore = { _ in store }
            dependencies.makeRetryCloudTranscriptionDependencies = {
                upload.dependencies()
            }
            let fileName = "retry-edit-\(UUID().uuidString).wav"
            try writeTestWAV(
                at: environment.storageLayout.audioDirectory
                    .appendingPathComponent(fileName)
            )
            let item = retryHistoryItem(audioFileName: fileName)
            _ = try store.append(item, maxCount: 10)

            let configuredDependencies = dependencies
            let appState = await MainActor.run {
                AppState(dependencies: configuredDependencies)
            }
            await MainActor.run {
                appState.transcriptionAPIKey = "transcription-key"
                appState.transcriptionAPIURL =
                    "https://api.example.com/openai/v1"
                appState.setNoteBrowserTranscriptionChoice(
                    .apiStandard(modelID: "whisper-large-v3")
                )
                appState.disablePostProcessing = true
                appState.retryTranscription(item: item)
            }
            await waitUntil(timeoutNanoseconds: 3_000_000_000) {
                upload.hasEnteredUpload
            }

            let editedTranscript = "Edited while Retry was running."
            await MainActor.run {
                appState.updateTranscript(
                    id: item.id,
                    text: editedTranscript
                )
                precondition(
                    !appState.retryingItemIDs.contains(item.id),
                    "durable transcript edit clears active Retry state"
                )
            }
            upload.release()
            await waitUntil(timeoutNanoseconds: 3_000_000_000) {
                upload.hasFinishedUpload
            }

            let persisted = try requireHistoryItem(
                withID: item.id,
                in: store.loadAllHistory()
            )
            precondition(persisted.postProcessedTranscript == editedTranscript)
            await MainActor.run {
                precondition(
                    appState.pipelineHistory.first?.postProcessedTranscript
                        == editedTranscript,
                    "late Retry completion does not overwrite a durable edit"
                )
            }
        }
    }

    private static func testDeleteFailureCancelsActiveRetryWithoutResurrection()
        async throws
    {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try FileManager.default.createDirectory(
                at: environment.storageLayout.audioDirectory,
                withIntermediateDirectories: true
            )
            resetDefaults()
            var shouldFailSave = false
            let store = PipelineHistoryStore(
                storeURL: environment.storageLayout.historyStoreURL,
                persistentStoreLoader:
                    PipelineHistoryStore.loadPersistentStoresSynchronously,
                contextSaver: { context in
                    if shouldFailSave {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try context.save()
                }
            )
            let upload = ControlledRetryCloudUpload(
                transcript: "late deleted-note transcript"
            )
            var dependencies = environment.dependencies
            dependencies.makePipelineHistoryStore = { _ in store }
            dependencies.makeRetryCloudTranscriptionDependencies = {
                upload.dependencies()
            }
            let fileName = "retry-delete-failure-\(UUID().uuidString).wav"
            try writeTestWAV(
                at: environment.storageLayout.audioDirectory
                    .appendingPathComponent(fileName)
            )
            let item = retryHistoryItem(audioFileName: fileName)
            _ = try store.append(item, maxCount: 10)

            let configuredDependencies = dependencies
            let appState = await MainActor.run {
                AppState(dependencies: configuredDependencies)
            }
            await MainActor.run {
                appState.transcriptionAPIKey = "transcription-key"
                appState.transcriptionAPIURL =
                    "https://api.example.com/openai/v1"
                appState.setNoteBrowserTranscriptionChoice(
                    .apiStandard(modelID: "whisper-large-v3")
                )
                appState.disablePostProcessing = true
                appState.retryTranscription(item: item)
            }
            await waitUntil(timeoutNanoseconds: 3_000_000_000) {
                upload.hasEnteredUpload
            }

            shouldFailSave = true
            await MainActor.run {
                appState.deleteHistoryEntry(id: item.id)
                precondition(appState.pipelineHistory.map(\.id) == [item.id])
                precondition(
                    !appState.retryingItemIDs.contains(item.id),
                    "failed durable delete still cancels the active Retry"
                )
            }
            upload.release()
            await waitUntil(timeoutNanoseconds: 3_000_000_000) {
                upload.hasFinishedUpload
            }

            await MainActor.run {
                let current = appState.pipelineHistory[0]
                precondition(current.rawTranscript == item.rawTranscript)
                precondition(
                    current.postProcessedTranscript
                        == item.postProcessedTranscript,
                    "late Retry completion cannot resurrect after delete failure"
                )
            }
        }
    }

    private static func testRetryWorkflowMutationRoutes() throws {
        let source = try String(
            contentsOfFile: "Sources/AppState.swift",
            encoding: .utf8
        )
        let update = sourceBlock(
            in: source,
            from: "func updateTranscript(id: UUID, text: String)",
            to: "\n    @MainActor\n    func importAudioFile"
        )
        let clear = sourceBlock(
            in: source,
            from: "func clearPipelineHistory()",
            to: "\n    @MainActor\n    func deleteHistoryEntry"
        )
        let delete = sourceBlock(
            in: source,
            from: "func deleteHistoryEntry(id: UUID)",
            to: "\n    @MainActor\n    func updateHistoryItemTitle"
        )
        let cleanup = sourceBlock(
            in: source,
            from: "private func cleanupDeletedPipelineHistoryAssets(",
            to: "\n    static func normalizeInterruptedHistoryItem"
        )
        let replacement = sourceBlock(
            in: source,
            from: "private func applyHistoryRuntimeReplacement(",
            to: "\n    @MainActor\n    private func recoveryOperationMessage"
        )

        guard let updateSave = update.range(
            of: "try pipelineHistoryStore.update(updated)"
        ), let updateInvalidation = update.range(
            of: "transcriptionRetryWorkflow.invalidate(noteID: id)"
        ) else {
            preconditionFailure("Expected transcript-edit Retry invalidation")
        }
        precondition(updateSave.lowerBound < updateInvalidation.lowerBound)

        guard let clearCancel = clear.range(
            of: "transcriptionRetryWorkflow.cancel(noteID: historyID)"
        ), let clearSave = clear.range(
            of: "try pipelineHistoryStore.clearAll("
        ), let clearForget = clear.range(
            of: "transcriptionRetryWorkflow.forgetAll()"
        ) else {
            preconditionFailure("Expected clear Retry cancellation and forget")
        }
        precondition(clearCancel.lowerBound < clearSave.lowerBound)
        precondition(clearSave.lowerBound < clearForget.lowerBound)

        guard let deleteCancel = delete.range(
            of: "transcriptionRetryWorkflow.cancel(noteID: id)"
        ), let deleteSave = delete.range(
            of: "try pipelineHistoryStore.delete("
        ) else {
            preconditionFailure("Expected delete Retry cancellation")
        }
        precondition(deleteCancel.lowerBound < deleteSave.lowerBound)
        precondition(
            cleanup.contains(
                "transcriptionRetryWorkflow.forget(noteID: assets.historyID)"
            )
        )
        guard let freshCase = replacement.range(of: "case .fresh(let runtime):"),
              let freshForget = replacement.range(
                of: "transcriptionRetryWorkflow.forgetAll()",
                range: freshCase.upperBound..<replacement.endIndex
              ),
              let storeReplacement = replacement.range(
                of: "pipelineHistoryStore = runtime.historyStore",
                range: freshForget.upperBound..<replacement.endIndex
              ) else {
            preconditionFailure("Expected fresh archive runtime Retry reset")
        }
        precondition(freshForget.lowerBound < storeReplacement.lowerBound)
    }

    private static func testRetryUsesCurrentPostProcessingAndAudioOnlyMetadata() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let retryRequest = sourceBlock(
            in: source,
            from: "private func transcriptionRetryWorkflowRequest(",
            to: "\n    @MainActor\n    private func transcriptionRetryWorkflowRuntime"
        )

        assert(retryRequest.contains("let isAudioOnly = item.machineStatus == .audioOnly"))
        assert(retryRequest.contains("postProcessingEnabled: !disablePostProcessing"))
        assert(!retryRequest.contains("item.usedPostProcessing"))
        assert(retryRequest.contains("? customVocabulary"))
        assert(retryRequest.contains(": item.customVocabulary"))
        assert(retryRequest.contains("? customSystemPrompt"))
        assert(retryRequest.contains(": item.customSystemPrompt"))
        // Retry no longer injects the stored contextSummary unconditionally:
        // it is gated by the current context toggle and by whether the
        // stored summary is actually usable (see
        // testRetryRequestGatesStoredContextByCurrentToggleAndUsability).
        assert(retryRequest.contains("let usesStoredContext = !isAudioOnly && !disableContextCapture"))
        assert(
            retryRequest.contains(
                "currentActivity: storedContextIsUsable ? item.contextSummary : \"\""
            )
        )
        guard let macroCapture = retryRequest.range(
            of: "let capturedMacros = voiceMacros"
        ), let processingStart = retryRequest.range(
            of: "let processing = TranscriptionRetryProcessingBehavior"
        ), let requestStart = retryRequest.range(
            of: "return TranscriptionRetryWorkflowRequest("
        ) else {
            preconditionFailure("Expected immutable Retry processing capture")
        }
        assert(macroCapture.lowerBound < processingStart.lowerBound)
        let processingBody = String(
            retryRequest[processingStart.lowerBound..<requestStart.lowerBound]
        )
        assert(!processingBody.contains("self."))
        assert(processingBody.contains("voiceMacros: capturedMacros"))
    }

    private static func testAudioOnlyRetryCreatesTranscriptFileAndPreservesMetadata() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let request = sourceBlock(
            in: source,
            from: "private func transcriptionRetryWorkflowRequest(",
            to: "\n    @MainActor\n    private func transcriptionRetryWorkflowRuntime"
        )
        let runtime = sourceBlock(
            in: source,
            from: "private func transcriptionRetryWorkflowRuntime()",
            to: "\n    @MainActor\n    private static func processRetryTranscription"
        )

        assert(request.contains("let isAudioOnly = item.machineStatus == .audioOnly"))
        assert(request.contains("initialItem: item"))
        assert(request.contains("TranscriptionRetryHistoryMetadata("))
        assert(runtime.contains("TranscriptionRetryAssetAccess("))
        assert(runtime.contains("assetStore.saveTranscript("))
        assert(runtime.contains("assetStore.deleteTranscript(fileName: fileName)"))
        assert(!runtime.contains("saveTranscriptFile("))
    }

    private static func testHistoryReconstructionPreservesMeetingSummaryMetadata() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let paths = [
            sourceBlock(
                in: source,
                from: "func updateTranscript(id: UUID, text: String)",
                to: "\n    @MainActor\n    func importAudioFile"
            ),
            sourceBlock(
                in: source,
                from: "private func updateLiveNoteTranscript(",
                to: "\n    static func resolvedSystemPrompt"
            ),
            sourceBlock(
                in: source,
                from: "private func recordPipelineHistoryEntry(",
                to: "\n    private func startRealtimeStreamingIfEnabled"
            )
        ]

        for path in paths {
            assert(path.contains("spokenLanguageCode:"))
            assert(path.contains("spokenLanguageResolution:"))
            assert(path.contains("meetingSummaryAttempt:"))
        }

        let finalRecording = paths[2]
        assert(
            finalRecording.contains(
                "let effectiveSpokenLanguage = spokenLanguage ??"
            )
        )
        assert(
            finalRecording.contains(
                "spokenLanguageCode: effectiveSpokenLanguage?.languageCode"
            )
        )
        assert(
            finalRecording.contains(
                "spokenLanguageResolution: effectiveSpokenLanguage?.source"
            )
        )
    }

    private static func testSuccessfulTranscriptionHistoryReceivesSpokenLanguage() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let importedAudioPath = sourceBlock(
            in: source,
            from: "func importAudioFile(_ fileURL: URL, choice: TranscriptionBackendChoice)",
            to: "\n    @MainActor\n    func noteBrowserStoredAudioURL"
        )
        let retry = sourceBlock(
            in: source,
            from: "private static func processRetryTranscription(",
            to: "\n    func updatePermissionStatus"
        )
        let stoppedRecording = sourceBlock(
            in: source,
            from: "private func runSuccessfulStoppedTranscriptionCompletionPipeline(",
            to: "\n    @MainActor\n    private func updateForegroundUIForStoppedTranscriptionCompletion"
        )
        let history = sourceBlock(
            in: source,
            from: "private func recordPipelineHistoryEntry(",
            to: "\n    private func startRealtimeStreamingIfEnabled"
        )
        for successfulPath in [importedAudioPath, retry] {
            precondition(successfulPath.contains("spokenLanguage: transcription.spokenLanguage"))
        }
        precondition(stoppedRecording.contains("spokenLanguage: completion.spokenLanguage"))
        precondition(history.contains("let effectiveSpokenLanguage = spokenLanguage ??"))
        precondition(history.contains("spokenLanguageCode: effectiveSpokenLanguage?.languageCode"))
        precondition(history.contains("spokenLanguageResolution: effectiveSpokenLanguage?.source"))
    }

    private static func testResumedRetryPersistsAIOutcomeAndCommandFallbackWhitespace() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            try FileManager.default.createDirectory(
                at: environment.storageLayout.audioDirectory,
                withIntermediateDirectories: true
            )
            resetDefaults()
            defer { resetDefaults() }
            let rawTranscript = "재실행 후 복구된 원본 전사문"
            let commandFallback = "  들여쓴 선택 영역\n"
            let historyID = UUID()
            let commandHistoryID = UUID()
            let fileName = "\(historyID.uuidString).wav"
            let commandFileName = "\(commandHistoryID.uuidString).wav"
            let audioURL = environment.storageLayout.audioDirectory
                .appendingPathComponent(fileName)
            let commandAudioURL = environment.storageLayout.audioDirectory
                .appendingPathComponent(commandFileName)
            try writeTestWAV(at: audioURL)
            try writeTestWAV(at: commandAudioURL)

            let store = PipelineHistoryStore(storeURL: environment.storageLayout.historyStoreURL)
            var dependencies = environment.dependencies
            dependencies.makePipelineHistoryStore = { _ in store }
            dependencies.makeRetryCloudTranscriptionDependencies = {
                successfulCloudDependencies(transcript: rawTranscript)
            }
            let originalItem = PipelineHistoryItem(
                id: historyID,
                timestamp: Date(timeIntervalSince1970: 1),
                rawTranscript: "",
                postProcessedTranscript: "",
                postProcessingPrompt: nil,
                contextSummary: "",
                contextScreenshotDataURL: nil,
                contextScreenshotStatus: "No screenshot",
                postProcessingStatus: PipelineHistoryItem
                    .cloudTranscribingStatus,
                aiProcessingOutcome: "succeeded",
                debugStatus: "Cloud transcription in progress",
                customVocabulary: "",
                audioFileName: fileName,
                usedLocalTranscription: false,
                usedContextCapture: false,
                usedPostProcessing: true,
                transcriptionLanguageCode: "ko"
            )
            let commandItem = PipelineHistoryItem(
                intent: .commandManual,
                selectedText: commandFallback,
                id: commandHistoryID,
                timestamp: Date(timeIntervalSince1970: 2),
                rawTranscript: "",
                postProcessedTranscript: "",
                postProcessingPrompt: nil,
                contextSummary: "",
                contextScreenshotDataURL: nil,
                contextScreenshotStatus: "No screenshot",
                postProcessingStatus: PipelineHistoryItem
                    .cloudTranscribingStatus,
                aiProcessingOutcome: "succeeded",
                debugStatus: "Cloud transcription in progress",
                customVocabulary: "",
                audioFileName: commandFileName,
                usedLocalTranscription: false,
                usedContextCapture: false,
                usedPostProcessing: true,
                transcriptionLanguageCode: "ko"
            )
            _ = try store.append(originalItem, maxCount: 10)
            _ = try store.append(commandItem, maxCount: 10)

            let jobStore = CloudTranscriptionJobStore(
                jobsDirectory: environment.storageLayout.cloudTranscriptionJobsDirectory,
                temporaryRoot: environment.rootDirectory
                    .appendingPathComponent(
                        "cloud-transcription/tmp",
                        isDirectory: true
                    )
            )
            let record = try makeResumableCloudRecord(
                historyID: historyID,
                audioURL: audioURL
            )
            let commandRecord = try makeResumableCloudRecord(
                historyID: commandHistoryID,
                audioURL: commandAudioURL
            )
            let session = jobStore.beginSession(historyID: historyID)
            try jobStore.create(record, session: session)
            jobStore.invalidateSession(historyID: historyID)
            let commandSession = jobStore.beginSession(
                historyID: commandHistoryID
            )
            try jobStore.create(commandRecord, session: commandSession)
            jobStore.invalidateSession(historyID: commandHistoryID)

            let defaults = UserDefaults.standard
            defer {
                defaults.removeObject(forKey: "output_language")
                defaults.removeObject(forKey: "disable_post_processing")
                defaults.removeObject(
                    forKey: "meeting_summary_output_language"
                )
                defaults.removeObject(
                    forKey: "meeting_summary_settings_initialized"
                )
            }
            defaults.set(true, forKey: "hasCompletedSetup")
            defaults.set(true, forKey: "meeting_summary_settings_initialized")
            defaults.set("", forKey: "meeting_summary_output_language")
            defaults.set(true, forKey: "transcription_enabled")
            defaults.set(false, forKey: "use_local_transcription")
            defaults.set(true, forKey: "disable_post_processing")
            defaults.set("English", forKey: "output_language")
            defaults.set(true, forKey: "press_enter_voice_command_enabled")
            defaults.set("whisper-large-v3", forKey: "transcription_model")
            defaults.set("ko", forKey: "transcription_language")
            AIProcessingBackendChoiceStore.save(
                .cloud(modelID: "provider/model"),
                defaults: defaults,
                key: "post_processing_backend_choice"
            )
            // AppState will be constructed with `environment.dependencies`, so
            // fixture credentials must be written through the same explicit
            // credentialStorageLayout it will actually read from, not the
            // transcription suite's separate credential layout.
            let credentialStore = CredentialStore(
                layout: environment.dependencies.credentialStorageLayout
            )
            try credentialStore.save(
                "post-processing-key",
                account: "groq_api_key"
            )
            try credentialStore.save(
                "transcription-key",
                account: "transcription_api_key"
            )
            try credentialStore.save(
                "http://127.0.0.1:1",
                account: "api_base_url"
            )
            try credentialStore.save(
                "http://127.0.0.1:1",
                account: "transcription_api_url"
            )

            let originalTransport = AppState.postProcessingTransport
            defer {
                AppState.postProcessingTransport = originalTransport
            }
            AppState.postProcessingTransport = { _ in
                throw URLError(.timedOut)
            }

            let configuredDependencies = dependencies
            let appState = await MainActor.run {
                AppState(dependencies: configuredDependencies)
            }
            await waitUntil(timeoutNanoseconds: 3_000_000_000) {
                let history = store.loadAllHistory()
                return [historyID, commandHistoryID].allSatisfy { id in
                    history.contains {
                        $0.id == id
                            && $0.debugStatus == "Resumed after relaunch"
                    }
                }
            }

            let inMemory = try requireHistoryItem(
                withID: historyID,
                in: appState.pipelineHistory
            )
            let persisted = try requireHistoryItem(
                withID: historyID,
                in: store.loadAllHistory()
            )
            for item in [inMemory, persisted] {
                try assertTimeoutFallbackHistory(
                    item,
                    rawTranscript: rawTranscript
                )
                precondition(item.debugStatus == "Resumed after relaunch")
            }
            let commandInMemory = try requireHistoryItem(
                withID: commandHistoryID,
                in: appState.pipelineHistory
            )
            let commandPersisted = try requireHistoryItem(
                withID: commandHistoryID,
                in: store.loadAllHistory()
            )
            for item in [commandInMemory, commandPersisted] {
                precondition(item.rawTranscript == rawTranscript)
                precondition(
                    item.postProcessedTranscript == commandFallback,
                    "startup Resume must preserve whitespace-sensitive command fallback text"
                )
                precondition(
                    item.aiProcessingOutcome == "failed:request-timed-out"
                )
                let issue = try QuillUserIssueRecord.decodePersistedStatus(
                    item.postProcessingStatus
                )
                precondition(issue.code == .requestTimedOut)
                precondition(issue.context.operation == .commandTransform)
                precondition(item.debugStatus == "Resumed after relaunch")
            }
            await MainActor.run {
                precondition(
                    appState.lastTranscript.isEmpty,
                    "startup Resume remains history-only"
                )
                precondition(
                    appState.noteRetryGeneration(for: historyID) == 1,
                    "durable startup Resume advances warning generation"
                )
                precondition(
                    appState.noteRetryGeneration(for: commandHistoryID) == 1,
                    "command Resume advances warning generation"
                )
            }
        }
    }

    private static func testHistoryDeletionForgetsSummaryGenerationStateAfterPersistence() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let clear = sourceBlock(
            in: source,
            from: "func clearPipelineHistory()",
            to: "\n    @MainActor\n    func deleteHistoryEntry"
        )
        let delete = sourceBlock(
            in: source,
            from: "func deleteHistoryEntry(id: UUID)",
            to: "\n    @MainActor\n    func updateHistoryItemTitle"
        )
        let retryEvents = sourceBlock(
            in: source,
            from: "private func applyTranscriptionRetryWorkflowEvent(",
            to: "\n    @MainActor\n    private func applyTranscriptionRetryWorkflowState"
        )

        assert(clear.contains("try pipelineHistoryStore.clearAll("))
        assert(clear.contains("requiresDurableStore: true"))
        assert(clear.contains("pipelineHistory = []"))
        assert(clear.contains("meetingSummaryWorkflow.forgetAll()"))
        assert(
            clear.range(of: "pipelineHistory = []")!.lowerBound
                < clear.range(of: "meetingSummaryWorkflow.forgetAll()")!.lowerBound
        )
        assert(delete.contains("try pipelineHistoryStore.delete("))
        assert(delete.contains("requiresDurableStore: true"))
        assert(delete.contains("pipelineHistory.remove(at: index)"))
        assert(delete.contains("meetingSummaryWorkflow.forget(noteID: id)"))
        assert(
            delete.range(of: "pipelineHistory.remove(at: index)")!.lowerBound
                < delete.range(
                    of: "meetingSummaryWorkflow.forget(noteID: id)"
                )!.lowerBound
        )
        assert(retryEvents.contains("case .itemPersisted(let item, let effects):"))
        assert(retryEvents.contains("incrementNoteRetryGeneration(for: item.id)"))
        assert(retryEvents.contains("meetingSummaryWorkflow.invalidate(noteID: item.id)"))
        assert(
            retryEvents.range(
                of: "case .itemPersisted(let item, let effects):"
            )!.lowerBound
                < retryEvents.range(
                    of: "meetingSummaryWorkflow.invalidate(noteID: item.id)"
                )!.lowerBound
        )
    }

    private static func testRealtimeConfiguredLanguageUsesOneRequestAndResolutionValue() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let start = sourceBlock(
            in: source,
            from: "private func startRealtimeStreamingIfEnabled()",
            to: "\n    private func tearDownRealtimeService"
        )
        let completion = sourceBlock(
            in: source,
            from: "let activeRealtime = self.realtimeService",
            to: "\n                    try Task.checkCancellation()"
        )

        assert(start.contains(
            "let realtimeLanguageConfiguration = RealtimeTranscriptionLanguageConfiguration("
        ))
        assert(start.contains(
            "language: realtimeLanguageConfiguration.requestLanguage"
        ))
        assert(completion.contains(
            "let activeRealtimeLanguageConfiguration = self.realtimeLanguageConfiguration"
        ))
        assert(completion.contains(
            "requestedLanguageCode: activeRealtimeLanguageConfiguration?.requestedLanguageCode"
        ))
    }

    private static func testAudioOnlyRetryDeletesNewTranscriptFileWhenStale() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let retry = sourceBlock(
            in: source,
            from: "func retryTranscription(item: PipelineHistoryItem)",
            to: "\n    @MainActor\n    private func copyRetryTranscriptToPasteboardIfNeeded"
        )
        let runtime = sourceBlock(
            in: source,
            from: "private func transcriptionRetryWorkflowRuntime()",
            to: "\n    @MainActor\n    private static func processRetryTranscription"
        )

        assert(retry.contains("transcriptionRetryWorkflow.startManual("))
        assert(retry.contains("runtime: transcriptionRetryWorkflowRuntime()"))
        assert(runtime.contains("deleteTranscript: { fileName in"))
        assert(runtime.contains("assetStore.deleteTranscript(fileName: fileName)"))
        assert(!runtime.contains("Self.deleteTranscriptFile"))
    }

    private static func makeResumableCloudRecord(
        historyID: UUID,
        audioURL: URL
    ) throws -> CloudTranscriptionJobRecord {
        let layout = try CanonicalPCM16WAV.validateFile(at: audioURL)
        let source = try CloudTranscriptionSourceIdentityBuilder.make(
            fileURL: audioURL,
            layout: layout
        )
        let multipart = CloudTranscriptionMultipartLayout(
            model: "whisper-large-v3",
            responseFormat: "verbose_json",
            language: "ko"
        )
        let plan = try CloudTranscriptionChunkPlanner().plan(
            fileURL: audioURL,
            source: source,
            wavLayout: layout,
            multipart: multipart,
            encodedUploadCeilingBytes: 20_000_000
        )
        let runtime = try CloudTranscriptionExecutionSnapshot(
            baseURL: "http://127.0.0.1:1",
            apiKey: "transcription-key",
            model: "whisper-large-v3",
            language: "ko",
            encodedUploadCeilingBytes: 20_000_000
        )
        return CloudTranscriptionJobRecord(
            schemaVersion: CloudTranscriptionJobRecord.currentSchemaVersion,
            historyID: historyID,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            phase: .interrupted,
            identity: CloudTranscriptionJobIdentity(
                providerID: runtime.providerID,
                model: runtime.model,
                language: runtime.language,
                responseFormat: runtime.responseFormat,
                source: source,
                planID: plan.planID
            ),
            plan: plan,
            completedChunks: [],
            firstIncompleteChunkIndex: 0,
            lastFailure: nil,
            completionPolicy: CloudTranscriptionCompletionPolicy(
                postProcessingEnabled: true,
                outputLanguage: "",
                pressEnterCommandEnabled: false
            )
        )
    }

    private static func writeTestWAV(at url: URL) throws {
        var data = CanonicalPCM16WAV.header(dataByteCount: 8)
        for sample: Int16 in [1, 1, 2, 2] {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        try data.write(to: url)
    }

    private static func successfulCloudDependencies(
        transcript: String
    ) -> CloudTranscriptionDependencies {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-timeout-history-\(UUID().uuidString)"
            )
        return CloudTranscriptionDependencies(
            encodedUploadCeilingBytes: 20_000_000,
            upload: { request, _ in
                try await Task.sleep(nanoseconds: 10_000_000)
                let data = try JSONSerialization.data(withJSONObject: [
                    "text": transcript,
                    "language": "ko",
                    "segments": []
                ])
                return (
                    data,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            },
            checkpointStore: InMemoryCloudTranscriptionCheckpointStore(),
            progress: { _ in },
            temporaryRoot: temporaryRoot,
            sleep: { _ in }
        )
    }

    private static func failingCloudDependencies() -> CloudTranscriptionDependencies {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-retry-failure-\(UUID().uuidString)"
            )
        return CloudTranscriptionDependencies(
            encodedUploadCeilingBytes: 20_000_000,
            upload: { _, _ in
                try await Task.sleep(nanoseconds: 10_000_000)
                throw URLError(.cannotConnectToHost)
            },
            checkpointStore: InMemoryCloudTranscriptionCheckpointStore(),
            progress: { _ in },
            temporaryRoot: temporaryRoot,
            sleep: { _ in }
        )
    }

    private static func assertTimeoutFallbackHistory(
        _ item: PipelineHistoryItem,
        rawTranscript: String
    ) throws {
        precondition(
            item.rawTranscript == rawTranscript,
            "Expected raw transcript \(rawTranscript), got \(item.rawTranscript); status=\(item.postProcessingStatus) outcome=\(item.aiProcessingOutcome)"
        )
        precondition(item.postProcessedTranscript == rawTranscript)
        precondition(
            item.aiProcessingOutcome == "failed:request-timed-out"
        )
        let issue = try QuillUserIssueRecord.decodePersistedStatus(
            item.postProcessingStatus
        )
        precondition(issue.code == .requestTimedOut)
        precondition(issue.context.operation == .postProcessing)
    }

    private static func retryHistoryItem(
        audioFileName: String?,
        aiProcessingOutcome: String = "succeeded",
        spokenLanguageCode: String? = nil,
        spokenLanguageResolution: SpokenLanguageResolutionSource? = nil,
        meetingSummaryAttempt: MeetingSummaryAttempt? = nil
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            timestamp: Date(timeIntervalSince1970: 1),
            rawTranscript: "",
            postProcessedTranscript: "",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: QuillUserIssueRecord(code: .localModelMissing).persistedStatus,
            aiProcessingOutcome: aiProcessingOutcome,
            debugStatus: "Failed",
            customVocabulary: "",
            audioFileName: audioFileName,
            usedLocalTranscription: true,
            spokenLanguageCode: spokenLanguageCode,
            spokenLanguageResolution: spokenLanguageResolution,
            meetingSummaryAttempt: meetingSummaryAttempt
        )
    }

    private static func resetDefaults() {
        resetCredentialStore()
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("app_state_transcription_test_") {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: "hasCompletedSetup")
        defaults.removeObject(forKey: "transcription_enabled")
        defaults.removeObject(forKey: "first_install_defaults_version")
        defaults.removeObject(forKey: "disable_auto_paste")
        defaults.removeObject(forKey: "recording_overlay_layout")
        defaults.removeObject(forKey: "overlay_waveform_display_mode")
        defaults.removeObject(forKey: "press_enter_voice_command_enabled")
        defaults.removeObject(forKey: "use_local_transcription")
        defaults.removeObject(forKey: "use_legacy_mlx_whisper")
        defaults.removeObject(forKey: "show_legacy_mlx_whisper_options")
        defaults.removeObject(forKey: "local_transcription_model")
        defaults.removeObject(forKey: "local_ai_transcription_model")
        defaults.removeObject(forKey: "transcription_language")
        defaults.removeObject(forKey: "context_model")
        defaults.removeObject(forKey: "post_processing_backend_choice")
        defaults.removeObject(forKey: "context_backend_choice")
        defaults.removeObject(forKey: "preserve_exact_wording")
        defaults.removeObject(forKey: "note_browser_enabled")
        defaults.removeObject(forKey: "selected_microphone_id")
        defaults.removeObject(forKey: "selected_microphone_device_id")
        defaults.removeObject(forKey: "realtime_streaming_enabled")
        defaults.removeObject(forKey: "hold_shortcut")
        defaults.removeObject(forKey: "toggle_shortcut")
        defaults.removeObject(forKey: "recording_cancel_shortcut")
        defaults.removeObject(forKey: "copy_again_shortcut")
        defaults.removeObject(forKey: "saved_hold_custom_shortcut")
        defaults.removeObject(forKey: "saved_toggle_custom_shortcut")
        defaults.removeObject(forKey: "saved_recording_cancel_custom_shortcut")
        defaults.removeObject(forKey: "saved_copy_again_custom_shortcut")
        defaults.removeObject(forKey: "command_mode_enabled")
        defaults.removeObject(forKey: "command_mode_style")
        defaults.removeObject(forKey: "command_mode_manual_modifier")
        defaults.removeObject(forKey: "google_calendar_client_id")
        defaults.removeObject(forKey: "google_calendar_selected_ids")
        defaults.removeObject(forKey: "calendar_recording_reminders_enabled")
        defaults.removeObject(forKey: "calendar_recording_reminder_lead_minutes")
        defaults.removeObject(forKey: "calendar_recording_reminder_lead_minutes_list")
        defaults.removeObject(forKey: "calendar_recording_reminder_refresh_interval_minutes")
        defaults.removeObject(forKey: GoogleCalendarConnectionMetadata.storageKey)
    }

    private static func sourceBlock(in source: String, from startMarker: String, to endMarker: String) -> String {
        guard let start = source.range(of: startMarker),
              let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else {
            preconditionFailure("Expected source block from \(startMarker) to \(endMarker)")
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private static func markerNativeWhisperExecution(
        modelID: String
    ) -> NativeWhisperExecutionSnapshot {
        NativeWhisperExecutionSnapshot(
            modelID: modelID,
            modelIsReady: { true },
            modelURL: { URL(fileURLWithPath: "/tmp/\(modelID).bin") },
            validateRunnerAndModel: { _ in },
            prepareAudio: { .init(fileURL: $0, cleanup: {}) },
            transcribe: { _, _, _ in
                TranscriptionResult(
                    text: modelID,
                    spokenLanguage: SpokenLanguageResolver.resolve(
                        requestedLanguageCode: "auto",
                        engineLanguageCode: nil,
                        transcript: modelID
                    )
                )
            }
        )
    }

    private static func mirroredCompleteTranscriptionConfiguration(
        _ service: TranscriptionService
    ) -> (
        apiKey: String,
        baseURL: String,
        useLocalTranscription: Bool,
        localTranscriptionModelID: String,
        transcriptionLanguageCode: String,
        localWhisperPath: String?,
        useLegacyMlxWhisper: Bool,
        transcriptionModel: String,
        language: String?,
        encodedUploadCeilingBytes: UInt64
    ) {
        let mirror = Mirror(reflecting: service)
        let dependencies = mirror.descendant("cloudDependencies")
            as? CloudTranscriptionDependencies
        return (
            mirror.descendant("apiKey") as? String ?? "",
            (mirror.descendant("baseURL") as? URL)?.absoluteString ?? "",
            mirror.descendant("useLocalTranscription") as? Bool ?? false,
            (mirror.descendant("localTranscriptionModel") as? TranscriptionModel)?.id
                ?? "",
            (mirror.descendant("transcriptionLanguage") as? TranscriptionLanguage)?.code
                ?? "",
            mirror.descendant("localWhisperPath") as? String,
            mirror.descendant("useLegacyMlxWhisper") as? Bool ?? false,
            mirror.descendant("transcriptionModel") as? String ?? "",
            mirror.descendant("language") as? String,
            dependencies?.encodedUploadCeilingBytes ?? 0
        )
    }

    private static func mirroredTranscriptionConfiguration(_ service: TranscriptionService) -> (
        useLocalTranscription: Bool,
        localTranscriptionModelID: String,
        transcriptionLanguageCode: String,
        localWhisperPath: String?,
        useLegacyMlxWhisper: Bool
    ) {
        let mirror = Mirror(reflecting: service)
        let useLocalTranscription = mirror.descendant("useLocalTranscription") as? Bool ?? false
        let localTranscriptionModel = mirror.descendant("localTranscriptionModel") as? TranscriptionModel ?? .default
        let transcriptionLanguage = mirror.descendant("transcriptionLanguage") as? TranscriptionLanguage ?? .auto
        let localWhisperPath = mirror.descendant("localWhisperPath") as? String
        let useLegacyMlxWhisper = mirror.descendant("useLegacyMlxWhisper") as? Bool ?? false
        return (useLocalTranscription, localTranscriptionModel.id, transcriptionLanguage.code, localWhisperPath, useLegacyMlxWhisper)
    }
}
