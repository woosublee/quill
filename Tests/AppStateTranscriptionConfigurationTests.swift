import Combine
import Foundation

@main
struct AppStateTranscriptionConfigurationTests {
    static func main() async throws {
        try testMakeTranscriptionServiceUsesLocalConfiguration()
        try testMakeTranscriptionServiceMapsEmptyLocalWhisperPathToNil()
        try testMakeTranscriptionServiceDefaultsLegacyMlxWhisperOff()
        try testMakeTranscriptionServicePassesLegacyMlxWhisperToggle()
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
        try testNoteBrowserTranscriptionMenuUsesFlatNativeCheckedItems()
        await testAPITranscriptionModesRequireResolvedAPIKey()
        try testSettingsAPIProviderTabDoesNotForceUnavailableAPIMode()
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
        precondition(importBody.contains("useLegacyMlxWhisper: useLegacyMlxWhisper,"))
        precondition(importBody.contains("let transcriptionService = try configuration.makeTranscriptionService()"))
        precondition(source.contains("let useLegacyMlxWhisper: Bool"))
        precondition(retryBody.contains("useLegacyMlxWhisper: snapshot.useLegacyMlxWhisper,"))
        precondition(stoppedRecordingBody.contains("let capturedUseLegacyMlxWhisper = useLegacyMlxWhisper"))
        precondition(stoppedRecordingBody.contains("useLegacyMlxWhisper: capturedUseLegacyMlxWhisper,"))
    }

    private static func testNoteBrowserTranscriptionMenuUsesFlatNativeCheckedItems() throws {
        let source = try String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)
        guard let itemStart = source.range(of: "private func transcriptionModeMenuItem")?.lowerBound,
              let bodyStart = source.range(of: "var body: some View", range: itemStart..<source.endIndex)?.lowerBound else {
            preconditionFailure("Expected transcription menu item block")
        }
        let menuItemSource = String(source[itemStart..<bodyStart])

        precondition(source.contains("transcriptionModeMenuItem(\"Standard\", mode: .apiStandard)"))
        precondition(source.contains("transcriptionModeMenuItem(\"Realtime\", mode: .apiRealtime)"))
        precondition(source.contains("transcriptionModeMenuItem(\"Whisper\", mode: .localWhisper)"))
        precondition(source.contains("transcriptionModeMenuItem(\"Apple Live\", mode: .localAppleLive)"))
        precondition(menuItemSource.contains("Toggle(isOn: Binding<Bool>("))
        precondition(menuItemSource.contains("get: { appState.currentNoteBrowserTranscriptionMode == mode }"))
        precondition(menuItemSource.contains("if isSelected { appState.setNoteBrowserTranscriptionMode(mode) }"))
        precondition(menuItemSource.contains(".disabled(!appState.isNoteBrowserTranscriptionModeAvailable(mode))"))
        precondition(!menuItemSource.contains("Picker(\"Transcription\", selection:"))
        precondition(!menuItemSource.contains("Image(systemName: \"checkmark\")"))
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
        defaults.removeObject(forKey: "local_transcription_model")
        defaults.removeObject(forKey: "transcription_language")
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
