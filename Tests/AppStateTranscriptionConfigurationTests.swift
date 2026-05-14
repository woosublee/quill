import Combine
import Foundation

@main
struct AppStateTranscriptionConfigurationTests {
    static func main() throws {
        try testMakeTranscriptionServiceUsesLocalConfiguration()
        try testMakeTranscriptionServiceMapsEmptyLocalWhisperPathToNil()
        testPermissionStatusUpdateSkipsUnchangedValues()
        testRecordingOverlayLayoutPersistsWithoutCompactOverlayBoolean()
        testRecordingCancelShortcutDefaultsToEscape()
        testRecordingCancelShortcutPersistsDisabled()
        testRecordingCancelShortcutPersistsCustomShortcut()
        testRecordingCancelShortcutDisablesDefaultWhenStoredHoldUsesEscape()
        testRecordingCancelShortcutRejectsHoldConflict()
        testHoldShortcutRejectsCancelConflict()
        testHoldShortcutRejectsMoreSpecificCancelOverlap()
        testRecordingCancelShortcutRejectsModifierOnlyOverlapWithKeyCombo()
        testRecordingCancelShortcutRejectsMoreSpecificHoldOverlap()
        testRecordingCancelShortcutRejectsManualModifierRuntimeOverlap()
        testCommandModeManualModifierReportsCancelOverlap()
        testStoppedTranscriptionCompletionSummaryTrimsFinalTranscript()
        testStoppedTranscriptionCompletionSummaryShowsFallbackIndicatorForNonEmptyRawFallback()
        testStoppedTranscriptionCompletionSummaryHidesFallbackIndicatorForEmptyRawFallback()
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

        assert(summary.rawTranscript == "raw transcript")
        assert(summary.finalTranscript == "final transcript")
        assert(summary.prompt == "prompt")
        assert(summary.processingStatus == "Post-processing succeeded")
        assert(!summary.shouldPressEnterAfterPaste)
        assert(!summary.shouldPersistRawDictationFallback)
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

        assert(summary.shouldPersistRawDictationFallback)
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

        assert(summary.finalTranscript.isEmpty)
        assert(summary.shouldPressEnterAfterPaste)
        assert(!summary.shouldPersistRawDictationFallback)
    }

    private static func resetDefaults() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("app_state_transcription_test_") {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: "use_local_transcription")
        defaults.removeObject(forKey: "local_transcription_model")
        defaults.removeObject(forKey: "transcription_language")
        defaults.removeObject(forKey: "hold_shortcut")
        defaults.removeObject(forKey: "toggle_shortcut")
        defaults.removeObject(forKey: "recording_cancel_shortcut")
        defaults.removeObject(forKey: "saved_hold_custom_shortcut")
        defaults.removeObject(forKey: "saved_toggle_custom_shortcut")
        defaults.removeObject(forKey: "saved_recording_cancel_custom_shortcut")
        defaults.removeObject(forKey: "command_mode_enabled")
        defaults.removeObject(forKey: "command_mode_style")
        defaults.removeObject(forKey: "command_mode_manual_modifier")
    }

    private static func mirroredTranscriptionConfiguration(_ service: TranscriptionService) -> (
        useLocalTranscription: Bool,
        localTranscriptionModelID: String,
        transcriptionLanguageCode: String,
        localWhisperPath: String?
    ) {
        let mirror = Mirror(reflecting: service)
        let useLocalTranscription = mirror.descendant("useLocalTranscription") as? Bool ?? false
        let localTranscriptionModel = mirror.descendant("localTranscriptionModel") as? TranscriptionModel ?? .default
        let transcriptionLanguage = mirror.descendant("transcriptionLanguage") as? TranscriptionLanguage ?? .auto
        let localWhisperPath = mirror.descendant("localWhisperPath") as? String
        return (useLocalTranscription, localTranscriptionModel.id, transcriptionLanguage.code, localWhisperPath)
    }
}
