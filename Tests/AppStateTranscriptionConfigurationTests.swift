import Combine
import Foundation

@main
struct AppStateTranscriptionConfigurationTests {
    static func main() async throws {
        try testMakeTranscriptionServiceUsesLocalConfiguration()
        try testMakeTranscriptionServiceMapsEmptyLocalWhisperPathToNil()
        try testMakeTranscriptionServiceDefaultsLegacyMlxWhisperOff()
        try testMakeTranscriptionServicePassesLegacyMlxWhisperToggle()
        testTranscriptionResponseFormatUsesVerboseJSONForKnownWhisperModels()
        testTranscriptionResponseFormatUsesJSONForOtherModels()
        testTranscriptionHTTP400UsesConfigurationGuidance()
        testQwen36ModelConfiguration()
        testQwen36ContextReasoningIsStripped()
        testContextSummaryPreservesNonReasoningModelOutput()
        testContextModelDefaultsToQwen36()
        testDeprecatedDefaultContextModelMigratesToQwen36()
        testCustomContextModelIsPreserved()
        testLLMTransportTimeoutNormalization()
        testPostProcessingCooldownDispositionDefaultsToProcessed()
        testPostProcessingCooldownDispositionCanBeMarkedSkipped()
        testPreserveExactWordingDefaultsOffAndPersists()
        testVerbatimTranslationPromptAndSanitizer()
        testVerbatimTranslationRejectsOutputThatSanitizesToEmpty()
        try testPreserveExactWordingSettingsAndPipelineWiring()
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
        testStoppedTranscriptionSettingsSnapshotCapturesHistoryMetadata()
        try testAppStateCreatedTranscriptionServicesPassLegacyMlxWhisperToggle()
        try testNativeWhisperPreparesAudioBeforeRuntime()
        try testNoteBrowserTranscriptionMenuUsesFlatNativeCheckedItems()
        await testAudioImportConfigurationUsesChoiceDerivedBackend()
        try testInitialAudioImportUsesChoiceConfiguration()
        try testAudioImportSheetUsesChoiceDisplayRows()
        await testNoteBrowserTranscriptionChoiceDisplayIncludesResolvedModels()
        try testNoteBrowserTranscriptionChoiceSetterUpdatesLocalBackend()
        await testAPITranscriptionModesRequireResolvedAPIKey()
        try testSettingsAPIProviderTabDoesNotForceUnavailableAPIMode()
        try testSettingsLegacyMlxWhisperToggleControlsOptionsVisibilityOnly()
        try testSettingsGlobalAPIKeyCanBeCleared()
        await testTranscriptionAPIKeyEnablesAPIModesWithoutGlobalAPIKey()
        await testEmptyTranscriptionAPIKeyFallsBackToGlobalAPIKey()
        await testRemovingAPIKeyNormalizesSelectedAPIMode()
        await testRemovingAPIKeyDoesNotNormalizeWhileRecording()
        await testSystemDefaultAndSystemAudioConvertsAPIRealtimeToStandard()
        await testSystemDefaultAndSystemAudioKeepsAppleLiveWhenNoFallbackIsAvailable()
        await testSystemDefaultAndSystemAudioRejectsLiveModeSelections()
        await testSystemDefaultAndSystemAudioNormalizesStoredAPIRealtimeOnStartup()
        await testSystemDefaultAndSystemAudioKeepsStoredAPIRealtimeWhenNoFallbackIsAvailable()
        await testSystemDefaultAndSystemAudioKeepsStoredAppleLiveWhenWhisperIsUnavailable()
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
        print("AppStateTranscriptionConfigurationTests passed")
    }

    private static func testMakeTranscriptionServiceUsesLocalConfiguration() throws {
        resetDefaults()
        let appState = AppState()
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
    }

    private static func testMakeTranscriptionServiceMapsEmptyLocalWhisperPathToNil() throws {
        resetDefaults()
        let appState = AppState()
        appState.useLocalTranscription = true
        appState.localWhisperPath = ""

        let service = try appState.makeTranscriptionService()
        let configuration = mirroredTranscriptionConfiguration(service)

        assert(configuration.localWhisperPath == nil)
    }

    private static func testMakeTranscriptionServiceDefaultsLegacyMlxWhisperOff() throws {
        resetDefaults()
        let appState = AppState()
        appState.useLocalTranscription = true
        appState.localTranscriptionModel = .find(id: "mlx-community/whisper-large-v3-turbo")

        let service = try appState.makeTranscriptionService()
        let configuration = mirroredTranscriptionConfiguration(service)

        assert(configuration.useLegacyMlxWhisper == false)
    }

