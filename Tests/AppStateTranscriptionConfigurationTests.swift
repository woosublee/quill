import Combine
import Foundation

@main
struct AppStateTranscriptionConfigurationTests {
    static func main() async throws {
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
        testStoppedTranscriptionSettingsSnapshotCapturesHistoryMetadata()
        try testGoogleCalendarConnectionMetadataRestoresStartupState()
        testGoogleCalendarConnectionMetadataClearsCorruptValue()
        await testGoogleCalendarStoredCustomOAuthCredentialsAreIgnored()
        await testGoogleCalendarRefreshMarksNeedsReconnectWhenTokenMissing()
        await testGoogleCalendarRefreshMarksNeedsReconnectWhenRefreshTokenIsMissing()
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
        defaults.removeObject(forKey: "google_calendar_client_id")
        defaults.removeObject(forKey: "google_calendar_selected_ids")
        defaults.removeObject(forKey: "calendar_recording_reminders_enabled")
        defaults.removeObject(forKey: "calendar_recording_reminder_lead_minutes")
        defaults.removeObject(forKey: "calendar_recording_reminder_refresh_interval_minutes")
        defaults.removeObject(forKey: GoogleCalendarConnectionMetadata.storageKey)
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
