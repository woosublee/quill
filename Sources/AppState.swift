import Foundation
import Combine
import AppKit
import AVFoundation
import ServiceManagement
import ApplicationServices
import ScreenCaptureKit
import Speech
import os.log
private let recordingLog = OSLog(subsystem: "com.woosublee.quill", category: "Recording")
private let calendarLog = OSLog(subsystem: "com.woosublee.quill", category: "Calendar")

struct VoiceMacro: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var command: String
    var payload: String
}

struct PrecomputedMacro {
    let original: VoiceMacro
    let normalizedCommand: String
}

private struct PreservedPasteboardEntry {
    let type: NSPasteboard.PasteboardType
    let value: Value

    enum Value {
        case string(String)
        case propertyList(Any)
        case data(Data)
    }
}

private struct PreservedPasteboardItem {
    let entries: [PreservedPasteboardEntry]

    init(item: NSPasteboardItem) {
        self.entries = item.types.compactMap { type in
            if let string = item.string(forType: type) {
                return PreservedPasteboardEntry(type: type, value: .string(string))
            }
            if let propertyList = item.propertyList(forType: type) {
                return PreservedPasteboardEntry(type: type, value: .propertyList(propertyList))
            }
            if let data = item.data(forType: type) {
                return PreservedPasteboardEntry(type: type, value: .data(data))
            }
            return nil
        }
    }

    func makePasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        for entry in entries {
            switch entry.value {
            case .string(let string):
                item.setString(string, forType: entry.type)
            case .propertyList(let propertyList):
                item.setPropertyList(propertyList, forType: entry.type)
            case .data(let data):
                item.setData(data, forType: entry.type)
            }
        }
        return item
    }
}

private struct PreservedPasteboardSnapshot {
    let items: [PreservedPasteboardItem]

    init(pasteboard: NSPasteboard) {
        self.items = (pasteboard.pasteboardItems ?? []).map(PreservedPasteboardItem.init)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        _ = pasteboard.writeObjects(items.map { $0.makePasteboardItem() })
    }
}

private struct PendingClipboardRestore {
    let snapshot: PreservedPasteboardSnapshot
    let expectedChangeCount: Int
    let writtenTranscript: String
}

struct AudioImportTranscriptionConfiguration {
    let mode: NoteBrowserTranscriptionMode
    let useLocalTranscription: Bool
    let localTranscriptionModel: TranscriptionModel
    let useLegacyMlxWhisper: Bool
    let transcriptionModel: String
}

private struct AudioImportTaskConfiguration {
    let mode: NoteBrowserTranscriptionMode
    let useLocalTranscription: Bool
    let localTranscriptionModel: TranscriptionModel
    let transcriptionAPIKey: String
    let transcriptionAPIBaseURL: String
    let localWhisperPath: String
    let useLegacyMlxWhisper: Bool
    let transcriptionLanguage: TranscriptionLanguage
    let transcriptionModel: String
    let customVocabulary: String
    let customSystemPrompt: String
    let outputLanguage: String
    let postProcessingEnabled: Bool
    let preserveExactWording: Bool
    let pressEnterCommandEnabled: Bool
    let postProcessingAPIKey: String
    let postProcessingBaseURL: String
    let postProcessingModel: String
    let postProcessingFallbackModel: String
    let instructionExecutionGuardEnabled: Bool

    init(
        transcriptionConfiguration: AudioImportTranscriptionConfiguration,
        transcriptionAPIKey: String,
        transcriptionAPIBaseURL: String,
        localWhisperPath: String,
        transcriptionLanguage: TranscriptionLanguage,
        customVocabulary: String,
        customSystemPrompt: String,
        outputLanguage: String,
        postProcessingEnabled: Bool,
        preserveExactWording: Bool,
        pressEnterCommandEnabled: Bool,
        postProcessingAPIKey: String,
        postProcessingBaseURL: String,
        postProcessingModel: String,
        postProcessingFallbackModel: String,
        instructionExecutionGuardEnabled: Bool
    ) {
        self.mode = transcriptionConfiguration.mode
        self.useLocalTranscription = transcriptionConfiguration.useLocalTranscription
        self.localTranscriptionModel = transcriptionConfiguration.localTranscriptionModel
        self.transcriptionAPIKey = transcriptionAPIKey
        self.transcriptionAPIBaseURL = transcriptionAPIBaseURL
        self.localWhisperPath = localWhisperPath
        self.useLegacyMlxWhisper = transcriptionConfiguration.useLegacyMlxWhisper
        self.transcriptionLanguage = transcriptionLanguage
        self.transcriptionModel = transcriptionConfiguration.transcriptionModel
        self.customVocabulary = customVocabulary
        self.customSystemPrompt = customSystemPrompt
        self.outputLanguage = outputLanguage
        self.postProcessingEnabled = postProcessingEnabled
        self.preserveExactWording = preserveExactWording
        self.pressEnterCommandEnabled = pressEnterCommandEnabled
        self.postProcessingAPIKey = postProcessingAPIKey
        self.postProcessingBaseURL = postProcessingBaseURL
        self.postProcessingModel = postProcessingModel
        self.postProcessingFallbackModel = postProcessingFallbackModel
        self.instructionExecutionGuardEnabled = instructionExecutionGuardEnabled
    }

    var systemPrompt: String {
        AppState.resolvedSystemPrompt(customSystemPrompt)
    }

    func makePostProcessingService() -> PostProcessingService {
        PostProcessingService(
            apiKey: postProcessingAPIKey,
            baseURL: postProcessingBaseURL,
            preferredModel: postProcessingModel,
            preferredFallbackModel: postProcessingFallbackModel,
            instructionExecutionGuardEnabled: instructionExecutionGuardEnabled
        )
    }

    func makeTranscriptionService() throws -> TranscriptionService {
        try TranscriptionService(
            apiKey: transcriptionAPIKey,
            baseURL: transcriptionAPIBaseURL,
            useLocalTranscription: useLocalTranscription,
            localWhisperPath: localWhisperPath.isEmpty ? nil : localWhisperPath,
            useLegacyMlxWhisper: useLegacyMlxWhisper,
            transcriptionLanguage: transcriptionLanguage,
            localTranscriptionModel: localTranscriptionModel,
            transcriptionModel: transcriptionModel
        )
    }
}

private struct RetrySnapshot {
    let item: PipelineHistoryItem
    let audioURL: URL
    let restoredContext: AppContext
    let restoredIntent: SessionIntent
    let transcriptionLanguage: TranscriptionLanguage
    let localTranscriptionModel: TranscriptionModel
    let useLocalTranscription: Bool
    let customVocabulary: String
    let customSystemPrompt: String
    let outputLanguage: String
    let postProcessingEnabled: Bool
    let preserveExactWording: Bool
    let localWhisperPath: String?
    let useLegacyMlxWhisper: Bool
    let transcriptionModel: String
}

private struct TranscriptCommandParsingResult {
    let transcript: String
    let shouldPressEnterAfterPaste: Bool
}

struct StoppedTranscriptionCompletionSummary {
    let rawTranscript: String
    let finalTranscript: String
    let prompt: String
    let processingStatus: String
    let shouldPressEnterAfterPaste: Bool
    let shouldPersistRawDictationFallback: Bool

    init(
        rawTranscript: String,
        finalTranscript: String,
        prompt: String,
        processingStatus: String,
        shouldPressEnterAfterPaste: Bool,
        outcomeWasPostProcessingFailedFallback: Bool
    ) {
        self.rawTranscript = rawTranscript
        self.finalTranscript = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        self.prompt = prompt
        self.processingStatus = processingStatus
        self.shouldPressEnterAfterPaste = shouldPressEnterAfterPaste
        self.shouldPersistRawDictationFallback = outcomeWasPostProcessingFailedFallback && !self.finalTranscript.isEmpty
    }
}

struct StoppedTranscriptionSettingsSnapshot {
    let customVocabulary: String
    let customSystemPrompt: String
    let useLocalTranscription: Bool
    let localTranscriptionModel: TranscriptionModel
    let transcriptionLanguage: TranscriptionLanguage
    let usedContextCapture: Bool
    let usedPostProcessing: Bool
    let preserveExactWording: Bool
}

private enum CommandInvocation: String {
    case automatic
    case manual
}

private enum SessionIntent {
    case dictation
    case command(invocation: CommandInvocation, selectedText: String)

    var isCommandMode: Bool {
        switch self {
        case .dictation:
            return false
        case .command:
            return true
        }
    }

    var persistedIntent: PipelineHistoryItemIntent {
        switch self {
        case .dictation:
            return .dictation
        case .command(let invocation, _):
            switch invocation {
            case .automatic:
                return .commandAutomatic
            case .manual:
                return .commandManual
            }
        }
    }

    var persistedSelectedText: String? {
        switch self {
        case .dictation:
            return nil
        case .command(_, let selectedText):
            return selectedText
        }
    }

    var isManualCommand: Bool {
        switch self {
        case .command(invocation: .manual, _):
            return true
        default:
            return false
        }
    }

    static func fromPersisted(intent: PipelineHistoryItemIntent, selectedText: String?) -> SessionIntent {
        if intent == .commandAutomatic, let selectedText {
            return .command(invocation: .automatic, selectedText: selectedText)
        }
        if intent == .commandManual, let selectedText {
            return .command(invocation: .manual, selectedText: selectedText)
        }
        return .dictation
    }
}

final class AppState: ObservableObject, @unchecked Sendable {
    static var googleCalendarTokenLoader: (Bool) -> GoogleCalendarOAuthToken? = { allowsAuthenticationUI in
        GoogleCalendarTokenStore.load(allowsAuthenticationUI: allowsAuthenticationUI)
    }
    static var googleCalendarServiceFactory: () -> GoogleCalendarService = {
        GoogleCalendarService()
    }
    static var nativeWhisperInstallStatusProvider: (NativeWhisperModel) -> NativeWhisperInstallStatus = { model in
        NativeWhisperModelStore().installStatus(for: model)
    }

    private struct TranscriptionJob {
        let id: UUID
        let startedAt: Date
        let sessionIntent: SessionIntent
        let sessionContext: AppContext?
        let contextTask: Task<AppContext?, Never>?
        var task: Task<Void, Never>?
        var audioFileName: String?
        var liveNoteID: UUID?
        var recordingStartedAt: Date?
        var recordingEndedAt: Date?
        var isImportedAudio: Bool
    }

    private enum ActiveAudioInterruption {
        case muted(previouslyMuted: Bool)
    }

    private let apiKeyStorageKey = "groq_api_key"
    private let apiBaseURLStorageKey = "api_base_url"
    private let transcriptionModelStorageKey = AppState.transcriptionModelStorageKeyName
    private let transcriptionAPIURLStorageKey = "transcription_api_url"
    private let transcriptionAPIKeyStorageKey = "transcription_api_key"
    private let postProcessingModelStorageKey = "post_processing_model"
    private let postProcessingFallbackModelStorageKey = "post_processing_fallback_model"
    private let contextModelStorageKey = "context_model"
    private let holdShortcutStorageKey = "hold_shortcut"
    private let toggleShortcutStorageKey = "toggle_shortcut"
    private let recordingCancelShortcutStorageKey = "recording_cancel_shortcut"
    private let copyAgainShortcutStorageKey = "copy_again_shortcut"
    private let savedHoldCustomShortcutStorageKey = "saved_hold_custom_shortcut"
    private let savedToggleCustomShortcutStorageKey = "saved_toggle_custom_shortcut"
    private let savedRecordingCancelCustomShortcutStorageKey = "saved_recording_cancel_custom_shortcut"
    private let savedCopyAgainCustomShortcutStorageKey = "saved_copy_again_custom_shortcut"
    private let customVocabularyStorageKey = "custom_vocabulary"
    private let selectedMicrophoneStorageKey = "selected_microphone_id"
    private let customSystemPromptStorageKey = "custom_system_prompt"
    private let customContextPromptStorageKey = "custom_context_prompt"
    private let instructionExecutionGuardEnabledStorageKey = "instruction_execution_guard_enabled"
    private let customSystemPromptLastModifiedStorageKey = "custom_system_prompt_last_modified"
    private let customContextPromptLastModifiedStorageKey = "custom_context_prompt_last_modified"
    private let contextScreenshotMaxDimensionStorageKey = "context_screenshot_max_dimension"
    private let shortcutStartDelayStorageKey = "shortcut_start_delay"
    private let preserveClipboardStorageKey = "preserve_clipboard"
    private let keepDictationInClipboardHistoryStorageKey = "keep_dictation_in_clipboard_history"
    private let pressEnterVoiceCommandStorageKey = "press_enter_voice_command_enabled"
    private let alertSoundsEnabledStorageKey = "alert_sounds_enabled"
    private let soundVolumeStorageKey = "sound_volume"
    private let voiceMacrosStorageKey = "voice_macros"
    private let useLocalTranscriptionStorageKey = "use_local_transcription"
    private let localWhisperPathStorageKey = "local_whisper_path"
    private let useLegacyMlxWhisperStorageKey = "use_legacy_mlx_whisper"
    private let showLegacyMlxWhisperOptionsStorageKey = "show_legacy_mlx_whisper_options"
    private let disableContextCaptureStorageKey = "disable_context_capture"
    private let disableAutoPasteStorageKey = "disable_auto_paste"
    private let disablePostProcessingStorageKey = "disable_post_processing"
    private let preserveExactWordingStorageKey = "preserve_exact_wording"
    private let transcriptionLanguageStorageKey = "transcription_language"
    private let outputLanguageStorageKey = "output_language"
    private let localTranscriptionModelStorageKey = AppState.localTranscriptionModelStorageKeyName
    private let noteBrowserEnabledStorageKey = "note_browser_enabled"
    private let commandModeEnabledStorageKey = "command_mode_enabled"
    private let commandModeStyleStorageKey = "command_mode_style"
    private let commandModeManualModifierStorageKey = "command_mode_manual_modifier"
    private let realtimeStreamingEnabledStorageKey = "realtime_streaming_enabled"
    private let realtimeStreamingModelStorageKey = "realtime_streaming_model"
    private let dictationAudioInterruptionEnabledStorageKey = "dictation_audio_interruption_enabled"
    private let recordingOverlayLayoutStorageKey = "recording_overlay_layout"
    private let overlayWaveformDisplayModeStorageKey = "overlay_waveform_display_mode"
    private let googleCalendarSelectedIDsStorageKey = "google_calendar_selected_ids"
    private let calendarRecordingRemindersEnabledStorageKey = "calendar_recording_reminders_enabled"
    private let legacyCalendarRecordingReminderLeadMinutesStorageKey = "calendar_recording_reminder_lead_minutes"
    private let calendarRecordingReminderLeadMinutesListStorageKey = "calendar_recording_reminder_lead_minutes_list"
    private let calendarRecordingReminderRefreshIntervalMinutesStorageKey = "calendar_recording_reminder_refresh_interval_minutes"
    private let pendingMutedAudioRestoreStorageKey = "pending_muted_audio_restore"
    private let pasteAfterShortcutReleaseDelay: TimeInterval = 0.03
    private let pressEnterAfterPasteDelay: TimeInterval = 0.08
    private let clipboardRestoreDelay: TimeInterval = 1.0
    let maxPipelineHistoryCount = Int.max
    static let defaultContextScreenshotMaxDimension = Int(AppContextService.defaultScreenshotMaxDimension)
    static let contextScreenshotDimensionOptions = [1024, 768, 640, 512]
    static let defaultTranscriptionModel = "whisper-large-v3"
    static let defaultPostProcessingModel = "openai/gpt-oss-20b"
    static let defaultPostProcessingFallbackModel = "meta-llama/llama-4-scout-17b-16e-instruct"
    static let defaultContextModel = "qwen/qwen3.6-27b"
    private static let deprecatedDefaultContextModel = "meta-llama/llama-4-scout-17b-16e-instruct"
    private static let trailingPressEnterCommandPattern = try! NSRegularExpression(
        pattern: #"(?i)(?:^|[ \t\r\n,;:\-]+)press[ \t\r\n]+enter[\s\p{P}]*$"#
    )

    private static let transcriptionModelStorageKeyName = "transcription_model"
    private static let localTranscriptionModelStorageKeyName = "local_transcription_model"
    private static let legacyAPITranscriptionModelStorageKeyName = "api_transcription_model"

    private static func migrateModelStorageKeys() {
        let defaults = UserDefaults.standard
        let sharedValue = defaults.string(forKey: transcriptionModelStorageKeyName)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let legacyAPIValue = defaults.string(forKey: legacyAPITranscriptionModelStorageKeyName)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let localValue = defaults.string(forKey: localTranscriptionModelStorageKeyName)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sharedLooksLikeLocalModel = !sharedValue.isEmpty && TranscriptionModel.all.contains(where: { $0.id == sharedValue })

        if localValue.isEmpty, sharedLooksLikeLocalModel {
            defaults.set(sharedValue, forKey: localTranscriptionModelStorageKeyName)
        }

        if !legacyAPIValue.isEmpty {
            defaults.set(legacyAPIValue, forKey: transcriptionModelStorageKeyName)
            defaults.removeObject(forKey: legacyAPITranscriptionModelStorageKeyName)
        } else if sharedLooksLikeLocalModel {
            defaults.set(defaultTranscriptionModel, forKey: transcriptionModelStorageKeyName)
        }
    }