    private static func testMakeTranscriptionServicePassesLegacyMlxWhisperToggle() throws {
        resetDefaults()
        let appState = AppState()
        appState.useLocalTranscription = true
        appState.useLegacyMlxWhisper = true

        let service = try appState.makeTranscriptionService()
        let configuration = mirroredTranscriptionConfiguration(service)

        assert(configuration.useLegacyMlxWhisper == true)
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

    private static func testTranscriptionHTTP400UsesConfigurationGuidance() {
        let message = TranscriptionService.friendlyHTTPMessage(status: 400, host: "api.example.com")

        assert(message.contains("HTTP 400"))
        assert(message.contains("model name"))
        assert(message.contains("Base URL"))
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
        let appState = AppState()

        assert(AppState.defaultContextModel == "qwen/qwen3.6-27b")
        assert(appState.contextModel == "qwen/qwen3.6-27b")
    }

    private static func testDeprecatedDefaultContextModelMigratesToQwen36() {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set("meta-llama/llama-4-scout-17b-16e-instruct", forKey: "context_model")

        let appState = AppState()

        assert(appState.contextModel == "qwen/qwen3.6-27b")
        assert(defaults.string(forKey: "context_model") == "qwen/qwen3.6-27b")
    }

    private static func testCustomContextModelIsPreserved() {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set("custom/context-model", forKey: "context_model")

        let appState = AppState()

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

    private static func testPreserveExactWordingDefaultsOffAndPersists() {
        resetDefaults()
        let defaults = UserDefaults.standard
        let appState = AppState()

        assert(!appState.preserveExactWording)
        appState.preserveExactWording = true
        assert(defaults.bool(forKey: "preserve_exact_wording"))
    }

    private static func testVerbatimTranslationPromptAndSanitizer() {
        let prompt = PostProcessingService.verbatimTranslationSystemPrompt(targetLanguage: "English")

        assert(prompt.contains("literal translator"))
        assert(prompt.contains("Preserve every word"))
        assert(prompt.contains("English"))
        assert(PostProcessingService.sanitizeVerbatimTranslation("\"EMPTY\"") == "EMPTY")
        assert(PostProcessingService.sanitizeVerbatimTranslation("\" translated text \"") == "translated text")
    }

    private static func testVerbatimTranslationRejectsOutputThatSanitizesToEmpty() {
        do {
            _ = try PostProcessingService.validatedVerbatimTranslation("\"\"")
            assertionFailure("Quote-only literal translation must be treated as empty output")
        } catch PostProcessingError.emptyOutput {
            // Expected: stripping the outer quotes leaves no literal text to paste.
        } catch {
            assertionFailure("Expected emptyOutput, got \(error)")
        }

        do {
            let literalEmpty = try PostProcessingService.validatedVerbatimTranslation("\"EMPTY\"")
            assert(literalEmpty == "EMPTY")

            let translated = try PostProcessingService.validatedVerbatimTranslation("\" translated text \"")
            assert(translated == "translated text")
        } catch {
            assertionFailure("Nonempty literal translations must remain valid: \(error)")
        }
    }

    private static func testPreserveExactWordingSettingsAndPipelineWiring() throws {
        let settings = try String(contentsOfFile: "Sources/SettingsView.swift", encoding: .utf8)
        let appState = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let sharedBehaviors = sourceBlock(
            in: settings,
            from: "private var sharedTranscriptionBehaviors: some View",
            to: "\n    private var vocabularySection"
        )

        precondition(sharedBehaviors.contains("Toggle(\"Preserve Exact Wording\", isOn: $appState.preserveExactWording)"))
        precondition(sharedBehaviors.contains(".disabled(appState.disablePostProcessing)"))
        precondition(appState.contains("if preserveExactWording"))
        precondition(appState.contains("postProcessingService.translateVerbatim"))
        precondition(appState.contains("preserveExactWording: preserveExactWording"))
    }

    private static func testLegacyMlxWhisperOptionsDefaultToOff() {
        resetDefaults()
        let appState = AppState()

        assert(appState.showLegacyMlxWhisperOptions == false)
        assert(appState.useLegacyMlxWhisper == false)
    }

    private static func testLegacyMlxWhisperOptionsPersistIndependentlyFromEngine() {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "show_legacy_mlx_whisper_options")
        defaults.set(false, forKey: "use_legacy_mlx_whisper")

        let appState = AppState()

        assert(appState.showLegacyMlxWhisperOptions == true)
        assert(appState.useLegacyMlxWhisper == false)

        appState.showLegacyMlxWhisperOptions = false

        assert(defaults.bool(forKey: "show_legacy_mlx_whisper_options") == false)
    }

    private static func testLegacyMlxWhisperOptionsFallBackToLegacyEnginePreference() {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "use_legacy_mlx_whisper")

        let appState = AppState()

        assert(appState.useLegacyMlxWhisper == true)
        assert(appState.showLegacyMlxWhisperOptions == true)
        assert(defaults.bool(forKey: "show_legacy_mlx_whisper_options") == true)
    }