    @Published var hasCompletedSetup: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedSetup, forKey: "hasCompletedSetup")
        }
    }

    @Published var apiKey: String {
        didSet {
            persistAPIKey(apiKey)
            rebuildContextService()
            scheduleNoteBrowserTranscriptionModeNormalizationForProviderConfiguration()
        }
    }

    @Published var apiBaseURL: String {
        didSet {
            persistAPIBaseURL(apiBaseURL)
            rebuildContextService()
        }
    }

    @Published var transcriptionAPIURL: String {
        didSet {
            persistOptionalAPIValue(transcriptionAPIURL, account: transcriptionAPIURLStorageKey)
        }
    }

    @Published var transcriptionAPIKey: String {
        didSet {
            persistOptionalAPIValue(transcriptionAPIKey, account: transcriptionAPIKeyStorageKey)
            scheduleNoteBrowserTranscriptionModeNormalizationForProviderConfiguration()
        }
    }

    @Published var transcriptionModel: String {
        didSet {
            UserDefaults.standard.set(transcriptionModel, forKey: transcriptionModelStorageKey)
        }
    }

    @Published var postProcessingModel: String {
        didSet {
            UserDefaults.standard.set(postProcessingModel, forKey: postProcessingModelStorageKey)
        }
    }

    @Published var postProcessingFallbackModel: String {
        didSet {
            UserDefaults.standard.set(postProcessingFallbackModel, forKey: postProcessingFallbackModelStorageKey)
        }
    }

    @Published var contextModel: String {
        didSet {
            UserDefaults.standard.set(contextModel, forKey: contextModelStorageKey)
            rebuildContextService()
        }
    }

    @Published var holdShortcut: ShortcutBinding {
        didSet {
            persistShortcut(holdShortcut, key: holdShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var toggleShortcut: ShortcutBinding {
        didSet {
            persistShortcut(toggleShortcut, key: toggleShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var recordingCancelShortcut: ShortcutBinding {
        didSet {
            persistShortcut(recordingCancelShortcut, key: recordingCancelShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var copyAgainShortcut: ShortcutBinding {
        didSet {
            persistShortcut(copyAgainShortcut, key: copyAgainShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published private(set) var savedHoldCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedHoldCustomShortcut, key: savedHoldCustomShortcutStorageKey)
        }
    }

    @Published private(set) var savedToggleCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedToggleCustomShortcut, key: savedToggleCustomShortcutStorageKey)
        }
    }

    @Published private(set) var savedRecordingCancelCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedRecordingCancelCustomShortcut, key: savedRecordingCancelCustomShortcutStorageKey)
        }
    }

    @Published private(set) var savedCopyAgainCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedCopyAgainCustomShortcut, key: savedCopyAgainCustomShortcutStorageKey)
        }
    }

    @Published var isCommandModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isCommandModeEnabled, forKey: commandModeEnabledStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var commandModeStyle: CommandModeStyle {
        didSet {
            UserDefaults.standard.set(commandModeStyle.rawValue, forKey: commandModeStyleStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published private(set) var commandModeManualModifier: CommandModeManualModifier {
        didSet {
            UserDefaults.standard.set(commandModeManualModifier.rawValue, forKey: commandModeManualModifierStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var customVocabulary: String {
        didSet {
            UserDefaults.standard.set(customVocabulary, forKey: customVocabularyStorageKey)
        }
    }

    @Published var customSystemPrompt: String {
        didSet {
            UserDefaults.standard.set(customSystemPrompt, forKey: customSystemPromptStorageKey)
        }
    }

    @Published var customContextPrompt: String {
        didSet {
            UserDefaults.standard.set(customContextPrompt, forKey: customContextPromptStorageKey)
            rebuildContextService()
        }
    }

    @Published var instructionExecutionGuardEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                instructionExecutionGuardEnabled,
                forKey: instructionExecutionGuardEnabledStorageKey
            )
        }
    }

    @Published var contextScreenshotMaxDimension: Int {
        didSet {
            let normalizedDimension = Self.normalizedContextScreenshotMaxDimension(contextScreenshotMaxDimension)
            if normalizedDimension != contextScreenshotMaxDimension {
                contextScreenshotMaxDimension = normalizedDimension
            }
            UserDefaults.standard.set(contextScreenshotMaxDimension, forKey: contextScreenshotMaxDimensionStorageKey)
            rebuildContextService()
        }
    }

    @Published var customSystemPromptLastModified: String {
        didSet {
            UserDefaults.standard.set(customSystemPromptLastModified, forKey: customSystemPromptLastModifiedStorageKey)
        }
    }

    @Published var customContextPromptLastModified: String {
        didSet {
            UserDefaults.standard.set(customContextPromptLastModified, forKey: customContextPromptLastModifiedStorageKey)
        }
    }

    @Published var shortcutStartDelay: TimeInterval {
        didSet {
            UserDefaults.standard.set(shortcutStartDelay, forKey: shortcutStartDelayStorageKey)
        }
    }

    /// Stream audio to the transcription backend during recording via the
    /// OpenAI Realtime WebSocket. Reduces wall-clock latency between "stop"
    /// and text-ready because most of the transcription work happens while
    /// the user is still speaking.
    @Published var realtimeStreamingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(realtimeStreamingEnabled, forKey: realtimeStreamingEnabledStorageKey)
        }
    }

    /// Model ID the realtime WebSocket should transcribe with. Empty means
    /// "use the server's default".
    @Published var realtimeStreamingModel: String {
        didSet {
            UserDefaults.standard.set(realtimeStreamingModel, forKey: realtimeStreamingModelStorageKey)
        }
    }

    @Published var dictationAudioInterruptionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                dictationAudioInterruptionEnabled,
                forKey: dictationAudioInterruptionEnabledStorageKey
            )
        }
    }

    @Published var recordingOverlayLayout: RecordingOverlayLayout {
        didSet {
            UserDefaults.standard.set(recordingOverlayLayout.rawValue, forKey: recordingOverlayLayoutStorageKey)
            overlayManager.setRecordingOverlayLayout(recordingOverlayLayout)
        }
    }

    @Published var overlayWaveformDisplayMode: OverlayWaveformDisplayMode {
        didSet {
            UserDefaults.standard.set(overlayWaveformDisplayMode.rawValue, forKey: overlayWaveformDisplayModeStorageKey)
            overlayManager.setWaveformDisplayMode(overlayWaveformDisplayMode)
        }
    }

    @Published private(set) var googleCalendarConnection = GoogleCalendarConnectionState.disconnected
    @Published private(set) var availableGoogleCalendars: [GoogleCalendarInfo] = []
    @Published private(set) var isGoogleCalendarBusy = false
    @Published private(set) var hasPendingGoogleCalendarOAuthConnection = false

    @Published var calendarRecordingRemindersEnabled: Bool {
        didSet {
            UserDefaults.standard.set(calendarRecordingRemindersEnabled, forKey: calendarRecordingRemindersEnabledStorageKey)
            scheduleCalendarRecordingReminderRefreshFromPropertyChange()
        }
    }

    @Published var calendarRecordingReminderLeadMinutes: [Int] {
        didSet {
            let normalized = CalendarRecordingReminderScheduler.normalizedLeadMinutes(calendarRecordingReminderLeadMinutes)
            if normalized != calendarRecordingReminderLeadMinutes {
                calendarRecordingReminderLeadMinutes = normalized
                return
            }
            UserDefaults.standard.set(calendarRecordingReminderLeadMinutes, forKey: calendarRecordingReminderLeadMinutesListStorageKey)
            scheduleCalendarRecordingReminderRefreshFromPropertyChange()
        }
    }

    @Published var calendarRecordingReminderRefreshIntervalMinutes: Int {
        didSet {
            let normalized = CalendarRecordingReminderScheduler.normalizedRefreshIntervalMinutes(calendarRecordingReminderRefreshIntervalMinutes)
            if normalized != calendarRecordingReminderRefreshIntervalMinutes {
                calendarRecordingReminderRefreshIntervalMinutes = normalized
                return
            }
            UserDefaults.standard.set(calendarRecordingReminderRefreshIntervalMinutes, forKey: calendarRecordingReminderRefreshIntervalMinutesStorageKey)
            scheduleCalendarRecordingReminderRefreshFromPropertyChange()
        }
    }

    private var builtInGoogleCalendarClientID: String {
        Bundle.main.object(forInfoDictionaryKey: "GoogleCalendarOAuthClientID") as? String ?? ""
    }

    private var builtInGoogleCalendarClientSecret: String {
        Bundle.main.object(forInfoDictionaryKey: "GoogleCalendarOAuthClientSecret") as? String ?? ""
    }

    @Published var preserveClipboard: Bool {
        didSet {
            UserDefaults.standard.set(preserveClipboard, forKey: preserveClipboardStorageKey)
        }
    }

    @Published var keepDictationInClipboardHistory: Bool {
        didSet {
            UserDefaults.standard.set(keepDictationInClipboardHistory, forKey: keepDictationInClipboardHistoryStorageKey)
        }
    }

    @Published var isPressEnterVoiceCommandEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isPressEnterVoiceCommandEnabled, forKey: pressEnterVoiceCommandStorageKey)
        }
    }

    @Published var alertSoundsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(alertSoundsEnabled, forKey: alertSoundsEnabledStorageKey)
        }
    }

    @Published var useLocalTranscription: Bool {
        didSet {
            UserDefaults.standard.set(useLocalTranscription, forKey: useLocalTranscriptionStorageKey)
        }
    }

    @Published var localWhisperPath: String {
        didSet {
            UserDefaults.standard.set(localWhisperPath, forKey: localWhisperPathStorageKey)
        }
    }

    @Published var useLegacyMlxWhisper: Bool {
        didSet {
            UserDefaults.standard.set(useLegacyMlxWhisper, forKey: useLegacyMlxWhisperStorageKey)
            guard oldValue != useLegacyMlxWhisper else { return }
            scheduleNoteBrowserTranscriptionModeNormalizationForProviderConfiguration()
        }
    }

    @Published var showLegacyMlxWhisperOptions: Bool {
        didSet {
            UserDefaults.standard.set(showLegacyMlxWhisperOptions, forKey: showLegacyMlxWhisperOptionsStorageKey)
        }
    }

    @Published var disableContextCapture: Bool {
        didSet {
            UserDefaults.standard.set(disableContextCapture, forKey: disableContextCaptureStorageKey)
        }
    }

    @Published var disableAutoPaste: Bool {
        didSet {
            UserDefaults.standard.set(disableAutoPaste, forKey: disableAutoPasteStorageKey)
        }
    }

    @Published var disablePostProcessing: Bool {
        didSet {
            UserDefaults.standard.set(disablePostProcessing, forKey: disablePostProcessingStorageKey)
        }
    }

    @Published var preserveExactWording: Bool {
        didSet {
            UserDefaults.standard.set(preserveExactWording, forKey: preserveExactWordingStorageKey)
        }
    }

    @Published var noteBrowserEnabled: Bool {
        didSet {
            UserDefaults.standard.set(noteBrowserEnabled, forKey: noteBrowserEnabledStorageKey)
        }
    }

    @Published var transcriptionLanguage: TranscriptionLanguage {
        didSet {
            UserDefaults.standard.set(transcriptionLanguage.code, forKey: transcriptionLanguageStorageKey)
        }
    }

    @Published var outputLanguage: String {
        didSet {
            UserDefaults.standard.set(outputLanguage, forKey: outputLanguageStorageKey)
        }
    }

    @Published var localTranscriptionModel: TranscriptionModel {
        didSet {
            UserDefaults.standard.set(localTranscriptionModel.id, forKey: localTranscriptionModelStorageKey)
        }
    }

    @Published private(set) var nativeWhisperInstallStatus: NativeWhisperInstallStatus =
        AppState.nativeWhisperInstallStatusProvider(.recommended)
    @Published private(set) var nativeWhisperInstallProgress = NativeWhisperDownloadProgress(downloadedBytes: 0, totalBytes: NativeWhisperModelCatalog.recommended.approximateBytes)
    @Published private(set) var isInstallingNativeWhisper = false
    @Published private(set) var nativeWhisperInstallError: String?
    private var nativeWhisperInstallTask: NativeWhisperInstallTask?
    private var nativeWhisperInstallCancellationMessage: String?

    @MainActor
    var noteBrowserTranscriptionModeLabel: String {
        noteBrowserTranscriptionChoiceLabel
    }

    @MainActor
    var noteBrowserTranscriptionChoiceLabel: String {
        noteBrowserTranscriptionDisplay(for: currentNoteBrowserTranscriptionChoice).localizedTitle()
    }

    @MainActor
    var noteBrowserTranscriptionChoiceDetailLabel: String {
        noteBrowserTranscriptionDisplay(for: currentNoteBrowserTranscriptionChoice).localizedCurrentLabel()
    }

    @MainActor
    var currentNoteBrowserTranscriptionChoice: TranscriptionBackendChoice {
        if useLocalTranscription {
            if localTranscriptionModel.isAppleSpeech {
                return .appleLive
            }
            if useLegacyMlxWhisper {
                return .legacyMlxWhisper(model: localTranscriptionModel)
            }
            return nativeWhisperChoice
        }
        return realtimeStreamingEnabled ? apiRealtimeChoice : apiStandardChoice
    }

    @MainActor
    var currentNoteBrowserTranscriptionMode: NoteBrowserTranscriptionMode {
        currentNoteBrowserTranscriptionChoice.mode
    }

    @MainActor
    var noteBrowserTranscriptionChoiceDisplays: [TranscriptionChoiceDisplay] {
        [
            noteBrowserTranscriptionDisplay(for: apiStandardChoice),
            noteBrowserTranscriptionDisplay(for: apiRealtimeChoice),
            noteBrowserTranscriptionDisplay(for: nativeWhisperChoice),
            noteBrowserTranscriptionDisplay(for: .appleLive)
        ] + installedLegacyLocalWhisperModels.map { model in
            noteBrowserTranscriptionDisplay(for: .legacyMlxWhisper(model: model))
        }
    }

    @MainActor
    func label(for mode: NoteBrowserTranscriptionMode) -> String {
        noteBrowserTranscriptionDisplay(for: preferredNoteBrowserTranscriptionChoice(for: mode)).localizedCurrentLabel()
    }

    @MainActor
    func noteBrowserTranscriptionDisplay(for choice: TranscriptionBackendChoice) -> TranscriptionChoiceDisplay {
        switch choice {
        case .apiStandard(let modelID):
            let resolvedModelID = nonEmptyModelID(modelID) ?? resolvedStandardTranscriptionModelID
            let unavailableReason = hasTranscriptionAPIKey ? nil : "API key is not configured"
            return TranscriptionChoiceDisplay(
                choice: .apiStandard(modelID: resolvedModelID),
                section: "API",
                title: "Standard",
                subtitle: resolvedModelID,
                compactLabel: "Standard · \(resolvedModelID)",
                currentLabel: "API · Standard · \(resolvedModelID)",
                isAvailable: unavailableReason == nil,
                unavailableReason: unavailableReason
            )
        case .apiRealtime(let modelID):
            let resolvedModelID = nonEmptyModelID(modelID ?? realtimeStreamingModel)
            let modelLabel = resolvedModelID ?? "Provider default"
            let unavailableReason: String? = if !hasTranscriptionAPIKey {
                "API key is not configured"
            } else if AudioInputDevice.isSystemDefaultAndSystemAudio(selectedMicrophoneID) {
                "Realtime is unavailable with System Default + System Audio"
            } else {
                nil
            }
            return TranscriptionChoiceDisplay(
                choice: .apiRealtime(modelID: resolvedModelID),
                section: "API",
                title: "Realtime",
                subtitle: modelLabel,
                compactLabel: "Realtime · \(modelLabel)",
                currentLabel: "API · Realtime · \(modelLabel)",
                isAvailable: unavailableReason == nil,
                unavailableReason: unavailableReason
            )
        case .nativeWhisper:
            let unavailableReason = hasNativeLocalWhisperModel ? nil : "Install the native Local Whisper model to use this option"
            return TranscriptionChoiceDisplay(
                choice: nativeWhisperChoice,
                section: "Local",
                title: "Native Whisper",
                subtitle: nativeWhisperDisplayName,
                compactLabel: "Native Whisper · \(nativeWhisperDisplayName)",
                currentLabel: "Local · Native Whisper · \(nativeWhisperDisplayName)",
                isAvailable: unavailableReason == nil,
                unavailableReason: unavailableReason
            )
        case .legacyMlxWhisper(let model):
            let unavailableReason = model.isInstalled ? nil : "Install \(model.displayName) in Settings to use this option"
            return TranscriptionChoiceDisplay(
                choice: .legacyMlxWhisper(model: model),
                section: "Legacy mlx-whisper",
                title: "Legacy mlx-whisper",
                subtitle: model.displayName,
                compactLabel: "Legacy · \(model.displayName)",
                currentLabel: "Local · Legacy · \(model.displayName)",
                isAvailable: unavailableReason == nil,
                unavailableReason: unavailableReason
            )
        case .appleLive:
            let unavailableReason = AudioInputDevice.isSystemDefaultAndSystemAudio(selectedMicrophoneID)
                ? "Apple Live is unavailable with System Default + System Audio"
                : nil
            return TranscriptionChoiceDisplay(
                choice: .appleLive,
                section: "Local",
                title: "Apple Live",
                subtitle: "Apple Speech",
                compactLabel: "Apple Live · Apple Speech",
                currentLabel: "Local · Apple Live · Apple Speech",
                isAvailable: unavailableReason == nil,
                unavailableReason: unavailableReason
            )
        }
    }

    func audioImportLabel(for mode: NoteBrowserTranscriptionMode) -> String {
        switch mode {
        case .apiStandard, .apiRealtime: return "API Standard"
        case .localWhisper, .localAppleLive: return "Local Whisper"
        }
    }

    var hasTranscriptionAPIKey: Bool {
        !resolvedTranscriptionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasNativeLocalWhisperModel: Bool {
        nativeWhisperInstallStatus == .ready
    }

    var installedLegacyLocalWhisperModels: [TranscriptionModel] {
        TranscriptionModel.all.filter { !$0.isAppleSpeech && $0.isInstalled }
    }

    var hasAnyLocalWhisperModel: Bool {
        hasNativeLocalWhisperModel || !installedLegacyLocalWhisperModels.isEmpty
    }

    var hasInstalledLocalWhisperModel: Bool {
        if useLegacyMlxWhisper {
            return hasLegacyLocalWhisperModel
        }
        return hasNativeLocalWhisperModel
    }

    var hasLegacyLocalWhisperModel: Bool {
        !installedLegacyLocalWhisperModels.isEmpty
    }

    private var apiStandardChoice: TranscriptionBackendChoice {
        .apiStandard(modelID: resolvedStandardTranscriptionModelID)
    }

    private var apiRealtimeChoice: TranscriptionBackendChoice {
        .apiRealtime(modelID: resolvedRealtimeStreamingModelID)
    }

    private var nativeWhisperChoice: TranscriptionBackendChoice {
        .nativeWhisper(modelID: NativeWhisperModelCatalog.recommended.id)
    }

    private var nativeWhisperDisplayName: String {
        NativeWhisperModelCatalog.recommended.displayName
    }

    private var nativeLocalWhisperSelectionModel: TranscriptionModel {
        TranscriptionModel.find(id: "mlx-community/whisper-large-v3-turbo")
    }

    private var resolvedStandardTranscriptionModelID: String {
        nonEmptyModelID(transcriptionModel) ?? Self.defaultTranscriptionModel
    }

    private var resolvedRealtimeStreamingModelID: String? {
        nonEmptyModelID(realtimeStreamingModel)
    }

    private func nonEmptyModelID(_ modelID: String) -> String? {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @MainActor
    func refreshNativeWhisperInstallStatus() {
        nativeWhisperInstallStatus = Self.nativeWhisperInstallStatusProvider(.recommended)
        scheduleNoteBrowserTranscriptionModeNormalizationForProviderConfiguration()
    }

    @MainActor
    func installNativeWhisperModel() {
        guard !isInstallingNativeWhisper else { return }
        let model = NativeWhisperModelCatalog.recommended
        nativeWhisperInstallError = nil
        nativeWhisperInstallCancellationMessage = nil
        isInstallingNativeWhisper = true
        nativeWhisperInstallProgress = NativeWhisperDownloadProgress(downloadedBytes: 0, totalBytes: model.approximateBytes)
        let installer = NativeWhisperInstaller()
        nativeWhisperInstallTask = installer.install(
            model: model,
            progress: { [weak self] progress in
                DispatchQueue.main.async {
                    self?.nativeWhisperInstallProgress = progress
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.nativeWhisperInstallTask = nil
                    self.isInstallingNativeWhisper = false
                    self.refreshNativeWhisperInstallStatus()
                    if case .failure(let error) = result {
                        switch error {
                        case .cancelled:
                            self.nativeWhisperInstallError = self.nativeWhisperInstallCancellationMessage
                            self.nativeWhisperInstallCancellationMessage = nil
                        default:
                            self.nativeWhisperInstallError = error.localizedDescription
                        }
                    }
                }
            }
        )
    }

    @MainActor
    func cancelNativeWhisperInstall() {
        nativeWhisperInstallCancellationMessage = nil
        nativeWhisperInstallTask?.cancel()
        let model = NativeWhisperModelCatalog.recommended
        try? NativeWhisperModelStore().deletePartialModel(model)
        nativeWhisperInstallProgress = NativeWhisperDownloadProgress(
            downloadedBytes: nativeWhisperInstallProgress.downloadedBytes,
            totalBytes: nativeWhisperInstallProgress.totalBytes,
            isCancelled: true
        )
        refreshNativeWhisperInstallStatus()
    }

    @MainActor
    func cancelNativeWhisperInstallForSettingsClose() {
        guard isInstallingNativeWhisper else { return }
        nativeWhisperInstallCancellationMessage = "Local Whisper download was canceled because Settings was closed. Start the install again when you're ready."
        nativeWhisperInstallTask?.cancel()
        try? NativeWhisperModelStore().deletePartialModel(.recommended)
        nativeWhisperInstallProgress = NativeWhisperDownloadProgress(
            downloadedBytes: nativeWhisperInstallProgress.downloadedBytes,
            totalBytes: nativeWhisperInstallProgress.totalBytes,
            isCancelled: true
        )
        refreshNativeWhisperInstallStatus()
    }

    @MainActor
    func deleteNativeWhisperModel() {
        do {
            try NativeWhisperModelStore().deleteModel(.recommended)
            nativeWhisperInstallError = nil
        } catch {
            nativeWhisperInstallError = error.localizedDescription
        }
        refreshNativeWhisperInstallStatus()
    }

    @MainActor
    func audioImportConfiguration(
        for mode: NoteBrowserTranscriptionMode
    ) -> AudioImportTranscriptionConfiguration {
        audioImportConfiguration(for: preferredAudioImportChoice(for: mode))
    }

    @MainActor
    func audioImportConfiguration(
        for choice: TranscriptionBackendChoice
    ) -> AudioImportTranscriptionConfiguration {
        switch choice {
        case .apiStandard(let modelID):
            let resolvedModelID = nonEmptyModelID(modelID) ?? resolvedStandardTranscriptionModelID
            return AudioImportTranscriptionConfiguration(
                mode: .apiStandard,
                useLocalTranscription: false,
                localTranscriptionModel: localTranscriptionModel,
                useLegacyMlxWhisper: false,
                transcriptionModel: resolvedModelID
            )
        case .apiRealtime:
            return audioImportConfiguration(for: apiStandardChoice)
        case .nativeWhisper:
            return AudioImportTranscriptionConfiguration(
                mode: .localWhisper,
                useLocalTranscription: true,
                localTranscriptionModel: nativeLocalWhisperSelectionModel,
                useLegacyMlxWhisper: false,
                transcriptionModel: resolvedStandardTranscriptionModelID
            )
        case .legacyMlxWhisper(let model):
            return AudioImportTranscriptionConfiguration(
                mode: .localWhisper,
                useLocalTranscription: true,
                localTranscriptionModel: model,
                useLegacyMlxWhisper: true,
                transcriptionModel: resolvedStandardTranscriptionModelID
            )
        case .appleLive:
            return audioImportConfiguration(for: preferredAudioImportChoice(for: .localWhisper))
        }
    }

    @MainActor
    func isNoteBrowserTranscriptionModeAvailable(_ mode: NoteBrowserTranscriptionMode) -> Bool {
        switch mode {
        case .apiStandard:
            return hasTranscriptionAPIKey
        case .apiRealtime:
            return hasTranscriptionAPIKey && !AudioInputDevice.isSystemDefaultAndSystemAudio(selectedMicrophoneID)
        case .localWhisper:
            return hasAnyLocalWhisperModel
        case .localAppleLive:
            return !AudioInputDevice.isSystemDefaultAndSystemAudio(selectedMicrophoneID)
        }
    }

    @MainActor
    func isNoteBrowserTranscriptionChoiceAvailable(_ choice: TranscriptionBackendChoice) -> Bool {
        noteBrowserTranscriptionDisplay(for: choice).isAvailable
    }

    @MainActor
    func setNoteBrowserTranscriptionMode(_ mode: NoteBrowserTranscriptionMode) {
        setNoteBrowserTranscriptionChoice(preferredNoteBrowserTranscriptionChoice(for: mode))
    }

    @MainActor
    func setNoteBrowserTranscriptionChoice(_ choice: TranscriptionBackendChoice) {
        applyNoteBrowserTranscriptionChoice(normalizedNoteBrowserTranscriptionChoice(choice))
    }

    private func scheduleNoteBrowserTranscriptionModeNormalizationForSelectedInput() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                guard !isApplyingNoteBrowserTranscriptionChoice else { return }
                normalizeNoteBrowserTranscriptionMode()
            }
        } else {
            Task { @MainActor [weak self] in
                guard let self, !self.isApplyingNoteBrowserTranscriptionChoice else { return }
                self.normalizeNoteBrowserTranscriptionMode()
            }
        }
    }

    private func scheduleNoteBrowserTranscriptionModeNormalizationForProviderConfiguration() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                guard !isApplyingNoteBrowserTranscriptionChoice,
                      !isRecording,
                      !isTranscribing else { return }
                normalizeNoteBrowserTranscriptionMode()
            }
        } else {
            Task { @MainActor [weak self] in
                guard let self,
                      !self.isApplyingNoteBrowserTranscriptionChoice,
                      !self.isRecording,
                      !self.isTranscribing else { return }
                self.normalizeNoteBrowserTranscriptionMode()
            }
        }
    }

    @MainActor
    private func normalizeNoteBrowserTranscriptionMode() {
        let currentChoice = currentNoteBrowserTranscriptionChoice
        let normalizedChoice = normalizedNoteBrowserTranscriptionChoice(currentChoice)
        guard normalizedChoice != currentChoice else { return }
        applyNoteBrowserTranscriptionChoice(normalizedChoice)
    }

    @MainActor
    private func normalizedNoteBrowserTranscriptionMode(_ mode: NoteBrowserTranscriptionMode) -> NoteBrowserTranscriptionMode {
        normalizedNoteBrowserTranscriptionChoice(preferredNoteBrowserTranscriptionChoice(for: mode)).mode
    }

    @MainActor
    private func normalizedNoteBrowserTranscriptionChoice(_ choice: TranscriptionBackendChoice) -> TranscriptionBackendChoice {
        guard !isNoteBrowserTranscriptionChoiceAvailable(choice) else { return choice }
        return noteBrowserFallbackChoices(for: choice).first(where: isNoteBrowserTranscriptionChoiceAvailable) ?? choice
    }

    @MainActor
    private func preferredNoteBrowserTranscriptionChoice(for mode: NoteBrowserTranscriptionMode) -> TranscriptionBackendChoice {
        switch mode {
        case .apiStandard:
            return apiStandardChoice
        case .apiRealtime:
            return apiRealtimeChoice
        case .localWhisper:
            if useLegacyMlxWhisper, !localTranscriptionModel.isAppleSpeech {
                return .legacyMlxWhisper(model: localTranscriptionModel)
            }
            return nativeWhisperChoice
        case .localAppleLive:
            return .appleLive
        }
    }

    @MainActor
    private func preferredAudioImportChoice(for mode: NoteBrowserTranscriptionMode) -> TranscriptionBackendChoice {
        switch mode {
        case .apiStandard, .apiRealtime:
            return apiStandardChoice
        case .localWhisper, .localAppleLive:
            if useLegacyMlxWhisper, !localTranscriptionModel.isAppleSpeech, localTranscriptionModel.isInstalled {
                return .legacyMlxWhisper(model: localTranscriptionModel)
            }
            if hasNativeLocalWhisperModel {
                return nativeWhisperChoice
            }
            if let legacyModel = installedLegacyLocalWhisperModels.first {
                return .legacyMlxWhisper(model: legacyModel)
            }
            return nativeWhisperChoice
        }
    }

    @MainActor
    private func noteBrowserFallbackChoices(for choice: TranscriptionBackendChoice) -> [TranscriptionBackendChoice] {
        let legacyChoices = installedLegacyLocalWhisperModels.map { TranscriptionBackendChoice.legacyMlxWhisper(model: $0) }
        switch choice {
        case .apiRealtime:
            return [apiStandardChoice, nativeWhisperChoice] + legacyChoices + [.appleLive]
        case .apiStandard:
            return [nativeWhisperChoice] + legacyChoices + [.appleLive, apiRealtimeChoice]
        case .appleLive:
            return [nativeWhisperChoice] + legacyChoices + [apiStandardChoice, apiRealtimeChoice]
        case .nativeWhisper:
            return legacyChoices + [apiStandardChoice, .appleLive, apiRealtimeChoice]
        case .legacyMlxWhisper(let model):
            let sameLegacy = TranscriptionBackendChoice.legacyMlxWhisper(model: model)
            return [nativeWhisperChoice] + legacyChoices.filter { $0 != sameLegacy } + [apiStandardChoice, .appleLive, apiRealtimeChoice]
        }
    }

    @MainActor
    private func applyNoteBrowserTranscriptionMode(_ mode: NoteBrowserTranscriptionMode) {
        applyNoteBrowserTranscriptionChoice(preferredNoteBrowserTranscriptionChoice(for: mode))
    }

    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppState, Value>, to value: Value) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }

    @MainActor
    private func applyNoteBrowserTranscriptionChoice(_ choice: TranscriptionBackendChoice) {
        guard !isApplyingNoteBrowserTranscriptionChoice else { return }
        isApplyingNoteBrowserTranscriptionChoice = true
        defer { isApplyingNoteBrowserTranscriptionChoice = false }

        switch choice {
        case .apiStandard(let modelID):
            update(\AppState.transcriptionModel, to: nonEmptyModelID(modelID) ?? resolvedStandardTranscriptionModelID)
            update(\AppState.useLocalTranscription, to: false)
            update(\AppState.realtimeStreamingEnabled, to: false)
        case .apiRealtime(let modelID):
            if let modelID {
                update(\AppState.realtimeStreamingModel, to: modelID)
            }
            update(\AppState.useLocalTranscription, to: false)
            update(\AppState.realtimeStreamingEnabled, to: true)
        case .nativeWhisper:
            update(\AppState.useLocalTranscription, to: true)
            update(\AppState.realtimeStreamingEnabled, to: false)
            update(\AppState.localTranscriptionModel, to: nativeLocalWhisperSelectionModel)
            update(\AppState.useLegacyMlxWhisper, to: false)
        case .legacyMlxWhisper(let model):
            update(\AppState.useLocalTranscription, to: true)
            update(\AppState.realtimeStreamingEnabled, to: false)
            update(\AppState.localTranscriptionModel, to: model)
            update(\AppState.useLegacyMlxWhisper, to: true)
            update(\AppState.showLegacyMlxWhisperOptions, to: true)
        case .appleLive:
            update(\AppState.useLocalTranscription, to: true)
            update(\AppState.realtimeStreamingEnabled, to: false)
            update(\AppState.localTranscriptionModel, to: .find(id: "apple-speech"))
            update(\AppState.useLegacyMlxWhisper, to: false)
        }
    }

    @MainActor
    func setGoogleCalendarSelected(_ calendarID: String, isSelected: Bool) {
        var selected = googleCalendarConnection.selectedCalendarIDs
        if isSelected {
            selected.insert(calendarID)
        } else {
            selected.remove(calendarID)
        }
        googleCalendarConnection.selectedCalendarIDs = selected
        Self.saveStringSet(selected, forKey: googleCalendarSelectedIDsStorageKey)
        scheduleCalendarRecordingReminderRefresh()
    }

    @MainActor
    func setCalendarRecordingReminderLeadTime(_ minutes: Int, isSelected: Bool) {
        var selection = Set(calendarRecordingReminderLeadMinutes)
        if isSelected {
            selection.insert(minutes)
        } else if selection.count > 1 {
            selection.remove(minutes)
        }
        let normalized = CalendarRecordingReminderScheduler.normalizedLeadMinutes(Array(selection))
        guard normalized != calendarRecordingReminderLeadMinutes else { return }
        calendarRecordingReminderLeadMinutes = normalized
    }

    @MainActor
    var googleCalendarConnectionControls: GoogleCalendarConnectionControls {
        GoogleCalendarConnectionControls(
            isConnected: googleCalendarConnection.isConnected,
            isBusy: isGoogleCalendarBusy,
            hasPendingOAuthConnection: hasPendingGoogleCalendarOAuthConnection
        )
    }

    @MainActor
    var googleCalendarOAuthConfiguration: GoogleCalendarOAuthConfiguration {
        GoogleCalendarOAuthConfiguration(
            builtInClientID: builtInGoogleCalendarClientID,
            builtInClientSecret: builtInGoogleCalendarClientSecret
        )
    }

    @MainActor
    func disconnectGoogleCalendar() {
        cancelGoogleCalendarConnection()
        clearGoogleCalendarConnectionState()
    }

    @MainActor
    func cancelGoogleCalendarConnection() {
        googleCalendarConnectionTask?.cancel()
        googleCalendarConnectionTask = nil
        hasPendingGoogleCalendarOAuthConnection = false
        isGoogleCalendarBusy = false
    }

    @MainActor
    private func clearGoogleCalendarConnectionState() {
        cancelGoogleCalendarConnection()
        GoogleCalendarTokenStore.delete()
        Self.clearGoogleCalendarConnectionMetadata()
        availableGoogleCalendars = []
        googleCalendarConnection = .disconnected
        UserDefaults.standard.removeObject(forKey: googleCalendarSelectedIDsStorageKey)
        stopCalendarRecordingReminderSchedulerIfNeeded()
    }

    @MainActor
    func refreshGoogleCalendars() {
        Task { [weak self] in
            await self?.loadGoogleCalendars(force: true)
        }
    }

    @MainActor
    func loadStoredGoogleCalendarConnection() {
        guard !isGoogleCalendarBusy else { return }
        Task { [weak self] in
            await self?.loadGoogleCalendars(force: true)
        }
    }

    @MainActor
    func startGoogleCalendarHealthCheck() {
        guard googleCalendarConnection.isConnected else { return }
        guard !isGoogleCalendarBusy else { return }
        Task { [weak self] in
            await self?.loadGoogleCalendars(force: true)
        }
    }

    @MainActor
    func connectGoogleCalendar() {
        guard !isGoogleCalendarBusy else { return }
        let oauthConfiguration = googleCalendarOAuthConfiguration
        guard oauthConfiguration.isConfigured else {
            googleCalendarConnection.lastErrorMessage = "Google Calendar sign-in is not configured. Bundled credentials are used by default; to use custom credentials, add both a client ID and client secret in Advanced settings."
            return
        }
        let clientID = oauthConfiguration.clientID
        let clientSecret = oauthConfiguration.clientSecret
        isGoogleCalendarBusy = true
        hasPendingGoogleCalendarOAuthConnection = true
        googleCalendarConnection.lastErrorMessage = nil
        googleCalendarConnectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let pkce = GoogleCalendarAuthService.makePKCEPair()
                let state = UUID().uuidString
                let receiver = try GoogleCalendarAuthService.LoopbackReceiver(state: state)
                defer { receiver.cancel() }
                receiver.start()
                let callbackURL = try await receiver.waitForCallbackURL()
                await MainActor.run {
                    GoogleCalendarAuthService.openAuthorizationPage(
                        clientID: clientID,
                        callbackURL: callbackURL,
                        codeChallenge: pkce.challenge,
                        state: state
                    )
                }
                let code = try await receiver.waitForCode()
                let token = try await GoogleCalendarAuthService.exchangeCode(
                    clientID: clientID,
                    clientSecret: clientSecret,
                    code: code,
                    codeVerifier: pkce.verifier,
                    redirectURI: callbackURL.absoluteString
                )
                try GoogleCalendarTokenStore.save(token)
                Self.saveGoogleCalendarConnectionMetadata(accountEmail: token.accountEmail)
                await MainActor.run {
                    self.googleCalendarConnection = GoogleCalendarConnectionState(
                        isConnected: true,
                        accountEmail: token.accountEmail,
                        selectedCalendarIDs: [],
                        lastErrorMessage: nil
                    )
                    Self.saveStringSet([], forKey: self.googleCalendarSelectedIDsStorageKey)
                    self.hasPendingGoogleCalendarOAuthConnection = false
                    self.googleCalendarConnectionTask = nil
                }
                await self.loadGoogleCalendars(force: true)
            } catch is CancellationError {
                await MainActor.run {
                    self.hasPendingGoogleCalendarOAuthConnection = false
                    self.isGoogleCalendarBusy = false
                    self.googleCalendarConnectionTask = nil
                }
            } catch {
                await MainActor.run {
                    self.googleCalendarConnection.lastErrorMessage = error.localizedDescription
                    self.hasPendingGoogleCalendarOAuthConnection = false
                    self.isGoogleCalendarBusy = false
                    self.googleCalendarConnectionTask = nil
                }
            }
        }
    }

    @Published var soundVolume: Float {
        didSet {
            UserDefaults.standard.set(soundVolume, forKey: soundVolumeStorageKey)
        }
    }

    private var precomputedMacros: [PrecomputedMacro] = []

    @Published var voiceMacros: [VoiceMacro] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(voiceMacros) {
                UserDefaults.standard.set(data, forKey: voiceMacrosStorageKey)
            }
            precomputeMacros()
        }
    }

    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var retryingItemIDs: Set<UUID> = []
    @Published var lastTranscript: String = ""
    @Published var errorMessage: String?
    @Published var statusText: String = localizedCatalogString("Ready")

    // MCP interface
    var mcpAdditionalContext: String = ""
    var mcpLastRecordingFailed: Bool = false
    var onTranscriptionCompleted: ((String, String) -> Void)?
    @Published var hasAccessibility = false
    @Published var hotkeyMonitoringErrorMessage: String?
    @Published var isDebugOverlayActive = false
    @Published var selectedSettingsTab: SettingsTab? = .general
    @Published var pipelineHistory: [PipelineHistoryItem] = []
    @Published var debugStatusMessage = "Idle"
    @Published var debugShowsUpdateReminderAfterDictation = false
    @Published var lastRawTranscript = ""
    @Published var lastPostProcessedTranscript = ""
    @Published var lastPostProcessingPrompt = ""
    @Published var lastContextSummary = ""
    @Published var lastPostProcessingStatus = ""
    @Published var lastContextScreenshotDataURL: String? = nil
    @Published var lastContextScreenshotStatus = "No screenshot"
    @Published var lastContextAppName: String = ""
    @Published var lastContextBundleIdentifier: String = ""
    @Published var lastContextWindowTitle: String = ""
    @Published var lastContextSelectedText: String = ""
    @Published var lastContextLLMPrompt: String = ""
    @Published var hasScreenRecordingPermission = false
    @Published var speechRecognitionAuthorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @Published var launchAtLogin: Bool {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    @Published var selectedMicrophoneID: String {
        didSet {
            UserDefaults.standard.set(selectedMicrophoneID, forKey: selectedMicrophoneStorageKey)
            scheduleNoteBrowserTranscriptionModeNormalizationForSelectedInput()
        }
    }
    @Published var availableMicrophones: [AudioDevice] = []

    let audioRecorder = AudioRecorder()
    let systemAudioRecorder = SystemAudioRecorder()
    lazy var systemDefaultAndSystemAudioRecorder = SystemDefaultAndSystemAudioRecorder(
        microphoneRecorder: audioRecorder,
        systemAudioRecorder: systemAudioRecorder
    )
    let hotkeyManager = HotkeyManager()
    let overlayManager = RecordingOverlayManager()
    @MainActor
    private lazy var meetingReminderOverlayManager = MeetingReminderOverlayManager { [weak self] in
        guard let self else {
            return MeetingReminderOverlayContext(phase: .idle, layout: .centerDropdownFill)
        }
        let phase: MeetingReminderOverlayContext.Phase = if self.isRecording || self.isDebugOverlayActive {
            // Treat the debug overlay as recording so the reminder shows its
            // recording (wrapping) variant for visual testing in dev builds.
            .recording
        } else if self.isTranscribing {
            .processing
        } else {
            .idle
        }
        let layout: MeetingReminderOverlayContext.Layout = self.recordingOverlayLayout == .notchSides ? .notchSides : .centerDropdownFill
        return MeetingReminderOverlayContext(phase: phase, layout: layout)
    }
    private var accessibilityTimer: Timer?
    private var audioLevelCancellable: AnyCancellable?
    private var debugOverlayTimer: Timer?
    private var recordingInitializationTimer: DispatchSourceTimer?
    private var transcribingIndicatorTask: Task<Void, Never>?
    private var liveTranscriber: (any LiveTranscriber)?
    private var currentRecordingLiveNoteID: UUID?
    private var activeRecordingStartedAt: Date?
    private var activeRecordingCalendarSnapshot: RecordingCalendarSnapshot?
    private var activeAudioInputID: String?
    /// Audio files of recording segments captured before a mid-recording input
    /// switch. Stitched with the final segment at finish to keep one note.
    private var recordingSegmentURLs: [URL] = []
    /// True once the active recording has switched inputs at least once. Such a
    /// session is finalized via file-based transcription of the stitched audio.
    private var didSwitchInputDuringRecording = false
    private var isCancelConfirmationShowing = false
    private var overlayTranscriptionID: UUID = UUID()
    private var foregroundTranscriptionJobID: UUID?
    private var activeTranscriptionJobs: [UUID: TranscriptionJob] = [:]
    private var contextService: AppContextService
    private var contextCaptureTask: Task<AppContext?, Never>?
    private var capturedContext: AppContext?
    private var googleCalendarConnectionTask: Task<Void, Never>?
    @MainActor
    private lazy var calendarRecordingReminderScheduler = CalendarRecordingReminderScheduler(
        notificationManager: AppNotificationManager.shared,
        inAppPresenter: meetingReminderOverlayManager
    ) { [weak self] timeMin, timeMax in
        guard let self else { return [] }
        return try await self.fetchCalendarRecordingReminderEvents(timeMin: timeMin, timeMax: timeMax)
    }
    private var isCalendarRecordingReminderSchedulerActive = false
    private var hasShownScreenshotPermissionAlert = false
    private var isEscapeCancelAlertPresented = false
    private var shouldTerminateAfterTranscription = false
    private var audioDeviceObservers: [NSObjectProtocol] = []
    private var needsMicrophoneRefreshAfterRecording = false
    private let pipelineHistoryStore = PipelineHistoryStore()
    private let recordingJournalStore: RecordingJournalStore
    private var activeMicrophoneJournalController: MicrophoneRecordingJournalController?
    private var activeRecordingID: UUID?
    private let shortcutSessionController = DictationShortcutSessionController()
    private var activeRecordingTriggerMode: RecordingTriggerMode?
    private var currentSessionIntent: SessionIntent = .dictation
    private var pendingSelectionSnapshot: AppSelectionSnapshot?
    private var pendingSelectionSnapshotTask: Task<AppSelectionSnapshot, Never>?
    private var pendingManualCommandInvocation = false
    private var pendingShortcutStartTask: Task<Void, Never>?
    private var pendingShortcutStartMode: RecordingTriggerMode?
    private var realtimeService: RealtimeTranscriptionService?
    private var criticalDictationActivityState = CriticalDictationActivityState()
    private var activeAudioInterruption: ActiveAudioInterruption?
    private var pendingOverlayDismissToken: UUID?
    private var shouldMonitorHotkeys = false
    private var isApplyingNoteBrowserTranscriptionChoice = false
    private var isCapturingShortcut = false
    private var isAwaitingMicrophonePermission = false
    private var isAwaitingSpeechRecognitionPermission = false
    private var pendingMicrophonePermissionTriggerMode: RecordingTriggerMode?
    private var pendingMicrophonePermissionSelectionSnapshot: AppSelectionSnapshot?
    private var pendingMicrophonePermissionManualCommandRequested: Bool?
    private var pendingSpeechPermissionTriggerMode: RecordingTriggerMode?
    private var pendingSpeechPermissionSelectionSnapshot: AppSelectionSnapshot?
    private var pendingSpeechPermissionManualCommandRequested: Bool?
    private let postTranscriptionUpdateReminderDuration: TimeInterval = 7

    init() {
        recordingJournalStore = RecordingJournalStore(
            audioDirectory: Self.audioStorageDirectory()
        )
        UserDefaults.standard.removeObject(forKey: "force_http2_transcription")
        Self.migrateModelStorageKeys()
        let hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedSetup")
        let apiKey = Self.loadStoredAPIKey(account: apiKeyStorageKey)
        let apiBaseURL = Self.loadStoredAPIBaseURL(account: "api_base_url")
        let transcriptionModel = UserDefaults.standard.string(forKey: transcriptionModelStorageKey) ?? Self.defaultTranscriptionModel
        let transcriptionAPIURL = Self.loadOptionalStoredAPIValue(account: transcriptionAPIURLStorageKey)
        let transcriptionAPIKey = Self.loadStoredAPIKey(account: transcriptionAPIKeyStorageKey)
        let postProcessingModel = UserDefaults.standard.string(forKey: postProcessingModelStorageKey) ?? Self.defaultPostProcessingModel
        let postProcessingFallbackModel = UserDefaults.standard.string(forKey: postProcessingFallbackModelStorageKey) ?? Self.defaultPostProcessingFallbackModel
        let contextModel = Self.loadStoredContextModel(key: contextModelStorageKey)
        let shortcuts = Self.loadShortcutConfiguration(
            holdKey: holdShortcutStorageKey,
            toggleKey: toggleShortcutStorageKey,
            copyAgainKey: copyAgainShortcutStorageKey
        )
        let savedHoldCustomShortcut = Self.loadSavedCustomShortcut(
            forKey: savedHoldCustomShortcutStorageKey,
            fallback: shortcuts.hold.isCustom ? shortcuts.hold : nil
        )
        let savedToggleCustomShortcut = Self.loadSavedCustomShortcut(
            forKey: savedToggleCustomShortcutStorageKey,
            fallback: shortcuts.toggle.isCustom ? shortcuts.toggle : nil
        )
        let savedCopyAgainCustomShortcut = Self.loadSavedCustomShortcut(
            forKey: savedCopyAgainCustomShortcutStorageKey,
            fallback: shortcuts.copyAgain.isCustom ? shortcuts.copyAgain : nil
        )
        let storedRecordingCancelShortcut = Self.loadShortcut(forKey: recordingCancelShortcutStorageKey)
        let recordingCancelShortcut = Self.initialRecordingCancelShortcut(
            stored: storedRecordingCancelShortcut.binding,
            hold: shortcuts.hold,
            toggle: shortcuts.toggle
        )
        let savedRecordingCancelCustomShortcut = Self.loadSavedCustomShortcut(
            forKey: savedRecordingCancelCustomShortcutStorageKey,
            fallback: recordingCancelShortcut.isCustom && recordingCancelShortcut != .defaultRecordingCancel
                ? recordingCancelShortcut
                : nil
        )
        let customVocabulary = UserDefaults.standard.string(forKey: customVocabularyStorageKey) ?? ""
        let customSystemPrompt = UserDefaults.standard.string(forKey: customSystemPromptStorageKey) ?? ""
        let customContextPrompt = UserDefaults.standard.string(forKey: customContextPromptStorageKey) ?? ""
        let instructionExecutionGuardEnabled = UserDefaults.standard.object(
            forKey: instructionExecutionGuardEnabledStorageKey
        ) == nil
            ? true
            : UserDefaults.standard.bool(forKey: instructionExecutionGuardEnabledStorageKey)
        let customSystemPromptLastModified = UserDefaults.standard.string(forKey: customSystemPromptLastModifiedStorageKey) ?? ""
        let customContextPromptLastModified = UserDefaults.standard.string(forKey: customContextPromptLastModifiedStorageKey) ?? ""
        let storedContextScreenshotMaxDimension = UserDefaults.standard.object(forKey: contextScreenshotMaxDimensionStorageKey) != nil
            ? UserDefaults.standard.integer(forKey: contextScreenshotMaxDimensionStorageKey)
            : Self.defaultContextScreenshotMaxDimension
        let contextScreenshotMaxDimension = Self.normalizedContextScreenshotMaxDimension(storedContextScreenshotMaxDimension)
        let shortcutStartDelay = max(0, UserDefaults.standard.double(forKey: shortcutStartDelayStorageKey))
        let isCommandModeEnabled = UserDefaults.standard.object(forKey: commandModeEnabledStorageKey) == nil
            ? false
            : UserDefaults.standard.bool(forKey: commandModeEnabledStorageKey)
        let commandModeStyle = CommandModeStyle(
            rawValue: UserDefaults.standard.string(forKey: commandModeStyleStorageKey) ?? ""
        ) ?? .automatic
        let commandModeManualModifier = CommandModeManualModifier(
            rawValue: UserDefaults.standard.string(forKey: commandModeManualModifierStorageKey) ?? ""
        ) ?? .option
        let preserveClipboard = UserDefaults.standard.object(forKey: preserveClipboardStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: preserveClipboardStorageKey)
        let keepDictationInClipboardHistory = UserDefaults.standard.bool(forKey: keepDictationInClipboardHistoryStorageKey)
        let realtimeStreamingEnabled = UserDefaults.standard.bool(forKey: realtimeStreamingEnabledStorageKey)
        let realtimeStreamingModel = UserDefaults.standard.string(forKey: realtimeStreamingModelStorageKey) ?? ""
        let dictationAudioInterruptionEnabled = UserDefaults.standard.bool(
            forKey: dictationAudioInterruptionEnabledStorageKey
        )
        let recordingOverlayLayout = RecordingOverlayLayout.find(
            rawValue: UserDefaults.standard.string(forKey: recordingOverlayLayoutStorageKey)
        )
        let overlayWaveformDisplayMode = OverlayWaveformDisplayMode.find(
            rawValue: UserDefaults.standard.string(forKey: overlayWaveformDisplayModeStorageKey)
        )
        let selectedGoogleCalendarIDs = Self.loadStringSet(forKey: googleCalendarSelectedIDsStorageKey)
        let storedGoogleCalendarConnectionMetadata = Self.loadGoogleCalendarConnectionMetadata()
        let calendarRecordingRemindersEnabled = UserDefaults.standard.bool(forKey: calendarRecordingRemindersEnabledStorageKey)
        let calendarRecordingReminderLeadMinutes: [Int]
        if let storedCalendarRecordingReminderLeadMinuteList = UserDefaults.standard.array(
            forKey: calendarRecordingReminderLeadMinutesListStorageKey
        ) as? [Int] {
            calendarRecordingReminderLeadMinutes = CalendarRecordingReminderScheduler.normalizedLeadMinutes(
                storedCalendarRecordingReminderLeadMinuteList
            )
            if calendarRecordingReminderLeadMinutes != storedCalendarRecordingReminderLeadMinuteList {
                UserDefaults.standard.set(
                    calendarRecordingReminderLeadMinutes,
                    forKey: calendarRecordingReminderLeadMinutesListStorageKey
                )
            }
        } else {
            let storedCalendarRecordingReminderLeadMinutes = UserDefaults.standard.object(
                forKey: legacyCalendarRecordingReminderLeadMinutesStorageKey
            ) != nil
                ? UserDefaults.standard.integer(forKey: legacyCalendarRecordingReminderLeadMinutesStorageKey)
                : CalendarRecordingReminderScheduler.defaultLeadMinutes
            calendarRecordingReminderLeadMinutes = CalendarRecordingReminderScheduler.normalizedLeadMinutes([
                storedCalendarRecordingReminderLeadMinutes
            ])
            UserDefaults.standard.set(
                calendarRecordingReminderLeadMinutes,
                forKey: calendarRecordingReminderLeadMinutesListStorageKey
            )
        }
        let storedCalendarRecordingReminderRefreshIntervalMinutes = UserDefaults.standard.object(forKey: calendarRecordingReminderRefreshIntervalMinutesStorageKey) != nil
            ? UserDefaults.standard.integer(forKey: calendarRecordingReminderRefreshIntervalMinutesStorageKey)
            : CalendarRecordingReminderScheduler.defaultRefreshIntervalMinutes
        let calendarRecordingReminderRefreshIntervalMinutes = CalendarRecordingReminderScheduler.normalizedRefreshIntervalMinutes(storedCalendarRecordingReminderRefreshIntervalMinutes)
        let isPressEnterVoiceCommandEnabled = UserDefaults.standard.object(forKey: pressEnterVoiceCommandStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: pressEnterVoiceCommandStorageKey)
        let useLocalTranscription = UserDefaults.standard.bool(forKey: useLocalTranscriptionStorageKey)
        let localWhisperPath = UserDefaults.standard.string(forKey: localWhisperPathStorageKey) ?? ""
        let useLegacyMlxWhisper = UserDefaults.standard.bool(forKey: useLegacyMlxWhisperStorageKey)
        let hasStoredLegacyMlxWhisperOptionsVisibility = UserDefaults.standard.object(forKey: showLegacyMlxWhisperOptionsStorageKey) != nil
        let showLegacyMlxWhisperOptions = hasStoredLegacyMlxWhisperOptionsVisibility
            ? UserDefaults.standard.bool(forKey: showLegacyMlxWhisperOptionsStorageKey)
            : useLegacyMlxWhisper
        if !hasStoredLegacyMlxWhisperOptionsVisibility {
            UserDefaults.standard.set(showLegacyMlxWhisperOptions, forKey: showLegacyMlxWhisperOptionsStorageKey)
        }
        let disableContextCapture = UserDefaults.standard.bool(forKey: disableContextCaptureStorageKey)
        let disableAutoPaste = UserDefaults.standard.bool(forKey: disableAutoPasteStorageKey)
        let disablePostProcessing = UserDefaults.standard.bool(forKey: disablePostProcessingStorageKey)
        let preserveExactWording = UserDefaults.standard.bool(forKey: preserveExactWordingStorageKey)
        let noteBrowserEnabled = UserDefaults.standard.bool(forKey: noteBrowserEnabledStorageKey)
        let transcriptionLanguage = TranscriptionLanguage.find(
            code: UserDefaults.standard.string(forKey: transcriptionLanguageStorageKey) ?? "ko"
        )
        let outputLanguage = UserDefaults.standard.string(forKey: outputLanguageStorageKey) ?? ""
        let localTranscriptionModel = TranscriptionModel.find(
            id: UserDefaults.standard.string(forKey: localTranscriptionModelStorageKey) ?? TranscriptionModel.default.id
        )
        let soundVolume: Float = UserDefaults.standard.object(forKey: soundVolumeStorageKey) != nil
            ? UserDefaults.standard.float(forKey: soundVolumeStorageKey) : 1.0
        let alertSoundsEnabled = UserDefaults.standard.object(forKey: alertSoundsEnabledStorageKey) != nil
            ? UserDefaults.standard.bool(forKey: alertSoundsEnabledStorageKey)
            : soundVolume > 0
        
        let initialMacros: [VoiceMacro]
        if let data = UserDefaults.standard.data(forKey: "voice_macros"),
           let decoded = try? JSONDecoder().decode([VoiceMacro].self, from: data) {
            initialMacros = decoded
        } else {
            initialMacros = []
        }

        let initialAccessibility = AXIsProcessTrusted()
        let initialScreenCapturePermission = CGPreflightScreenCaptureAccess()
        Self.recoverRecordingJournalsBeforeHistoryLoad(
            recordingJournalStore: recordingJournalStore,
            historyStore: pipelineHistoryStore
        )
        var removedStoredFiles: [DeletedPipelineHistoryAssets] = []
        do {
            removedStoredFiles = try pipelineHistoryStore.trim(to: maxPipelineHistoryCount)
        } catch {
            print("Failed to trim pipeline history during init: \(error)")
        }
        for removedAssets in removedStoredFiles {
            Self.deleteStoredFiles(removedAssets)
        }
        var savedHistory = Self.markInterruptedRecoveryPlaceholders(
            in: pipelineHistoryStore.loadAllHistory(),
            store: pipelineHistoryStore
        )
        let historyStore = pipelineHistoryStore
        do {
            savedHistory = try LegacyNoteTitleMigration.migrate(history: savedHistory) { item in
                try historyStore.update(item)
            }
        } catch {
            print("Failed to migrate legacy note titles: \(error)")
        }
        let referencedAudioFileNames = Set(savedHistory.compactMap(\.audioFileName))
        let referencedTranscriptFileNames = Set(savedHistory.compactMap(\.transcriptFileName))
        let protectedInflightAudioFileNames = Self.protectedInflightAudioFileNames(
            store: recordingJournalStore
        )
        Task.detached(priority: .background) {
            Self.sweepOrphanStoredFiles(
                referencedAudioFileNames: referencedAudioFileNames,
                referencedTranscriptFileNames: referencedTranscriptFileNames,
                protectedInflightAudioFileNames: protectedInflightAudioFileNames
            )
        }

        let selectedMicrophoneID = UserDefaults.standard.string(forKey: selectedMicrophoneStorageKey) ?? "default"
        let shouldRestoreMutedAudio = UserDefaults.standard.bool(forKey: pendingMutedAudioRestoreStorageKey)

        self.contextService = Self.makeAppContextService(
            apiKey: apiKey,
            baseURL: apiBaseURL,
            customContextPrompt: customContextPrompt,
            contextModel: contextModel,
            contextScreenshotMaxDimension: contextScreenshotMaxDimension
        )
        self.hasCompletedSetup = hasCompletedSetup
        self.apiKey = apiKey
        self.apiBaseURL = apiBaseURL
        self.transcriptionAPIURL = transcriptionAPIURL
        self.transcriptionAPIKey = transcriptionAPIKey
        self.transcriptionModel = transcriptionModel
        self.postProcessingModel = postProcessingModel
        self.postProcessingFallbackModel = postProcessingFallbackModel
        self.contextModel = contextModel
        self.holdShortcut = shortcuts.hold
        self.toggleShortcut = shortcuts.toggle
        self.recordingCancelShortcut = recordingCancelShortcut
        self.copyAgainShortcut = shortcuts.copyAgain
        self.savedHoldCustomShortcut = savedHoldCustomShortcut.binding
        self.savedToggleCustomShortcut = savedToggleCustomShortcut.binding
        self.savedRecordingCancelCustomShortcut = savedRecordingCancelCustomShortcut.binding
        self.savedCopyAgainCustomShortcut = savedCopyAgainCustomShortcut.binding
        self.isCommandModeEnabled = isCommandModeEnabled
        self.commandModeStyle = commandModeStyle
        self.commandModeManualModifier = commandModeManualModifier
        self.customVocabulary = customVocabulary
        self.customSystemPrompt = customSystemPrompt
        self.customContextPrompt = customContextPrompt
        self.instructionExecutionGuardEnabled = instructionExecutionGuardEnabled
        self.contextScreenshotMaxDimension = contextScreenshotMaxDimension
        self.customSystemPromptLastModified = customSystemPromptLastModified
        self.customContextPromptLastModified = customContextPromptLastModified
        self.shortcutStartDelay = shortcutStartDelay
        self.preserveClipboard = preserveClipboard
        self.keepDictationInClipboardHistory = keepDictationInClipboardHistory
        self.realtimeStreamingEnabled = realtimeStreamingEnabled
        self.realtimeStreamingModel = realtimeStreamingModel
        self.dictationAudioInterruptionEnabled = dictationAudioInterruptionEnabled
        self.recordingOverlayLayout = recordingOverlayLayout
        self.overlayWaveformDisplayMode = overlayWaveformDisplayMode
        self.googleCalendarConnection = storedGoogleCalendarConnectionMetadata?.connectionState(
            selectedCalendarIDs: selectedGoogleCalendarIDs
        ) ?? .disconnected
        self.calendarRecordingRemindersEnabled = calendarRecordingRemindersEnabled
        self.calendarRecordingReminderLeadMinutes = calendarRecordingReminderLeadMinutes
        self.calendarRecordingReminderRefreshIntervalMinutes = calendarRecordingReminderRefreshIntervalMinutes
        self.overlayManager.setRecordingOverlayLayout(recordingOverlayLayout)
        self.overlayManager.setWaveformDisplayMode(overlayWaveformDisplayMode)
        self.isPressEnterVoiceCommandEnabled = isPressEnterVoiceCommandEnabled
        self.alertSoundsEnabled = alertSoundsEnabled
        self.useLocalTranscription = useLocalTranscription
        self.localWhisperPath = localWhisperPath
        self.useLegacyMlxWhisper = useLegacyMlxWhisper
        self.showLegacyMlxWhisperOptions = showLegacyMlxWhisperOptions
        self.disableContextCapture = disableContextCapture
        self.disableAutoPaste = disableAutoPaste
        self.disablePostProcessing = disablePostProcessing
        self.preserveExactWording = preserveExactWording
        self.noteBrowserEnabled = noteBrowserEnabled
        self.transcriptionLanguage = transcriptionLanguage
        self.outputLanguage = outputLanguage
        self.localTranscriptionModel = localTranscriptionModel
        self.soundVolume = soundVolume
        self.voiceMacros = initialMacros
        self.pipelineHistory = savedHistory
        self.hasAccessibility = initialAccessibility
        self.hasScreenRecordingPermission = initialScreenCapturePermission
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.selectedMicrophoneID = selectedMicrophoneID
        scheduleNoteBrowserTranscriptionModeNormalizationForSelectedInput()
        self.precomputeMacros()

        speechRecognitionAuthorizationStatus = Self.currentSpeechRecognitionAuthorizationStatus()
        refreshAvailableMicrophones()
        installAudioDeviceObservers()

        if shortcuts.didUpdateHoldStoredValue {
            persistShortcut(shortcuts.hold, key: holdShortcutStorageKey)
        }
        if shortcuts.didUpdateToggleStoredValue {
            persistShortcut(shortcuts.toggle, key: toggleShortcutStorageKey)
        }
        if shortcuts.didUpdateCopyAgainStoredValue {
            persistShortcut(shortcuts.copyAgain, key: copyAgainShortcutStorageKey)
        }
        if savedHoldCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedHoldCustomShortcut.binding, key: savedHoldCustomShortcutStorageKey)
        }
        if savedToggleCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedToggleCustomShortcut.binding, key: savedToggleCustomShortcutStorageKey)
        }
        if storedRecordingCancelShortcut.binding == nil || storedRecordingCancelShortcut.didNormalize {
            persistShortcut(recordingCancelShortcut, key: recordingCancelShortcutStorageKey)
        }
        if savedRecordingCancelCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedRecordingCancelCustomShortcut.binding, key: savedRecordingCancelCustomShortcutStorageKey)
        }
        if savedCopyAgainCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedCopyAgainCustomShortcut.binding, key: savedCopyAgainCustomShortcutStorageKey)
        }

        if shouldRestoreMutedAudio {
            _ = SystemAudioStatus.setDefaultOutputMuted(false)
            UserDefaults.standard.removeObject(forKey: pendingMutedAudioRestoreStorageKey)
        }

        overlayManager.onStopButtonPressed = { [weak self] in
            DispatchQueue.main.async {
                self?.handleOverlayStopButtonPressed()
            }
        }
        overlayManager.onSelectInput = { [weak self] inputID in
            DispatchQueue.main.async {
                self?.switchActiveRecordingInput(to: inputID)
            }
        }
        Task { @MainActor [weak self] in
            self?.meetingReminderOverlayManager.onStart = { [weak self] schedule in
                self?.activeRecordingCalendarSnapshot = RecordingCalendarSnapshot(
                    eventID: schedule.event.id,
                    calendarID: schedule.event.calendarID,
                    title: schedule.event.title,
                    startDate: schedule.event.start,
                    endDate: schedule.event.end,
                    matchSource: CalendarMatchSource.calendarNotification.rawValue,
                    attendeeNames: schedule.event.attendees.compactMap { attendee in
                        attendee.displayName ?? attendee.email
                    }
                )
                self?.startRecordingFromCalendarReminder()
            }
        }
    }

    deinit {
        removeAudioDeviceObservers()
    }

    private func removeAudioDeviceObservers() {
        let notificationCenter = NotificationCenter.default
        for observer in audioDeviceObservers {
            notificationCenter.removeObserver(observer)
        }
        audioDeviceObservers.removeAll()
    }

    private static func loadStoredAPIKey(account: String) -> String {
        if let storedKey = AppSettingsStorage.load(account: account), !storedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return storedKey
        }
        return ""
    }

    private func persistAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppSettingsStorage.delete(account: apiKeyStorageKey)
        } else {
            AppSettingsStorage.save(trimmed, account: apiKeyStorageKey)
        }
    }

    static let defaultAPIBaseURL = "https://api.groq.com/openai/v1"

    private struct StoredShortcutConfiguration {
        let hold: ShortcutBinding
        let toggle: ShortcutBinding
        let copyAgain: ShortcutBinding
        let didUpdateHoldStoredValue: Bool
        let didUpdateToggleStoredValue: Bool
        let didUpdateCopyAgainStoredValue: Bool
    }

    private struct StoredOptionalShortcut {
        let binding: ShortcutBinding?
        let didUpdateStoredValue: Bool
    }

    private struct StoredShortcutLoadResult {
        let binding: ShortcutBinding?
        let hadStoredValue: Bool
        let didNormalize: Bool
    }

    private static func loadStoredAPIBaseURL(account: String) -> String {
        if let stored = AppSettingsStorage.load(account: account), !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored
        }
        return defaultAPIBaseURL
    }

    private static func loadStoredContextModel(key: String) -> String {
        guard let stored = UserDefaults.standard.string(forKey: key) else {
            return defaultContextModel
        }

        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == deprecatedDefaultContextModel {
            UserDefaults.standard.set(defaultContextModel, forKey: key)
            return defaultContextModel
        }

        return trimmed.isEmpty ? defaultContextModel : trimmed
    }

    private static func loadGoogleCalendarConnectionMetadata() -> GoogleCalendarConnectionMetadata? {
        guard let data = UserDefaults.standard.data(forKey: GoogleCalendarConnectionMetadata.storageKey) else { return nil }
        do {
            return try JSONDecoder().decode(GoogleCalendarConnectionMetadata.self, from: data)
        } catch {
            UserDefaults.standard.removeObject(forKey: GoogleCalendarConnectionMetadata.storageKey)
            return nil
        }
    }

    private static func saveGoogleCalendarConnectionMetadata(accountEmail: String?) {
        guard let data = try? JSONEncoder().encode(GoogleCalendarConnectionMetadata(accountEmail: accountEmail)) else { return }
        UserDefaults.standard.set(data, forKey: GoogleCalendarConnectionMetadata.storageKey)
    }

    private static func clearGoogleCalendarConnectionMetadata() {
        UserDefaults.standard.removeObject(forKey: GoogleCalendarConnectionMetadata.storageKey)
    }

    private static func loadShortcutConfiguration(
        holdKey: String,
        toggleKey: String,
        copyAgainKey: String
    ) -> StoredShortcutConfiguration {
        let legacyPreset = ShortcutPreset(
            rawValue: UserDefaults.standard.string(forKey: "hotkey_option") ?? ShortcutPreset.fnKey.rawValue
        ) ?? .fnKey
        let hold = legacyPreset.binding
        let toggle = hold.withAddedModifiers(.command)
        let storedHold = loadShortcut(forKey: holdKey)
        let storedToggle = loadShortcut(forKey: toggleKey)
        let storedCopyAgain = loadShortcut(forKey: copyAgainKey)
        return StoredShortcutConfiguration(
            hold: storedHold.binding ?? hold,
            toggle: storedToggle.binding ?? toggle,
            copyAgain: storedCopyAgain.binding ?? .disabled,
            didUpdateHoldStoredValue: storedHold.binding == nil || storedHold.didNormalize,
            didUpdateToggleStoredValue: storedToggle.binding == nil || storedToggle.didNormalize,
            didUpdateCopyAgainStoredValue: storedCopyAgain.didNormalize
        )
    }

    private static func loadShortcut(forKey key: String) -> StoredShortcutLoadResult {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return StoredShortcutLoadResult(binding: nil, hadStoredValue: false, didNormalize: false)
        }
        guard let decoded = try? JSONDecoder().decode(ShortcutBinding.self, from: data) else {
            return StoredShortcutLoadResult(binding: nil, hadStoredValue: true, didNormalize: false)
        }
        let normalized = decoded.normalizedForStorageMigration()
        return StoredShortcutLoadResult(
            binding: normalized,
            hadStoredValue: true,
            didNormalize: normalized != decoded
        )
    }

    private static func initialRecordingCancelShortcut(
        stored: ShortcutBinding?,
        hold: ShortcutBinding,
        toggle: ShortcutBinding
    ) -> ShortcutBinding {
        if let stored {
            return stored
        }
        if defaultRecordingCancelOverlaps(hold) || defaultRecordingCancelOverlaps(toggle) {
            return .disabled
        }
        return .defaultRecordingCancel
    }

    private static func defaultRecordingCancelOverlaps(_ binding: ShortcutBinding) -> Bool {
        guard !binding.isDisabled else { return false }
        guard binding.kind == .key else { return false }
        return binding.keyCode == ShortcutBinding.defaultRecordingCancel.keyCode
    }

    private static func loadSavedCustomShortcut(
        forKey key: String,
        fallback: ShortcutBinding?
    ) -> StoredOptionalShortcut {
        let stored = loadShortcut(forKey: key)
        if let binding = stored.binding {
            return StoredOptionalShortcut(binding: binding, didUpdateStoredValue: stored.didNormalize)
        }

        return StoredOptionalShortcut(
            binding: fallback,
            didUpdateStoredValue: stored.hadStoredValue || fallback != nil
        )
    }

    static func normalizedContextScreenshotMaxDimension(_ value: Int) -> Int {
        contextScreenshotDimensionOptions.contains(value)
            ? value
            : defaultContextScreenshotMaxDimension
    }

    static func makeAppContextService(
        apiKey: String,
        baseURL: String,
        customContextPrompt: String,
        contextModel: String,
        contextScreenshotMaxDimension: Int
    ) -> AppContextService {
        AppContextService(
            apiKey: apiKey,
            baseURL: baseURL,
            customContextPrompt: customContextPrompt,
            contextModel: contextModel,
            screenshotMaxDimension: CGFloat(normalizedContextScreenshotMaxDimension(contextScreenshotMaxDimension))
        )
    }

    func makeAppContextService() -> AppContextService {
        Self.makeAppContextService(
            apiKey: apiKey,
            baseURL: apiBaseURL,
            customContextPrompt: customContextPrompt,
            contextModel: contextModel,
            contextScreenshotMaxDimension: contextScreenshotMaxDimension
        )
    }

    private func rebuildContextService() {
        contextService = makeAppContextService()
    }

    private func persistAPIBaseURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == Self.defaultAPIBaseURL {
            AppSettingsStorage.delete(account: apiBaseURLStorageKey)
        } else {
            AppSettingsStorage.save(trimmed, account: apiBaseURLStorageKey)
        }
    }

    private func persistOptionalAPIValue(_ value: String, account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppSettingsStorage.delete(account: account)
        } else {
            AppSettingsStorage.save(trimmed, account: account)
        }
    }

    private static func loadOptionalStoredAPIValue(account: String) -> String {
        let stored = AppSettingsStorage.load(account: account) ?? ""
        return stored.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func loadStringSet(forKey key: String) -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: key),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(values)
    }

    private static func saveStringSet(_ values: Set<String>, forKey key: String) {
        let sorted = values.sorted()
        if sorted.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(sorted) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private var resolvedTranscriptionBaseURL: String {
        let trimmed = transcriptionAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? apiBaseURL : trimmed
    }

    private var resolvedTranscriptionAPIKey: String {
        let trimmed = transcriptionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? apiKey : trimmed
    }

    private enum GoogleCalendarHealthError: LocalizedError {
        case needsReconnect

        var errorDescription: String? {
            switch self {
            case .needsReconnect:
                return localizedCatalogString("Google Calendar needs reconnecting.")
            }
        }
    }

    private static func googleCalendarReconnectMessage() -> String {
        localizedCatalogString("Google Calendar needs reconnecting. Reconnect to restore meeting reminders and calendar-based note titles.")
    }

    static func isGoogleCalendarReconnectError(_ error: Error) -> Bool {
        if error is GoogleCalendarHealthError { return true }
        guard let oauthError = error as? GoogleCalendarAuthService.OAuthError else { return false }
        switch oauthError {
        case .missingRefreshToken:
            return true
        case .requestFailed:
            return false
        case .response(let code, _):
            return code == "invalid_grant"
        }
    }

    private func validGoogleCalendarToken(allowsAuthenticationUI: Bool = true) async throws -> GoogleCalendarOAuthToken? {
        guard var token = Self.googleCalendarTokenLoader(allowsAuthenticationUI) else { return nil }
        if token.needsRefresh {
            let oauthConfiguration = await MainActor.run {
                googleCalendarOAuthConfiguration
            }
            guard oauthConfiguration.isConfigured else { return nil }
            token = try await GoogleCalendarAuthService.refreshToken(
                clientID: oauthConfiguration.clientID,
                clientSecret: oauthConfiguration.clientSecret,
                token: token
            )
            try GoogleCalendarTokenStore.save(token, allowsAuthenticationUI: allowsAuthenticationUI)
        }
        return token
    }

    private func fetchCalendarRecordingReminderEvents(timeMin: Date, timeMax: Date) async throws -> [GoogleCalendarEvent] {
        let selectedCalendarIDs = await MainActor.run { googleCalendarConnection.selectedCalendarIDs }
        guard !selectedCalendarIDs.isEmpty else { return [] }
        let token: GoogleCalendarOAuthToken
        do {
            guard let loadedToken = try await validGoogleCalendarToken() else {
                await MainActor.run {
                    markGoogleCalendarNeedsReconnect(
                        feature: .recordingReminders,
                        message: localizedCatalogString("Google Calendar needs reconnecting. Reconnect to restore meeting reminders.")
                    )
                }
                throw GoogleCalendarHealthError.needsReconnect
            }
            token = loadedToken
        } catch {
            await MainActor.run {
                if Self.isGoogleCalendarReconnectError(error) {
                    markGoogleCalendarNeedsReconnect(
                        feature: .recordingReminders,
                        message: localizedCatalogString("Google Calendar needs reconnecting. Reconnect to restore meeting reminders.")
                    )
                } else {
                    markGoogleCalendarTemporarilyUnavailable(
                        feature: .recordingReminders,
                        message: localizedCatalogFormat("Unable to refresh Google Calendar reminders: %@", error.localizedDescription)
                    )
                }
            }
            throw error
        }
        let fetchResult = await Self.googleCalendarServiceFactory().fetchEventsWithDiagnostics(
            accessToken: token.accessToken,
            calendarIDs: Array(selectedCalendarIDs),
            timeMin: timeMin,
            timeMax: timeMax
        )
        await MainActor.run {
            if fetchResult.failedCalendarIDs.isEmpty {
                markGoogleCalendarHealthy(feature: .recordingReminders)
            } else {
                markGoogleCalendarTemporarilyUnavailable(
                    feature: .recordingReminders,
                    message: localizedCatalogString("Some Google calendars could not be refreshed. Reminders may be incomplete.")
                )
            }
        }
        return fetchResult.events
    }

    @MainActor
    func startCalendarRecordingReminderScheduling() {
        scheduleCalendarRecordingReminderRefresh()
    }

    @MainActor
    func stopCalendarRecordingReminderScheduling() {
        stopCalendarRecordingReminderSchedulerIfNeeded()
    }

    @MainActor
    private func stopCalendarRecordingReminderSchedulerIfNeeded() {
        guard isCalendarRecordingReminderSchedulerActive else { return }
        calendarRecordingReminderScheduler.stop()
        isCalendarRecordingReminderSchedulerActive = false
    }

    private func scheduleCalendarRecordingReminderRefreshFromPropertyChange() {
        Task { @MainActor in
            self.scheduleCalendarRecordingReminderRefresh()
        }
    }

    @MainActor
    private func scheduleCalendarRecordingReminderRefresh() {
        guard calendarRecordingRemindersEnabled,
              googleCalendarConnection.isConnected,
              !googleCalendarConnection.selectedCalendarIDs.isEmpty else {
            stopCalendarRecordingReminderSchedulerIfNeeded()
            return
        }
        calendarRecordingReminderScheduler.start(
            leadMinutes: calendarRecordingReminderLeadMinutes,
            refreshIntervalMinutes: calendarRecordingReminderRefreshIntervalMinutes
        )
        isCalendarRecordingReminderSchedulerActive = true
    }

    @MainActor
    func markGoogleCalendarHealthy(feature: GoogleCalendarHealthFeature) {
        if googleCalendarConnection.health.status != .healthy,
           let affectedFeature = googleCalendarConnection.health.affectedFeature,
           affectedFeature != feature {
            return
        }
        googleCalendarConnection.lastErrorMessage = nil
        googleCalendarConnection.health = GoogleCalendarHealth(
            status: .healthy,
            checkedAt: Date(),
            affectedFeature: feature
        )
    }

    @MainActor
    private func markGoogleCalendarNeedsReconnect(feature: GoogleCalendarHealthFeature, message: String) {
        googleCalendarConnection.lastErrorMessage = message
        googleCalendarConnection.health = GoogleCalendarHealth(
            status: .needsReconnect,
            checkedAt: Date(),
            message: message,
            affectedFeature: feature
        )
    }

    @MainActor
    func markGoogleCalendarTemporarilyUnavailable(feature: GoogleCalendarHealthFeature, message: String) {
        googleCalendarConnection.lastErrorMessage = message
        googleCalendarConnection.health = GoogleCalendarHealth(
            status: .temporaryFailure,
            checkedAt: Date(),
            message: message,
            affectedFeature: feature
        )
    }

    @MainActor
    func loadGoogleCalendars(force: Bool = false) async {
        guard force || !isGoogleCalendarBusy else { return }
        isGoogleCalendarBusy = true
        defer { isGoogleCalendarBusy = false }
        do {
            guard let token = try await validGoogleCalendarToken() else {
                markGoogleCalendarNeedsReconnect(
                    feature: .calendarList,
                    message: Self.googleCalendarReconnectMessage()
                )
                return
            }
            let calendars = try await Self.googleCalendarServiceFactory().fetchCalendars(accessToken: token.accessToken)
            Self.saveGoogleCalendarConnectionMetadata(accountEmail: token.accountEmail)
            availableGoogleCalendars = calendars
            googleCalendarConnection.isConnected = true
            googleCalendarConnection.accountEmail = token.accountEmail
            markGoogleCalendarHealthy(feature: .calendarList)
            scheduleCalendarRecordingReminderRefresh()
        } catch {
            if Self.isGoogleCalendarReconnectError(error) {
                markGoogleCalendarNeedsReconnect(
                    feature: .calendarList,
                    message: Self.googleCalendarReconnectMessage()
                )
            } else {
                markGoogleCalendarTemporarilyUnavailable(
                    feature: .calendarList,
                    message: localizedCatalogFormat("Unable to refresh Google Calendar: %@", error.localizedDescription)
                )
            }
        }
    }

    func makeTranscriptionService() throws -> TranscriptionService {
        try TranscriptionService(
            apiKey: resolvedTranscriptionAPIKey,
            baseURL: resolvedTranscriptionBaseURL,
            useLocalTranscription: useLocalTranscription,
            localWhisperPath: localWhisperPath.isEmpty ? nil : localWhisperPath,
            useLegacyMlxWhisper: useLegacyMlxWhisper,
            transcriptionLanguage: transcriptionLanguage,
            localTranscriptionModel: localTranscriptionModel,
            transcriptionModel: transcriptionModel
        )
    }

    private func persistShortcut(_ binding: ShortcutBinding, key: String) {
        let normalizedBinding = binding.normalizedForStorageMigration()
        guard let data = try? JSONEncoder().encode(normalizedBinding) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func persistOptionalShortcut(_ binding: ShortcutBinding?, key: String) {
        guard let binding else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        persistShortcut(binding, key: key)
    }

    struct SavedAudioFile: Sendable {
        let fileName: String
        let fileURL: URL
    }

    static func audioStorageDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Quill"
        let audioDir = appSupport.appendingPathComponent("\(appName)/audio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: audioDir.path) {
            try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        }
        return audioDir
    }

    static func transcriptStorageDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Quill"
        let dir = appSupport.appendingPathComponent("\(appName)/transcripts", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func recoverRecordingJournalsBeforeHistoryLoad(
        recordingJournalStore: RecordingJournalStore,
        historyStore: PipelineHistoryStore
    ) {
        let executor = RecordingJournalRecoveryExecutor(
            store: recordingJournalStore
        )
        let historyBridge = RecordingRecoveryHistory(
            journalStore: recordingJournalStore,
            historyStore: historyStore
        )
        for result in executor.recoverAll() {
            switch result {
            case .recovered(let artifact):
                do {
                    let removedAssets = try historyBridge.persist(
                        artifact,
                        maxCount: Int.max
                    )
                    for assets in removedAssets {
                        Self.deleteStoredFiles(assets)
                    }
                } catch {
                    print("Failed to persist recovered recording \(artifact.recordingID): \(error)")
                }
            case .manualRecoveryRequired(let candidate):
                print("Recording journal requires manual recovery at \(candidate.recordingDirectory.path): \(candidate.diagnostics)")
            case .failed(let candidate, let message):
                print("Failed to recover recording journal at \(candidate.recordingDirectory.path): \(message)")
            }
        }
    }

    private static func protectedInflightAudioFileNames(
        store: RecordingJournalStore
    ) -> Set<String> {
        Set(
            InflightRecordingRecovery(store: store).scan().compactMap { candidate in
                candidate.promotion?.fileName
            }
        )
    }

    private static func sweepOrphanStoredFiles(
        referencedAudioFileNames: Set<String>,
        referencedTranscriptFileNames: Set<String>,
        protectedInflightAudioFileNames: Set<String> = []
    ) {
        let fileManager = FileManager.default
        let now = Date()
        let gracePeriod: TimeInterval = 300
        let audioDirectory = audioStorageDirectory()
        if let audioFiles = try? fileManager.contentsOfDirectory(atPath: audioDirectory.path) {
            for fileName in audioFiles where !referencedAudioFileNames.contains(fileName) {
                guard fileName != "inflight" else { continue }
                guard !protectedInflightAudioFileNames.contains(fileName) else { continue }
                let fileURL = audioDirectory.appendingPathComponent(fileName)
                guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                      let modificationDate = attributes[.modificationDate] as? Date,
                      now.timeIntervalSince(modificationDate) > gracePeriod else { continue }
                try? fileManager.removeItem(at: fileURL)
            }
        }
        let transcriptDirectory = transcriptStorageDirectory()
        if let transcriptFiles = try? fileManager.contentsOfDirectory(atPath: transcriptDirectory.path) {
            for fileName in transcriptFiles where !referencedTranscriptFileNames.contains(fileName) {
                let fileURL = transcriptDirectory.appendingPathComponent(fileName)
                guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                      let modificationDate = attributes[.modificationDate] as? Date,
                      now.timeIntervalSince(modificationDate) > gracePeriod else { continue }
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    static func saveTranscriptFile(rawTranscript: String, postProcessedTranscript: String) -> String? {
        let fileName = UUID().uuidString + ".txt"
        let fileURL = transcriptStorageDirectory().appendingPathComponent(fileName)
        // postProcessedTranscript가 있으면 그걸, 없으면 rawTranscript 저장
        let content = postProcessedTranscript.isEmpty ? rawTranscript : postProcessedTranscript
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileName
        } catch {
            return nil
        }
    }

    static func deleteTranscriptFile(_ fileName: String) {
        let fileURL = transcriptStorageDirectory().appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func loadTranscript(from fileName: String) -> String? {
        let fileURL = transcriptStorageDirectory().appendingPathComponent(fileName)
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    static func fileSizeBytes(for fileURL: URL) -> Int64? {
        (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map { Int64($0) }
    }

    static func saveAudioFile(from tempURL: URL) -> SavedAudioFile? {
        let fileName = UUID().uuidString + "." + AudioImportOptions.storageExtension(for: tempURL.lastPathComponent)
        let destURL = audioStorageDirectory().appendingPathComponent(fileName)
        do {
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.copyItem(at: tempURL, to: destURL)
            return SavedAudioFile(fileName: fileName, fileURL: destURL)
        } catch {
            return nil
        }
    }

    private static func isProtectedRecordingJournalAudioFile(
        _ fileName: String
    ) -> Bool {
        guard fileName.hasSuffix(".wav") else { return false }
        let recordingID = String(fileName.dropLast(4))
        return UUID(uuidString: recordingID) != nil
    }

    private static func savedAudioFileForStoppedRecording(
        _ fileURL: URL
    ) -> SavedAudioFile? {
        let audioDirectory = audioStorageDirectory().standardizedFileURL
        let standardizedURL = fileURL.standardizedFileURL
        guard standardizedURL.deletingLastPathComponent() == audioDirectory else {
            return saveAudioFile(from: fileURL)
        }
        guard standardizedURL.pathExtension.lowercased() == "wav",
              (try? RecordingCanonicalWAV.validateFile(at: standardizedURL)) != nil else {
            return saveAudioFile(from: fileURL)
        }
        return SavedAudioFile(
            fileName: standardizedURL.lastPathComponent,
            fileURL: standardizedURL
        )
    }

    static func saveSecurityScopedAudioFileOffMain(from fileURL: URL) async -> SavedAudioFile? {
        await Task.detached(priority: .userInitiated) {
            let accessGranted = fileURL.startAccessingSecurityScopedResource()
            defer {
                if accessGranted {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }
            return Self.saveAudioFile(from: fileURL)
        }.value
    }

    private static func deleteAudioFile(_ fileName: String) {
        let fileURL = audioStorageDirectory().appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func deleteStoredFiles(audioFileName: String?, transcriptFileName: String?) {
        if let audioFileName {
            deleteAudioFile(audioFileName)
        }
        if let transcriptFileName {
            deleteTranscriptFile(transcriptFileName)
        }
    }

    private static func deleteStoredFiles(_ assets: DeletedPipelineHistoryAssets) {
        deleteStoredFiles(audioFileName: assets.audioFileName, transcriptFileName: assets.transcriptFileName)
    }

    private static func markInterruptedRecoveryPlaceholders(
        in history: [PipelineHistoryItem],
        store: PipelineHistoryStore
    ) -> [PipelineHistoryItem] {
        history.map { item in
            guard item.isIncompleteTranscription else { return item }
            let updated = item.markInterruptedBeforeCompletion()
            try? store.update(updated)
            return updated
        }
    }

    @MainActor
    private func refreshTranscribingState() {
        isTranscribing = !activeTranscriptionJobs.isEmpty
        syncCriticalDictationActivity()
        meetingReminderOverlayManager.refreshVisibleReminder()
    }

    @MainActor
    private func syncCriticalDictationActivity() {
        let reason = "Quill dictation in progress"
        switch criticalDictationActivityState.update(
            isRecording: isRecording,
            activeTranscriptionJobCount: activeTranscriptionJobs.count
        ) {
        case .begin:
            ProcessInfo.processInfo.disableAutomaticTermination(reason)
        case .end:
            ProcessInfo.processInfo.enableAutomaticTermination(reason)
        case .none:
            break
        }
    }

    @MainActor
    private func registerTranscriptionJob(
        id: UUID,
        startedAt: Date,
        sessionIntent: SessionIntent,
        sessionContext: AppContext?,
        contextTask: Task<AppContext?, Never>?,
        recordingStartedAt: Date? = nil,
        recordingEndedAt: Date? = nil,
        isImportedAudio: Bool = false
    ) {
        activeTranscriptionJobs[id] = TranscriptionJob(
            id: id,
            startedAt: startedAt,
            sessionIntent: sessionIntent,
            sessionContext: sessionContext,
            contextTask: contextTask,
            task: nil,
            audioFileName: nil,
            liveNoteID: nil,
            recordingStartedAt: recordingStartedAt,
            recordingEndedAt: recordingEndedAt,
            isImportedAudio: isImportedAudio
        )
        foregroundTranscriptionJobID = id
        refreshTranscribingState()
    }

    @MainActor
    private func updateTranscriptionJob(_ id: UUID, _ mutate: (inout TranscriptionJob) -> Void) {
        guard var job = activeTranscriptionJobs[id] else { return }
        mutate(&job)
        activeTranscriptionJobs[id] = job
    }

    @MainActor
    private func finishTranscriptionJob(_ id: UUID) {
        activeTranscriptionJobs.removeValue(forKey: id)
        if foregroundTranscriptionJobID == id {
            foregroundTranscriptionJobID = activeTranscriptionJobs.values.max(by: { $0.startedAt < $1.startedAt })?.id
        }
        refreshTranscribingState()
        terminateIfReady()
    }

    @MainActor
    private func foregroundTranscriptionJob() -> TranscriptionJob? {
        guard let foregroundTranscriptionJobID else { return nil }
        return activeTranscriptionJobs[foregroundTranscriptionJobID]
    }

    @MainActor
    private func cleanupActiveAudioRecordersIfIdle() {
        guard !isRecording else { return }
        audioRecorder.cleanup()
        systemAudioRecorder.cleanup()
        systemDefaultAndSystemAudioRecorder.cleanup()
        activeAudioInputID = nil
        discardRecordingSegments()
        refreshAvailableMicrophonesIfNeeded()
    }

    @MainActor
    private func clearAudioRecorderCallbacks() {
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        audioRecorder.onPCM16Samples = nil
        systemAudioRecorder.onRecordingReady = nil
        systemAudioRecorder.onRecordingFailure = nil
        systemAudioRecorder.onPCM16Samples = nil
        systemDefaultAndSystemAudioRecorder.onRecordingReady = nil
        systemDefaultAndSystemAudioRecorder.onRecordingFailure = nil
    }

    @MainActor
    private func configureSelectedAudioRecorderCallbacks(
        inputID: String,
        onReady: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        clearAudioRecorderCallbacks()
        if AudioInputDevice.isSystemDefaultAndSystemAudio(inputID) {
            systemDefaultAndSystemAudioRecorder.onRecordingReady = onReady
            systemDefaultAndSystemAudioRecorder.onRecordingFailure = onFailure
        } else if AudioInputDevice.isSystemAudio(inputID) {
            systemAudioRecorder.onRecordingReady = onReady
            systemAudioRecorder.onRecordingFailure = onFailure
        } else {
            audioRecorder.onRecordingReady = onReady
            audioRecorder.onRecordingFailure = onFailure
        }
    }

    private func activeRecorderAudioLevelPublisher(inputID: String) -> AnyPublisher<Float, Never> {
        if AudioInputDevice.isSystemDefaultAndSystemAudio(inputID) {
            return systemDefaultAndSystemAudioRecorder.$audioLevel.eraseToAnyPublisher()
        }
        if AudioInputDevice.isSystemAudio(inputID) {
            return systemAudioRecorder.$audioLevel.eraseToAnyPublisher()
        }
        return audioRecorder.$audioLevel.eraseToAnyPublisher()
    }

    private func setActiveRecorderPCMHandler(_ handler: ((Data) -> Void)?) {
        let inputID = activeAudioInputID ?? selectedMicrophoneID
        if AudioInputDevice.isSystemDefaultAndSystemAudio(inputID) {
            audioRecorder.onPCM16Samples = nil
            systemAudioRecorder.onPCM16Samples = nil
        } else if AudioInputDevice.isSystemAudio(inputID) {
            systemAudioRecorder.onPCM16Samples = handler
            audioRecorder.onPCM16Samples = nil
        } else {
            audioRecorder.onPCM16Samples = handler
            systemAudioRecorder.onPCM16Samples = nil
        }
    }

    @MainActor
    private func startSelectedAudioRecorder(inputID: String) async throws {
        if AudioInputDevice.isSystemDefaultAndSystemAudio(inputID) {
            try await systemDefaultAndSystemAudioRecorder.startRecording()
        } else if AudioInputDevice.isSystemAudio(inputID) {
            try await systemAudioRecorder.startRecording()
        } else if didSwitchInputDuringRecording {
            try audioRecorder.startRecording(deviceUID: inputID)
        } else {
            let controller = try makeActiveMicrophoneJournalController()
            audioRecorder.normalizedPCM16Sink = controller.sink
            do {
                try audioRecorder.startRecording(deviceUID: inputID)
                controller.startCheckpointing { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        let message = localizedCatalogString(
                            "Unexpected quit recovery is unavailable for this recording. Recording continues normally."
                        )
                        self.errorMessage = LocalizedUserMessage.providerFailure(
                            prefix: message,
                            providerDetail: error.localizedDescription
                        )
                        self.overlayManager.showRecordingNotice(
                            message,
                            reminderFrame: self.meetingReminderOverlayManager.visibleOverlayFrame
                        )
                    }
                }
            } catch {
                audioRecorder.normalizedPCM16Sink = nil
                try? controller.discard()
                activeMicrophoneJournalController = nil
                activeRecordingID = nil
                throw error
            }
        }
    }

    private func stopActiveAudioRecorder(completion: @escaping (URL?) -> Void) {
        let inputID = activeAudioInputID ?? selectedMicrophoneID
        if AudioInputDevice.isSystemDefaultAndSystemAudio(inputID) {
            systemDefaultAndSystemAudioRecorder.stopRecording(completion: completion)
        } else if AudioInputDevice.isSystemAudio(inputID) {
            systemAudioRecorder.stopRecording(completion: completion)
        } else {
            audioRecorder.stopRecording { [weak self] temporaryURL in
                guard let self else {
                    completion(temporaryURL)
                    return
                }
                self.audioRecorder.normalizedPCM16Sink = nil
                let promotedURL = self.finishActiveMicrophoneJournal()
                if let promotedURL {
                    if let temporaryURL, temporaryURL.path != promotedURL.path {
                        try? FileManager.default.removeItem(at: temporaryURL)
                    }
                    completion(promotedURL)
                } else {
                    completion(temporaryURL)
                }
            }
        }
    }

    private func cancelActiveAudioRecorder() {
        let inputID = activeAudioInputID ?? selectedMicrophoneID
        if AudioInputDevice.isSystemDefaultAndSystemAudio(inputID) {
            systemDefaultAndSystemAudioRecorder.cancelRecording()
        } else if AudioInputDevice.isSystemAudio(inputID) {
            systemAudioRecorder.cancelRecording()
        } else {
            audioRecorder.normalizedPCM16Sink = nil
            audioRecorder.cancelRecording { [weak self] in
                self?.discardActiveMicrophoneJournal()
            }
        }
    }

    @MainActor
    private func makeActiveMicrophoneJournalController() throws -> MicrophoneRecordingJournalController {
        if let activeMicrophoneJournalController {
            return activeMicrophoneJournalController
        }
        let recordingID = activeRecordingID ?? UUID()
        activeRecordingID = recordingID
        let startedAt = Date(
            timeIntervalSince1970: floor(Date().timeIntervalSince1970 * 1_000) / 1_000
        )
        let request = RecordingJournalCreateRequest(
            recordingID: recordingID,
            sourceID: UUID(),
            segmentID: UUID(),
            startedAt: startedAt,
            monotonicAnchorNanoseconds: DispatchTime.now().uptimeNanoseconds,
            sourceMode: .microphone,
            sourceKind: .microphone,
            sourceFileName: "microphone.wav.part",
            pipeline: recordingPipelineSnapshot()
        )
        let controller = try MicrophoneRecordingJournalController(
            request: request,
            store: recordingJournalStore
        )
        activeMicrophoneJournalController = controller
        return controller
    }

    @MainActor
    private func recordingPipelineSnapshot() -> RecordingPipelineSnapshot {
        let transcriptionBackend: RecordingTranscriptionBackendSnapshot
        let transcriptionModelID: String?
        switch currentNoteBrowserTranscriptionChoice {
        case .apiStandard(let modelID):
            transcriptionBackend = .apiStandard
            transcriptionModelID = modelID
        case .apiRealtime(let modelID):
            transcriptionBackend = .apiRealtime
            transcriptionModelID = modelID
        case .nativeWhisper(let modelID):
            transcriptionBackend = .nativeWhisper
            transcriptionModelID = modelID
        case .legacyMlxWhisper(let model):
            transcriptionBackend = .legacyMlxWhisper
            transcriptionModelID = model.id
        case .appleLive:
            transcriptionBackend = .appleLive
            transcriptionModelID = nil
        }

        let intent: RecordingIntentSnapshot = switch currentSessionIntent.persistedIntent {
        case .dictation: .dictation
        case .commandAutomatic: .commandAutomatic
        case .commandManual: .commandManual
        }
        let trigger: RecordingTriggerSnapshot = switch activeRecordingTriggerMode {
        case .hold: .hold
        case .toggle: .toggle
        case nil: .unknown
        }

        return RecordingPipelineSnapshot(
            trigger: trigger,
            intent: intent,
            selectedText: currentSessionIntent.persistedSelectedText,
            title: activeRecordingCalendarSnapshot?.title,
            calendar: activeRecordingCalendarSnapshot,
            transcription: RecordingTranscriptionSnapshot(
                backend: transcriptionBackend,
                modelID: transcriptionModelID,
                spokenLanguageCode: transcriptionLanguage.code,
                providerSelection: transcriptionAPIURL.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty ? .defaultConfiguration : .transcriptionOverride
            ),
            processing: RecordingProcessingSnapshot(
                postProcessingEnabled: !disablePostProcessing,
                preferredModelID: postProcessingModel,
                fallbackModelID: postProcessingFallbackModel,
                outputLanguage: outputLanguage,
                preserveExactWording: preserveExactWording,
                contextCaptureEnabled: !disableContextCapture,
                instructionExecutionGuardEnabled: instructionExecutionGuardEnabled,
                customVocabulary: customVocabulary
                    .split(whereSeparator: \.isNewline)
                    .map(String.init),
                customSystemPrompt: customSystemPrompt.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty ? nil : customSystemPrompt
            )
        )
    }

    private func finishActiveMicrophoneJournal() -> URL? {
        guard let controller = activeMicrophoneJournalController else {
            activeRecordingID = nil
            return nil
        }
        defer {
            activeMicrophoneJournalController = nil
            activeRecordingID = nil
        }
        do {
            return try controller.finish()
        } catch {
            os_log(
                .error,
                log: recordingLog,
                "microphone journal finalization failed: %{public}@",
                error.localizedDescription
            )
            try? controller.preserveForRecovery()
            return nil
        }
    }

    private func detachActiveMicrophoneJournalForDiscard() -> MicrophoneRecordingJournalController? {
        audioRecorder.normalizedPCM16Sink = nil
        let controller = activeMicrophoneJournalController
        activeMicrophoneJournalController = nil
        activeRecordingID = nil
        return controller
    }

    private func discardActiveMicrophoneJournal() {
        let controller = detachActiveMicrophoneJournalForDiscard()
        try? controller?.discard()
    }

    private func completePromotedRecordingJournal(recordingID: UUID) {
        do {
            var manifest = try recordingJournalStore.loadManifest(
                recordingID: recordingID
            )
            guard manifest.state == .promoted
                    || manifest.state == .historyStored
                    || manifest.state == .finalized else {
                return
            }
            if manifest.state == .promoted {
                manifest = try recordingJournalStore.transition(
                    recordingID: recordingID,
                    to: .historyStored,
                    historyItemID: recordingID
                )
            }
            if manifest.state == .historyStored {
                _ = try recordingJournalStore.transition(
                    recordingID: recordingID,
                    to: .finalized
                )
            }
            try recordingJournalStore.removeInflightRecording(
                recordingID: recordingID
            )
        } catch RecordingJournalStoreError.recordingNotFound {
            return
        } catch {
            os_log(
                .error,
                log: recordingLog,
                "failed to complete promoted recording journal: %{public}@",
                error.localizedDescription
            )
        }
    }

    private func discardRecordingJournalAfterSuccessfulTranscription(
        recordingID: UUID
    ) {
        do {
            let manifest = try recordingJournalStore.loadManifest(
                recordingID: recordingID
            )
            guard manifest.state == .promoted else { return }
            try recordingJournalStore.removeInflightRecording(
                recordingID: recordingID
            )
        } catch RecordingJournalStoreError.recordingNotFound {
            return
        } catch {
            os_log(
                .error,
                log: recordingLog,
                "failed to remove completed recording journal: %{public}@",
                error.localizedDescription
            )
        }
    }

    private func preserveActiveMicrophoneJournalForRecovery() {
        audioRecorder.normalizedPCM16Sink = nil
        let controller = activeMicrophoneJournalController
        activeMicrophoneJournalController = nil
        activeRecordingID = nil
        try? controller?.preserveForRecovery()
    }

    /// Switches the audio input of an in-progress recording without ending the
    /// session. The current recorder's audio is kept as a segment and stitched
    /// with later segments at finish, so the result stays a single note. Live
    /// transcription is torn down (plan A): a switched session is transcribed
    /// from the stitched file at the end.
    @MainActor
    func switchActiveRecordingInput(to newInputID: String) {
        guard isRecording else { return }
        let currentInputID = activeAudioInputID ?? selectedMicrophoneID
        guard !AudioInputDevice.isSameInput(newInputID, currentInputID) else { return }

        // Verify access to the new input BEFORE stopping the current recorder.
        // A failed start (e.g. System Audio without Screen Recording permission)
        // runs handleRecordingFailure, which would discard the whole in-progress
        // recording. Use non-prompting checks so we don't trigger the
        // recording-start permission UI / state resets mid-session.
        guard canAccessRecordingInput(newInputID) else {
            // Detailed guidance in the menu bar; a short notice on the overlay
            // (which the user is actually looking at) that auto-dismisses without
            // ending the session. Pass the reminder card's frame so the overlay
            // can anchor a toast below it instead of overlapping.
            errorMessage = recordingInputAccessErrorMessage(for: newInputID)
            overlayManager.showRecordingNotice(
                recordingInputAccessNotice(for: newInputID),
                reminderFrame: meetingReminderOverlayManager.visibleOverlayFrame
            )
            return
        }

        liveTranscriber = nil
        tearDownRealtimeService()
        setActiveRecorderPCMHandler(nil)
        let journalToDiscardAfterDrain = detachActiveMicrophoneJournalForDiscard()
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        // All recorders deliver stopRecording's completion on the main thread
        // (AudioRecorder, SystemAudioRecorder, SystemDefaultAndSystemAudioRecorder),
        // matching the existing stopAndTranscribe path, so it is safe to touch
        // main-actor state here.
        stopActiveAudioRecorder { [weak self] segmentURL in
            try? journalToDiscardAfterDrain?.discard()
            guard let self else { return }
            // The session may have been stopped/cancelled while the old recorder
            // was finishing. Don't start a new recorder in that case — it would
            // leak a recording the app thinks has ended.
            guard self.isRecording else {
                if let segmentURL {
                    try? FileManager.default.removeItem(at: segmentURL)
                }
                return
            }
            if let segmentURL {
                self.recordingSegmentURLs.append(segmentURL)
            }
            self.didSwitchInputDuringRecording = true
            self.selectedMicrophoneID = newInputID
            self.activeAudioInputID = newInputID
            // Keep the output-mute interruption in sync with the new input: mic-only
            // mutes output to avoid echo, but System Audio must stay unmuted or it
            // would be captured silent.
            if AudioInputDevice.isMicrophoneOnly(newInputID) {
                self.applyAudioInterruptionIfNeeded()
            } else {
                self.restoreAudioInterruptionIfNeeded()
            }
            self.refreshOverlayInputOptions()
            self.configureSelectedAudioRecorderCallbacks(
                inputID: newInputID,
                onReady: {},
                onFailure: { [weak self] error in
                    DispatchQueue.main.async {
                        self?.handleRecordingFailure(error)
                    }
                }
            )
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.startSelectedAudioRecorder(inputID: newInputID)
                    await MainActor.run {
                        guard self.isRecording else { return }
                        self.audioLevelCancellable = self.activeRecorderAudioLevelPublisher(inputID: newInputID)
                            .receive(on: DispatchQueue.main)
                            .sink { [weak self] level in
                                self?.overlayManager.updateAudioLevel(level)
                            }
                    }
                } catch {
                    await MainActor.run {
                        self.handleRecordingFailure(error)
                    }
                }
            }
        }
    }

    /// Non-prompting permission check for switching to an input mid-recording.
    /// Unlike ensureRecordingInputAccess(for:) this has no side effects (no
    /// prompts, no error UI, no session-state resets).
    private func canAccessRecordingInput(_ inputID: String) -> Bool {
        let microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if AudioInputDevice.isSystemDefaultAndSystemAudio(inputID) {
            return microphoneGranted && hasScreenCapturePermission()
        }
        if AudioInputDevice.isSystemAudio(inputID) {
            return hasScreenCapturePermission()
        }
        return microphoneGranted
    }

    private func recordingInputAccessErrorMessage(for inputID: String) -> String {
        let tail = "Recording continues on the current input."
        if AudioInputDevice.isSystemDefaultAndSystemAudio(inputID) {
            return "Couldn't switch input: System Default + System Audio needs Microphone and Screen & System Audio Recording access (System Settings > Privacy & Security). \(tail)"
        }
        if AudioInputDevice.isSystemAudio(inputID) {
            return "Couldn't switch input: System Audio needs Screen & System Audio Recording access (System Settings > Privacy & Security). \(tail)"
        }
        return "Couldn't switch input: Microphone access is required (System Settings > Privacy & Security). \(tail)"
    }

    /// Short, single-line variant for the recording overlay pill, which only has
    /// room for a brief notice. Full guidance lives in the menu-bar message.
    private func recordingInputAccessNotice(for inputID: String) -> String {
        if AudioInputDevice.isSystemDefaultAndSystemAudio(inputID) {
            return "Mic + Screen Recording needed to switch"
        }
        if AudioInputDevice.isSystemAudio(inputID) {
            return "Screen Recording needed to switch"
        }
        return "Microphone access needed to switch"
    }

    /// Removes any captured segment temp files and resets the switch state.
    private func discardRecordingSegments() {
        for url in recordingSegmentURLs {
            try? FileManager.default.removeItem(at: url)
        }
        recordingSegmentURLs = []
        didSwitchInputDuringRecording = false
    }

    /// The audio file to finalize. When the session switched inputs, stitches the
    /// captured segments and the final segment into one continuous file;
    /// otherwise returns the final segment unchanged.
    private func stitchedRecordingURL(finalSegmentURL: URL) -> URL {
        guard didSwitchInputDuringRecording, !recordingSegmentURLs.isEmpty else {
            return finalSegmentURL
        }
        let segments = recordingSegmentURLs + [finalSegmentURL]
        defer { discardRecordingSegments() }
        do {
            return try AudioMixdownService().concatenate(segments)
        } catch {
            os_log(.error, log: recordingLog, "failed to stitch recording segments: %{public}@", String(describing: error))
            return finalSegmentURL
        }
    }

    /// Audio source choices shown in the recording overlay's input switcher.
    /// Limited to the source modes — the meaningful mid-recording choice — rather
    /// than the full hardware microphone list.
    private func recordingOverlayInputOptions() -> [RecordingOverlayInputOption] {
        [
            RecordingOverlayInputOption(id: AudioInputDevice.defaultMicrophoneID, name: "System Default", isStaticQuillName: true),
            RecordingOverlayInputOption(id: AudioInputDevice.systemAudioID, name: "System Audio", isStaticQuillName: true),
            RecordingOverlayInputOption(id: AudioInputDevice.systemDefaultAndSystemAudioID, name: "System Default + System Audio", isStaticQuillName: true)
        ]
    }

    private func refreshOverlayInputOptions() {
        overlayManager.updateInputOptions(
            recordingOverlayInputOptions(),
            selectedID: activeAudioInputID ?? selectedMicrophoneID
        )
    }

    func clearPipelineHistory() {
        do {
            let removedStoredFiles = try pipelineHistoryStore.clearAll()
            for removedAssets in removedStoredFiles {
                Self.deleteStoredFiles(removedAssets)
            }
            pipelineHistory = []
        } catch {
            errorMessage = LocalizedUserMessage.providerFailure(prefix: localizedCatalogString("Unable to clear run history"), providerDetail: error.localizedDescription)
        }
    }

    func deleteHistoryEntry(id: UUID) {
        guard let index = pipelineHistory.firstIndex(where: { $0.id == id }) else { return }
        do {
            if let deletedAssets = try pipelineHistoryStore.delete(id: id) {
                Self.deleteStoredFiles(deletedAssets)
            }
            pipelineHistory.remove(at: index)
        } catch {
            errorMessage = LocalizedUserMessage.providerFailure(prefix: localizedCatalogString("Unable to delete run history entry"), providerDetail: error.localizedDescription)
        }
    }

    @MainActor
    func updateHistoryItemTitle(id: UUID, title: String) {
        guard let index = pipelineHistory.firstIndex(where: { $0.id == id }) else { return }
        let item = pipelineHistory[index]
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = trimmed.isEmpty ? nil : trimmed
        guard item.customTitle != normalizedTitle else { return }
        let updated = item.withCustomTitle(normalizedTitle)
        do {
            try pipelineHistoryStore.update(updated)
            pipelineHistory[index] = updated
        } catch {
            errorMessage = LocalizedUserMessage.providerFailure(prefix: localizedCatalogString("Failed to save note title"), providerDetail: error.localizedDescription)
        }
    }

    func updateTranscript(id: UUID, text: String) {
        guard let item = pipelineHistory.first(where: { $0.id == id }) else { return }
        // 파일에도 동기화해서 앱 재시작 후 폴백 로딩 시에도 일관성 유지
        if let fileName = item.transcriptFileName {
            let fileURL = Self.transcriptStorageDirectory().appendingPathComponent(fileName)
            try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        let updated = PipelineHistoryItem(
            intent: item.intent,
            selectedText: item.selectedText,
            id: item.id,
            timestamp: item.timestamp,
            recordingStartedAt: item.recordingStartedAt,
            recordingEndedAt: item.recordingEndedAt,
            calendarMatch: item.calendarMatch,
            rawTranscript: item.rawTranscript,
            postProcessedTranscript: text,
            postProcessingPrompt: item.postProcessingPrompt,
            contextSummary: item.contextSummary,
            contextPrompt: item.contextPrompt,
            contextScreenshotDataURL: item.contextScreenshotDataURL,
            contextScreenshotStatus: item.contextScreenshotStatus,
            postProcessingStatus: item.postProcessingStatus,
            debugStatus: item.debugStatus,
            customVocabulary: item.customVocabulary,
            customSystemPrompt: item.customSystemPrompt,
            audioFileName: item.audioFileName,
            usedLocalTranscription: item.usedLocalTranscription,
            usedContextCapture: item.usedContextCapture,
            usedPostProcessing: item.usedPostProcessing,
            transcriptionLanguageCode: item.transcriptionLanguageCode,
            localTranscriptionModelID: item.localTranscriptionModelID,
            transcriptFileName: item.transcriptFileName,
            contextAppName: item.contextAppName,
            contextBundleIdentifier: item.contextBundleIdentifier,
            contextWindowTitle: item.contextWindowTitle,
            customTitle: item.customTitle
        )
        do {
            try pipelineHistoryStore.update(updated)
            if let index = pipelineHistory.firstIndex(where: { $0.id == id }) {
                pipelineHistory[index] = updated
            }
        } catch {
            errorMessage = LocalizedUserMessage.providerFailure(prefix: localizedCatalogString("Failed to save transcript edit"), providerDetail: error.localizedDescription)
        }
    }

    @MainActor
    func importAudioFile(_ fileURL: URL, mode: NoteBrowserTranscriptionMode) {
        importAudioFile(fileURL, choice: preferredAudioImportChoice(for: mode))
    }

    @MainActor
    func importAudioFile(_ fileURL: URL, choice: TranscriptionBackendChoice) {
        let configuration = AudioImportTaskConfiguration(
            transcriptionConfiguration: audioImportConfiguration(for: choice),
            transcriptionAPIKey: resolvedTranscriptionAPIKey,
            transcriptionAPIBaseURL: resolvedTranscriptionBaseURL,
            localWhisperPath: localWhisperPath,
            transcriptionLanguage: transcriptionLanguage,
            customVocabulary: customVocabulary,
            customSystemPrompt: customSystemPrompt,
            outputLanguage: outputLanguage,
            postProcessingEnabled: !disablePostProcessing,
            preserveExactWording: preserveExactWording,
            pressEnterCommandEnabled: isPressEnterVoiceCommandEnabled,
            postProcessingAPIKey: apiKey,
            postProcessingBaseURL: apiBaseURL,
            postProcessingModel: postProcessingModel,
            postProcessingFallbackModel: postProcessingFallbackModel,
            instructionExecutionGuardEnabled: instructionExecutionGuardEnabled
        )
        let jobID = UUID()
        let noteID = UUID()
        let startedAt = Date()
        let importContextSummary = AudioImportOptions.importContextSummary(for: fileURL.lastPathComponent)

        Task { [weak self] in
            guard let savedAudioFile = await Self.saveSecurityScopedAudioFileOffMain(from: fileURL) else {
                self?.errorMessage = localizedCatalogString("Unable to save the audio file. Check disk space or file permissions and try again.")
                return
            }
            guard let self else {
                Self.deleteAudioFile(savedAudioFile.fileName)
                return
            }

            let placeholder = PipelineHistoryItem(
                id: noteID,
                timestamp: startedAt,
                recordingStartedAt: nil,
                recordingEndedAt: nil,
                calendarMatch: nil,
                rawTranscript: "",
                postProcessedTranscript: "",
                postProcessingPrompt: nil,
                systemPrompt: configuration.systemPrompt,
                contextSummary: importContextSummary,
                contextPrompt: nil,
                contextScreenshotDataURL: nil,
                contextScreenshotStatus: "No screenshot",
                postProcessingStatus: "importing",
                debugStatus: "Importing audio",
                customVocabulary: configuration.customVocabulary,
                customSystemPrompt: configuration.customSystemPrompt,
                audioFileName: savedAudioFile.fileName,
                usedLocalTranscription: configuration.useLocalTranscription,
                usedContextCapture: false,
                usedPostProcessing: configuration.postProcessingEnabled,
                transcriptionLanguageCode: configuration.transcriptionLanguage.code,
                localTranscriptionModelID: configuration.localTranscriptionModel.id,
                contextAppName: nil,
                contextBundleIdentifier: nil,
                contextWindowTitle: nil
            )

            do {
                let removedStoredFiles = try self.appendPipelineHistoryItem(placeholder)
                for removedAssets in removedStoredFiles {
                    Self.deleteStoredFiles(removedAssets)
                }
            } catch {
                Self.deleteAudioFile(savedAudioFile.fileName)
                self.errorMessage = LocalizedUserMessage.providerFailure(prefix: localizedCatalogString("Unable to save imported audio note"), providerDetail: error.localizedDescription)
                return
            }

            self.registerTranscriptionJob(
                id: jobID,
                startedAt: startedAt,
                sessionIntent: .dictation,
                sessionContext: nil,
                contextTask: nil,
                recordingStartedAt: nil,
                recordingEndedAt: nil,
                isImportedAudio: true
            )
            self.updateTranscriptionJob(jobID) {
                $0.liveNoteID = noteID
                $0.audioFileName = savedAudioFile.fileName
            }

            let task = Task { [weak self] in
                guard let self else { return }
                let importedContext = AppContext(
                    appName: nil,
                    bundleIdentifier: nil,
                    windowTitle: nil,
                    selectedText: nil,
                    currentActivity: importContextSummary,
                    contextSystemPrompt: nil,
                    contextPrompt: nil,
                    screenshotDataURL: nil,
                    screenshotMimeType: nil,
                    screenshotError: "No screenshot"
                )
                do {
                    let transcriptionService = try configuration.makeTranscriptionService()
                    let rawTranscript = try await transcriptionService.transcribe(fileURL: savedAudioFile.fileURL)
                    try Task.checkCancellation()
                    let parsedTranscript = Self.parseTranscriptCommands(
                        from: rawTranscript,
                        pressEnterCommandEnabled: configuration.pressEnterCommandEnabled
                    )
                    let result = await self.processTranscript(
                        parsedTranscript.transcript,
                        intent: .dictation,
                        context: importedContext,
                        postProcessingService: configuration.makePostProcessingService(),
                        customVocabulary: configuration.customVocabulary,
                        customSystemPrompt: configuration.customSystemPrompt,
                        outputLanguage: configuration.outputLanguage,
                        postProcessingEnabled: configuration.postProcessingEnabled,
                        preserveExactWording: configuration.preserveExactWording
                    )
                    try Task.checkCancellation()
                    let processingStatus = Self.statusMessage(
                        for: result.outcome,
                        parsedTranscript: parsedTranscript
                    )
                    self.recordPipelineHistoryEntry(
                        jobID: jobID,
                        rawTranscript: parsedTranscript.transcript,
                        postProcessedTranscript: result.finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
                        postProcessingPrompt: result.prompt,
                        systemPrompt: configuration.systemPrompt,
                        context: importedContext,
                        processingStatus: processingStatus,
                        intent: .dictation,
                        audioFileName: savedAudioFile.fileName,
                        useLocalTranscriptionOverride: configuration.useLocalTranscription,
                        localTranscriptionModelIDOverride: configuration.localTranscriptionModel.id,
                        usedContextCaptureOverride: false,
                        usedPostProcessingOverride: configuration.postProcessingEnabled,
                        transcriptionLanguageCodeOverride: configuration.transcriptionLanguage.code,
                        customVocabularyOverride: configuration.customVocabulary,
                        customSystemPromptOverride: configuration.customSystemPrompt
                    )
                    self.finishTranscriptionJob(jobID)
                } catch is CancellationError {
                    self.finishTranscriptionJob(jobID)
                } catch {
                    guard !Task.isCancelled else {
                        self.finishTranscriptionJob(jobID)
                        return
                    }
                    self.recordPipelineHistoryEntry(
                        jobID: jobID,
                        rawTranscript: "",
                        postProcessedTranscript: "",
                        postProcessingPrompt: "",
                        systemPrompt: configuration.systemPrompt,
                        context: importedContext,
                        processingStatus: "Error: \(error.localizedDescription)",
                        intent: .dictation,
                        audioFileName: savedAudioFile.fileName,
                        useLocalTranscriptionOverride: configuration.useLocalTranscription,
                        localTranscriptionModelIDOverride: configuration.localTranscriptionModel.id,
                        usedContextCaptureOverride: false,
                        usedPostProcessingOverride: configuration.postProcessingEnabled,
                        transcriptionLanguageCodeOverride: configuration.transcriptionLanguage.code,
                        customVocabularyOverride: configuration.customVocabulary,
                        customSystemPromptOverride: configuration.customSystemPrompt
                    )
                    self.finishTranscriptionJob(jobID)
                }
            }
            self.updateTranscriptionJob(jobID) { $0.task = task }
        }
    }

    @MainActor
    func retryTranscription(item: PipelineHistoryItem) {
        guard !retryingItemIDs.contains(item.id) else { return }

        let snapshot: RetrySnapshot
        do {
            snapshot = try makeRetrySnapshot(for: item)
        } catch {
            errorMessage = LocalizedUserMessage.providerFailure(prefix: localizedCatalogString("Unable to prepare retry"), providerDetail: error.localizedDescription)
            return
        }

        retryingItemIDs.insert(item.id)

        let postProcessingService = PostProcessingService(
            apiKey: apiKey,
            baseURL: apiBaseURL,
            preferredModel: postProcessingModel,
            preferredFallbackModel: postProcessingFallbackModel,
            instructionExecutionGuardEnabled: instructionExecutionGuardEnabled
        )

        Task { [weak self] in
            guard let self else { return }

            let updatedItem: PipelineHistoryItem
            let retrySucceeded: Bool
            do {
                let transcriptionService = try TranscriptionService(
                    apiKey: resolvedTranscriptionAPIKey,
                    baseURL: resolvedTranscriptionBaseURL,
                    useLocalTranscription: snapshot.useLocalTranscription,
                    localWhisperPath: snapshot.localWhisperPath,
                    useLegacyMlxWhisper: snapshot.useLegacyMlxWhisper,
                    transcriptionLanguage: snapshot.transcriptionLanguage,
                    localTranscriptionModel: snapshot.localTranscriptionModel,
                    transcriptionModel: snapshot.transcriptionModel
                )
                let rawTranscript = try await transcriptionService.transcribe(fileURL: snapshot.audioURL)
                let parsedTranscript = Self.parseTranscriptCommands(
                    from: rawTranscript,
                    pressEnterCommandEnabled: self.isPressEnterVoiceCommandEnabled
                )
                let result = await self.processTranscript(
                    parsedTranscript.transcript,
                    intent: snapshot.restoredIntent,
                    context: snapshot.restoredContext,
                    postProcessingService: postProcessingService,
                    customVocabulary: snapshot.customVocabulary,
                    customSystemPrompt: snapshot.customSystemPrompt,
                    outputLanguage: snapshot.outputLanguage,
                    postProcessingEnabled: snapshot.postProcessingEnabled,
                    preserveExactWording: snapshot.preserveExactWording
                )
                updatedItem = self.makeRetryHistoryItem(
                    from: snapshot,
                    rawTranscript: parsedTranscript.transcript,
                    postProcessedTranscript: result.finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
                    postProcessingPrompt: result.prompt,
                    postProcessingStatus: Self.statusMessage(
                        for: result.outcome,
                        parsedTranscript: parsedTranscript,
                        isRetry: true
                    ),
                    debugStatus: "Retried"
                )
                retrySucceeded = true
            } catch {
                updatedItem = self.makeRetryHistoryItem(
                    from: snapshot,
                    rawTranscript: snapshot.item.rawTranscript,
                    postProcessedTranscript: snapshot.item.postProcessedTranscript,
                    postProcessingPrompt: snapshot.item.postProcessingPrompt,
                    postProcessingStatus: "Error: \(error.localizedDescription)",
                    debugStatus: "Retry failed"
                )
                retrySucceeded = false
            }

            await MainActor.run {
                do {
                    try self.pipelineHistoryStore.update(updatedItem)
                    self.pipelineHistory = self.pipelineHistoryStore.loadAllHistory()
                    if retrySucceeded {
                        self.copyRetryTranscriptToPasteboardIfNeeded(updatedItem.postProcessedTranscript)
                    }
                } catch {
                    self.errorMessage = LocalizedUserMessage.providerFailure(prefix: localizedCatalogString("Failed to save retry result"), providerDetail: error.localizedDescription)
                }
                self.retryingItemIDs.remove(snapshot.item.id)
            }
        }
    }

    @MainActor
    private func copyRetryTranscriptToPasteboardIfNeeded(_ transcript: String) {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return }
        lastTranscript = trimmedTranscript
        writeDictationStringToPasteboard(trimmedTranscript)
    }

    @MainActor
    private func makeRetrySnapshot(for item: PipelineHistoryItem) throws -> RetrySnapshot {
        guard let audioFileName = item.audioFileName else {
            throw TranscriptionError.submissionFailed("Audio file not found for retry.")
        }

        let audioURL = Self.audioStorageDirectory().appendingPathComponent(audioFileName)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw TranscriptionError.submissionFailed("Audio file not found for retry.")
        }

        let options = AudioImportOptions(
            fileExtension: audioURL.pathExtension,
            currentChoice: currentNoteBrowserTranscriptionChoice,
            apiStandardModelID: resolvedStandardTranscriptionModelID,
            fileSizeBytes: Self.fileSizeBytes(for: audioURL),
            hasAPIKey: hasTranscriptionAPIKey,
            hasNativeLocalWhisperModel: hasNativeLocalWhisperModel,
            legacyLocalWhisperModels: installedLegacyLocalWhisperModels,
            nativeWhisperModelID: NativeWhisperModelCatalog.recommended.id,
            nativeWhisperDisplayName: NativeWhisperModelCatalog.recommended.displayName
        )
        guard let retryChoice = options.defaultChoice else {
            throw TranscriptionError.submissionFailed("No transcription method is available. Configure an API key or install a Local Whisper model, then try again.")
        }
        let configuration = audioImportConfiguration(for: retryChoice)

        return RetrySnapshot(
            item: item,
            audioURL: audioURL,
            restoredContext: AppContext(
                appName: nil,
                bundleIdentifier: nil,
                windowTitle: nil,
                selectedText: nil,
                currentActivity: item.contextSummary,
                contextSystemPrompt: item.contextSystemPrompt,
                contextPrompt: item.contextPrompt,
                screenshotDataURL: item.contextScreenshotDataURL,
                screenshotMimeType: item.contextScreenshotDataURL != nil ? "image/jpeg" : nil,
                screenshotError: nil
            ),
            restoredIntent: SessionIntent.fromPersisted(intent: item.intent, selectedText: item.selectedText),
            transcriptionLanguage: TranscriptionLanguage.find(code: item.transcriptionLanguageCode),
            localTranscriptionModel: configuration.localTranscriptionModel,
            useLocalTranscription: configuration.useLocalTranscription,
            customVocabulary: item.customVocabulary,
            customSystemPrompt: item.customSystemPrompt,
            outputLanguage: outputLanguage,
            postProcessingEnabled: item.usedPostProcessing,
            preserveExactWording: preserveExactWording,
            localWhisperPath: localWhisperPath.isEmpty ? nil : localWhisperPath,
            useLegacyMlxWhisper: configuration.useLegacyMlxWhisper,
            transcriptionModel: configuration.transcriptionModel
        )
    }

    private func makeRetryHistoryItem(
        from snapshot: RetrySnapshot,
        rawTranscript: String,
        postProcessedTranscript: String,
        postProcessingPrompt: String?,
        postProcessingStatus: String,
        debugStatus: String
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            intent: snapshot.item.intent,
            selectedText: snapshot.item.selectedText,
            id: snapshot.item.id,
            timestamp: snapshot.item.timestamp,
            recordingStartedAt: snapshot.item.recordingStartedAt,
            recordingEndedAt: snapshot.item.recordingEndedAt,
            calendarMatch: snapshot.item.calendarMatch,
            rawTranscript: rawTranscript,
            postProcessedTranscript: postProcessedTranscript,
            postProcessingPrompt: postProcessingPrompt,
            contextSummary: snapshot.item.contextSummary,
            contextPrompt: snapshot.item.contextPrompt,
            contextScreenshotDataURL: snapshot.item.contextScreenshotDataURL,
            contextScreenshotStatus: snapshot.item.contextScreenshotStatus,
            postProcessingStatus: postProcessingStatus,
            debugStatus: debugStatus,
            customVocabulary: snapshot.customVocabulary,
            customSystemPrompt: snapshot.customSystemPrompt,
            audioFileName: snapshot.item.audioFileName,
            usedLocalTranscription: snapshot.useLocalTranscription,
            usedContextCapture: snapshot.item.usedContextCapture,
            usedPostProcessing: snapshot.postProcessingEnabled,
            transcriptionLanguageCode: snapshot.transcriptionLanguage.code,
            localTranscriptionModelID: snapshot.localTranscriptionModel.id,
            transcriptFileName: snapshot.item.transcriptFileName
        )
    }

    func updatePermissionStatus(accessibility: Bool, screenRecording: Bool) {
        if hasAccessibility != accessibility {
            hasAccessibility = accessibility
        }
        if hasScreenRecordingPermission != screenRecording {
            hasScreenRecordingPermission = screenRecording
        }
    }

    @MainActor
    func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        updatePermissionStatus(
            accessibility: AXIsProcessTrusted(),
            screenRecording: hasScreenCapturePermission()
        )
        if hasAccessibility && hasScreenRecordingPermission {
            return
        }
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updatePermissionStatus(
                    accessibility: AXIsProcessTrusted(),
                    screenRecording: self.hasScreenCapturePermission()
                )
                if self.hasAccessibility && self.hasScreenRecordingPermission {
                    self.stopAccessibilityPolling()
                }
            }
        }
    }

    @MainActor
    func stopAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
    }

    func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            openPrivacySettingsPane("Privacy_Accessibility")
        }
    }

    /// Shows the native macOS Accessibility prompt directly (the system "wants to
    /// control this computer" dialog) without our own explanatory alert and
    /// without force-opening System Settings — the system dialog already has an
    /// "Open System Settings" button. Used at launch so the user sees a single
    /// native prompt. macOS only surfaces this dialog while the app is still
    /// undetermined; once the user has decided it no-ops, and the menu-bar
    /// "Accessibility Required" warning remains the path back.
    func promptForAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openMicrophoneSettings() {
        openPrivacySettingsPane("Privacy_Microphone")
    }

    func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            refreshAvailableMicrophones()
            DispatchQueue.main.async {
                completion(true)
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.refreshAvailableMicrophones()
                    }
                    completion(granted)
                }
            }
        case .denied, .restricted:
            openMicrophoneSettings()
            DispatchQueue.main.async {
                completion(false)
            }
        @unknown default:
            openMicrophoneSettings()
            DispatchQueue.main.async {
                completion(false)
            }
        }
    }


    func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestScreenCapturePermissionForRecordingStart() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        let granted = await Task.detached(priority: .userInitiated) {
            CGRequestScreenCaptureAccess()
        }.value
        return granted || CGPreflightScreenCaptureAccess()
    }

    func requestScreenCapturePermission() {
        // ScreenCaptureKit triggers the "Screen & System Audio Recording"
        // permission dialog on macOS Sequoia+, correctly identifying the
        // running app (unlike the legacy CGWindowListCreateImage path).
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] _, _ in
            DispatchQueue.main.async {
                let granted = CGPreflightScreenCaptureAccess()
                self?.hasScreenRecordingPermission = granted
                if !granted {
                    self?.openScreenCaptureSettings()
                }
            }
        }

        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    func openScreenCaptureSettings() {
        openPrivacySettingsPane("Privacy_ScreenCapture")
    }

    private func openPrivacySettingsPane(_ pane: String) {
        let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        if let url = settingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert the toggle on failure without re-triggering didSet
            let current = SMAppService.mainApp.status == .enabled
            if current != launchAtLogin {
                launchAtLogin = current
            }
        }
    }

    func refreshLaunchAtLoginStatus() {
        let current = SMAppService.mainApp.status == .enabled
        if current != launchAtLogin {
            launchAtLogin = current
        }
    }

    func refreshAvailableMicrophones() {
        guard !isRecording, !audioRecorder.isRecording else {
            needsMicrophoneRefreshAfterRecording = true
            return
        }

        needsMicrophoneRefreshAfterRecording = false
        availableMicrophones = AudioDevice.availableInputDevices()
    }

    private func refreshAvailableMicrophonesIfNeeded() {
        guard needsMicrophoneRefreshAfterRecording else { return }
        refreshAvailableMicrophones()
    }

    private func installAudioDeviceObservers() {
        removeAudioDeviceObservers()

        let notificationCenter = NotificationCenter.default
        let refreshOnAudioDeviceChange: (Notification) -> Void = { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice,
                  device.hasMediaType(.audio) else {
                return
            }
            self?.refreshAvailableMicrophones()
        }

        audioDeviceObservers.append(
            notificationCenter.addObserver(
                forName: .AVCaptureDeviceWasConnected,
                object: nil,
                queue: .main,
                using: refreshOnAudioDeviceChange
            )
        )
        audioDeviceObservers.append(
            notificationCenter.addObserver(
                forName: .AVCaptureDeviceWasDisconnected,
                object: nil,
                queue: .main,
                using: refreshOnAudioDeviceChange
            )
        )
    }

    var usesFnShortcut: Bool {
        holdShortcut.usesFnKey || toggleShortcut.usesFnKey || copyAgainShortcut.usesFnKey
    }

    var hasEnabledHoldShortcut: Bool {
        !holdShortcut.isDisabled
    }

    var hasEnabledToggleShortcut: Bool {
        !toggleShortcut.isDisabled
    }

    var shortcutStatusText: String {
        if hotkeyMonitoringErrorMessage != nil {
            return localizedCatalogString("Global shortcuts unavailable")
        }

        switch (hasEnabledHoldShortcut, hasEnabledToggleShortcut) {
        case (true, true):
            return String(format: localizedCatalogString("Hold %@ or tap %@ to dictate"), holdShortcut.displayName, toggleShortcut.displayName)
        case (true, false):
            return LocalizedUserMessage.shortcutStatus(shortcut: holdShortcut.displayName, isToggleMode: false)
        case (false, true):
            return LocalizedUserMessage.shortcutStatus(shortcut: toggleShortcut.displayName, isToggleMode: true)
        case (false, false):
            return localizedCatalogString("No dictation shortcut enabled")
        }
    }

    var shortcutStartDelayMilliseconds: Int {
        Int((shortcutStartDelay * 1000).rounded())
    }

    func savedCustomShortcut(for role: ShortcutRole) -> ShortcutBinding? {
        switch role {
        case .hold:
            return savedHoldCustomShortcut
        case .toggle:
            return savedToggleCustomShortcut
        case .recordingCancel:
            return savedRecordingCancelCustomShortcut
        case .copyAgain:
            return savedCopyAgainCustomShortcut
        }
    }

    var savedRecordingCancelShortcut: ShortcutBinding? {
        savedRecordingCancelCustomShortcut
    }

    var commandModeManualModifierValidationMessage: String? {
        guard isCommandModeEnabled, commandModeStyle == .manual else { return nil }
        return commandModeManualModifierCollisionMessage(for: commandModeManualModifier)
            ?? recordingCancelShortcutCollisionMessage()
    }

    @discardableResult
    func setCommandModeEnabled(_ enabled: Bool) -> String? {
        isCommandModeEnabled = enabled
        if enabled, commandModeStyle == .manual {
            return commandModeManualModifierCollisionMessage(for: commandModeManualModifier)
                ?? recordingCancelShortcutCollisionMessage()
        }
        return nil
    }

    @discardableResult
    func setCommandModeStyle(_ style: CommandModeStyle) -> String? {
        commandModeStyle = style
        if isCommandModeEnabled, style == .manual {
            return commandModeManualModifierCollisionMessage(for: commandModeManualModifier)
                ?? recordingCancelShortcutCollisionMessage()
        }
        return nil
    }

    @discardableResult
    func setCommandModeManualModifier(_ modifier: CommandModeManualModifier) -> String? {
        // Match sibling setters: always commit, then validate.
        commandModeManualModifier = modifier
        if isCommandModeEnabled, commandModeStyle == .manual {
            return commandModeManualModifierCollisionMessage(for: modifier)
                ?? recordingCancelShortcutCollisionMessage(
                    permittedAdditionalExactMatchModifiers: modifier.shortcutModifier
                )
        }
        return nil
    }

    @discardableResult
    func setRecordingCancelShortcut(_ binding: ShortcutBinding) -> String? {
        let binding = binding.normalizedForStorageMigration()
        guard !cancelShortcutOverlapsDictationShortcut(binding, holdShortcut),
              !cancelShortcutOverlapsDictationShortcut(binding, toggleShortcut) else {
            return "Cancel shortcut must be distinct from dictation shortcuts."
        }
        guard !binding.conflicts(with: copyAgainShortcut) else {
            return "Cancel shortcut must be distinct from Paste Again."
        }

        if binding.isCustom && binding != .defaultRecordingCancel {
            savedRecordingCancelCustomShortcut = binding
        }
        recordingCancelShortcut = binding
        return nil
    }

    @discardableResult
    func setShortcut(_ binding: ShortcutBinding, for role: ShortcutRole) -> String? {
        let binding = binding.normalizedForStorageMigration()
        if role == .recordingCancel {
            return setRecordingCancelShortcut(binding)
        }

        if role == .hold || role == .toggle {
            let otherDictationBinding = role == .hold ? toggleShortcut : holdShortcut
            guard !binding.conflicts(with: otherDictationBinding) else {
                return "Hold and tap shortcuts must be distinct."
            }
        }

        if role != .copyAgain, binding.conflicts(with: copyAgainShortcut) {
            return "This shortcut is already used by Paste Again."
        }
        if role == .copyAgain {
            if binding.conflicts(with: recordingCancelShortcut) {
                return "Paste Again cannot share a shortcut with Cancel Recording."
            }
            if binding.conflicts(with: holdShortcut) {
                return "Paste Again cannot share a shortcut with Hold to Talk."
            }
            if binding.conflicts(with: toggleShortcut) {
                return "Paste Again cannot share a shortcut with Tap to Toggle."
            }
            if isCommandModeEnabled, commandModeStyle == .manual,
               let message = commandModeManualModifierCollisionMessage(
                for: commandModeManualModifier,
                copyAgainBinding: binding
               ) {
                return message
            }
        }
        guard !cancelShortcutOverlapsDictationShortcut(recordingCancelShortcut, binding) else {
            return "Dictation shortcuts must be distinct from the cancel shortcut."
        }

        let nextHoldShortcut = role == .hold ? binding : holdShortcut
        let nextToggleShortcut = role == .toggle ? binding : toggleShortcut
        if isCommandModeEnabled,
           commandModeStyle == .manual,
           let message = commandModeManualModifierCollisionMessage(
            for: commandModeManualModifier,
            holdBinding: nextHoldShortcut,
            toggleBinding: nextToggleShortcut
           ) {
            return message
        }

        if role == .hold {
            if binding.isCustom {
                savedHoldCustomShortcut = binding
            }
            holdShortcut = binding
        } else if role == .toggle {
            if binding.isCustom {
                savedToggleCustomShortcut = binding
            }
            toggleShortcut = binding
        } else if role == .copyAgain {
            if binding.isCustom {
                savedCopyAgainCustomShortcut = binding
            }
            copyAgainShortcut = binding
        }

        return nil
    }

    private func recordingCancelShortcutCollisionMessage(
        permittedAdditionalExactMatchModifiers: ShortcutModifiers? = nil
    ) -> String? {
        let permittedAdditionalExactMatchModifiers = permittedAdditionalExactMatchModifiers
            ?? permittedAdditionalExactMatchModifiersForShortcutMatching
        if cancelShortcutOverlapsDictationShortcut(
            recordingCancelShortcut,
            holdShortcut,
            permittedAdditionalExactMatchModifiers: permittedAdditionalExactMatchModifiers
        ) || cancelShortcutOverlapsDictationShortcut(
            recordingCancelShortcut,
            toggleShortcut,
            permittedAdditionalExactMatchModifiers: permittedAdditionalExactMatchModifiers
        ) {
            return "Cancel shortcut must be distinct from dictation shortcuts."
        }
        return nil
    }

    private func cancelShortcutOverlapsDictationShortcut(
        _ cancel: ShortcutBinding,
        _ dictation: ShortcutBinding,
        permittedAdditionalExactMatchModifiers: ShortcutModifiers? = nil
    ) -> Bool {
        guard !cancel.isDisabled, !dictation.isDisabled else { return false }
        guard cancel.primaryInputOverlapsForCancellation(with: dictation) else { return false }

        let permittedAdditionalExactMatchModifiers = permittedAdditionalExactMatchModifiers
            ?? permittedAdditionalExactMatchModifiersForShortcutMatching
        let orderedModifierKeyCodes = Array(ShortcutBinding.modifierKeyCodes).sorted()
        let combinations = 1 << orderedModifierKeyCodes.count

        for mask in 0..<combinations {
            var pressedModifierKeyCodes: Set<UInt16> = []
            for (index, keyCode) in orderedModifierKeyCodes.enumerated() where (mask & (1 << index)) != 0 {
                pressedModifierKeyCodes.insert(keyCode)
            }

            if cancel.isActiveForCancellationConflict(
                pressedModifierKeyCodes: pressedModifierKeyCodes,
                permittedAdditionalExactMatchModifiers: permittedAdditionalExactMatchModifiers
            ) && dictation.isActiveForCancellationConflict(
                pressedModifierKeyCodes: pressedModifierKeyCodes,
                permittedAdditionalExactMatchModifiers: permittedAdditionalExactMatchModifiers
            ) {
                return true
            }
        }

        return false
    }

    private func commandModeManualModifierCollisionMessage(
        for modifier: CommandModeManualModifier,
        holdBinding: ShortcutBinding? = nil,
        toggleBinding: ShortcutBinding? = nil,
        copyAgainBinding: ShortcutBinding? = nil
    ) -> String? {
        let holdBinding = holdBinding ?? holdShortcut
        let toggleBinding = toggleBinding ?? toggleShortcut
        let copyAgainBinding = copyAgainBinding ?? copyAgainShortcut
        let manualModifier = modifier.shortcutModifier

        if !holdBinding.isDisabled && holdBinding.modifiers.contains(manualModifier) {
            return "That modifier is already part of the hold shortcut."
        }
        if !toggleBinding.isDisabled && toggleBinding.modifiers.contains(manualModifier) {
            return "That modifier is already part of the tap shortcut."
        }
        if !copyAgainBinding.isDisabled && copyAgainBinding.modifiers.contains(manualModifier) {
            return "That modifier is already part of the Paste Again shortcut."
        }
        // Modifier-only bindings carry identity in keyCode, not modifiers.
        if !holdBinding.isDisabled,
           holdBinding.kind == .modifierKey,
           let bindingModifier = ShortcutBinding.modifier(forKeyCode: holdBinding.keyCode),
           bindingModifier == manualModifier {
            return "That modifier is already the hold shortcut."
        }
        if !toggleBinding.isDisabled,
           toggleBinding.kind == .modifierKey,
           let bindingModifier = ShortcutBinding.modifier(forKeyCode: toggleBinding.keyCode),
           bindingModifier == manualModifier {
            return "That modifier is already the tap shortcut."
        }
        if !copyAgainBinding.isDisabled,
           copyAgainBinding.kind == .modifierKey,
           let bindingModifier = ShortcutBinding.modifier(forKeyCode: copyAgainBinding.keyCode),
           bindingModifier == manualModifier {
            return "That modifier is already the Paste Again shortcut."
        }

        return nil
    }

    func startHotkeyMonitoring() {
        shouldMonitorHotkeys = true
        hotkeyManager.onShortcutEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.handleShortcutEvent(event)
            }
        }
        hotkeyManager.onRecordingCancelShortcut = { [weak self] in
            guard let self else { return false }
            let shouldHandle = Thread.isMainThread
                ? self.shouldConfirmEscapeCancellation
                : DispatchQueue.main.sync {
                    self.shouldConfirmEscapeCancellation
                }
            guard shouldHandle else { return false }
            DispatchQueue.main.async {
                _ = self.handleEscapeKeyPress()
            }
            return true
        }
        hotkeyManager.onCopyAgainShortcut = { [weak self] in
            guard let self else { return false }
            if Thread.isMainThread {
                return MainActor.assumeIsolated {
                    self.copyLastTranscriptToPasteboard()
                }
            }
            return DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    self.copyLastTranscriptToPasteboard()
                }
            }
        }
        restartHotkeyMonitoring()
    }

    func stopHotkeyMonitoring() {
        shouldMonitorHotkeys = false
        hotkeyMonitoringErrorMessage = nil
        hotkeyManager.onShortcutEvent = nil
        hotkeyManager.onRecordingCancelShortcut = nil
        hotkeyManager.onCopyAgainShortcut = nil
        hotkeyManager.stop()
    }

    func suspendHotkeyMonitoringForShortcutCapture() {
        isCapturingShortcut = true
        restartHotkeyMonitoring()
    }

    func resumeHotkeyMonitoringAfterShortcutCapture() {
        isCapturingShortcut = false
        restartHotkeyMonitoring()
    }

    private var permittedAdditionalExactMatchModifiersForShortcutMatching: ShortcutModifiers {
        if isCommandModeEnabled, commandModeStyle == .manual {
            return commandModeManualModifier.shortcutModifier
        }
        return []
    }

    private var activeShortcutConfiguration: ShortcutConfiguration {
        ShortcutConfiguration(
            hold: holdShortcut,
            toggle: toggleShortcut,
            recordingCancel: recordingCancelShortcut,
            copyAgain: copyAgainShortcut,
            permittedAdditionalExactMatchModifiers: permittedAdditionalExactMatchModifiersForShortcutMatching
        )
    }

    private func restartHotkeyMonitoring() {
        guard shouldMonitorHotkeys, !isCapturingShortcut, !isAwaitingMicrophonePermission, !isAwaitingSpeechRecognitionPermission else {
            hotkeyManager.stop()
            return
        }

        do {
            try hotkeyManager.start(configuration: activeShortcutConfiguration)
            hotkeyMonitoringErrorMessage = nil
        } catch {
            hotkeyMonitoringErrorMessage = error.localizedDescription
            os_log(.error, log: recordingLog, "Hotkey monitoring failed to start: %{public}@", error.localizedDescription)
        }
    }

    @MainActor
    private func handleShortcutEvent(_ event: ShortcutEvent) {
        guard let action = shortcutSessionController.handle(event: event, isTranscribing: isTranscribing) else {
            return
        }

        switch action {
        case .start(let mode):
            os_log(.info, log: recordingLog, "Shortcut start fired for mode %{public}@", mode.rawValue)
            scheduleShortcutStart(mode: mode)
        case .stop:
            cancelPendingShortcutStart()
            guard isRecording else {
                shortcutSessionController.reset()
                activeRecordingTriggerMode = nil
                return
            }
            stopAndTranscribe()
        case .switchedToToggle:
            if isRecording {
                activeRecordingTriggerMode = .toggle
                overlayManager.setRecordingTriggerMode(.toggle, animated: true)
            } else if pendingShortcutStartMode != nil {
                pendingShortcutStartMode = .toggle
            }
        }
    }

    @MainActor
    private func handleEscapeKeyPress() -> Bool {
        guard shouldConfirmEscapeCancellation else { return false }
        presentEscapeCancellationAlert()
        return true
    }

    @MainActor
    @discardableResult
    func copyLastTranscriptToPasteboard() -> Bool {
        guard !lastTranscript.isEmpty else { return false }
        let pendingClipboardRestore = writeTranscriptToPasteboard(lastTranscript)
        pasteAtCursorWhenShortcutReleased { [weak self] in
            self?.restoreClipboardIfNeeded(pendingClipboardRestore)
        }
        return true
    }

    @MainActor
    func toggleRecording() {
        os_log(.info, log: recordingLog, "toggleRecording() called, isRecording=%{public}d", isRecording)
        cancelPendingShortcutStart()
        if isRecording {
            stopAndTranscribe()
        } else {
            shortcutSessionController.beginManual(mode: .toggle)
            startRecording(triggerMode: .toggle)
        }
    }

    // MCP public interface
    @MainActor
    func startRecordingFromMCP() {
        lastTranscript = ""
        mcpLastRecordingFailed = false
        shortcutSessionController.beginManual(mode: .toggle)
        startRecording(triggerMode: .toggle)
    }

    @MainActor
    func startRecordingFromCalendarReminder(_ action: CalendarRecordingReminderNotificationAction) {
        beginCalendarReminderRecording { [weak self] in
            self?.calendarRecordingReminderScheduler.markReminderHandledExternally(
                identifier: action.identifier,
                reminderGroupIdentifier: action.reminderGroupIdentifier
            )
        }
    }

    @MainActor
    func startRecordingFromCalendarReminder() {
        beginCalendarReminderRecording()
    }

    @MainActor
    private func beginCalendarReminderRecording(onStarted: (@MainActor () -> Void)? = nil) {
        guard !isRecording else { return }
        lastTranscript = ""
        shortcutSessionController.beginManual(mode: .toggle)
        startRecording(triggerMode: .toggle, onStarted: onStarted)
    }

    @MainActor
    func stopRecordingFromMCP() {
        guard isRecording else { return }
        stopAndTranscribe()
    }

    @MainActor
    private func handleOverlayStopButtonPressed() {
        guard isRecording, activeRecordingTriggerMode == .toggle else { return }
        stopAndTranscribe()
    }

    @MainActor
    func requestTerminationWhileRecording() -> NSApplication.TerminateReply {
        guard shouldConfirmTermination else { return .terminateNow }
        guard !isEscapeCancelAlertPresented else { return .terminateCancel }

        let alert = NSAlert()
        alert.messageText = localizedCatalogString("Quit while recording?")
        alert.informativeText = localizedCatalogString("Quill will stop the current recording, finish transcription, and quit when transcription is complete.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: localizedCatalogString("Stop Recording and Quit"))
        alert.addButton(withTitle: localizedCatalogString("Cancel"))
        alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)

        isEscapeCancelAlertPresented = true
        let response = alert.runModal()
        isEscapeCancelAlertPresented = false

        guard response == .alertFirstButtonReturn else { return .terminateCancel }
        shouldTerminateAfterTranscription = true

        if isRecording {
            stopAndTranscribe()
        } else {
            terminateIfReady()
        }

        return .terminateLater
    }

    private var shouldConfirmEscapeCancellation: Bool {
        guard !isEscapeCancelAlertPresented else { return false }
        if isRecording || isTranscribing {
            return true
        }
        return pendingShortcutStartMode == .toggle || activeRecordingTriggerMode == .toggle
    }

    private var shouldConfirmTermination: Bool {
        isRecording || isTranscribing || pendingShortcutStartMode == .toggle || activeRecordingTriggerMode == .toggle
    }

    @MainActor
    private func terminateIfReady() {
        guard shouldTerminateAfterTranscription, !isRecording, !isTranscribing else { return }
        shouldTerminateAfterTranscription = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    @MainActor
    private func presentEscapeCancellationAlert() {
        guard !isEscapeCancelAlertPresented else { return }
        isEscapeCancelAlertPresented = true

        let alert = NSAlert()
        alert.messageText = localizedCatalogString("Cancel current recording?")
        alert.informativeText = localizedCatalogString("Press Cancel to keep recording, or Stop Recording to discard the current recording session.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: localizedCatalogString("Stop Recording"))
        alert.addButton(withTitle: localizedCatalogString("Cancel"))
        alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)

        let response = alert.runModal()
        isEscapeCancelAlertPresented = false

        guard response == .alertFirstButtonReturn else { return }

        if isTranscribing {
            cancelTranscription()
            return
        }

        if isRecording || pendingShortcutStartMode == .toggle || activeRecordingTriggerMode == .toggle {
            cancelToggleShortcutSession()
        }
    }

    @MainActor
    private func cancelToggleShortcutSession() {
        guard pendingShortcutStartMode == .toggle || activeRecordingTriggerMode == .toggle else { return }

        cancelPendingShortcutStart()
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        clearAudioRecorderCallbacks()
        liveTranscriber?.cancel()
        liveTranscriber = nil
        if let id = currentRecordingLiveNoteID {
            currentRecordingLiveNoteID = nil
            pipelineHistory.removeAll { $0.id == id }
            if let deletedAssets = try? pipelineHistoryStore.delete(id: id) {
                Self.deleteStoredFiles(deletedAssets)
            }
        }
        if let job = foregroundTranscriptionJob(), let id = job.liveNoteID {
            updateTranscriptionJob(job.id) { $0.liveNoteID = nil }
            pipelineHistory.removeAll { $0.id == id }
            if let deletedAssets = try? pipelineHistoryStore.delete(id: id) {
                Self.deleteStoredFiles(deletedAssets)
            }
        }
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        cancelRecordingInitializationTimer()
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        capturedContext = nil
        activeRecordingStartedAt = nil
        activeRecordingCalendarSnapshot = nil
        currentSessionIntent = .dictation
        isRecording = false
        errorMessage = nil
        debugStatusMessage = "Cancelled"
        let cancelledStatus = localizedCatalogString("Cancelled")
        statusText = cancelledStatus
        dismissTranscribingOverlay()
        tearDownRealtimeService()
        cancelActiveAudioRecorder()
        discardRecordingSegments()
        restoreAudioInterruptionIfNeeded()
        syncCriticalDictationActivity()
        refreshAvailableMicrophonesIfNeeded()
        if !isRecording && !isTranscribing && statusText == cancelledStatus {
            scheduleReadyStatusReset(after: 2, matching: [cancelledStatus])
        }
    }

    @MainActor
    private func cancelTranscription() {
        guard let job = foregroundTranscriptionJob() else { return }

        job.task?.cancel()
        transcribingIndicatorTask?.cancel()
        transcribingIndicatorTask = nil
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        currentSessionIntent = .dictation
        isRecording = false
        errorMessage = nil
        debugStatusMessage = "Cancelled"
        let cancelledStatus = localizedCatalogString("Cancelled")
        statusText = cancelledStatus
        dismissTranscribingOverlay()
        cleanupActiveAudioRecordersIfIdle()
        if let audioFileName = job.audioFileName {
            Self.deleteAudioFile(audioFileName)
        }
        if let liveNoteID = job.liveNoteID {
            pipelineHistory.removeAll { $0.id == liveNoteID }
            if let deletedAssets = try? pipelineHistoryStore.delete(id: liveNoteID) {
                Self.deleteStoredFiles(deletedAssets)
            }
        }
        finishTranscriptionJob(job.id)
        refreshAvailableMicrophonesIfNeeded()
        if !isRecording && !isTranscribing && statusText == cancelledStatus {
            scheduleReadyStatusReset(after: 2, matching: [cancelledStatus])
        }
    }

    @MainActor
    private func scheduleShortcutStart(mode: RecordingTriggerMode) {
        cancelPendingShortcutStart(resetMode: false)
        pendingManualCommandInvocation = hotkeyManager.currentPressedModifiers.contains(
            commandModeManualModifier.shortcutModifier
        )
        pendingShortcutStartMode = mode
        let delay = shortcutStartDelay

        guard delay > 0 else {
            pendingShortcutStartMode = nil
            startRecording(triggerMode: mode)
            return
        }

        pendingSelectionSnapshotTask = Task.detached(priority: .userInitiated) { [contextService] in
            contextService.collectSelectionSnapshot()
        }

        pendingShortcutStartTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }

            await MainActor.run { [weak self] in
                guard let self, let pendingMode = self.pendingShortcutStartMode else { return }
                self.pendingShortcutStartTask = nil
                self.pendingShortcutStartMode = nil
                self.startRecording(triggerMode: pendingMode)
            }
        }
    }

    private func cancelPendingShortcutStart(resetMode: Bool = true) {
        pendingShortcutStartTask?.cancel()
        pendingShortcutStartTask = nil
        pendingSelectionSnapshotTask?.cancel()
        pendingSelectionSnapshotTask = nil
        pendingSelectionSnapshot = nil
        pendingManualCommandInvocation = false
        if resetMode {
            pendingShortcutStartMode = nil
        }
    }

    private func resolveSessionIntent(
        triggerMode: RecordingTriggerMode,
        selectionSnapshot: AppSelectionSnapshot,
        manualCommandRequested: Bool
    ) -> SessionIntent? {
        guard isCommandModeEnabled else {
            return .dictation
        }

        let rawSelectedText = selectionSnapshot.selectedText ?? ""
        let trimmedSelectedText = rawSelectedText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch commandModeStyle {
        case .automatic:
            if !trimmedSelectedText.isEmpty {
                return .command(invocation: .automatic, selectedText: rawSelectedText)
            }
            return .dictation
        case .manual:
            // If the binding IS the manual modifier, the "modifier pressed"
            // signal is the binding's own press. Fall back to plain dictation.
            let activeBinding: ShortcutBinding = (triggerMode == .toggle) ? toggleShortcut : holdShortcut
            if activeBinding.kind == .modifierKey,
               let bindingModifier = ShortcutBinding.modifier(forKeyCode: activeBinding.keyCode),
               bindingModifier == commandModeManualModifier.shortcutModifier {
                return .dictation
            }
            if let message = commandModeManualModifierCollisionMessage(for: commandModeManualModifier) {
                rejectInvalidCommandModeModifier(triggerMode: triggerMode, message: message)
                return nil
            }
            guard manualCommandRequested else {
                return .dictation
            }
            guard !trimmedSelectedText.isEmpty else {
                rejectCommandModeSelectionRequirement(triggerMode: triggerMode)
                return nil
            }
            return .command(invocation: .manual, selectedText: rawSelectedText)
        }
    }

    private func rejectCommandModeSelectionRequirement(triggerMode: RecordingTriggerMode) {
        currentSessionIntent = .dictation
        activeRecordingTriggerMode = nil
        pendingSelectionSnapshot = nil
        pendingManualCommandInvocation = false
        errorMessage = localizedCatalogString("Select text to transform first.")
        statusText = localizedCatalogString("Select text to transform first")
        debugStatusMessage = "Edit mode requires selected text"
        shortcutSessionController.reset()
        if triggerMode == .toggle {
            cancelPendingShortcutStart()
        }
        playAlertSound(named: "Basso")
        scheduleReadyStatusReset(after: 2, matching: [localizedCatalogString("Select text to transform first")])
    }

    private func rejectInvalidCommandModeModifier(triggerMode: RecordingTriggerMode, message: String) {
        currentSessionIntent = .dictation
        activeRecordingTriggerMode = nil
        pendingSelectionSnapshot = nil
        pendingManualCommandInvocation = false
        errorMessage = message
        statusText = localizedCatalogString("Fix Edit Mode modifier")
        debugStatusMessage = "Edit mode modifier conflicts with dictation shortcuts"
        shortcutSessionController.reset()
        if triggerMode == .toggle {
            cancelPendingShortcutStart()
        }
        playAlertSound(named: "Basso")
        scheduleReadyStatusReset(after: 2, matching: [localizedCatalogString("Fix Edit Mode modifier")])
    }

    @MainActor
    private func startRecording(triggerMode: RecordingTriggerMode, onStarted: (@MainActor () -> Void)? = nil) {
        let t0 = CFAbsoluteTimeGetCurrent()
        os_log(.info, log: recordingLog, "startRecording() entered")
        guard !isRecording else { return }

        // 전사 중이면 기존 transcribing overlay/indicator를 정리하고 소유권만 넘긴다.
        if isTranscribing {
            dismissTranscribingOverlay(resetOverlayOwner: true)
            foregroundTranscriptionJobID = nil
        }

        let scheduledSelectionSnapshot = pendingSelectionSnapshot
        let scheduledSelectionSnapshotTask = pendingSelectionSnapshotTask
        let scheduledManualCommandInvocation = pendingManualCommandInvocation
        cancelPendingShortcutStart()

        Task { [weak self] in
            guard let self else { return }
            let manualCommandRequested = scheduledSelectionSnapshot != nil
                ? scheduledManualCommandInvocation
                : hotkeyManager.currentPressedModifiers.contains(commandModeManualModifier.shortcutModifier)
            guard await prepareRecordingStart(
                triggerMode: triggerMode,
                selectionSnapshot: scheduledSelectionSnapshot,
                selectionSnapshotTask: scheduledSelectionSnapshotTask,
                manualCommandRequested: manualCommandRequested,
                startedAt: t0
            ) else { return }
            let audioInputID = selectedMicrophoneID
            guard await ensureRecordingInputAccess(for: audioInputID) else { return }
            os_log(.info, log: recordingLog, "audio input access check passed: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            if AudioInputDevice.isMicrophoneOnly(audioInputID) {
                applyAudioInterruptionIfNeeded()
            }
            beginRecording(triggerMode: triggerMode, onStarted: onStarted)
            os_log(.info, log: recordingLog, "startRecording() finished: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
    }

    /// Whether the configured recording flow will actually exercise Accessibility.
    /// Auto-paste synthesizes a Cmd+V keystroke and command mode reads the
    /// frontmost app's selected text — both require AX. Pure dictation that only
    /// copies to the clipboard (auto-paste off, command mode off) does not, so
    /// MCP / Rec-button / calendar recordings can proceed without it.
    ///
    /// Note: the global hotkey's event tap also needs AX, but that is a separate
    /// concern — we intentionally don't gate on whether a shortcut is bound here.
    var requiresAccessibility: Bool {
        !disableAutoPaste || isCommandModeEnabled
    }

    @MainActor
    private func prepareRecordingStart(
        triggerMode: RecordingTriggerMode,
        selectionSnapshot: AppSelectionSnapshot? = nil,
        selectionSnapshotTask: Task<AppSelectionSnapshot, Never>? = nil,
        manualCommandRequested: Bool? = nil,
        startedAt: CFAbsoluteTime? = nil
    ) async -> Bool {
        activeRecordingTriggerMode = triggerMode
        let isAccessibilityTrusted = AXIsProcessTrusted()
        hasAccessibility = isAccessibilityTrusted
        guard isAccessibilityTrusted || !requiresAccessibility else {
            errorMessage = localizedCatalogString("Accessibility permission required. Grant access in System Settings > Privacy & Security > Accessibility.")
            statusText = localizedCatalogString("No Accessibility")
            activeRecordingTriggerMode = nil
            currentSessionIntent = .dictation
            shortcutSessionController.reset()
            openAccessibilitySettings()
            return false
        }
        if let startedAt {
            os_log(.info, log: recordingLog, "accessibility check passed: %.3fms", (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        }

        let resolvedSelectionSnapshot: AppSelectionSnapshot
        if let selectionSnapshot {
            resolvedSelectionSnapshot = selectionSnapshot
        } else if let selectionSnapshotTask {
            resolvedSelectionSnapshot = await selectionSnapshotTask.value
        } else {
            resolvedSelectionSnapshot = await Task.detached(priority: .userInitiated) { [contextService] in
                contextService.collectSelectionSnapshot()
            }.value
        }
        let manualCommandRequested = manualCommandRequested
            ?? hotkeyManager.currentPressedModifiers.contains(commandModeManualModifier.shortcutModifier)
        guard let resolvedIntent = resolveSessionIntent(
            triggerMode: triggerMode,
            selectionSnapshot: resolvedSelectionSnapshot,
            manualCommandRequested: manualCommandRequested
        ) else { return false }

        if resolvedIntent.isCommandMode {
            guard ensureScreenCaptureAccess() else { return false }
            if let startedAt {
                os_log(.info, log: recordingLog, "screen capture check passed: %.3fms", (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            }
        } else {
            hasScreenRecordingPermission = hasScreenCapturePermission()
        }

        currentSessionIntent = resolvedIntent
        overlayManager.setRecordingTriggerMode(triggerMode, animated: false)
        return true
    }

    static func currentSpeechRecognitionAuthorizationStatus() -> SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    var hasSpeechRecognitionPermission: Bool {
        speechRecognitionAuthorizationStatus == .authorized
    }

    @MainActor
    func refreshSpeechRecognitionAuthorizationStatus() {
        speechRecognitionAuthorizationStatus = Self.currentSpeechRecognitionAuthorizationStatus()
    }

    @MainActor
    func requestSpeechRecognitionAccess(completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.speechRecognitionAuthorizationStatus = status
                    completion?(status == .authorized)
                }
            }
        case .denied, .restricted:
            speechRecognitionAuthorizationStatus = status
            openPrivacySettingsPane("Privacy_SpeechRecognition")
            completion?(false)
        case .authorized:
            speechRecognitionAuthorizationStatus = status
            completion?(true)
        @unknown default:
            speechRecognitionAuthorizationStatus = status
            completion?(false)
        }
    }

    @MainActor
    func showSpeechRecognitionPermissionAlert() {

        let alert = NSAlert()
        alert.messageText = localizedCatalogString("Speech Recognition Permission Required")
        alert.informativeText = localizedCatalogString("Quill cannot use Apple Live transcription without Speech Recognition access.\n\nGo to System Settings > Privacy & Security > Speech Recognition and enable Quill.")
        alert.alertStyle = .critical
        alert.addButton(withTitle: localizedCatalogString("Open System Settings"))
        alert.addButton(withTitle: localizedCatalogString("Dismiss"))
        alert.icon = NSImage(systemSymbolName: "waveform.badge.mic", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openPrivacySettingsPane("Privacy_SpeechRecognition")
        }
    }

    @MainActor
    private func prepareForSpeechRecognitionPermissionPrompt(
        triggerMode: RecordingTriggerMode,
        selectionSnapshot: AppSelectionSnapshot?,
        manualCommandRequested: Bool?
    ) {
        isAwaitingSpeechRecognitionPermission = true
        pendingSpeechPermissionTriggerMode = triggerMode
        pendingSpeechPermissionSelectionSnapshot = selectionSnapshot
        pendingSpeechPermissionManualCommandRequested = manualCommandRequested
        hotkeyManager.stop()
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        cancelRecordingInitializationTimer()
        clearAudioRecorderCallbacks()
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        dismissTranscribingOverlay()
    }

    private func ensureScreenCaptureAccess() -> Bool {
        let granted = hasScreenCapturePermission()
        hasScreenRecordingPermission = granted
        guard granted else {
            let message = localizedCatalogString("Screen recording permission not granted. Enable in System Settings > Privacy & Security > Screen Recording.")
            errorMessage = message
            statusText = localizedCatalogString("Screenshot Required")
            activeRecordingTriggerMode = nil
            currentSessionIntent = .dictation
            shortcutSessionController.reset()
            playAlertSound(named: "Basso")
            showScreenshotPermissionAlert(message: localizedCatalogString("Screen Recording access was not granted."))
            return false
        }

        return true
    }

    @MainActor
    private func ensureRecordingInputAccess(for inputID: String) async -> Bool {
        if AudioInputDevice.isSystemDefaultAndSystemAudio(inputID) {
            return await ensureSystemDefaultAndSystemAudioAccess()
        }
        if AudioInputDevice.isSystemAudio(inputID) {
            return await ensureSystemAudioAccess()
        }
        return ensureMicrophoneAccess()
    }

    @MainActor
    private func ensureSystemDefaultAndSystemAudioAccess() async -> Bool {
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphoneStatus == .notDetermined {
            _ = ensureMicrophoneAccess()
            return false
        }

        let microphoneGranted = microphoneStatus == .authorized
        guard microphoneGranted else {
            hasScreenRecordingPermission = hasScreenCapturePermission()
            showSystemDefaultAndSystemAudioAccessError()
            return false
        }

        let systemGranted = await requestScreenCapturePermissionForRecordingStart()
        hasScreenRecordingPermission = systemGranted
        guard systemGranted else {
            showSystemDefaultAndSystemAudioAccessError()
            return false
        }

        return true
    }

    @MainActor
    private func showSystemDefaultAndSystemAudioAccessError() {
        let message = localizedCatalogString("System Default + System Audio recording needs Microphone and Screen & System Audio Recording access. Enable both in System Settings > Privacy & Security.")
        errorMessage = message
        statusText = localizedCatalogString("System Default + System Audio Required")
        activeRecordingTriggerMode = nil
        currentSessionIntent = .dictation
        shortcutSessionController.reset()
        playAlertSound(named: "Basso")
    }

    @MainActor
    private func ensureSystemAudioAccess() async -> Bool {
        let granted = await requestScreenCapturePermissionForRecordingStart()
        hasScreenRecordingPermission = granted
        guard granted else {
            let message = localizedCatalogString("System Audio recording permission not granted. Enable Screen & System Audio Recording in System Settings > Privacy & Security.")
            errorMessage = message
            statusText = localizedCatalogString("System Audio Required")
            activeRecordingTriggerMode = nil
            currentSessionIntent = .dictation
            shortcutSessionController.reset()
            playAlertSound(named: "Basso")
            showScreenshotPermissionAlert(message: localizedCatalogString("Screen Recording access was not granted."))
            return false
        }
        return true
    }

    @MainActor
    private func ensureMicrophoneAccess() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            guard let triggerMode = activeRecordingTriggerMode else {
                return false
            }

            prepareForMicrophonePermissionPrompt(
                triggerMode: triggerMode,
                selectionSnapshot: pendingSelectionSnapshot ?? contextService.collectSelectionSnapshot(),
                manualCommandRequested: currentSessionIntent.isManualCommand
            )
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let strongSelf = self else { return }
                    let pendingTriggerMode = strongSelf.pendingMicrophonePermissionTriggerMode
                    let pendingSelectionSnapshot = strongSelf.pendingMicrophonePermissionSelectionSnapshot
                    let pendingManualCommandRequested = strongSelf.pendingMicrophonePermissionManualCommandRequested
                    strongSelf.pendingMicrophonePermissionTriggerMode = nil
                    strongSelf.pendingMicrophonePermissionSelectionSnapshot = nil
                    strongSelf.pendingMicrophonePermissionManualCommandRequested = nil
                    strongSelf.isAwaitingMicrophonePermission = false
                    strongSelf.restartHotkeyMonitoring()

                    guard let triggerMode = pendingTriggerMode else { return }
                    if granted {
                        strongSelf.errorMessage = nil
                        if triggerMode == .toggle {
                            Task { [weak strongSelf] in
                                guard let strongSelf else { return }
                                guard await strongSelf.prepareRecordingStart(
                                    triggerMode: .toggle,
                                    selectionSnapshot: pendingSelectionSnapshot,
                                    manualCommandRequested: pendingManualCommandRequested
                                ) else { return }
                                let audioInputID = strongSelf.selectedMicrophoneID
                                guard await strongSelf.ensureRecordingInputAccess(for: audioInputID) else { return }
                                strongSelf.shortcutSessionController.beginManual(mode: .toggle)
                                if AudioInputDevice.isMicrophoneOnly(audioInputID) {
                                    strongSelf.applyAudioInterruptionIfNeeded()
                                }
                                strongSelf.beginRecording(triggerMode: .toggle)
                            }
                        } else {
                            strongSelf.currentSessionIntent = .dictation
                            strongSelf.statusText = localizedCatalogString("Microphone access granted. Press and hold again to record.")
                            strongSelf.scheduleReadyStatusReset(
                                after: 2,
                                matching: [localizedCatalogString("Microphone access granted. Press and hold again to record.")]
                            )
                        }
                    } else {
                        strongSelf.errorMessage = localizedCatalogString("Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone.")
                        strongSelf.statusText = localizedCatalogString("No Microphone")
                        strongSelf.activeRecordingTriggerMode = nil
                        strongSelf.currentSessionIntent = .dictation
                        strongSelf.shortcutSessionController.reset()
                        strongSelf.showMicrophonePermissionAlert()
                    }
                }
            }
            return false
        default:
            errorMessage = localizedCatalogString("Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone.")
            statusText = localizedCatalogString("No Microphone")
            activeRecordingTriggerMode = nil
            currentSessionIntent = .dictation
            shortcutSessionController.reset()
            showMicrophonePermissionAlert()
            return false
        }
    }

    @MainActor
    private func prepareForMicrophonePermissionPrompt(
        triggerMode: RecordingTriggerMode,
        selectionSnapshot: AppSelectionSnapshot?,
        manualCommandRequested: Bool?
    ) {
        isAwaitingMicrophonePermission = true
        pendingMicrophonePermissionTriggerMode = triggerMode
        pendingMicrophonePermissionSelectionSnapshot = selectionSnapshot
        pendingMicrophonePermissionManualCommandRequested = manualCommandRequested
        hotkeyManager.stop()
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        cancelRecordingInitializationTimer()
        clearAudioRecorderCallbacks()
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        dismissTranscribingOverlay()
    }

    private func applyAudioInterruptionIfNeeded() {
        guard dictationAudioInterruptionEnabled, activeAudioInterruption == nil else { return }

        let wasMuted = SystemAudioStatus.isDefaultOutputMuted()
        if wasMuted {
            activeAudioInterruption = .muted(previouslyMuted: true)
        } else if SystemAudioStatus.setDefaultOutputMuted(true) {
            UserDefaults.standard.set(true, forKey: pendingMutedAudioRestoreStorageKey)
            activeAudioInterruption = .muted(previouslyMuted: false)
        }
    }

    private func restoreAudioInterruptionIfNeeded() {
        guard let activeAudioInterruption else { return }
        self.activeAudioInterruption = nil

        switch activeAudioInterruption {
        case .muted(let previouslyMuted):
            if !previouslyMuted {
                _ = SystemAudioStatus.setDefaultOutputMuted(false)
                UserDefaults.standard.removeObject(forKey: pendingMutedAudioRestoreStorageKey)
            }
        }
    }

    @MainActor
    private func markRecordingStarted(_ date: Date) {
        guard isRecording, activeRecordingTriggerMode != nil else { return }
        activeRecordingStartedAt = date
        overlayManager.setRecordingStartedAt(date)
    }

    @MainActor
    private func beginRecording(triggerMode: RecordingTriggerMode, onStarted: (@MainActor () -> Void)? = nil) {
        os_log(.info, log: recordingLog, "beginRecording() entered")
        clearPendingOverlayDismissToken()
        errorMessage = nil
        let audioInputID = selectedMicrophoneID
        activeRecordingID = AudioInputDevice.isMicrophoneOnly(audioInputID)
            ? UUID()
            : nil
        let supportsLiveTranscription = !AudioInputDevice.isSystemDefaultAndSystemAudio(audioInputID)

        if supportsLiveTranscription && useLocalTranscription && localTranscriptionModel.isAppleSpeech {
            refreshSpeechRecognitionAuthorizationStatus()
            switch speechRecognitionAuthorizationStatus {
            case .authorized:
                break
            case .notDetermined:
                guard let triggerMode = activeRecordingTriggerMode else { return }
                prepareForSpeechRecognitionPermissionPrompt(
                    triggerMode: triggerMode,
                    selectionSnapshot: pendingSelectionSnapshot,
                    manualCommandRequested: currentSessionIntent.isManualCommand
                )
                requestSpeechRecognitionAccess { [weak self] granted in
                    guard let self else { return }
                    let pendingTriggerMode = self.pendingSpeechPermissionTriggerMode
                    let pendingSelectionSnapshot = self.pendingSpeechPermissionSelectionSnapshot
                    let pendingManualCommandRequested = self.pendingSpeechPermissionManualCommandRequested
                    self.pendingSpeechPermissionTriggerMode = nil
                    self.pendingSpeechPermissionSelectionSnapshot = nil
                    self.pendingSpeechPermissionManualCommandRequested = nil
                    self.isAwaitingSpeechRecognitionPermission = false
                    self.restartHotkeyMonitoring()

                    guard let resumedTriggerMode = pendingTriggerMode else { return }
                    if granted {
                        self.errorMessage = nil
                        if resumedTriggerMode == .toggle {
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                guard await self.prepareRecordingStart(
                                    triggerMode: .toggle,
                                    selectionSnapshot: pendingSelectionSnapshot,
                                    manualCommandRequested: pendingManualCommandRequested
                                ) else { return }
                                let audioInputID = self.selectedMicrophoneID
                                self.shortcutSessionController.beginManual(mode: .toggle)
                                if AudioInputDevice.isMicrophoneOnly(audioInputID) {
                                    self.applyAudioInterruptionIfNeeded()
                                }
                                self.beginRecording(triggerMode: .toggle, onStarted: onStarted)
                            }
                        } else {
                            self.currentSessionIntent = .dictation
                            self.restoreAudioInterruptionIfNeeded()
                            self.statusText = localizedCatalogString("Speech Recognition access granted. Press and hold again to record.")
                            self.scheduleReadyStatusReset(
                                after: 2,
                                matching: [localizedCatalogString("Speech Recognition access granted. Press and hold again to record.")]
                            )
                        }
                    } else {
                        self.restoreAudioInterruptionIfNeeded()
                        self.errorMessage = localizedCatalogString("Speech Recognition permission is required for Apple Live transcription. Enable it in System Settings > Privacy & Security > Speech Recognition.")
                        self.statusText = localizedCatalogString("No Speech Recognition")
                        self.activeRecordingTriggerMode = nil
                        self.currentSessionIntent = .dictation
                        self.shortcutSessionController.reset()
                        self.showSpeechRecognitionPermissionAlert()
                    }
                }
                return
            default:
                isRecording = false
                syncCriticalDictationActivity()
                restoreAudioInterruptionIfNeeded()
                activeRecordingTriggerMode = nil
                currentSessionIntent = .dictation
                shortcutSessionController.reset()
                errorMessage = localizedCatalogString("Speech Recognition permission is required for Apple Live transcription. Enable it in System Settings > Privacy & Security > Speech Recognition.")
                statusText = localizedCatalogString("No Speech Recognition")
                showSpeechRecognitionPermissionAlert()
                return
            }
        }

        isRecording = true
        syncCriticalDictationActivity()
        meetingReminderOverlayManager.refreshVisibleReminder()
        statusText = localizedCatalogString("Starting...")
        hasShownScreenshotPermissionAlert = false

        // Show initializing dots only if engine takes longer than 0.2s to start
        var overlayShown = false
        cancelRecordingInitializationTimer()
        let initTimer = DispatchSource.makeTimerSource(queue: .main)
        recordingInitializationTimer = initTimer
        initTimer.schedule(deadline: .now() + 0.2)
        initTimer.setEventHandler { [weak self] in
            guard let self, !overlayShown else { return }
            overlayShown = true
            os_log(.info, log: recordingLog, "engine slow — showing initializing overlay")
            self.clearPendingOverlayDismissToken()
            self.overlayManager.showInitializing(
                mode: self.activeRecordingTriggerMode ?? triggerMode,
                isCommandMode: self.currentSessionIntent.isCommandMode
            )
            self.meetingReminderOverlayManager.refreshVisibleReminder()
        }
        initTimer.resume()

        activeAudioInputID = audioInputID
        discardRecordingSegments()
        refreshOverlayInputOptions()
        overlayManager.setRecordingStartedAt(nil)
        configureSelectedAudioRecorderCallbacks(
            inputID: audioInputID,
            onReady: { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.cancelRecordingInitializationTimer()
                    os_log(.info, log: recordingLog, "first real audio — transitioning to waveform")
                    self.statusText = localizedCatalogString("Recording...")
                    self.clearPendingOverlayDismissToken()
                    if overlayShown {
                        self.overlayManager.transitionToRecording(
                            mode: self.activeRecordingTriggerMode ?? triggerMode,
                            isCommandMode: self.currentSessionIntent.isCommandMode
                        )
                    } else {
                        self.overlayManager.showRecording(
                            mode: self.activeRecordingTriggerMode ?? triggerMode,
                            isCommandMode: self.currentSessionIntent.isCommandMode
                        )
                    }
                    self.meetingReminderOverlayManager.refreshVisibleReminder()
                    overlayShown = true
                    self.playAlertSound(named: "Tink")
                }
            },
            onFailure: { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.cancelRecordingInitializationTimer()
                    self.handleRecordingFailure(error)
                }
            }
        )

        if supportsLiveTranscription {
            startRealtimeStreamingIfEnabled()
        }

        // Start engine on background thread so UI isn't blocked
        if supportsLiveTranscription, useLocalTranscription, let transcriber = localTranscriptionModel.makeLiveTranscriber() {
            // Live transcription: initialize before recording starts so the request is ready
            // to receive buffers from the very first sample
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await transcriber.start(locale: transcriptionLanguage.sfSpeechLocale)
                    self.liveTranscriber = transcriber
                    if !transcriber.handlesRecording {
                        self.setActiveRecorderPCMHandler { [weak transcriber] data in
                            transcriber?.appendPCM16(data)
                        }
                    }

                    transcriber.onAudioLevel = { [weak self] level in
                        Task { @MainActor [weak self] in
                            self?.overlayManager.updateAudioLevel(level)
                        }
                    }

                    // 녹음 시작 전 예비 노트를 생성해 Note Browser에 즉시 표시
                    let liveID = self.activeRecordingID ?? UUID()
                    self.activeRecordingID = liveID
                    self.currentRecordingLiveNoteID = liveID
                    transcriber.onPartialResult = { [weak self] text in
                        Task { @MainActor [weak self] in
                            self?.updateLiveNoteTranscript(noteID: liveID, text)
                        }
                    }
                    await MainActor.run {
                        self.createLiveNote(jobID: liveID, noteID: liveID)
                    }

                    let t0 = CFAbsoluteTimeGetCurrent()
                    if transcriber.handlesRecording {
                        // AVAudioEngine이 transcriber.start()에서 이미 시작됨 — 녹음 UI만 트리거
                        let actualRecordingStartedAt = Date()
                        await MainActor.run {
                            self.markRecordingStarted(actualRecordingStartedAt)
                            if self.isRecording, self.activeRecordingTriggerMode != nil {
                                onStarted?()
                            }
                        }
                        self.audioRecorder.onRecordingReady?()
                    } else {
                        try await self.startSelectedAudioRecorder(inputID: audioInputID)
                        let actualRecordingStartedAt = Date()
                        await MainActor.run {
                            self.markRecordingStarted(actualRecordingStartedAt)
                            if self.isRecording, self.activeRecordingTriggerMode != nil {
                                onStarted?()
                            }
                        }
                        os_log(.info, log: recordingLog, "selected audio recorder start done: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    }
                    await MainActor.run {
                        guard self.isRecording, self.activeRecordingTriggerMode != nil else { return }
                        self.startContextCapture()
                        if !transcriber.handlesRecording {
                            self.audioLevelCancellable = self.activeRecorderAudioLevelPublisher(inputID: audioInputID)
                                .receive(on: DispatchQueue.main)
                                .sink { [weak self] level in
                                    self?.overlayManager.updateAudioLevel(level)
                                }
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.cancelRecordingInitializationTimer()
                        guard self.isRecording || self.activeRecordingTriggerMode != nil else { return }
                        self.handleRecordingFailure(error)
                    }
                }
            }
        } else {
            Task { [weak self] in
                guard let self else { return }
                let t0 = CFAbsoluteTimeGetCurrent()
                do {
                    try await self.startSelectedAudioRecorder(inputID: audioInputID)
                    let actualRecordingStartedAt = Date()
                    os_log(.info, log: recordingLog, "selected audio recorder start done: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    await MainActor.run {
                        self.markRecordingStarted(actualRecordingStartedAt)
                        guard self.isRecording, self.activeRecordingTriggerMode != nil else { return }
                        onStarted?()
                        self.startContextCapture()
                        self.audioLevelCancellable = self.activeRecorderAudioLevelPublisher(inputID: audioInputID)
                            .receive(on: DispatchQueue.main)
                            .sink { [weak self] level in
                                self?.overlayManager.updateAudioLevel(level)
                            }
                    }
                } catch {
                    await MainActor.run {
                        self.cancelRecordingInitializationTimer()
                        guard self.isRecording || self.activeRecordingTriggerMode != nil else { return }
                        self.handleRecordingFailure(error)
                    }
                }
            }
        }
    }

    @MainActor
    private func handleRecordingFailure(_ error: Error) {
        cancelRecordingInitializationTimer()
        preserveActiveMicrophoneJournalForRecovery()
        clearAudioRecorderCallbacks()
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        capturedContext = nil
        activeRecordingStartedAt = nil
        activeRecordingCalendarSnapshot = nil
        if let liveNoteID = currentRecordingLiveNoteID {
            currentRecordingLiveNoteID = nil
            pipelineHistory.removeAll { $0.id == liveNoteID }
            if let deletedAssets = try? pipelineHistoryStore.delete(id: liveNoteID) {
                Self.deleteStoredFiles(deletedAssets)
            }
        }
        tearDownRealtimeService()
        restoreAudioInterruptionIfNeeded()
        isRecording = false
        cleanupActiveAudioRecordersIfIdle()
        syncCriticalDictationActivity()
        transcribingIndicatorTask?.cancel()
        transcribingIndicatorTask = nil
        refreshTranscribingState()
        activeRecordingTriggerMode = nil
        currentSessionIntent = .dictation
        shortcutSessionController.reset()
        errorMessage = formattedRecordingStartError(error)
        statusText = localizedCatalogString("Error")
        dismissTranscribingOverlay()
        refreshAvailableMicrophonesIfNeeded()
    }

    private func formattedRecordingStartError(_ error: Error) -> String {
        if let recorderError = error as? AudioRecorderError {
            return LocalizedUserMessage.providerFailure(prefix: localizedCatalogString("Failed to start recording"), providerDetail: recorderError.localizedDescription)
        }

        let lower = error.localizedDescription.lowercased()
        if lower.contains("operation couldn't be completed") || lower.contains("operation could not be completed") {
            return localizedCatalogString("Failed to start recording: Audio input error. Verify microphone access is granted and a working mic is selected in System Settings > Sound > Input.")
        }

        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain {
            return String(format: localizedCatalogString("Failed to start recording (audio subsystem error %@). Check microphone permissions and selected input device."), String(nsError.code))
        }

        return LocalizedUserMessage.providerFailure(prefix: localizedCatalogString("Failed to start recording"), providerDetail: error.localizedDescription)
    }

    /// Turn a transcription failure into a concise, user-facing message,
    /// classifying by the locale-independent `URLError.Code` rather than the
    /// system's English description (which varies across releases and locales).
    private func formattedTranscriptionError(_ error: Error) -> String {
        if let code = Self.urlErrorCode(in: error) {
            switch code {
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return localizedCatalogString("No internet — check connection")
            case .timedOut:
                return NetworkMonitor.shared.isOnline
                    ? localizedCatalogString("Request timed out — try again")
                    : localizedCatalogString("No internet — check connection")
            default:
                break
            }
        }

        let lower = error.localizedDescription.lowercased()
        if lower.contains("timed out") || lower.contains("timeout") {
            return NetworkMonitor.shared.isOnline
                ? localizedCatalogString("Request timed out — try again")
                : localizedCatalogString("No internet — check connection")
        }
        if lower.contains("offline") || lower.contains("internet connection")
            || lower.contains("not connected") || lower.contains("network")
            || lower.contains("cannot find host") {
            return localizedCatalogString("No internet — check connection")
        }
        return error.localizedDescription
    }

    /// Find a `URLError.Code` anywhere in the error's underlying-error chain,
    /// so a wrapped transport error is still classified by its root cause.
    private static func urlErrorCode(in error: Error) -> URLError.Code? {
        var current: Error? = error
        var depth = 0
        while let err = current, depth < 8 {
            if let urlError = err as? URLError {
                return urlError.code
            }
            let nsError = err as NSError
            if nsError.domain == NSURLErrorDomain {
                return URLError.Code(rawValue: nsError.code)
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? Error
            depth += 1
        }
        return nil
    }

    func showMicrophonePermissionAlert() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.showMicrophonePermissionAlert()
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = localizedCatalogString("Microphone Permission Required")
        alert.informativeText = localizedCatalogString("Quill cannot record audio without Microphone access.\n\nGo to System Settings > Privacy & Security > Microphone and enable Quill.")
        alert.alertStyle = .critical
        alert.addButton(withTitle: localizedCatalogString("Open System Settings"))
        alert.addButton(withTitle: localizedCatalogString("Dismiss"))
        alert.icon = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openMicrophoneSettings()
        }
    }


    private func precomputeMacros() {
        precomputedMacros = voiceMacros.map { macro in
            PrecomputedMacro(
                original: macro,
                normalizedCommand: normalize(macro.command)
            )
        }
    }

    private func normalize(_ text: String) -> String {
        let lowercased = text.lowercased()
        let strippedPunctuation = lowercased.components(separatedBy: CharacterSet.punctuationCharacters).joined()
        return strippedPunctuation.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseTranscriptCommands(
        from transcript: String,
        pressEnterCommandEnabled: Bool
    ) -> TranscriptCommandParsingResult {
        guard pressEnterCommandEnabled else {
            return TranscriptCommandParsingResult(
                transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                shouldPressEnterAfterPaste: false
            )
        }

        let fullRange = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        guard
            let match = trailingPressEnterCommandPattern.firstMatch(in: transcript, range: fullRange),
            let commandRange = Range(match.range, in: transcript)
        else {
            return TranscriptCommandParsingResult(
                transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                shouldPressEnterAfterPaste: false
            )
        }

        var strippedTranscript = transcript
        strippedTranscript.removeSubrange(commandRange)

        return TranscriptCommandParsingResult(
            transcript: strippedTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
            shouldPressEnterAfterPaste: true
        )
    }

    private static func statusMessage(
        for outcome: TranscriptProcessingOutcome,
        parsedTranscript: TranscriptCommandParsingResult,
        isRetry: Bool = false
    ) -> String {
        let status = outcome.statusMessage(isRetry: isRetry)
        guard parsedTranscript.shouldPressEnterAfterPaste else { return status }
        return "\(status); detected press enter command"
    }

    func playAlertSound(named name: String) {
        guard alertSoundsEnabled else { return }

        let sound = NSSound(named: name)
        sound?.volume = soundVolume
        sound?.play()
    }

    private func findMatchingMacro(for transcript: String) -> VoiceMacro? {
        let normalizedTranscript = normalize(transcript)
        guard !normalizedTranscript.isEmpty else { return nil }

        return precomputedMacros.first {
            normalizedTranscript == $0.normalizedCommand
        }?.original
    }

    private enum TranscriptProcessingOutcome {
        case skippedEmptyRawTranscript
        case voiceMacro(command: String)
        case postProcessingDisabled
        case preservedExactWording
        case preservedExactWordingTranslated
        case preservedExactWordingTranslationFailedFallback
        case postProcessingSucceeded
        case postProcessingSkippedCooldown
        case postProcessingFailedFallback
        case commandModeSucceeded(invocation: CommandInvocation)
        case commandModeSkippedCooldown(invocation: CommandInvocation)
        case commandModeFailedFallback(invocation: CommandInvocation)

        func statusMessage(isRetry: Bool = false) -> String {
            switch self {
            case .skippedEmptyRawTranscript:
                return "Skipped macros and post-processing for empty raw transcript"
            case .voiceMacro(let command):
                return "Voice macro used: \(command)"
            case .postProcessingDisabled:
                return "Post-processing disabled"
            case .preservedExactWording:
                return "Preserved exact wording, skipped cleanup"
            case .preservedExactWordingTranslated:
                return "Preserved exact wording, translated to output language"
            case .preservedExactWordingTranslationFailedFallback:
                return "Literal translation failed, using raw transcript"
            case .postProcessingSucceeded:
                return isRetry ? "Post-processing succeeded (retried)" : "Post-processing succeeded"
            case .postProcessingSkippedCooldown:
                return "Post-processing skipped while configured models cool down"
            case .postProcessingFailedFallback:
                return isRetry
                    ? "Post-processing failed on retry, using raw transcript"
                    : "Post-processing failed, using raw transcript"
            case .commandModeSucceeded(let invocation):
                return "Edit mode succeeded (\(invocation.rawValue))"
            case .commandModeSkippedCooldown(let invocation):
                return "Edit mode skipped while configured models cool down (\(invocation.rawValue))"
            case .commandModeFailedFallback(let invocation):
                return "Edit mode failed, using selected text (\(invocation.rawValue))"
            }
        }
    }

    private func processTranscript(
        _ rawTranscript: String,
        intent: SessionIntent,
        context: AppContext,
        postProcessingService: PostProcessingService,
        customVocabulary: String,
        customSystemPrompt: String,
        outputLanguage: String,
        postProcessingEnabled: Bool,
        preserveExactWording: Bool
    ) async -> (finalTranscript: String, outcome: TranscriptProcessingOutcome, prompt: String) {
        let trimmedRawTranscript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedRawTranscript.isEmpty else {
            return ("", .skippedEmptyRawTranscript, "")
        }

        if case .command(let invocation, let selectedText) = intent {
            do {
                let result = try await postProcessingService.commandTransform(
                    selectedText: selectedText,
                    voiceCommand: rawTranscript,
                    context: context,
                    customVocabulary: customVocabulary,
                    outputLanguage: outputLanguage
                )
                let outcome: TranscriptProcessingOutcome = result.skippedDueToCooldown
                    ? .commandModeSkippedCooldown(invocation: invocation)
                    : .commandModeSucceeded(invocation: invocation)
                return (result.transcript, outcome, result.prompt)
            } catch {
                os_log(.error, log: recordingLog, "Edit mode failed: %{public}@", error.localizedDescription)
                return (selectedText, .commandModeFailedFallback(invocation: invocation), "")
            }
        }

        if let macro = findMatchingMacro(for: trimmedRawTranscript) {
            os_log(.info, log: recordingLog, "Voice macro triggered: %{public}@", macro.command)
            return (macro.payload, .voiceMacro(command: macro.command), "")
        }

        if !postProcessingEnabled {
            return (rawTranscript, .postProcessingDisabled, "")
        }

        if preserveExactWording {
            let targetLanguage = outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !targetLanguage.isEmpty else {
                return (trimmedRawTranscript, .preservedExactWording, "")
            }
            do {
                let result = try await postProcessingService.translateVerbatim(
                    transcript: trimmedRawTranscript,
                    targetLanguage: targetLanguage
                )
                let outcome: TranscriptProcessingOutcome = result.skippedDueToCooldown
                    ? .postProcessingSkippedCooldown
                    : .preservedExactWordingTranslated
                return (result.transcript, outcome, result.prompt)
            } catch {
                os_log(.error, log: recordingLog, "Literal translation failed: %{public}@", error.localizedDescription)
                return (trimmedRawTranscript, .preservedExactWordingTranslationFailedFallback, "")
            }
        }

        do {
            let result = try await postProcessingService.postProcess(
                transcript: trimmedRawTranscript,
                context: context,
                customVocabulary: customVocabulary,
                customSystemPrompt: customSystemPrompt,
                outputLanguage: outputLanguage
            )
            let outcome: TranscriptProcessingOutcome = result.skippedDueToCooldown
                ? .postProcessingSkippedCooldown
                : .postProcessingSucceeded
            return (result.transcript, outcome, result.prompt)
        } catch {
            os_log(.error, log: recordingLog, "Post-processing failed: %{public}@", error.localizedDescription)
            return (trimmedRawTranscript, .postProcessingFailedFallback, "")
        }
    }

    /// Await the realtime WebSocket's final transcript. If it errors out (or
    /// was never started) fall back to the file-based POST so the user still
    /// gets a transcript. Runs the realtime commit and file upload in that
    /// strict order to avoid paying for both when realtime succeeds.
    private static func resolveRawTranscript(
        realtimeService: RealtimeTranscriptionService?,
        fileService: TranscriptionService,
        fileURL: URL
    ) async throws -> String {
        if let realtimeService {
            do {
                try Task.checkCancellation()
                return try await withTaskCancellationHandler {
                    try await realtimeService.commitAndAwaitFinal()
                } onCancel: {
                    realtimeService.cancel()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                return try await fileService.transcribe(fileURL: fileURL)
            }
        }
        return try await fileService.transcribe(fileURL: fileURL)
    }

    private func resolveStoppedRecordingContext(
        sessionContext: AppContext?,
        inFlightContextTask: Task<AppContext?, Never>?
    ) async -> AppContext {
        if let sessionContext {
            return sessionContext
        }
        if let inFlightContext = await inFlightContextTask?.value {
            return inFlightContext
        }
        return fallbackContextAtStop()
    }

    @MainActor
    private func bootstrapLastTranscriptForPasteAgain(_ transcript: String, pressEnterCommandEnabled: Bool) {
        let parsedTranscript = Self.parseTranscriptCommands(
            from: transcript,
            pressEnterCommandEnabled: pressEnterCommandEnabled
        )
        let bootstrapTranscript = parsedTranscript.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bootstrapTranscript.isEmpty else { return }
        lastTranscript = bootstrapTranscript
    }

    private func makeStoppedTranscriptionCompletionSummary(
        rawTranscript: String,
        intent: SessionIntent,
        context: AppContext,
        postProcessingService: PostProcessingService,
        customVocabulary: String,
        customSystemPrompt: String,
        outputLanguage: String,
        postProcessingEnabled: Bool,
        preserveExactWording: Bool,
        pressEnterCommandEnabled: Bool
    ) async throws -> StoppedTranscriptionCompletionSummary {
        let parsedTranscript = Self.parseTranscriptCommands(
            from: rawTranscript,
            pressEnterCommandEnabled: pressEnterCommandEnabled
        )
        try Task.checkCancellation()
        await MainActor.run { [weak self] in
            self?.debugStatusMessage = "Running post-processing"
        }
        let result = await processTranscript(
            parsedTranscript.transcript,
            intent: intent,
            context: context,
            postProcessingService: postProcessingService,
            customVocabulary: customVocabulary,
            customSystemPrompt: customSystemPrompt,
            outputLanguage: outputLanguage,
            postProcessingEnabled: postProcessingEnabled,
            preserveExactWording: preserveExactWording
        )
        try Task.checkCancellation()
        let processingStatus = Self.statusMessage(
            for: result.outcome,
            parsedTranscript: parsedTranscript
        )
        let outcomeWasPostProcessingFailedFallback: Bool
        switch result.outcome {
        case .postProcessingFailedFallback, .preservedExactWordingTranslationFailedFallback:
            outcomeWasPostProcessingFailedFallback = true
        default:
            outcomeWasPostProcessingFailedFallback = false
        }
        return StoppedTranscriptionCompletionSummary(
            rawTranscript: parsedTranscript.transcript,
            finalTranscript: result.finalTranscript,
            prompt: result.prompt,
            processingStatus: processingStatus,
            shouldPressEnterAfterPaste: parsedTranscript.shouldPressEnterAfterPaste,
            outcomeWasPostProcessingFailedFallback: outcomeWasPostProcessingFailedFallback
        )
    }

    private func runSuccessfulStoppedTranscriptionCompletionPipeline(
        jobID: UUID,
        overlayID: UUID,
        completion: StoppedTranscriptionCompletionSummary,
        context: AppContext,
        intent: SessionIntent,
        audioFileName: String?,
        settings: StoppedTranscriptionSettingsSnapshot
    ) async throws {
        try Task.checkCancellation()
        let calendarMatch = await calendarMatchForHistoryItem(jobID: jobID)
        try Task.checkCancellation()
        try await MainActor.run {
            try Task.checkCancellation()
            recordPipelineHistoryEntry(
                jobID: jobID,
                rawTranscript: completion.rawTranscript,
                postProcessedTranscript: completion.finalTranscript,
                postProcessingPrompt: completion.prompt,
                systemPrompt: Self.resolvedSystemPrompt(settings.customSystemPrompt),
                context: context,
                processingStatus: completion.processingStatus,
                intent: intent,
                audioFileName: audioFileName,
                useLocalTranscriptionOverride: settings.useLocalTranscription,
                localTranscriptionModelIDOverride: settings.localTranscriptionModel.id,
                usedContextCaptureOverride: settings.usedContextCapture,
                usedPostProcessingOverride: settings.usedPostProcessing,
                transcriptionLanguageCodeOverride: settings.transcriptionLanguage.code,
                customVocabularyOverride: settings.customVocabulary,
                customSystemPromptOverride: settings.customSystemPrompt,
                calendarMatch: calendarMatch
            )
            if audioFileName.map(Self.isProtectedRecordingJournalAudioFile) == true {
                discardRecordingJournalAfterSuccessfulTranscription(
                    recordingID: jobID
                )
            }
            cleanupActiveAudioRecordersIfIdle()
            let completionStatusText = disableAutoPaste || !preserveClipboard ? "Copied to clipboard!" : "Pasted at cursor!"
            updateForegroundUIForStoppedTranscriptionCompletion(
                overlayID: overlayID,
                completion: completion,
                context: context,
                completionStatusText: completionStatusText,
                enterOnlyStatusText: "Pressed Enter"
            )
            finishTranscriptionJob(jobID, overlayID: overlayID)
        }
    }

    @MainActor
    private func updateForegroundUIForStoppedTranscriptionCompletion(
        overlayID: UUID,
        completion: StoppedTranscriptionCompletionSummary,
        context: AppContext,
        completionStatusText: String,
        enterOnlyStatusText: String
    ) {
        guard overlayTranscriptionID == overlayID else { return }
        lastContextSummary = context.contextSummary
        lastContextScreenshotDataURL = context.screenshotDataURL
        lastContextScreenshotStatus = context.screenshotError
            ?? "available (\(context.screenshotMimeType ?? "image"))"
        lastContextAppName = context.appName ?? ""
        lastContextBundleIdentifier = context.bundleIdentifier ?? ""
        lastContextWindowTitle = context.windowTitle ?? ""
        lastContextSelectedText = context.selectedText ?? ""
        lastContextLLMPrompt = context.contextPrompt ?? ""
        lastPostProcessingPrompt = completion.prompt
        lastRawTranscript = completion.rawTranscript
        lastPostProcessedTranscript = completion.finalTranscript
        lastPostProcessingStatus = completion.processingStatus
        lastTranscript = completion.finalTranscript
        debugStatusMessage = "Done"
        statusText = completionStatusText
        if completion.finalTranscript.isEmpty {
            mcpLastRecordingFailed = true
            statusText = completion.shouldPressEnterAfterPaste ? enterOnlyStatusText : "Nothing to transcribe"
            dismissTranscribingOverlay()
            if completion.shouldPressEnterAfterPaste {
                pressEnterWhenShortcutReleased()
            }
        } else {
            if completion.shouldPersistRawDictationFallback {
                scheduleOverlayDismissAfterFailureIndicator(after: 2.5)
            } else {
                dismissTranscribingOverlay()
            }
            let pendingClipboardRestore = writeTranscriptToPasteboard(completion.finalTranscript)
            if !disableAutoPaste {
                pasteAtCursorWhenShortcutReleased {
                    if completion.shouldPressEnterAfterPaste {
                        self.pressEnterAfterPaste {
                            self.restoreClipboardIfNeeded(pendingClipboardRestore)
                        }
                    } else {
                        self.restoreClipboardIfNeeded(pendingClipboardRestore)
                    }
                }
            }
        }
        scheduleReadyStatusReset(after: 3, matching: [completionStatusText, "Nothing to transcribe", enterOnlyStatusText])
    }

    @MainActor
    private func finishTranscriptionJob(_ id: UUID, overlayID: UUID) {
        finishTranscriptionJob(id)
        if overlayTranscriptionID == overlayID {
            cancelTranscribingIndicatorTask()
        }
    }

    @MainActor
    private func stopAndTranscribe() {
        cancelPendingShortcutStart()
        cancelRecordingInitializationTimer()
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        let sessionIntent = currentSessionIntent
        currentSessionIntent = .dictation
        clearAudioRecorderCallbacks()
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        let sessionContext = capturedContext
        let inFlightContextTask = contextCaptureTask
        let jobID = currentRecordingLiveNoteID ?? activeRecordingID ?? UUID()
        let liveNoteID = currentRecordingLiveNoteID
        currentRecordingLiveNoteID = nil
        let recordingStartedAt = activeRecordingStartedAt
        let recordingEndedAt = Date()
        activeRecordingStartedAt = nil
        activeRecordingCalendarSnapshot = nil
        let startedAt = recordingEndedAt
        registerTranscriptionJob(
            id: jobID,
            startedAt: startedAt,
            sessionIntent: sessionIntent,
            sessionContext: sessionContext,
            contextTask: inFlightContextTask,
            recordingStartedAt: recordingStartedAt,
            recordingEndedAt: recordingEndedAt,
            isImportedAudio: false
        )
        updateTranscriptionJob(jobID) { $0.liveNoteID = liveNoteID }
        capturedContext = nil
        contextCaptureTask = nil
        lastRawTranscript = ""
        lastPostProcessedTranscript = ""
        lastContextSummary = ""
        lastPostProcessingStatus = ""
        lastPostProcessingPrompt = ""
        lastContextScreenshotDataURL = nil
        lastContextScreenshotStatus = "No screenshot"
        let myOverlayID = UUID()
        overlayTranscriptionID = myOverlayID
        isRecording = false
        restoreAudioInterruptionIfNeeded()
        refreshTranscribingState()
        statusText = localizedCatalogString("Preparing audio...")
        errorMessage = nil
        playAlertSound(named: "Pop")
        overlayManager.showTranscribing()

        let postProcessingService = PostProcessingService(
            apiKey: apiKey,
            baseURL: apiBaseURL,
            preferredModel: postProcessingModel,
            preferredFallbackModel: postProcessingFallbackModel,
            instructionExecutionGuardEnabled: instructionExecutionGuardEnabled
        )
        let capturedApiKey = resolvedTranscriptionAPIKey
        let capturedApiBaseURL = resolvedTranscriptionBaseURL
        let capturedUseLocalTranscription = useLocalTranscription
        let capturedLocalWhisperPath = localWhisperPath
        let capturedUseLegacyMlxWhisper = useLegacyMlxWhisper
        let capturedTranscriptionLanguage = transcriptionLanguage
        let capturedLocalTranscriptionModel = localTranscriptionModel
        let capturedTranscriptionModel = transcriptionModel
        let capturedCustomVocabulary = customVocabulary
        let capturedCustomSystemPrompt = customSystemPrompt
        let capturedOutputLanguage = outputLanguage
        let capturedSettings = StoppedTranscriptionSettingsSnapshot(
            customVocabulary: capturedCustomVocabulary,
            customSystemPrompt: capturedCustomSystemPrompt,
            useLocalTranscription: capturedUseLocalTranscription,
            localTranscriptionModel: capturedLocalTranscriptionModel,
            transcriptionLanguage: capturedTranscriptionLanguage,
            usedContextCapture: !disableContextCapture,
            usedPostProcessing: !disablePostProcessing,
            preserveExactWording: preserveExactWording
        )
        let capturedLiveTranscriber = liveTranscriber
        let capturedPressEnterCommandEnabled = isPressEnterVoiceCommandEnabled
        liveTranscriber = nil
        setActiveRecorderPCMHandler(nil)

        if let transcriber = capturedLiveTranscriber, transcriber.handlesRecording {
            if overlayTranscriptionID == myOverlayID {
                prepareTranscribingOverlay(for: myOverlayID, statusText: localizedCatalogString("Transcribing..."), debugStatus: "Transcribing audio")
            }
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    let rawTranscript = try await transcriber.finalize()
                    let savedAudioFile = transcriber.recordedAudioURL.flatMap { url -> SavedAudioFile? in
                        let saved = Self.saveAudioFile(from: url)
                        try? FileManager.default.removeItem(at: url)
                        return saved
                    }
                    await MainActor.run {
                        self.updateTranscriptionJob(jobID) { $0.audioFileName = savedAudioFile?.fileName }
                    }
                    try Task.checkCancellation()
                    await MainActor.run {
                        self.bootstrapLastTranscriptForPasteAgain(rawTranscript, pressEnterCommandEnabled: capturedPressEnterCommandEnabled)
                    }
                    let appContext = await self.resolveStoppedRecordingContext(
                        sessionContext: sessionContext,
                        inFlightContextTask: inFlightContextTask
                    )
                    let completion = try await self.makeStoppedTranscriptionCompletionSummary(
                        rawTranscript: rawTranscript,
                        intent: sessionIntent,
                        context: appContext,
                        postProcessingService: postProcessingService,
                        customVocabulary: capturedCustomVocabulary,
                        customSystemPrompt: capturedCustomSystemPrompt,
                        outputLanguage: capturedOutputLanguage,
                        postProcessingEnabled: capturedSettings.usedPostProcessing,
                        preserveExactWording: capturedSettings.preserveExactWording,
                        pressEnterCommandEnabled: capturedPressEnterCommandEnabled
                    )
                    try await self.runSuccessfulStoppedTranscriptionCompletionPipeline(
                        jobID: jobID,
                        overlayID: myOverlayID,
                        completion: completion,
                        context: appContext,
                        intent: sessionIntent,
                        audioFileName: savedAudioFile?.fileName,
                        settings: capturedSettings
                    )
                } catch is CancellationError {
                    await MainActor.run {
                        self.finishTranscriptionJob(jobID, overlayID: myOverlayID)
                    }
                } catch {
                    let resolvedContext = await self.resolveStoppedRecordingContext(
                        sessionContext: sessionContext,
                        inFlightContextTask: inFlightContextTask
                    )
                    let errorAudioFile = transcriber.recordedAudioURL.flatMap { url -> SavedAudioFile? in
                        let saved = Self.saveAudioFile(from: url)
                        try? FileManager.default.removeItem(at: url)
                        return saved
                    }
                    let calendarMatch = await self.calendarMatchForHistoryItem(jobID: jobID)
                    await MainActor.run {
                        self.updateTranscriptionJob(jobID) { $0.audioFileName = errorAudioFile?.fileName }
                        self.recordPipelineHistoryEntry(
                            jobID: jobID,
                            rawTranscript: "",
                            postProcessedTranscript: "",
                            postProcessingPrompt: "",
                            systemPrompt: Self.resolvedSystemPrompt(capturedSettings.customSystemPrompt),
                            context: resolvedContext,
                            processingStatus: "Error: \(error.localizedDescription)",
                            intent: sessionIntent,
                            audioFileName: errorAudioFile?.fileName,
                            useLocalTranscriptionOverride: capturedSettings.useLocalTranscription,
                            localTranscriptionModelIDOverride: capturedSettings.localTranscriptionModel.id,
                            usedContextCaptureOverride: capturedSettings.usedContextCapture,
                            usedPostProcessingOverride: capturedSettings.usedPostProcessing,
                            transcriptionLanguageCodeOverride: capturedSettings.transcriptionLanguage.code,
                            customVocabularyOverride: capturedSettings.customVocabulary,
                            customSystemPromptOverride: capturedSettings.customSystemPrompt,
                            calendarMatch: calendarMatch
                        )
                        self.cleanupActiveAudioRecordersIfIdle()
                        guard self.overlayTranscriptionID == myOverlayID else {
                            self.finishTranscriptionJob(jobID, overlayID: myOverlayID)
                            return
                        }
                        let userFacingErrorMessage = self.formattedTranscriptionError(error)
                        self.errorMessage = userFacingErrorMessage
                        self.statusText = localizedCatalogString("Error")
                        self.overlayManager.showError(userFacingErrorMessage)
                        self.lastPostProcessedTranscript = ""
                        self.lastRawTranscript = ""
                        self.lastContextSummary = ""
                        self.lastPostProcessingStatus = "Error: \(error.localizedDescription)"
                        self.lastPostProcessingPrompt = ""
                        self.lastContextScreenshotDataURL = resolvedContext.screenshotDataURL
                        self.lastContextScreenshotStatus = resolvedContext.screenshotError
                            ?? "available (\(resolvedContext.screenshotMimeType ?? "image"))"
                        self.finishTranscriptionJob(jobID, overlayID: myOverlayID)
                    }
                }
            }
            updateTranscriptionJob(jobID) { $0.task = task }
            return
        }

        stopActiveAudioRecorder { [weak self] fileURL in
            guard let self else { return }
            guard let fileURL else {
                if self.overlayTranscriptionID == myOverlayID {
                    self.errorMessage = localizedCatalogString("No audio recorded")
                    self.statusText = localizedCatalogString("Error")
                    self.dismissTranscribingOverlay()
                }
                self.mcpLastRecordingFailed = true
                self.tearDownRealtimeService()
                self.cleanupActiveAudioRecordersIfIdle()
                self.finishTranscriptionJob(jobID)
                return
            }

            let recordingFileURL = self.stitchedRecordingURL(finalSegmentURL: fileURL)
            let savedAudioFile = Self.savedAudioFileForStoppedRecording(
                recordingFileURL
            )
            let transcriptionFileURL = savedAudioFile?.fileURL ?? recordingFileURL
            // Remove the stitched temp file once it has been copied to permanent
            // storage (only created when segments were stitched, i.e. a new path).
            if savedAudioFile != nil, recordingFileURL.path != fileURL.path {
                try? FileManager.default.removeItem(at: recordingFileURL)
            }
            if let savedAudioFile {
                let recoveryContext = sessionContext ?? self.fallbackContextAtStop()
                let activeJob = self.activeTranscriptionJobs[jobID]
                _ = self.createTranscriptionRecoveryPlaceholder(
                    jobID: jobID,
                    noteID: liveNoteID ?? jobID,
                    startedAt: startedAt,
                    sessionIntent: sessionIntent,
                    context: recoveryContext,
                    audioFileName: savedAudioFile.fileName,
                    useLocalTranscription: capturedUseLocalTranscription,
                    localTranscriptionModelID: capturedLocalTranscriptionModel.id,
                    transcriptionLanguageCode: capturedTranscriptionLanguage.code,
                    recordingStartedAt: activeJob?.recordingStartedAt,
                    recordingEndedAt: activeJob?.recordingEndedAt
                )
            } else {
                self.updateTranscriptionJob(jobID) { $0.audioFileName = nil }
            }
            let activeRealtime = self.realtimeService
            self.realtimeService = nil
            self.setActiveRecorderPCMHandler(nil)

            if self.overlayTranscriptionID == myOverlayID {
                self.prepareTranscribingOverlay(for: myOverlayID, statusText: "Transcribing...", debugStatus: "Transcribing audio")
            }

            let task = Task { [weak self] in
                guard let self else { return }
                defer { activeRealtime?.cancel() }
                do {
                    let rawTranscript: String
                    let liveResult = try await capturedLiveTranscriber?.finalize()
                    if let text = liveResult, !text.isEmpty {
                        rawTranscript = text
                    } else {
                        let transcriptionService = try TranscriptionService(
                            apiKey: capturedApiKey,
                            baseURL: capturedApiBaseURL,
                            useLocalTranscription: capturedUseLocalTranscription,
                            localWhisperPath: capturedLocalWhisperPath.isEmpty ? nil : capturedLocalWhisperPath,
                            useLegacyMlxWhisper: capturedUseLegacyMlxWhisper,
                            transcriptionLanguage: capturedTranscriptionLanguage,
                            localTranscriptionModel: capturedLocalTranscriptionModel,
                            transcriptionModel: capturedTranscriptionModel
                        )
                        rawTranscript = try await Self.resolveRawTranscript(
                            realtimeService: activeRealtime,
                            fileService: transcriptionService,
                            fileURL: transcriptionFileURL
                        )
                    }
                    try Task.checkCancellation()
                    await MainActor.run {
                        self.bootstrapLastTranscriptForPasteAgain(rawTranscript, pressEnterCommandEnabled: capturedPressEnterCommandEnabled)
                    }
                    let appContext = await self.resolveStoppedRecordingContext(
                        sessionContext: sessionContext,
                        inFlightContextTask: inFlightContextTask
                    )
                    let completion = try await self.makeStoppedTranscriptionCompletionSummary(
                        rawTranscript: rawTranscript,
                        intent: sessionIntent,
                        context: appContext,
                        postProcessingService: postProcessingService,
                        customVocabulary: capturedCustomVocabulary,
                        customSystemPrompt: capturedCustomSystemPrompt,
                        outputLanguage: capturedOutputLanguage,
                        postProcessingEnabled: capturedSettings.usedPostProcessing,
                        preserveExactWording: capturedSettings.preserveExactWording,
                        pressEnterCommandEnabled: capturedPressEnterCommandEnabled
                    )
                    try await self.runSuccessfulStoppedTranscriptionCompletionPipeline(
                        jobID: jobID,
                        overlayID: myOverlayID,
                        completion: completion,
                        context: appContext,
                        intent: sessionIntent,
                        audioFileName: savedAudioFile?.fileName,
                        settings: capturedSettings
                    )
                } catch is CancellationError {
                    await MainActor.run {
                        self.finishTranscriptionJob(jobID, overlayID: myOverlayID)
                    }
                } catch {
                    let resolvedContext = await self.resolveStoppedRecordingContext(
                        sessionContext: sessionContext,
                        inFlightContextTask: inFlightContextTask
                    )
                    let calendarMatch = await self.calendarMatchForHistoryItem(jobID: jobID)
                    await MainActor.run {
                        self.recordPipelineHistoryEntry(
                            jobID: jobID,
                            rawTranscript: "",
                            postProcessedTranscript: "",
                            postProcessingPrompt: "",
                            systemPrompt: Self.resolvedSystemPrompt(capturedSettings.customSystemPrompt),
                            context: resolvedContext,
                            processingStatus: "Error: \(error.localizedDescription)",
                            intent: sessionIntent,
                            audioFileName: savedAudioFile?.fileName,
                            useLocalTranscriptionOverride: capturedSettings.useLocalTranscription,
                            localTranscriptionModelIDOverride: capturedSettings.localTranscriptionModel.id,
                            usedContextCaptureOverride: capturedSettings.usedContextCapture,
                            usedPostProcessingOverride: capturedSettings.usedPostProcessing,
                            transcriptionLanguageCodeOverride: capturedSettings.transcriptionLanguage.code,
                            customVocabularyOverride: capturedSettings.customVocabulary,
                            customSystemPromptOverride: capturedSettings.customSystemPrompt,
                            calendarMatch: calendarMatch
                        )
                        self.cleanupActiveAudioRecordersIfIdle()
                        guard self.overlayTranscriptionID == myOverlayID else {
                            self.finishTranscriptionJob(jobID, overlayID: myOverlayID)
                            return
                        }
                        let userFacingErrorMessage = self.formattedTranscriptionError(error)
                        self.errorMessage = userFacingErrorMessage
                        self.statusText = localizedCatalogString("Error")
                        self.overlayManager.showError(userFacingErrorMessage)
                        self.lastPostProcessedTranscript = ""
                        self.lastRawTranscript = ""
                        self.lastContextSummary = ""
                        self.lastPostProcessingStatus = "Error: \(error.localizedDescription)"
                        self.lastPostProcessingPrompt = ""
                        self.lastContextScreenshotDataURL = resolvedContext.screenshotDataURL
                        self.lastContextScreenshotStatus = resolvedContext.screenshotError
                            ?? "available (\(resolvedContext.screenshotMimeType ?? "image"))"
                        self.finishTranscriptionJob(jobID, overlayID: myOverlayID)
                    }
                }
            }
            self.updateTranscriptionJob(jobID) { $0.task = task }
        }
    }

    // 라이브 전사 시작 시 Note Browser에 즉시 표시될 예비 노트 생성
    @MainActor
    private func createLiveNote(jobID: UUID, noteID: UUID) {
        updateTranscriptionJob(jobID) { $0.liveNoteID = noteID }
        let job = activeTranscriptionJobs[jobID]
        let entry = PipelineHistoryItem(
            id: noteID,
            timestamp: Date(),
            recordingStartedAt: job?.recordingStartedAt,
            recordingEndedAt: job?.recordingEndedAt,
            calendarMatch: nil,
            rawTranscript: "",
            postProcessedTranscript: "",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "",
            postProcessingStatus: "live-recording",
            debugStatus: "",
            customVocabulary: "",
            customSystemPrompt: customSystemPrompt,
            usedLocalTranscription: true,
            usedContextCapture: false,
            usedPostProcessing: false,
            transcriptionLanguageCode: transcriptionLanguage.code
        )
        do {
            let removed = try pipelineHistoryStore.append(entry, maxCount: maxPipelineHistoryCount)
            for removedAssets in removed {
                Self.deleteStoredFiles(removedAssets)
            }
            pipelineHistory = pipelineHistoryStore.loadAllHistory()
        } catch {
            updateTranscriptionJob(jobID) { $0.liveNoteID = nil }
        }
    }

    // 라이브 전사 partial 결과로 노트 텍스트 업데이트
    @MainActor
    private func updateLiveNoteTranscript(noteID: UUID, _ text: String) {
        guard let index = pipelineHistory.firstIndex(where: { $0.id == noteID }) else { return }
        let existing = pipelineHistory[index]
        let updated = PipelineHistoryItem(
            intent: existing.intent,
            selectedText: existing.selectedText,
            capturedSelection: existing.capturedSelection,
            id: existing.id,
            timestamp: existing.timestamp,
            recordingStartedAt: existing.recordingStartedAt,
            recordingEndedAt: existing.recordingEndedAt,
            calendarMatch: existing.calendarMatch,
            rawTranscript: existing.rawTranscript,
            postProcessedTranscript: text,
            postProcessingPrompt: existing.postProcessingPrompt,
            systemPrompt: existing.systemPrompt,
            contextSummary: existing.contextSummary,
            contextSystemPrompt: existing.contextSystemPrompt,
            contextPrompt: existing.contextPrompt,
            contextScreenshotDataURL: existing.contextScreenshotDataURL,
            contextScreenshotStatus: existing.contextScreenshotStatus,
            postProcessingStatus: "live-recording",
            debugStatus: existing.debugStatus,
            customVocabulary: existing.customVocabulary,
            customSystemPrompt: existing.customSystemPrompt,
            audioFileName: existing.audioFileName,
            usedLocalTranscription: existing.usedLocalTranscription,
            usedContextCapture: existing.usedContextCapture,
            usedPostProcessing: existing.usedPostProcessing,
            transcriptionLanguageCode: existing.transcriptionLanguageCode,
            localTranscriptionModelID: existing.localTranscriptionModelID,
            transcriptFileName: existing.transcriptFileName,
            contextAppName: existing.contextAppName,
            contextBundleIdentifier: existing.contextBundleIdentifier,
            contextWindowTitle: existing.contextWindowTitle,
            customTitle: existing.customTitle
        )
        // DB write 없이 메모리만 업데이트 — partial 결과는 최종 저장 시 반영됨
        pipelineHistory[index] = updated
    }

    static func resolvedSystemPrompt(_ customSystemPrompt: String) -> String {
        customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? PostProcessingService.defaultSystemPrompt
            : customSystemPrompt
    }

    @MainActor
    private func appendPipelineHistoryItem(_ item: PipelineHistoryItem) throws -> [DeletedPipelineHistoryAssets] {
        let removedStoredFiles = try pipelineHistoryStore.append(item, maxCount: maxPipelineHistoryCount)
        pipelineHistory.insert(item, at: 0)
        if pipelineHistory.count > maxPipelineHistoryCount {
            pipelineHistory.removeLast(pipelineHistory.count - maxPipelineHistoryCount)
        }
        return removedStoredFiles
    }

    @MainActor
    private func updatePipelineHistoryItem(_ item: PipelineHistoryItem) {
        if let index = pipelineHistory.firstIndex(where: { $0.id == item.id }) {
            pipelineHistory[index] = item
        } else {
            pipelineHistory.insert(item, at: 0)
            if pipelineHistory.count > maxPipelineHistoryCount {
                pipelineHistory.removeLast(pipelineHistory.count - maxPipelineHistoryCount)
            }
        }
    }

    @MainActor
    private func createTranscriptionRecoveryPlaceholder(
        jobID: UUID,
        noteID: UUID,
        startedAt: Date,
        sessionIntent: SessionIntent,
        context: AppContext,
        audioFileName: String,
        useLocalTranscription: Bool,
        localTranscriptionModelID: String,
        transcriptionLanguageCode: String,
        recordingStartedAt: Date?,
        recordingEndedAt: Date?
    ) -> Bool {
        let item = PipelineHistoryItem.transcriptionRecoveryPlaceholder(
            id: noteID,
            timestamp: startedAt,
            recordingStartedAt: recordingStartedAt,
            recordingEndedAt: recordingEndedAt,
            intent: sessionIntent.persistedIntent,
            selectedText: sessionIntent.persistedSelectedText,
            capturedSelection: context.selectedText,
            contextSummary: context.contextSummary,
            contextSystemPrompt: context.contextSystemPrompt,
            contextPrompt: context.contextPrompt,
            contextScreenshotDataURL: context.screenshotDataURL,
            contextScreenshotStatus: context.screenshotError ?? "available (\(context.screenshotMimeType ?? "image"))",
            systemPrompt: Self.resolvedSystemPrompt(customSystemPrompt),
            customVocabulary: customVocabulary,
            customSystemPrompt: customSystemPrompt,
            audioFileName: audioFileName,
            usedLocalTranscription: useLocalTranscription,
            usedContextCapture: !disableContextCapture,
            usedPostProcessing: !disablePostProcessing,
            transcriptionLanguageCode: transcriptionLanguageCode,
            localTranscriptionModelID: localTranscriptionModelID,
            contextAppName: context.appName,
            contextBundleIdentifier: context.bundleIdentifier,
            contextWindowTitle: context.windowTitle
        )
        do {
            let removedStoredFiles = try pipelineHistoryStore.upsert(
                item,
                maxCount: maxPipelineHistoryCount
            )
            for removedAssets in removedStoredFiles {
                Self.deleteStoredFiles(removedAssets)
            }
            updatePipelineHistoryItem(item)
            updateTranscriptionJob(jobID) {
                $0.liveNoteID = noteID
                $0.audioFileName = audioFileName
            }
            return true
        } catch {
            errorMessage = LocalizedUserMessage.providerFailure(prefix: localizedCatalogString("Unable to save recovery entry"), providerDetail: error.localizedDescription)
            return false
        }
    }

    private static func logTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func calendarMatchForHistoryItem(jobID: UUID) async -> CalendarEventMatch? {
        guard let job = await MainActor.run(body: { activeTranscriptionJobs[jobID] }) else {
            os_log(.info, log: calendarLog, "Calendar match skipped: missing transcription job %{public}@", jobID.uuidString)
            return nil
        }
        guard !job.isImportedAudio else {
            os_log(.info, log: calendarLog, "Calendar match skipped: imported audio job %{public}@", jobID.uuidString)
            return nil
        }
        guard let recordingStartedAt = job.recordingStartedAt,
              let recordingEndedAt = job.recordingEndedAt else {
            os_log(.info, log: calendarLog, "Calendar match skipped: missing recording interval for job %{public}@", jobID.uuidString)
            return nil
        }
        guard recordingEndedAt > recordingStartedAt else {
            os_log(
                .info,
                log: calendarLog,
                "Calendar match skipped: invalid recording interval for job %{public}@ start=%{public}@ end=%{public}@",
                jobID.uuidString,
                Self.logTimestamp(recordingStartedAt),
                Self.logTimestamp(recordingEndedAt)
            )
            return nil
        }
        let selectedCalendarIDs = await MainActor.run { googleCalendarConnection.selectedCalendarIDs }
        guard !selectedCalendarIDs.isEmpty else {
            os_log(
                .info,
                log: calendarLog,
                "Calendar match skipped: no selected calendars for job %{public}@ start=%{public}@ end=%{public}@",
                jobID.uuidString,
                Self.logTimestamp(recordingStartedAt),
                Self.logTimestamp(recordingEndedAt)
            )
            return nil
        }
        do {
            guard let token = try await validGoogleCalendarToken() else {
                os_log(.info, log: calendarLog, "Calendar match skipped: no valid Google Calendar token for job %{public}@", jobID.uuidString)
                await MainActor.run {
                    markGoogleCalendarNeedsReconnect(
                        feature: .recordingMatch,
                        message: localizedCatalogString("Google Calendar needs reconnecting. Calendar-based note titles may be unavailable.")
                    )
                }
                return nil
            }
            os_log(
                .info,
                log: calendarLog,
                "Calendar match fetch started: job=%{public}@ calendars=%d start=%{public}@ end=%{public}@",
                jobID.uuidString,
                selectedCalendarIDs.count,
                Self.logTimestamp(recordingStartedAt),
                Self.logTimestamp(recordingEndedAt)
            )
            let fetchResult = await Self.googleCalendarServiceFactory().fetchEventsWithDiagnostics(
                accessToken: token.accessToken,
                calendarIDs: Array(selectedCalendarIDs),
                timeMin: recordingStartedAt,
                timeMax: recordingEndedAt
            )
            if !fetchResult.failedCalendarIDs.isEmpty {
                await MainActor.run {
                    markGoogleCalendarTemporarilyUnavailable(
                        feature: .recordingMatch,
                        message: localizedCatalogString("Some Google calendars could not be refreshed. Calendar-based note titles may be incomplete.")
                    )
                }
                os_log(
                    .error,
                    log: calendarLog,
                    "Calendar match fetch had failures: job=%{public}@ failedCalendars=%{private}@ fetchedEvents=%d",
                    jobID.uuidString,
                    fetchResult.failedCalendarIDs.joined(separator: ","),
                    fetchResult.events.count
                )
            } else {
                await MainActor.run {
                    markGoogleCalendarHealthy(feature: .recordingMatch)
                }
                os_log(
                    .info,
                    log: calendarLog,
                    "Calendar match fetch succeeded: job=%{public}@ fetchedEvents=%d",
                    jobID.uuidString,
                    fetchResult.events.count
                )
            }
            guard let event = CalendarEventMatcher.bestMatch(
                recordingStartedAt: recordingStartedAt,
                recordingEndedAt: recordingEndedAt,
                events: fetchResult.events
            ) else {
                os_log(
                    .info,
                    log: calendarLog,
                    "Calendar match not found: job=%{public}@ fetchedEvents=%d failedCalendars=%d",
                    jobID.uuidString,
                    fetchResult.events.count,
                    fetchResult.failedCalendarIDs.count
                )
                return nil
            }
            os_log(
                .info,
                log: calendarLog,
                "Calendar match found: job=%{public}@ calendar=%{private}@ event=%{private}@ title=%{private}@ start=%{public}@ end=%{public}@",
                jobID.uuidString,
                event.calendarID,
                event.id,
                event.title,
                Self.logTimestamp(event.start),
                Self.logTimestamp(event.end)
            )
            return event.match(
                accountID: token.accountEmail,
                source: .overlapSuggestion,
                titleState: .suggested
            )
        } catch {
            os_log(
                .error,
                log: calendarLog,
                "Calendar match failed: job=%{public}@ error=%{public}@",
                jobID.uuidString,
                error.localizedDescription
            )
            await MainActor.run {
                if Self.isGoogleCalendarReconnectError(error) {
                    markGoogleCalendarNeedsReconnect(
                        feature: .recordingMatch,
                        message: localizedCatalogString("Google Calendar needs reconnecting. Calendar-based note titles may be unavailable.")
                    )
                } else {
                    markGoogleCalendarTemporarilyUnavailable(
                        feature: .recordingMatch,
                        message: localizedCatalogFormat("Unable to refresh Google Calendar for note titles: %@", error.localizedDescription)
                    )
                }
            }
            return nil
        }
    }

    @MainActor
    private func recordPipelineHistoryEntry(
        jobID: UUID,
        rawTranscript: String,
        postProcessedTranscript: String,
        postProcessingPrompt: String,
        systemPrompt: String,
        context: AppContext,
        processingStatus: String,
        intent: SessionIntent,
        audioFileName: String? = nil,
        useLocalTranscriptionOverride: Bool? = nil,
        localTranscriptionModelIDOverride: String? = nil,
        usedContextCaptureOverride: Bool? = nil,
        usedPostProcessingOverride: Bool? = nil,
        transcriptionLanguageCodeOverride: String? = nil,
        customVocabularyOverride: String? = nil,
        customSystemPromptOverride: String? = nil,
        calendarMatch: CalendarEventMatch? = nil
    ) {
        let existingID = activeTranscriptionJobs[jobID]?.liveNoteID
        let existingEntry = existingID.flatMap { id in
            pipelineHistory.first(where: { $0.id == id })
        }
        let previousTranscriptFileName = existingEntry?.transcriptFileName
        let transcriptFileName = Self.saveTranscriptFile(
            rawTranscript: rawTranscript,
            postProcessedTranscript: postProcessedTranscript
        )
        updateTranscriptionJob(jobID) {
            $0.liveNoteID = nil
            $0.audioFileName = audioFileName
        }
        let isJournalAudioFile = audioFileName.map(
            Self.isProtectedRecordingJournalAudioFile
        ) == true
        let entryID = existingID ?? (isJournalAudioFile ? jobID : UUID())
        let entry = PipelineHistoryItem(
            intent: intent.persistedIntent,
            selectedText: intent.persistedSelectedText,
            capturedSelection: context.selectedText,
            id: entryID,
            timestamp: existingEntry?.timestamp ?? activeTranscriptionJobs[jobID]?.startedAt ?? Date(),
            recordingStartedAt: activeTranscriptionJobs[jobID]?.recordingStartedAt ?? existingEntry?.recordingStartedAt,
            recordingEndedAt: activeTranscriptionJobs[jobID]?.recordingEndedAt ?? existingEntry?.recordingEndedAt,
            calendarMatch: calendarMatch ?? existingEntry?.calendarMatch,
            rawTranscript: rawTranscript,
            postProcessedTranscript: postProcessedTranscript,
            postProcessingPrompt: postProcessingPrompt,
            systemPrompt: systemPrompt,
            contextSummary: context.contextSummary,
            contextSystemPrompt: context.contextSystemPrompt,
            contextPrompt: context.contextPrompt,
            contextScreenshotDataURL: context.screenshotDataURL,
            contextScreenshotStatus: context.screenshotError
                ?? "available (\(context.screenshotMimeType ?? "image"))",
            postProcessingStatus: processingStatus,
            debugStatus: debugStatusMessage,
            customVocabulary: customVocabularyOverride ?? customVocabulary,
            customSystemPrompt: customSystemPromptOverride ?? customSystemPrompt,
            audioFileName: audioFileName,
            usedLocalTranscription: useLocalTranscriptionOverride ?? useLocalTranscription,
            usedContextCapture: usedContextCaptureOverride ?? !disableContextCapture,
            usedPostProcessing: usedPostProcessingOverride ?? !disablePostProcessing,
            transcriptionLanguageCode: transcriptionLanguageCodeOverride ?? transcriptionLanguage.code,
            localTranscriptionModelID: localTranscriptionModelIDOverride ?? localTranscriptionModel.id,
            transcriptFileName: transcriptFileName,
            contextAppName: context.appName,
            contextBundleIdentifier: context.bundleIdentifier,
            contextWindowTitle: context.windowTitle,
            customTitle: existingEntry?.customTitle
        )
        do {
            if existingID != nil {
                try pipelineHistoryStore.update(entry)
                if let previousTranscriptFileName,
                   previousTranscriptFileName != transcriptFileName {
                    Self.deleteTranscriptFile(previousTranscriptFileName)
                }
            } else {
                let removedStoredFiles = try appendPipelineHistoryItem(entry)
                for removedAssets in removedStoredFiles {
                    Self.deleteStoredFiles(removedAssets)
                }
            }
            updatePipelineHistoryItem(entry)
            if isJournalAudioFile {
                completePromotedRecordingJournal(recordingID: jobID)
            }
        } catch {
            if !isJournalAudioFile {
                Self.deleteStoredFiles(
                    audioFileName: audioFileName,
                    transcriptFileName: transcriptFileName
                )
            } else if let transcriptFileName {
                Self.deleteTranscriptFile(transcriptFileName)
            }
            errorMessage = LocalizedUserMessage.providerFailure(prefix: localizedCatalogString("Unable to save run history entry"), providerDetail: error.localizedDescription)
        }

        // MCP notification
        if !postProcessedTranscript.isEmpty, let callback = onTranscriptionCompleted {
            let context = mcpAdditionalContext
            mcpAdditionalContext = ""
            callback(postProcessedTranscript, context)
        }
    }

    private func startRealtimeStreamingIfEnabled() {
        guard realtimeStreamingEnabled, !useLocalTranscription else { return }
        let trimmedBase = resolvedTranscriptionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else {
            os_log(.info, log: recordingLog, "realtime streaming requested but base URL is empty — skipping")
            return
        }
        let model = realtimeStreamingModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = RealtimeTranscriptionService.Configuration(
            baseURL: trimmedBase,
            apiKey: resolvedTranscriptionAPIKey,
            model: model,
            language: nil
        )
        let service = RealtimeTranscriptionService(config: config)
        do {
            try service.start()
        } catch {
            os_log(.error, log: recordingLog, "failed to start realtime service: %{public}@", error.localizedDescription)
            return
        }
        realtimeService = service
        setActiveRecorderPCMHandler { [weak service] data in
            service?.appendPCM16(data)
        }
    }

    private func tearDownRealtimeService() {
        setActiveRecorderPCMHandler(nil)
        realtimeService?.cancel()
        realtimeService = nil
    }

    private func startContextCapture() {
        contextCaptureTask?.cancel()
        capturedContext = nil

        guard !disableContextCapture else {
            lastContextSummary = "Context capture disabled"
            lastPostProcessingStatus = "Context capture disabled"
            lastContextScreenshotDataURL = nil
            lastContextScreenshotStatus = "Disabled"
            return
        }

        lastContextSummary = "Collecting app context..."
        lastPostProcessingStatus = ""
        lastContextScreenshotDataURL = nil
        lastContextScreenshotStatus = "Collecting screenshot..."

        contextCaptureTask = Task { [weak self] in
            guard let self else { return nil }
            let context = await self.contextService.collectContext()
            await MainActor.run {
                self.capturedContext = context
                self.lastContextSummary = context.contextSummary
                self.lastContextScreenshotDataURL = context.screenshotDataURL
                self.lastContextScreenshotStatus = context.screenshotError
                    ?? "available (\(context.screenshotMimeType ?? "image"))"
                self.lastContextAppName = context.appName ?? ""
                self.lastContextBundleIdentifier = context.bundleIdentifier ?? ""
                self.lastContextWindowTitle = context.windowTitle ?? ""
                self.lastContextSelectedText = context.selectedText ?? ""
                self.lastContextLLMPrompt = context.contextPrompt ?? ""
                self.lastPostProcessingStatus = "App context captured"
                self.handleScreenshotCaptureIssue(context.screenshotError)
            }
            return context
        }
    }

    private func fallbackContextAtStop() -> AppContext {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let windowTitle = focusedWindowTitle(for: frontmostApp)
        return AppContext(
            appName: frontmostApp?.localizedName,
            bundleIdentifier: frontmostApp?.bundleIdentifier,
            windowTitle: windowTitle,
            selectedText: nil,
            currentActivity: "Could not refresh app context at stop time; using text-only post-processing.",
            contextSystemPrompt: resolvedContextSystemPrompt(),
            contextPrompt: nil,
            screenshotDataURL: nil,
            screenshotMimeType: nil,
            screenshotError: "No app context captured before stop"
        )
    }

    private func resolvedContextSystemPrompt() -> String {
        let trimmedPrompt = customContextPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPrompt.isEmpty ? AppContextService.defaultContextPrompt : trimmedPrompt
    }

    private func focusedWindowTitle(for app: NSRunningApplication?) -> String? {
        guard let app else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return focusedWindowTitle(from: appElement)
    }

    private func focusedWindowTitle(from appElement: AXUIElement) -> String? {
        guard let focusedWindow = accessibilityElement(from: appElement, attribute: kAXFocusedWindowAttribute as CFString) else {
            return nil
        }

        guard let windowTitle = accessibilityString(from: focusedWindow, attribute: kAXTitleAttribute as CFString) else {
            return nil
        }

        return trimmedText(windowTitle)
    }

    private func accessibilityElement(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(rawValue, to: AXUIElement.self)
    }

    private func accessibilityString(from element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let stringValue = value as? String else { return nil }
        return stringValue
    }

    private func trimmedText(_ value: String) -> String? {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return trimmed.isEmpty ? nil : trimmed
    }

    @MainActor
    private func handleScreenshotCaptureIssue(_ message: String?) {
        guard let message, !message.isEmpty else {
            hasShownScreenshotPermissionAlert = false
            return
        }

        os_log(.error, "Screenshot capture issue: %{public}@", message)

        if isScreenCapturePermissionError(message) && !hasShownScreenshotPermissionAlert {
            hasScreenRecordingPermission = false
            guard currentSessionIntent.isCommandMode else { return }
            errorMessage = message
            hasShownScreenshotPermissionAlert = true

            // Permission errors are fatal — preserve committed microphone audio for recovery.
            tearDownRealtimeService()
            preserveActiveMicrophoneJournalForRecovery()
            cancelActiveAudioRecorder()
            audioLevelCancellable?.cancel()
            audioLevelCancellable = nil
            contextCaptureTask?.cancel()
            contextCaptureTask = nil
            capturedContext = nil
            isRecording = false
            syncCriticalDictationActivity()
            restoreAudioInterruptionIfNeeded()
            shortcutSessionController.reset()
            activeRecordingTriggerMode = nil
            statusText = localizedCatalogString("Screenshot Required")
            dismissTranscribingOverlay()

            playAlertSound(named: "Basso")
            showScreenshotPermissionAlert(message: localizedCatalogString("Screen Recording access was not granted."))
        }
        // Non-permission errors (transient failures) — continue recording without context
    }

    private func isScreenCapturePermissionError(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("screen recording permission not granted")
            || lowered.contains("requires screen recording permission")
    }

    private func showScreenshotPermissionAlert(message: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.showScreenshotPermissionAlert(message: message)
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = localizedCatalogString("Screen Recording Permission Required")
        alert.informativeText = LocalizedUserMessage.screenRecordingPermission(detail: message)
        alert.alertStyle = .critical
        alert.addButton(withTitle: localizedCatalogString("Open System Settings"))
        alert.addButton(withTitle: localizedCatalogString("Dismiss"))
        alert.icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openScreenCaptureSettings()
        }
    }

    private func showScreenshotCaptureErrorAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = localizedCatalogString("Screenshot Capture Failed")
        alert.informativeText = LocalizedUserMessage.screenshotFailure(detail: message)
        alert.alertStyle = .critical
        alert.addButton(withTitle: localizedCatalogString("Dismiss"))
        alert.icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
        _ = alert.runModal()
    }

    @MainActor
    func toggleDebugOverlay() {
        if isDebugOverlayActive {
            stopDebugOverlay()
        } else {
            startDebugOverlay()
        }
    }

    private func startDebugOverlay() {
        isDebugOverlayActive = true
        clearPendingOverlayDismissToken()
        overlayManager.showRecording()

        // Simulate audio levels with a timer
        var phase: Double = 0.0
        debugOverlayTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            phase += 0.15
            // Generate a fake audio level that oscillates like speech
            let base = 0.3 + 0.2 * sin(phase)
            let noise = Float.random(in: -0.15...0.15)
            let level = min(max(Float(base) + noise, 0.0), 1.0)
            self.overlayManager.updateAudioLevel(level)
        }
    }

    @MainActor
    private func stopDebugOverlay() {
        debugOverlayTimer?.invalidate()
        debugOverlayTimer = nil
        isDebugOverlayActive = false
        clearPendingOverlayDismissToken()
        dismissTranscribingOverlay()
    }

    private func clearPendingOverlayDismissToken() {
        pendingOverlayDismissToken = nil
    }

    @MainActor
    private func showPostTranscriptionUpdateReminderIfNeeded() -> Bool {
        if debugShowsUpdateReminderAfterDictation {
            showDebugUpdateAvailableOverlay()
            return true
        }

        let updateManager = UpdateManager.shared
        guard updateManager.shouldShowPostTranscriptionReminder() else { return false }

        let dismissToken = UUID()
        pendingOverlayDismissToken = dismissToken
        updateManager.markPostTranscriptionReminderShown()
        overlayManager.showUpdateAvailable(version: updateManager.latestReleaseVersion)

        DispatchQueue.main.asyncAfter(deadline: .now() + postTranscriptionUpdateReminderDuration) { [weak self] in
            guard let self, self.pendingOverlayDismissToken == dismissToken else { return }
            self.pendingOverlayDismissToken = nil
            self.overlayManager.dismiss()
        }

        return true
    }

    @MainActor
    func showDebugUpdateAvailableOverlay() {
        let updateManager = UpdateManager.shared
        let version = updateManager.latestReleaseVersion.isEmpty ? "9.9.9" : updateManager.latestReleaseVersion
        let dismissToken = UUID()
        if isDebugOverlayActive || debugOverlayTimer != nil {
            stopDebugOverlay()
        }
        pendingOverlayDismissToken = dismissToken
        overlayManager.showUpdateAvailable(version: version)

        DispatchQueue.main.asyncAfter(deadline: .now() + postTranscriptionUpdateReminderDuration) { [weak self] in
            guard let self, self.pendingOverlayDismissToken == dismissToken else { return }
            self.pendingOverlayDismissToken = nil
            self.overlayManager.dismiss()
        }
    }

    @MainActor
    func showDebugMeetingReminderOverlay() {
        let now = Date()
        let event = GoogleCalendarEvent(
            id: "debug-meeting-reminder-\(UUID().uuidString)",
            calendarID: "primary",
            title: "Team Standup",
            start: now.addingTimeInterval(600),
            end: now.addingTimeInterval(1_800),
            isAllDay: false,
            attendees: []
        )
        let schedule = CalendarRecordingReminderSchedule(
            identifier: "debug-meeting-reminder:\(UUID().uuidString)",
            fireDate: now,
            event: event,
            delivery: .immediate
        )
        Task { [weak self] in
            _ = await self?.meetingReminderOverlayManager.presentCalendarRecordingReminder(schedule) { _ in }
        }
    }

    @MainActor
    private func handleUpdateOverlayPressed() {
        clearPendingOverlayDismissToken()
        overlayManager.dismiss()
        selectedSettingsTab = .general
        NotificationCenter.default.post(name: .showSettings, object: nil)

        DispatchQueue.main.async {
            if UpdateManager.shared.updateAvailable {
                UpdateManager.shared.showUpdateAlert()
            }
        }
    }

    @MainActor
    private func cancelTranscribingIndicatorTask() {
        transcribingIndicatorTask?.cancel()
        transcribingIndicatorTask = nil
    }

    @MainActor
    private func dismissTranscribingOverlay(resetOverlayOwner: Bool = false) {
        cancelTranscribingIndicatorTask()
        clearPendingOverlayDismissToken()
        overlayManager.dismiss()
        if resetOverlayOwner {
            overlayTranscriptionID = UUID()
        }
    }

    @MainActor
    private func prepareTranscribingOverlay(for overlayID: UUID, statusText: String, debugStatus: String) {
        guard overlayTranscriptionID == overlayID else { return }
        self.statusText = statusText
        self.debugStatusMessage = debugStatus
        cancelTranscribingIndicatorTask()
        overlayManager.showTranscribing()
    }

    private func scheduleOverlayDismissAfterFailureIndicator(after delay: TimeInterval) {
        let dismissToken = UUID()
        pendingOverlayDismissToken = dismissToken
        overlayManager.showFailureIndicator()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.pendingOverlayDismissToken == dismissToken else { return }
            self.pendingOverlayDismissToken = nil
            self.overlayManager.dismiss()
        }
    }

    func toggleDebugPanel() {
        selectedSettingsTab = .runLog
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }

    private func pasteAtCursor() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)
    }

    private func pressEnter() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        keyUp?.post(tap: .cgSessionEventTap)
    }

    /// Writes the final transcript to the system pasteboard.
    /// Also handles appending necessary trailing spaces, declaring transient
    /// types for clipboard managers, and saving the clipboard state for later restoration.
    /// - Parameter transcript: The text to be pasted.
    /// - Returns: A `PendingClipboardRestore` object if clipboard preservation is enabled, otherwise nil.
    /// Writes a dictation string to the general pasteboard, marking it transient
    /// so well-behaved clipboard managers (Maccy, Raycast, Paste, Clipy, Flycut,
    /// etc.) skip recording it — unless the user opted to keep dictations in
    /// history. Shared by the main dictation write and the retry copy so both
    /// honor `keepDictationInClipboardHistory` consistently.
    ///
    /// See: https://github.com/nicke5012/TransientPasteboardType
    private func writeDictationStringToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general

        if keepDictationInClipboardHistory {
            // Plain write so clipboard managers record the dictation in history.
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        } else {
            // Declare standard transient types alongside .string. The text still
            // pastes normally via Cmd-V — only clipboard history is affected.
            let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
            let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
            let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
            let legacyTransientType = NSPasteboard.PasteboardType("de.petermaurer.TransientPasteboardType")

            pasteboard.declareTypes([
                .string,
                transientType,
                concealedType,
                autoGeneratedType,
                legacyTransientType
            ], owner: nil)

            pasteboard.setString(text, forType: .string)

            // Populate empty values for the marker types — some clipboard managers
            // check the data presence rather than just the declared type.
            pasteboard.setString("", forType: transientType)
            pasteboard.setString("", forType: concealedType)
            pasteboard.setString("", forType: autoGeneratedType)
            pasteboard.setString("", forType: legacyTransientType)
        }
    }

    private func writeTranscriptToPasteboard(_ transcript: String) -> PendingClipboardRestore? {
        let pasteboard = NSPasteboard.general
        let snapshot = preserveClipboard ? PreservedPasteboardSnapshot(pasteboard: pasteboard) : nil

        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let textToWrite: String
        if transcript.last?.isWhitespace != true,
           let last = trimmedTranscript.last,
           ".!?".contains(last) {
            textToWrite = transcript + " "
        } else {
            textToWrite = transcript
        }

        writeDictationStringToPasteboard(textToWrite)

        guard let snapshot else { return nil }
        return PendingClipboardRestore(
            snapshot: snapshot,
            expectedChangeCount: pasteboard.changeCount,
            writtenTranscript: textToWrite
        )
    }

    private func restoreClipboardIfNeeded(_ pendingRestore: PendingClipboardRestore?) {
        guard let pendingRestore else { return }

        // Some apps consume Cmd-V asynchronously, so restoring too quickly can paste
        // the pre-dictation clipboard instead of the transcript.
        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
            let pasteboard = NSPasteboard.general
            // A bare changeCount check is too strict: browsers, iCloud Universal
            // Clipboard sync, and other background apps bump the change count
            // without the user copying anything, which left the transcript
            // stranded on the clipboard. Restore when nothing changed, or when the
            // clipboard still holds exactly the transcript we wrote (so the user
            // has not deliberately copied something new that we would clobber).
            let clipboardStillHoldsTranscript =
                pasteboard.string(forType: .string) == pendingRestore.writtenTranscript
            guard pasteboard.changeCount == pendingRestore.expectedChangeCount
                || clipboardStillHoldsTranscript else { return }
            pendingRestore.snapshot.restore(to: pasteboard)
        }
    }

    private func performAfterShortcutReleased(attempt: Int = 0, action: @escaping () -> Void) {
        let maxAttempts = 24
        if hotkeyManager.hasPressedShortcutInputs && attempt < maxAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                self?.performAfterShortcutReleased(attempt: attempt + 1, action: action)
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pasteAfterShortcutReleaseDelay) {
            action()
        }
    }

    private func pasteAtCursorWhenShortcutReleased(completion: (() -> Void)? = nil) {
        performAfterShortcutReleased { [weak self] in
            self?.pasteAtCursor()
            completion?()
        }
    }

    private func pressEnterWhenShortcutReleased(completion: (() -> Void)? = nil) {
        performAfterShortcutReleased { [weak self] in
            self?.pressEnter()
            completion?()
        }
    }

    private func pressEnterAfterPaste(completion: (() -> Void)? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + pressEnterAfterPasteDelay) { [weak self] in
            self?.pressEnter()
            completion?()
        }
    }

    private func cancelRecordingInitializationTimer() {
        recordingInitializationTimer?.cancel()
        recordingInitializationTimer = nil
    }

    private func scheduleReadyStatusReset(after delay: TimeInterval, matching statuses: Set<String>? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if let statuses, !statuses.contains(self.statusText) {
                return
            }
            self.statusText = localizedCatalogString("Ready")
        }
    }
}