    private static func testLegacyMlxWhisperOptionsStayVisibleWhenEngineIsTurnedOff() {
        resetDefaults()
        let appState = AppState()
        appState.showLegacyMlxWhisperOptions = true
        appState.useLegacyMlxWhisper = true

        appState.useLegacyMlxWhisper = false

        assert(appState.showLegacyMlxWhisperOptions == true)
        assert(appState.useLegacyMlxWhisper == false)
    }

    private static func testPermissionStatusUpdateSkipsUnchangedValues() {
        resetDefaults()
        let appState = AppState()
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

        let appState = AppState()
        appState.recordingOverlayLayout = .notchSides

        assert(defaults.string(forKey: "recording_overlay_layout") == "notchSides")
        assert(defaults.object(forKey: "use_compact_overlay") == nil)
    }

    private static func testRecordingCancelShortcutDefaultsToEscape() {
        resetDefaults()
        UserDefaults.standard.removeObject(forKey: "recording_cancel_shortcut")

        let appState = AppState()

        assert(appState.recordingCancelShortcut == .defaultRecordingCancel)
    }

    private static func testRecordingCancelShortcutPersistsDisabled() {
        resetDefaults()
        var appState = AppState()
        let validation = appState.setRecordingCancelShortcut(.disabled)
        assert(validation == nil)

        appState = AppState()

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
        var appState = AppState()
        let validation = appState.setRecordingCancelShortcut(custom)
        assert(validation == nil)

        appState = AppState()

        assert(appState.recordingCancelShortcut == custom)
        assert(appState.savedRecordingCancelCustomShortcut == custom)
    }

    private static func testRecordingCancelShortcutDisablesDefaultWhenStoredHoldUsesEscape() {
        resetDefaults()
        let defaults = UserDefaults.standard
        let escHold = ShortcutBinding.defaultRecordingCancel
        defaults.set(try! JSONEncoder().encode(escHold), forKey: "hold_shortcut")
        defaults.removeObject(forKey: "recording_cancel_shortcut")

        let appState = AppState()
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
        let appState = AppState()

        let validation = appState.setRecordingCancelShortcut(appState.holdShortcut)

        assert(validation == "Cancel shortcut must be distinct from dictation shortcuts.")
        assert(appState.recordingCancelShortcut == .defaultRecordingCancel)
    }

    private static func testRecordingCancelShortcutRejectsPasteAgainConflict() {
        resetDefaults()
        let appState = AppState()
        let f5 = ShortcutPreset.f5.binding

        assert(appState.setShortcut(f5, for: .copyAgain) == nil)
        let validation = appState.setRecordingCancelShortcut(f5)

        assert(validation == "Cancel shortcut must be distinct from Paste Again.")
        assert(appState.recordingCancelShortcut == .defaultRecordingCancel)
    }

    private static func testPasteAgainShortcutRejectsRecordingCancelConflict() {
        resetDefaults()
        let appState = AppState()

        let validation = appState.setShortcut(.defaultRecordingCancel, for: .copyAgain)

        assert(validation == "Paste Again cannot share a shortcut with Cancel Recording.")
        assert(appState.copyAgainShortcut == .disabled)
    }

    private static func testPasteAgainShortcutReportsManualModifierCollision() {
        resetDefaults()
        let appState = AppState()
        _ = appState.setCommandModeEnabled(true)
        _ = appState.setCommandModeStyle(.manual)
        _ = appState.setCommandModeManualModifier(.option)

        let validation = appState.setShortcut(ShortcutPreset.rightOption.binding, for: .copyAgain)

        assert(validation == "That modifier is already the Paste Again shortcut.")
        assert(appState.copyAgainShortcut == .disabled)
    }

    private static func testHoldShortcutRejectsCancelConflict() {
        resetDefaults()
        let appState = AppState()

        let validation = appState.setShortcut(.defaultRecordingCancel, for: .hold)

        assert(validation == "Dictation shortcuts must be distinct from the cancel shortcut.")
        assert(appState.holdShortcut == .defaultHold)
    }