private extension ShortcutBinding {
    func primaryInputOverlapsForCancellation(with other: ShortcutBinding) -> Bool {
        if kind == other.kind {
            switch kind {
            case .disabled:
                return false
            case .key, .modifierKey:
                return keyCode == other.keyCode
            }
        }

        if kind == .modifierKey,
           other.kind == .key,
           let modifier = Self.logicalModifier(forKeyCode: keyCode) {
            return other.modifiers.contains(modifier)
        }

        if kind == .key,
           other.kind == .modifierKey,
           let modifier = Self.logicalModifier(forKeyCode: other.keyCode) {
            return modifiers.contains(modifier)
        }

        return false
    }

    func isActiveForCancellationConflict(
        pressedModifierKeyCodes: Set<UInt16>,
        permittedAdditionalExactMatchModifiers: ShortcutModifiers
    ) -> Bool {
        let currentModifiers = Self.modifiers(for: pressedModifierKeyCodes)
        guard currentModifiers.isSuperset(of: modifiers) else {
            return false
        }

        if let exactModifierKeyCodes,
           !Self.exactModifierKeyCodesMatch(
            pressedModifierKeyCodes,
            exactModifierKeyCodes: exactModifierKeyCodes,
            permittedAdditionalExactMatchModifiers: permittedAdditionalExactMatchModifiers
           ) {
            return false
        }

        switch kind {
        case .disabled:
            return false
        case .key:
            return true
        case .modifierKey:
            return pressedModifierKeyCodes.contains(keyCode)
        }
    }
}