    private static func testHoldShortcutRejectsMoreSpecificCancelOverlap() {
        resetDefaults()
        let appState = AppState()
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
        let appState = AppState()
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
        let appState = AppState()
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
        let appState = AppState()
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
        let appState = AppState()
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

    private static func testAppStateCreatedTranscriptionServicesPassLegacyMlxWhisperToggle() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let importBody = sourceBlock(
            in: source,
            from: "func importAudioFile(_ fileURL: URL, mode: NoteBrowserTranscriptionMode)",
            to: "\n    @MainActor\n    func retryTranscription"
        )
        let retryBody = sourceBlock(
            in: source,
            from: "func retryTranscription(item: PipelineHistoryItem)",
            to: "\n    @MainActor\n    private func copyRetryTranscriptToPasteboardIfNeeded"
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
        precondition(importBody.contains("let transcriptionService = try configuration.makeTranscriptionService()"))
        precondition(source.contains("self.useLegacyMlxWhisper = transcriptionConfiguration.useLegacyMlxWhisper"))
        precondition(retryBody.contains("useLegacyMlxWhisper: snapshot.useLegacyMlxWhisper,"))
        precondition(stoppedRecordingBody.contains("let capturedUseLegacyMlxWhisper = useLegacyMlxWhisper"))
        precondition(stoppedRecordingBody.contains("useLegacyMlxWhisper: capturedUseLegacyMlxWhisper,"))
    }

    private static func testNativeWhisperPreparesAudioBeforeRuntime() throws {
        let source = try String(contentsOfFile: "Sources/TranscriptionService.swift", encoding: .utf8)
        let nativeBody = sourceBlock(
            in: source,
            from: "private func transcribeWithNativeWhisper(fileURL: URL)",
            to: "    // Run mlx_whisper locally"
        )
        guard let preflightRange = nativeBody.range(of: "try runtime.validateRunnerAndModel(modelURL: modelURL)"),
              let conversionRange = nativeBody.range(of: "let preparedAudio = try await AudioImportConversionService().prepareForNativeWhisper(fileURL)") else {
            preconditionFailure("Expected native Whisper preflight before audio conversion")
        }

        precondition(preflightRange.lowerBound < conversionRange.lowerBound)
        precondition(nativeBody.contains("let runtime = NativeWhisperRuntime()"))
        precondition(nativeBody.contains("let modelURL = store.modelURL(for: model)"))
        precondition(nativeBody.contains("defer { preparedAudio.cleanup() }"))
        precondition(nativeBody.contains("audioURL: preparedAudio.fileURL"))
        precondition(nativeBody.contains("modelURL: modelURL"))
        precondition(!nativeBody.contains("audioURL: fileURL"))
    }

    private static func testNoteBrowserTranscriptionMenuUsesFlatNativeCheckedItems() throws {
        let source = try String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)
        guard let itemStart = source.range(of: "private func transcriptionChoiceMenuItem")?.lowerBound,
              let itemEnd = source.range(of: "\n    private func transcriptionChoiceDisplays", range: itemStart..<source.endIndex)?.lowerBound else {
            preconditionFailure("Expected transcription choice menu item block")
        }
        let menuItemSource = String(source[itemStart..<itemEnd])

        precondition(source.contains("ForEach(transcriptionChoiceDisplays(in: \"API\"))"))
        precondition(source.contains("ForEach(transcriptionChoiceDisplays(in: \"Local\"))"))
        precondition(source.contains("ForEach(transcriptionChoiceDisplays(in: \"Legacy mlx-whisper\"))"))
        precondition(menuItemSource.contains("Toggle(isOn: Binding<Bool>("))
        precondition(menuItemSource.contains("get: { appState.currentNoteBrowserTranscriptionChoice == display.choice }"))
        precondition(menuItemSource.contains("if isSelected { appState.setNoteBrowserTranscriptionChoice(display.choice) }"))
        precondition(menuItemSource.contains(".disabled(!display.isAvailable)"))
        precondition(!menuItemSource.contains("Picker(\"Transcription\", selection:"))
        precondition(!menuItemSource.contains("Image(systemName: \"checkmark\")"))
    }

    private static func testAudioImportConfigurationUsesChoiceDerivedBackend() async {
        resetDefaults()
        await MainActor.run {
            let appState = AppState()
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
        precondition(!sheetBody.contains("[NoteBrowserTranscriptionMode.apiStandard, .localWhisper]"))
        precondition(!sheetBody.contains("appState.audioImportLabel(for:"))
    }

    private static func testNoteBrowserTranscriptionChoiceDisplayIncludesResolvedModels() async {
        resetDefaults()
        await MainActor.run {
            let appState = AppState()
            appState.transcriptionModel = "whisper-large-v3-turbo"
            appState.realtimeStreamingModel = ""

            let apiDisplay = appState.noteBrowserTranscriptionDisplay(for: .apiStandard(modelID: appState.transcriptionModel))
            precondition(apiDisplay.title == "Standard")
            precondition(apiDisplay.currentLabel == "API · Standard · whisper-large-v3-turbo")

            let realtimeDisplay = appState.noteBrowserTranscriptionDisplay(for: .apiRealtime(modelID: nil))
            precondition(realtimeDisplay.title == "Realtime")
            precondition(realtimeDisplay.currentLabel == "API · Realtime · Provider default")

            let nativeDisplay = appState.noteBrowserTranscriptionDisplay(for: .nativeWhisper(modelID: NativeWhisperModelCatalog.recommended.id))
            precondition(nativeDisplay.title == "Native Whisper")
            precondition(nativeDisplay.currentLabel == "Local · Native Whisper · Whisper Large v3 Turbo")

            let legacyModel = TranscriptionModel.find(id: "mlx-community/whisper-medium-mlx")
            let legacyDisplay = appState.noteBrowserTranscriptionDisplay(for: .legacyMlxWhisper(model: legacyModel))
            precondition(legacyDisplay.title == "Legacy mlx-whisper")
            precondition(legacyDisplay.currentLabel == "Local · Legacy · Whisper Medium")

            let appleDisplay = appState.noteBrowserTranscriptionDisplay(for: .appleLive)
            precondition(appleDisplay.title == "Apple Live")
            precondition(appleDisplay.currentLabel == "Local · Apple Live · Apple Speech")

            appState.useLocalTranscription = false
            appState.realtimeStreamingEnabled = false
            precondition(appState.noteBrowserTranscriptionChoiceLabel == "Standard")
            precondition(appState.noteBrowserTranscriptionChoiceDetailLabel == "API · Standard · whisper-large-v3-turbo")
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

        precondition(nativeBranch.contains("useLocalTranscription = true"))
        precondition(nativeBranch.contains("realtimeStreamingEnabled = false"))
        precondition(nativeBranch.contains("useLegacyMlxWhisper = false"))
        precondition(nativeBranch.contains("localTranscriptionModel = nativeLocalWhisperSelectionModel"))
        precondition(legacyBranch.contains("useLocalTranscription = true"))
        precondition(legacyBranch.contains("realtimeStreamingEnabled = false"))
        precondition(legacyBranch.contains("useLegacyMlxWhisper = true"))
        precondition(legacyBranch.contains("showLegacyMlxWhisperOptions = true"))
        precondition(legacyBranch.contains("localTranscriptionModel = model"))
    }

    private static func testAPITranscriptionModesRequireResolvedAPIKey() async {
        resetDefaults()
        await MainActor.run {
            let appState = AppState()

            precondition(!appState.isNoteBrowserTranscriptionModeAvailable(.apiStandard))
            precondition(!appState.isNoteBrowserTranscriptionModeAvailable(.apiRealtime))
            precondition(!appState.isNoteBrowserTranscriptionModeAvailable(.localWhisper))
            precondition(appState.isNoteBrowserTranscriptionModeAvailable(.localAppleLive))

            appState.setNoteBrowserTranscriptionMode(.apiStandard)
            precondition(appState.currentNoteBrowserTranscriptionMode == .localAppleLive)

            appState.setNoteBrowserTranscriptionMode(.apiRealtime)
            precondition(appState.currentNoteBrowserTranscriptionMode == .localAppleLive)
        }
    }

    private static func testSettingsAPIProviderTabDoesNotForceUnavailableAPIMode() throws {
        let source = try String(contentsOfFile: "Sources/SettingsView.swift", encoding: .utf8)
        let transcriptionSection = sourceBlock(
            in: source,
            from: "private var transcriptionSection: some View",
            to: "\n    private var localTranscriptionSettings"
        )
        let saveKeyBody = sourceBlock(
            in: source,
            from: "private func validateAndSaveKey()",
            to: "\n    // MARK: System Prompt"
        )

        precondition(source.contains("@State private var showingLocalTranscriptionSettings = true"))
        precondition(transcriptionSection.contains("Picker(\"Transcription Mode\", selection: $showingLocalTranscriptionSettings)"))
        precondition(transcriptionSection.contains("if showsLocal {"))
        precondition(transcriptionSection.contains("appState.useLocalTranscription = true"))
        precondition(transcriptionSection.contains("} else if appState.hasTranscriptionAPIKey {"))
        precondition(transcriptionSection.contains("appState.setNoteBrowserTranscriptionMode(.apiStandard)"))
        precondition(!transcriptionSection.contains("selection: $appState.useLocalTranscription"))
        precondition(saveKeyBody.contains("if !showingLocalTranscriptionSettings"))
        precondition(saveKeyBody.contains("appState.setNoteBrowserTranscriptionMode(.apiStandard)"))
    }

    private static func testSettingsLegacyMlxWhisperToggleControlsOptionsVisibilityOnly() throws {
        let source = try String(contentsOfFile: "Sources/SettingsView.swift", encoding: .utf8)
        let localSettings = sourceBlock(
            in: source,
            from: "private var localTranscriptionSettings: some View",
            to: "\n    private var apiProviderTranscriptionSettings"
        )
        let appleSpeechRow = sourceBlock(
            in: localSettings,
            from: "ModelRowView(\n                    model: TranscriptionModel.find(id: \"apple-speech\")",
            to: "\n\n                NativeWhisperModelRowView"
        )
        let nativeWhisperRow = sourceBlock(
            in: localSettings,
            from: "NativeWhisperModelRowView(",
            to: "\n                Text(\"If you close Settings while the model is downloading"
        )
        let legacyRows = sourceBlock(
            in: localSettings,
            from: "ForEach(TranscriptionModel.all.filter { !$0.isAppleSpeech })",
            to: "\n\n                    TextField(\"~/.local/bin/mlx_whisper\""
        )

        precondition(localSettings.contains("Toggle(\"Use legacy mlx-whisper\", isOn: $appState.showLegacyMlxWhisperOptions)"))
        precondition(!localSettings.contains("Toggle(\"Use legacy mlx-whisper\", isOn: $appState.useLegacyMlxWhisper)"))
        precondition(appleSpeechRow.contains("appState.useLegacyMlxWhisper = false"))
        precondition(!appleSpeechRow.contains("showLegacyMlxWhisperOptions"))
        precondition(nativeWhisperRow.contains("appState.useLegacyMlxWhisper = false"))
        precondition(!nativeWhisperRow.contains("showLegacyMlxWhisperOptions"))
        precondition(legacyRows.contains("appState.useLegacyMlxWhisper = true"))
        precondition(legacyRows.contains("appState.showLegacyMlxWhisperOptions = true"))
        precondition(localSettings.contains(".disabled(!appState.showLegacyMlxWhisperOptions)"))
        precondition(localSettings.contains(".opacity(appState.showLegacyMlxWhisperOptions ? 1 : 0.55)"))
    }

    private static func testSettingsGlobalAPIKeyCanBeCleared() throws {
        let source = try String(contentsOfFile: "Sources/SettingsView.swift", encoding: .utf8)
        let providerSection = sourceBlock(
            in: source,
            from: "private var apiProviderTranscriptionSettings: some View",
            to: "\n    private var languageSettings"
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
        precondition(saveKeyBody.contains("keyValidationSuccess = true"))
        precondition(providerSection.contains(".disabled(isValidatingKey)"))
        precondition(!providerSection.contains(".disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidatingKey)"))
        precondition(providerSection.contains("API key cleared"))
    }

    private static func testTranscriptionAPIKeyEnablesAPIModesWithoutGlobalAPIKey() async {
        resetDefaults()
        await MainActor.run {
            let appState = AppState()
            appState.transcriptionAPIKey = "transcription-key"

            precondition(appState.isNoteBrowserTranscriptionModeAvailable(.apiStandard))
            precondition(appState.isNoteBrowserTranscriptionModeAvailable(.apiRealtime))

            appState.setNoteBrowserTranscriptionMode(.apiRealtime)
            precondition(appState.currentNoteBrowserTranscriptionMode == .apiRealtime)
        }
    }

    private static func testEmptyTranscriptionAPIKeyFallsBackToGlobalAPIKey() async {
        resetDefaults()
        await MainActor.run {
            let appState = AppState()
            appState.apiKey = "global-key"
            appState.transcriptionAPIKey = "  "

            precondition(appState.isNoteBrowserTranscriptionModeAvailable(.apiStandard))
            precondition(appState.isNoteBrowserTranscriptionModeAvailable(.apiRealtime))
        }
    }

    private static func testRemovingAPIKeyNormalizesSelectedAPIMode() async {
        resetDefaults()
        await MainActor.run {
            let appState = AppState()
            appState.apiKey = "global-key"
            appState.setNoteBrowserTranscriptionMode(.apiStandard)
            precondition(appState.currentNoteBrowserTranscriptionMode == .apiStandard)

            appState.apiKey = ""

            precondition(appState.currentNoteBrowserTranscriptionMode == .localAppleLive)
            precondition(appState.useLocalTranscription)
        }
    }

    private static func testRemovingAPIKeyDoesNotNormalizeWhileRecording() async {
        resetDefaults()
        await MainActor.run {
            let appState = AppState()
            appState.apiKey = "global-key"
            appState.setNoteBrowserTranscriptionMode(.apiRealtime)
            precondition(appState.currentNoteBrowserTranscriptionMode == .apiRealtime)

            appState.isRecording = true
            appState.apiKey = ""

            precondition(appState.currentNoteBrowserTranscriptionMode == .apiRealtime)
            precondition(!appState.useLocalTranscription)
            precondition(appState.realtimeStreamingEnabled)
        }
    }

    private static func testSystemDefaultAndSystemAudioConvertsAPIRealtimeToStandard() async {
        resetDefaults()
        await MainActor.run {
            let appState = AppState()
            appState.apiKey = "global-key"
            appState.setNoteBrowserTranscriptionMode(.apiRealtime)
            precondition(appState.currentNoteBrowserTranscriptionMode == .apiRealtime)

            appState.selectedMicrophoneID = AudioInputDevice.systemDefaultAndSystemAudioID

            precondition(appState.currentNoteBrowserTranscriptionMode == .apiStandard)
            precondition(!appState.useLocalTranscription)
            precondition(!appState.realtimeStreamingEnabled)
        }
    }

    private static func testSystemDefaultAndSystemAudioKeepsAppleLiveWhenNoFallbackIsAvailable() async {
        resetDefaults()
        await MainActor.run {
            let appState = AppState()
            appState.setNoteBrowserTranscriptionMode(.localAppleLive)
            precondition(appState.currentNoteBrowserTranscriptionMode == .localAppleLive)

            appState.selectedMicrophoneID = AudioInputDevice.systemDefaultAndSystemAudioID

            precondition(appState.currentNoteBrowserTranscriptionMode == .localAppleLive)
            precondition(appState.useLocalTranscription)
            precondition(appState.localTranscriptionModel.isAppleSpeech)
        }
    }

    private static func testSystemDefaultAndSystemAudioRejectsLiveModeSelections() async {
        resetDefaults()
        await MainActor.run {
            let appState = AppState()
            appState.apiKey = "global-key"
            appState.selectedMicrophoneID = AudioInputDevice.systemDefaultAndSystemAudioID
            precondition(!appState.isNoteBrowserTranscriptionModeAvailable(.apiRealtime))
            precondition(!appState.isNoteBrowserTranscriptionModeAvailable(.localAppleLive))
            precondition(appState.isNoteBrowserTranscriptionModeAvailable(.apiStandard))
            precondition(!appState.isNoteBrowserTranscriptionModeAvailable(.localWhisper))

            appState.setNoteBrowserTranscriptionMode(.apiRealtime)
            precondition(appState.currentNoteBrowserTranscriptionMode == .apiStandard)

            appState.setNoteBrowserTranscriptionMode(.localAppleLive)
            precondition(appState.currentNoteBrowserTranscriptionMode == .apiStandard)
        }
    }

    private static func testSystemDefaultAndSystemAudioNormalizesStoredAPIRealtimeOnStartup() async {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set(AudioInputDevice.systemDefaultAndSystemAudioID, forKey: "selected_microphone_id")
        defaults.set(false, forKey: "use_local_transcription")
        defaults.set(true, forKey: "realtime_streaming_enabled")
        AppSettingsStorage.save("global-key", account: "groq_api_key")

        await MainActor.run {
            let appState = AppState()

            precondition(appState.currentNoteBrowserTranscriptionMode == .apiStandard)
            precondition(!appState.useLocalTranscription)
            precondition(!appState.realtimeStreamingEnabled)
        }
    }

    private static func testSystemDefaultAndSystemAudioKeepsStoredAPIRealtimeWhenNoFallbackIsAvailable() async {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set(AudioInputDevice.systemDefaultAndSystemAudioID, forKey: "selected_microphone_id")
        defaults.set(false, forKey: "use_local_transcription")
        defaults.set(true, forKey: "realtime_streaming_enabled")

        await MainActor.run {
            let appState = AppState()

            precondition(appState.currentNoteBrowserTranscriptionMode == .apiRealtime)
            precondition(!appState.useLocalTranscription)
            precondition(appState.realtimeStreamingEnabled)
        }
    }

    private static func testSystemDefaultAndSystemAudioKeepsStoredAppleLiveWhenWhisperIsUnavailable() async {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set(AudioInputDevice.systemDefaultAndSystemAudioID, forKey: "selected_microphone_id")
        defaults.set(true, forKey: "use_local_transcription")
        defaults.set("apple-speech", forKey: "local_transcription_model")

        await MainActor.run {
            let appState = AppState()

            precondition(appState.currentNoteBrowserTranscriptionMode == .localAppleLive)
            precondition(appState.useLocalTranscription)
            precondition(appState.localTranscriptionModel.isAppleSpeech)
        }
    }

    private static func testGoogleCalendarConnectionMetadataRestoresStartupState() throws {
        resetDefaults()
        let selectedCalendarIDs: Set<String> = ["primary"]
        UserDefaults.standard.set(try JSONEncoder().encode(Array(selectedCalendarIDs).sorted()), forKey: "google_calendar_selected_ids")
        let metadata = GoogleCalendarConnectionMetadata(accountEmail: "user@example.com")
        UserDefaults.standard.set(try JSONEncoder().encode(metadata), forKey: GoogleCalendarConnectionMetadata.storageKey)

        let appState = AppState()

        assert(appState.googleCalendarConnection.isConnected)
        assert(appState.googleCalendarConnection.accountEmail == "user@example.com")
        assert(appState.googleCalendarConnection.selectedCalendarIDs == selectedCalendarIDs)
        assert(appState.googleCalendarConnection.health.status == .unknown)
        assert(appState.googleCalendarConnection.health.checkedAt == nil)
    }

    private static func testGoogleCalendarConnectionMetadataClearsCorruptValue() {
        resetDefaults()
        UserDefaults.standard.set(Data("not-json".utf8), forKey: GoogleCalendarConnectionMetadata.storageKey)

        let appState = AppState()

        assert(!appState.googleCalendarConnection.isConnected)
        assert(UserDefaults.standard.data(forKey: GoogleCalendarConnectionMetadata.storageKey) == nil)
    }

    private static func testCalendarRecordingReminderLeadMinutesMigrateLegacyValue() {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set(30, forKey: "calendar_recording_reminder_lead_minutes")
        defaults.removeObject(forKey: "calendar_recording_reminder_lead_minutes_list")

        let appState = AppState()

        assert(appState.calendarRecordingReminderLeadMinutes == [30])
        assert(defaults.array(forKey: "calendar_recording_reminder_lead_minutes_list") as? [Int] == [30])
    }

    private static func testCalendarRecordingReminderLeadMinutesNormalizesStoredSelection() {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set([120, 14, 14], forKey: "calendar_recording_reminder_lead_minutes_list")

        let appState = AppState()

        assert(appState.calendarRecordingReminderLeadMinutes == [15, 60])
        assert(defaults.array(forKey: "calendar_recording_reminder_lead_minutes_list") as? [Int] == [15, 60])
    }

    private static func testCalendarRecordingReminderLeadMinutesDefaultsStoredEmptySelection() {
        resetDefaults()
        let defaults = UserDefaults.standard
        defaults.set([], forKey: "calendar_recording_reminder_lead_minutes_list")

        let appState = AppState()

        assert(appState.calendarRecordingReminderLeadMinutes == [CalendarRecordingReminderScheduler.defaultLeadMinutes])
        assert(defaults.array(forKey: "calendar_recording_reminder_lead_minutes_list") as? [Int] == [CalendarRecordingReminderScheduler.defaultLeadMinutes])
    }

    private static func testCalendarRecordingReminderLeadMinutesPersistNormalizedSelection() {
        resetDefaults()
        let defaults = UserDefaults.standard
        let appState = AppState()

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
            AppState().googleCalendarOAuthConfiguration
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

        let appState = AppState()
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

        let appState = AppState()
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
        let appState = AppState()
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

        let appState = AppState()
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

        let appState = AppState()
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

        let appState = AppState()
        await appState.loadGoogleCalendars(force: true)

        assert(appState.googleCalendarConnection.isConnected)
        assert(appState.googleCalendarConnection.health.status == .healthy)
        assert(appState.googleCalendarConnection.health.affectedFeature == .calendarList)
        assert(appState.googleCalendarConnection.lastErrorMessage == nil)
        assert(appState.availableGoogleCalendars.map(\.id) == ["primary"])
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

    private struct CalendarListFailure: Error {}

    private static func testStoppedTranscriptionSettingsSnapshotCapturesHistoryMetadata() {
        let snapshot = StoppedTranscriptionSettingsSnapshot(
            customVocabulary: "team terms",
            customSystemPrompt: "custom prompt",
            useLocalTranscription: true,
            localTranscriptionModel: .find(id: "apple-speech"),
            transcriptionLanguage: .find(code: "en"),
            usedContextCapture: true,
            usedPostProcessing: false,
            preserveExactWording: true
        )

        precondition(snapshot.customVocabulary == "team terms")
        precondition(snapshot.customSystemPrompt == "custom prompt")
        precondition(snapshot.useLocalTranscription)
        precondition(snapshot.localTranscriptionModel.id == "apple-speech")
        precondition(snapshot.transcriptionLanguage.code == "en")
        precondition(snapshot.usedContextCapture)
        precondition(!snapshot.usedPostProcessing)
        precondition(snapshot.preserveExactWording)
    }

    private static func resetDefaults() {
        let isolatedSettingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-app-state-transcription-tests-\(ProcessInfo.processInfo.globallyUniqueString)",
                isDirectory: true
            )
        try? FileManager.default.removeItem(at: isolatedSettingsDirectory)
        AppSettingsStorage.storageDirectoryOverride = isolatedSettingsDirectory
        AppSettingsStorage.delete(account: "groq_api_key")
        AppSettingsStorage.delete(account: "transcription_api_key")
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("app_state_transcription_test_") {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: "use_local_transcription")
        defaults.removeObject(forKey: "use_legacy_mlx_whisper")
        defaults.removeObject(forKey: "show_legacy_mlx_whisper_options")
        defaults.removeObject(forKey: "local_transcription_model")
        defaults.removeObject(forKey: "transcription_language")
        defaults.removeObject(forKey: "context_model")
        defaults.removeObject(forKey: "preserve_exact_wording")
        defaults.removeObject(forKey: "selected_microphone_id")
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
