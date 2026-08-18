import Foundation
import Combine
import AppKit
import AVFoundation
import CoreAudio
import ServiceManagement
import ApplicationServices
import ScreenCaptureKit
import Speech
import os.log
private let recordingLog = OSLog(subsystem: "com.woosublee.quill", category: "Recording")
private let calendarLog = OSLog(subsystem: "com.woosublee.quill", category: "Calendar")

extension AIProcessingFeature {
    var modelFeature: AIModelFeature {
        switch self {
        case .postProcessing: .postProcessing
        case .context: .contextCapture
        case .meetingSummary: .meetingSummary
        }
    }
}

extension AIProcessingBackendChoice {
    var capabilities: AIModelCapabilities {
        switch self {
        case .cloud(let modelID):
            ModelConfiguration.capabilities(for: modelID)
        case .localAI(let modelID):
            LocalAIModelCatalog.capabilities(for: modelID)
                ?? .none
        }
    }
}

func isAIProcessingChoiceCompatible(
    _ choice: AIProcessingBackendChoice,
    for feature: AIProcessingFeature
) -> Bool {
    guard choice.capabilities.supports(feature.modelFeature) else { return false }
    return feature != .context || choice.capabilities.modalities.contains(.image)
}

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
    let pressEnterCommandEnabled: Bool
    let nativeWhisperExecution: NativeWhisperExecutionSnapshot?
    let cloudDependencies: CloudTranscriptionDependencies
    let postProcessingService: PostProcessingService

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
        pressEnterCommandEnabled: Bool,
        nativeWhisperExecution: NativeWhisperExecutionSnapshot?,
        cloudDependencies: CloudTranscriptionDependencies,
        postProcessingService: PostProcessingService
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
        self.pressEnterCommandEnabled = pressEnterCommandEnabled
        self.nativeWhisperExecution = nativeWhisperExecution
        self.cloudDependencies = cloudDependencies
        self.postProcessingService = postProcessingService
    }

    var systemPrompt: String {
        AppState.resolvedSystemPrompt(customSystemPrompt)
    }

    func makePostProcessingService() -> PostProcessingService {
        postProcessingService
    }

    func makeTranscriptionService(
        cloudExecutionContext: CloudTranscriptionExecutionContext? = nil
    ) throws -> TranscriptionService {
        try TranscriptionService(
            apiKey: transcriptionAPIKey,
            baseURL: transcriptionAPIBaseURL,
            useLocalTranscription: useLocalTranscription,
            localWhisperPath: localWhisperPath.isEmpty ? nil : localWhisperPath,
            useLegacyMlxWhisper: useLegacyMlxWhisper,
            transcriptionLanguage: transcriptionLanguage,
            localTranscriptionModel: localTranscriptionModel,
            transcriptionModel: transcriptionModel,
            nativeWhisperExecution: nativeWhisperExecution,
            cloudDependencies: cloudDependencies,
            cloudExecutionContext: cloudExecutionContext
        )
    }
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
    let spokenLanguage: SpokenLanguageResolution?
    let shouldPersistRawDictationFallback: Bool
    let aiProcessingOutcome: AIProcessingOutcome

    init(
        rawTranscript: String,
        finalTranscript: String,
        prompt: String,
        processingStatus: String,
        shouldPressEnterAfterPaste: Bool,
        spokenLanguage: SpokenLanguageResolution? = nil,
        outcomeWasPostProcessingFailedFallback: Bool,
        aiProcessingOutcome: AIProcessingOutcome = .succeeded
    ) {
        self.rawTranscript = rawTranscript
        self.finalTranscript = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        self.prompt = prompt
        self.processingStatus = processingStatus
        self.shouldPressEnterAfterPaste = shouldPressEnterAfterPaste
        self.spokenLanguage = spokenLanguage
        self.shouldPersistRawDictationFallback = outcomeWasPostProcessingFailedFallback && !self.finalTranscript.isEmpty
        self.aiProcessingOutcome = aiProcessingOutcome
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

enum MeetingSummaryAvailability: Equatable {
    case available
    case featureDisabled
    case modelUnavailable
    case transcriptUnavailable
    case transcriptionInProgress
    case generationInProgress
}

final class AppState: ObservableObject, @unchecked Sendable {
    static var audioImportCloudTranscriptionDependenciesFactory:
        () -> CloudTranscriptionDependencies = {
            .live
        }
    static var postProcessingTransport: PostProcessingService.Transport = { request in
        try await LLMAPITransport.data(for: request)
    }

    static var googleCalendarTokenLoader: (Bool) -> GoogleCalendarOAuthToken? = { allowsAuthenticationUI in
        GoogleCalendarTokenStore.load(allowsAuthenticationUI: allowsAuthenticationUI)
    }
    static var googleCalendarServiceFactory: () -> GoogleCalendarService = {
        GoogleCalendarService()
    }
    static var modelDownloadQuitAlertPresenter: @MainActor () -> NSApplication.ModalResponse = {
        let alert = NSAlert()
        alert.messageText = localizedCatalogString("Quit while models are downloading?")
        alert.informativeText = localizedCatalogString(
            "Quill will cancel unfinished model downloads and delete partial files before quitting."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: localizedCatalogString("Quit and Cancel Downloads"))
        alert.addButton(withTitle: localizedCatalogString("Cancel"))
        alert.icon = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )
        return alert.runModal()
    }
    static var applicationTerminationReply: @MainActor (Bool) -> Void = {
        NSApp.reply(toApplicationShouldTerminate: $0)
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

    private struct RecordingAudioSelection: Equatable {
        let inputID: String
        let microphoneDeviceID: String
    }

    private struct PendingRecordingPermissionContext {
        let triggerMode: RecordingTriggerMode
        let selectionSnapshot: AppSelectionSnapshot?
        let manualCommandRequested: Bool?
    }

    private let apiKeyStorageKey = "groq_api_key"
    private let apiBaseURLStorageKey = "api_base_url"
    private let transcriptionEnabledStorageKey = "transcription_enabled"
    private let transcriptionModelStorageKey = AppState.transcriptionModelStorageKeyName
    private let transcriptionAPIURLStorageKey = "transcription_api_url"
    private let transcriptionAPIKeyStorageKey = "transcription_api_key"
    private let postProcessingModelStorageKey = "post_processing_model"
    private let postProcessingFallbackModelStorageKey = "post_processing_fallback_model"
    private let contextModelStorageKey = "context_model"
    private let meetingSummaryModelStorageKey = "meeting_summary_model"
    private let meetingSummaryFallbackModelStorageKey = "meeting_summary_fallback_model"
    private let meetingSummaryBackendChoiceStorageKey = "meeting_summary_backend_choice"
    private let meetingSummaryOutputLanguageStorageKey = "meeting_summary_output_language"
    private let meetingSummarySettingsInitializedStorageKey = "meeting_summary_settings_initialized"
    private let postProcessingBackendChoiceStorageKey = "post_processing_backend_choice"
    private let contextBackendChoiceStorageKey = "context_backend_choice"
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
    private let selectedMicrophoneDeviceStorageKey = "selected_microphone_device_id"
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
    private let disableMeetingSummaryStorageKey = "disable_meeting_summary"
    private let transcriptionLanguageStorageKey = "transcription_language"
    private let outputLanguageStorageKey = "output_language"
    private let localTranscriptionModelStorageKey = AppState.localTranscriptionModelStorageKeyName
    private let noteBrowserEnabledStorageKey = "note_browser_enabled"
    private let commandModeEnabledStorageKey = "command_mode_enabled"
    private let commandModeStyleStorageKey = "command_mode_style"
    private let commandModeManualModifierStorageKey = "command_mode_manual_modifier"
    private let realtimeStreamingEnabledStorageKey = "realtime_streaming_enabled"
    private let realtimeStreamingModelStorageKey = "realtime_streaming_model"
    private let showRealtimeTranscriptionOptionStorageKey = "show_realtime_transcription_option"
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
    static let defaultMeetingSummaryModel = defaultPostProcessingModel
    static let defaultMeetingSummaryFallbackModel = defaultPostProcessingFallbackModel
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

    private static func normalizedCloudModelID(
        _ modelID: String,
        defaultModelID: String
    ) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultModelID : trimmed
    }

    private static func normalizedAIProcessingBackendChoice(
        _ choice: AIProcessingBackendChoice,
        fallbackCloudModelID: String,
        defaultCloudModelID: String
    ) -> AIProcessingBackendChoice {
        guard case .cloud(let modelID) = choice else { return choice }
        let fallback = normalizedCloudModelID(
            fallbackCloudModelID,
            defaultModelID: defaultCloudModelID
        )
        let normalizedModelID = normalizedCloudModelID(
            modelID,
            defaultModelID: fallback
        )
        return .cloud(modelID: normalizedModelID)
    }

    private static let firstInstallDefaultsVersion = 1
    private static let firstInstallDefaultsVersionKey = "first_install_defaults_version"

    private static func seedFirstInstallDefaultsIfNeeded(
        defaults: UserDefaults,
        hasCompletedSetup: Bool
    ) {
        guard defaults.integer(forKey: firstInstallDefaultsVersionKey)
                < firstInstallDefaultsVersion else { return }

        if hasCompletedSetup {
            defaults.set(firstInstallDefaultsVersion, forKey: firstInstallDefaultsVersionKey)
            return
        }

        if defaults.object(forKey: "disable_auto_paste") == nil {
            defaults.set(true, forKey: "disable_auto_paste")
        }
        if defaults.object(forKey: "transcription_language") == nil {
            defaults.set("auto", forKey: "transcription_language")
        }
        if defaults.object(forKey: "recording_overlay_layout") == nil {
            defaults.set(RecordingOverlayLayout.notchSides.rawValue, forKey: "recording_overlay_layout")
        }
        if defaults.object(forKey: "overlay_waveform_display_mode") == nil {
            defaults.set(OverlayWaveformDisplayMode.hoverTime.rawValue, forKey: "overlay_waveform_display_mode")
        }
        if defaults.object(forKey: "press_enter_voice_command_enabled") == nil {
            defaults.set(false, forKey: "press_enter_voice_command_enabled")
        }

        defaults.set(firstInstallDefaultsVersion, forKey: firstInstallDefaultsVersionKey)
    }

    @Published var hasCompletedSetup: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedSetup, forKey: "hasCompletedSetup")
        }
    }

    @Published var transcriptionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                transcriptionEnabled,
                forKey: transcriptionEnabledStorageKey
            )
            guard transcriptionEnabled, oldValue != transcriptionEnabled else { return }
            scheduleNoteBrowserTranscriptionModeNormalizationForProviderConfiguration()
        }
    }

    @Published var apiKey: String {
        didSet {
            persistAPIKey(apiKey)
            rebuildContextService()
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
            if case .cloud = postProcessingBackendChoice {
                let derivedChoice = AIProcessingBackendChoice.cloud(
                    modelID: resolvedPostProcessingCloudModelID
                )
                if derivedChoice != postProcessingBackendChoice {
                    postProcessingBackendChoice = derivedChoice
                }
            }
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
            if case .cloud = contextBackendChoice {
                let derivedChoice = AIProcessingBackendChoice.cloud(
                    modelID: resolvedContextCloudModelID
                )
                if derivedChoice != contextBackendChoice {
                    contextBackendChoice = derivedChoice
                }
            }
        }
    }

    @Published var meetingSummaryModel: String {
        didSet {
            UserDefaults.standard.set(
                meetingSummaryModel,
                forKey: meetingSummaryModelStorageKey
            )
            if case .cloud = meetingSummaryBackendChoice {
                let derivedChoice = AIProcessingBackendChoice.cloud(
                    modelID: resolvedMeetingSummaryCloudModelID
                )
                if derivedChoice != meetingSummaryBackendChoice {
                    meetingSummaryBackendChoice = derivedChoice
                }
            }
        }
    }

    @Published var meetingSummaryFallbackModel: String {
        didSet {
            UserDefaults.standard.set(
                meetingSummaryFallbackModel,
                forKey: meetingSummaryFallbackModelStorageKey
            )
        }
    }

    @Published var meetingSummaryOutputLanguage: String {
        didSet {
            UserDefaults.standard.set(
                meetingSummaryOutputLanguage,
                forKey: meetingSummaryOutputLanguageStorageKey
            )
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

    /// Whether Realtime should appear as a selectable transcription option in
    /// Settings and the Note Browser. Realtime otherwise stays hidden from
    /// both pickers unless it is already the active choice.
    @Published var showRealtimeTranscriptionOption: Bool {
        didSet {
            UserDefaults.standard.set(
                showRealtimeTranscriptionOption,
                forKey: showRealtimeTranscriptionOptionStorageKey
            )
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

    @Published var disableMeetingSummary: Bool {
        didSet {
            UserDefaults.standard.set(
                disableMeetingSummary,
                forKey: disableMeetingSummaryStorageKey
            )
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

    @Published private(set) var nativeWhisperInstallStatus: NativeWhisperInstallStatus
    @Published private(set) var nativeWhisperInstallProgress: NativeWhisperDownloadProgress
    @Published private(set) var isInstallingNativeWhisper = false
    @Published private(set) var nativeWhisperInstallError: String?
    @Published private(set) var nativeWhisperInstallIssue: QuillUserIssueRecord?
    @Published private(set) var pendingNativeWhisperAutoSelectionModelID: String?

    var willAutoSelectNativeWhisperWhenReady: Bool {
        pendingNativeWhisperAutoSelectionModelID != nil
    }

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

    /// Predefined Standard API model IDs, plus the current custom model ID if
    /// it isn't already one of them. Shared by Settings and the Note Browser
    /// so both list the same Cloud Standard models.
    var standardAPIModelIDs: [String] {
        var modelIDs: [String] = []
        for modelID in ModelConfiguration.transcriptionModels where !modelIDs.contains(modelID) {
            modelIDs.append(modelID)
        }
        let currentModelID = transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentModelID.isEmpty && !modelIDs.contains(currentModelID) {
            modelIDs.append(currentModelID)
        }
        return modelIDs
    }

    @MainActor
    var noteBrowserTranscriptionChoiceDisplays: [TranscriptionChoiceDisplay] {
        let standardDisplays = standardAPIModelIDs.map { modelID in
            noteBrowserTranscriptionDisplay(for: .apiStandard(modelID: modelID))
        }
        let realtimeDisplays = (showRealtimeTranscriptionOption || realtimeStreamingEnabled)
            ? [noteBrowserTranscriptionDisplay(for: apiRealtimeChoice)]
            : []
        return standardDisplays + realtimeDisplays + [
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
            return TranscriptionChoiceDisplay(
                choice: .apiStandard(modelID: resolvedModelID),
                section: "Cloud",
                title: "Standard",
                subtitle: resolvedModelID,
                compactLabel: "Standard · \(resolvedModelID)",
                currentLabel: "Cloud · Standard · \(resolvedModelID)",
                isAvailable: true,
                unavailableReason: nil
            )
        case .apiRealtime(let modelID):
            let resolvedModelID = nonEmptyModelID(modelID ?? realtimeStreamingModel)
            let modelLabel = resolvedModelID ?? "Provider default"
            let unavailableReason = AudioInputDevice
                .isSystemDefaultAndSystemAudio(selectedMicrophoneID)
                ? "Realtime is unavailable with Microphone + System Audio"
                : nil
            return TranscriptionChoiceDisplay(
                choice: .apiRealtime(modelID: resolvedModelID),
                section: "Cloud",
                title: "Realtime",
                subtitle: modelLabel,
                compactLabel: "Realtime · \(modelLabel)",
                currentLabel: "Cloud · Realtime · \(modelLabel)",
                isAvailable: unavailableReason == nil,
                unavailableReason: unavailableReason
            )
        case .nativeWhisper:
            let unavailableReason = hasNativeLocalWhisperModel ? nil : "Install the native Local Whisper model to use this option"
            return TranscriptionChoiceDisplay(
                choice: nativeWhisperChoice,
                section: "On This Mac",
                title: "Native Whisper",
                subtitle: nativeWhisperDisplayName,
                compactLabel: "Native Whisper · \(nativeWhisperDisplayName)",
                currentLabel: "On This Mac · Native Whisper · \(nativeWhisperDisplayName)",
                isAvailable: unavailableReason == nil,
                unavailableReason: unavailableReason
            )
        case .legacyMlxWhisper(let model):
            let unavailableReason = model.isInstalled ? nil : "Install \(model.displayName) in Settings to use this option"
            return TranscriptionChoiceDisplay(
                choice: .legacyMlxWhisper(model: model),
                section: "On This Mac",
                title: "Legacy mlx-whisper",
                subtitle: model.displayName,
                compactLabel: "Legacy · \(model.displayName)",
                currentLabel: "On This Mac · Legacy · \(model.displayName)",
                isAvailable: unavailableReason == nil,
                unavailableReason: unavailableReason
            )
        case .appleLive:
            let unavailableReason = AudioInputDevice.isSystemDefaultAndSystemAudio(selectedMicrophoneID)
                ? "Apple Live is unavailable with Microphone + System Audio"
                : nil
            return TranscriptionChoiceDisplay(
                choice: .appleLive,
                section: "On This Mac",
                title: "Apple Live",
                subtitle: "Apple Speech",
                compactLabel: "Apple Live · Apple Speech",
                currentLabel: "On This Mac · Apple Live · Apple Speech",
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

    private var resolvedPostProcessingCloudModelID: String {
        nonEmptyModelID(postProcessingModel) ?? Self.defaultPostProcessingModel
    }

    private var resolvedContextCloudModelID: String {
        nonEmptyModelID(contextModel) ?? Self.defaultContextModel
    }

    private var resolvedMeetingSummaryCloudModelID: String {
        nonEmptyModelID(meetingSummaryModel) ?? Self.defaultMeetingSummaryModel
    }

    private func resolvedCloudModelID(
        for feature: AIProcessingFeature
    ) -> String {
        switch feature {
        case .postProcessing:
            return resolvedPostProcessingCloudModelID
        case .context:
            return resolvedContextCloudModelID
        case .meetingSummary:
            return resolvedMeetingSummaryCloudModelID
        }
    }

    private func nonEmptyModelID(_ modelID: String) -> String? {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @MainActor
    func refreshNativeWhisperInstallStatus() {
        nativeWhisperWorkflow.refreshInstallStatus()
        scheduleNoteBrowserTranscriptionModeNormalizationForProviderConfiguration()
    }

    @MainActor
    func installNativeWhisperModel(autoSelectWhenReady: Bool = true) {
        guard !isModelTerminationCleanupPending else { return }
        if autoSelectWhenReady {
            pendingNativeWhisperAutoSelectionModelID = NativeWhisperModelCatalog.recommended.id
        }
        nativeWhisperWorkflow.startInstall()
    }

    @MainActor
    func waitForNativeWhisperInstallToQuiesce() async {
        await nativeWhisperWorkflow.waitUntilQuiesced()
    }

    @MainActor
    func cancelNativeWhisperAutoSelection() {
        pendingNativeWhisperAutoSelectionModelID = nil
    }

    @MainActor
    func cancelNativeWhisperInstall() {
        pendingNativeWhisperAutoSelectionModelID = nil
        nativeWhisperWorkflow.cancelInstall()
    }

    @MainActor
    func deleteNativeWhisperModel() {
        nativeWhisperWorkflow.deleteModel()
        scheduleNoteBrowserTranscriptionModeNormalizationForProviderConfiguration()
    }

    @MainActor
    private func applyNativeWhisperModelWorkflowEvent(
        _ event: NativeWhisperModelWorkflowEvent
    ) {
        switch event {
        case .stateChanged(let state):
            update(\AppState.nativeWhisperInstallStatus, to: state.installStatus)
            update(\AppState.nativeWhisperInstallProgress, to: state.installProgress)
            update(\AppState.isInstallingNativeWhisper, to: state.isInstalling)
            update(\AppState.nativeWhisperInstallError, to: state.installError)
            update(\AppState.nativeWhisperInstallIssue, to: state.installIssue)

        case .installCompleted(let outcome):
            scheduleNoteBrowserTranscriptionModeNormalizationForProviderConfiguration()
            switch outcome {
            case .succeeded:
                if pendingNativeWhisperAutoSelectionModelID
                    == NativeWhisperModelCatalog.recommended.id {
                    setNoteBrowserTranscriptionChoice(
                        .nativeWhisper(modelID: NativeWhisperModelCatalog.recommended.id)
                    )
                }
                pendingNativeWhisperAutoSelectionModelID = nil
            case .cancelled, .failed:
                pendingNativeWhisperAutoSelectionModelID = nil
            }
        }
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
            return true
        case .apiRealtime:
            return !AudioInputDevice.isSystemDefaultAndSystemAudio(selectedMicrophoneID)
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
    func isNoteBrowserTranscriptionChoiceReady(
        _ choice: TranscriptionBackendChoice
    ) -> Bool {
        guard isNoteBrowserTranscriptionChoiceAvailable(choice) else {
            return false
        }
        return !choice.usesCloudAPI || hasTranscriptionAPIKey
    }

    @MainActor
    func setNoteBrowserTranscriptionMode(_ mode: NoteBrowserTranscriptionMode) {
        setNoteBrowserTranscriptionChoice(preferredNoteBrowserTranscriptionChoice(for: mode))
    }

    @MainActor
    func setNoteBrowserTranscriptionChoice(_ choice: TranscriptionBackendChoice) {
        applyNoteBrowserTranscriptionChoice(normalizedNoteBrowserTranscriptionChoice(choice))
    }

    @MainActor
    func setNoteBrowserTranscriptionSelection(
        _ choice: TranscriptionBackendChoice?
    ) {
        guard let choice else {
            transcriptionEnabled = false
            return
        }
        guard isNoteBrowserTranscriptionChoiceReady(choice) else { return }
        setNoteBrowserTranscriptionChoice(choice)
        transcriptionEnabled = true
    }

    @MainActor
    func setSettingsTranscriptionEnabled(_ isEnabled: Bool) {
        guard isEnabled else {
            transcriptionEnabled = false
            return
        }
        guard let readyChoice = readyNoteBrowserTranscriptionChoice(
            preferred: currentNoteBrowserTranscriptionChoice
        ) else {
            transcriptionEnabled = false
            return
        }
        applyNoteBrowserTranscriptionChoice(readyChoice)
        transcriptionEnabled = true
    }

    @MainActor
    private func readyNoteBrowserTranscriptionChoice(
        preferred: TranscriptionBackendChoice
    ) -> TranscriptionBackendChoice? {
        if isNoteBrowserTranscriptionChoiceReady(preferred) {
            return preferred
        }
        let currentChoice = currentNoteBrowserTranscriptionChoice
        if isNoteBrowserTranscriptionChoiceReady(currentChoice) {
            return currentChoice
        }
        return noteBrowserFallbackChoices(for: preferred)
            .first(where: isNoteBrowserTranscriptionChoiceReady)
    }

    @MainActor
    func applySetupProcessingPreset(_ preset: SetupFlow.ProcessingPreset) {
        switch preset {
        case .recordOnly:
            transcriptionEnabled = false
        case .localAppleSpeech:
            transcriptionEnabled = true
            setNoteBrowserTranscriptionChoice(.appleLive)
            disablePostProcessing = true
            disableContextCapture = true
        case .localNativeWhisper:
            transcriptionEnabled = true
            setNoteBrowserTranscriptionChoice(
                .nativeWhisper(modelID: NativeWhisperModelCatalog.recommended.id)
            )
            disablePostProcessing = true
            disableContextCapture = true
        case .apiStandard:
            transcriptionEnabled = true
            setNoteBrowserTranscriptionChoice(
                .apiStandard(modelID: transcriptionModel)
            )
            disablePostProcessing = false
            disableContextCapture = false
        }
    }

    private func scheduleNoteBrowserTranscriptionModeNormalizationForSelectedInput() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                guard transcriptionEnabled,
                      !isApplyingNoteBrowserTranscriptionChoice else { return }
                normalizeNoteBrowserTranscriptionMode()
            }
        } else {
            Task { @MainActor [weak self] in
                guard let self,
                      self.transcriptionEnabled,
                      !self.isApplyingNoteBrowserTranscriptionChoice else { return }
                self.normalizeNoteBrowserTranscriptionMode()
            }
        }
    }

    private func scheduleNoteBrowserTranscriptionModeNormalizationForProviderConfiguration() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                guard transcriptionEnabled,
                      !isApplyingNoteBrowserTranscriptionChoice,
                      !isRecording,
                      !isTranscribing else { return }
                normalizeNoteBrowserTranscriptionMode()
            }
        } else {
            Task { @MainActor [weak self] in
                guard let self,
                      self.transcriptionEnabled,
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
        guard isNoteBrowserTranscriptionChoiceReady(normalizedChoice) else {
            transcriptionEnabled = false
            return
        }
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

    // MARK: Warning banner dismissal (per note + issue code, invalidated by retry)

    // A per-note counter bumped every time that note is retried. Dismissals
    // are recorded against the generation they were dismissed at, so a later
    // retry (which may produce a different outcome) makes the banner
    // reappear if the warning condition still holds.
    @Published private(set) var noteRetryGenerationByID: [String: Int] = AppState.loadIntDictionary(
        forKey: AppState.noteRetryGenerationDefaultsKey
    )
    @Published private(set) var dismissedWarningBannerGeneration: [String: Int] = AppState.loadIntDictionary(
        forKey: AppState.dismissedWarningBannerGenerationDefaultsKey
    )

    private static let noteRetryGenerationDefaultsKey = "note_retry_generation_by_id"
    private static let dismissedWarningBannerGenerationDefaultsKey = "dismissed_warning_banner_generation_by_key"

    private static func loadIntDictionary(forKey key: String) -> [String: Int] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let values = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return values
    }

    private static func saveIntDictionary(_ values: [String: Int], forKey key: String) {
        guard !values.isEmpty else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func dismissalKey(noteID: UUID, code: QuillUserIssueCode) -> String {
        "\(noteID.uuidString):\(code.rawValue)"
    }

    func noteRetryGeneration(for noteID: UUID) -> Int {
        noteRetryGenerationByID[noteID.uuidString] ?? 0
    }

    @MainActor
    func incrementNoteRetryGeneration(for noteID: UUID) {
        let key = noteID.uuidString
        noteRetryGenerationByID[key] = (noteRetryGenerationByID[key] ?? 0) + 1
        Self.saveIntDictionary(noteRetryGenerationByID, forKey: Self.noteRetryGenerationDefaultsKey)
    }

    func isWarningBannerDismissed(noteID: UUID, code: QuillUserIssueCode) -> Bool {
        let key = Self.dismissalKey(noteID: noteID, code: code)
        guard let dismissedGeneration = dismissedWarningBannerGeneration[key] else {
            return false
        }
        return dismissedGeneration == noteRetryGeneration(for: noteID)
    }

    @MainActor
    func dismissWarningBanner(noteID: UUID, code: QuillUserIssueCode) {
        let key = Self.dismissalKey(noteID: noteID, code: code)
        dismissedWarningBannerGeneration[key] = noteRetryGeneration(for: noteID)
        Self.saveIntDictionary(
            dismissedWarningBannerGeneration,
            forKey: Self.dismissedWarningBannerGenerationDefaultsKey
        )
    }

    /// Drops the per-note retry generation and any banner dismissals for a
    /// deleted note so these side-store dictionaries don't grow unbounded.
    @MainActor
    private func forgetWarningBannerState(for noteID: UUID) {
        let dismissalPrefix = "\(noteID.uuidString):"
        let hadState = noteRetryGenerationByID[noteID.uuidString] != nil
            || dismissedWarningBannerGeneration.keys.contains { $0.hasPrefix(dismissalPrefix) }
        guard hadState else { return }
        noteRetryGenerationByID.removeValue(forKey: noteID.uuidString)
        dismissedWarningBannerGeneration = dismissedWarningBannerGeneration.filter {
            !$0.key.hasPrefix(dismissalPrefix)
        }
        Self.saveIntDictionary(noteRetryGenerationByID, forKey: Self.noteRetryGenerationDefaultsKey)
        Self.saveIntDictionary(
            dismissedWarningBannerGeneration,
            forKey: Self.dismissedWarningBannerGenerationDefaultsKey
        )
    }

    /// Clears all banner dismissal / retry-generation side state, e.g. when the
    /// entire run history is cleared.
    @MainActor
    private func forgetAllWarningBannerState() {
        guard !noteRetryGenerationByID.isEmpty || !dismissedWarningBannerGeneration.isEmpty else { return }
        noteRetryGenerationByID = [:]
        dismissedWarningBannerGeneration = [:]
        Self.saveIntDictionary(noteRetryGenerationByID, forKey: Self.noteRetryGenerationDefaultsKey)
        Self.saveIntDictionary(
            dismissedWarningBannerGeneration,
            forKey: Self.dismissedWarningBannerGenerationDefaultsKey
        )
    }

    var isTranscriptionConfigurationLocked: Bool {
        isRecording || isTranscribing || !retryingItemIDs.isEmpty
    }
    @Published private(set) var cloudTranscriptionProgressByHistoryID:
        [UUID: CloudTranscriptionDisplayProgress] = [:]
    private var transcriptionRetryWorkflowItemIDs: Set<UUID> = []
    private var transcriptionRetryWorkflowProgressIDs: Set<UUID> = []
    @Published var lastTranscript: String = ""
    @Published var errorMessage: String?
    @Published private(set) var historyPersistenceWarning: QuillUserIssueRecord?
    @Published private(set) var isHistoryUnavailable = false
    @Published private(set) var historyArchiveSafety: HistoryArchiveSafety = .normal
    @Published private(set) var isHistoryArchiveTransitioning = false
    @Published private(set) var historyRecoverySnapshots: [HistoryRecoverySnapshotDescriptor] = []
    @Published private(set) var historyRecoveryInspections: [UUID: HistoryRecoveryInspection] = [:]
    @Published private(set) var historyRecoveryInspectionSnapshotID: UUID?
    @Published private(set) var isHistoryRecoveryOperationInProgress = false
    @Published private(set) var historyRecoveryOperationMessage: String?
    @Published private(set) var historyRecoveryImportResult: HistoryRecoveryImportResult?
    var historyUnavailableMessage: String {
        QuillUserIssueRecord(code: .historyPersistenceUnavailable)
            .presentation().compactMessage
    }
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
    @Published private(set) var meetingSummaryGeneratingNoteIDs: Set<UUID> = []
    private let meetingSummaryWorkflow: MeetingSummaryWorkflow
    private let transcriptionRetryWorkflow: TranscriptionRetryWorkflow
    private let nativeWhisperWorkflow: NativeWhisperModelWorkflow
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

    /// Effective recorder route kept in the legacy storage shape for backward
    /// compatibility: a microphone device id or one of the special source ids.
    @Published var selectedMicrophoneID: String {
        didSet {
            UserDefaults.standard.set(selectedMicrophoneID, forKey: selectedMicrophoneStorageKey)
            if AudioInputDevice.isMicrophoneOnly(selectedMicrophoneID) {
                let deviceID = AudioInputDevice.normalizedMicrophoneDeviceID(selectedMicrophoneID)
                if selectedMicrophoneDeviceID != deviceID {
                    selectedMicrophoneDeviceID = deviceID
                }
            }
            scheduleNoteBrowserTranscriptionModeNormalizationForSelectedInput()
        }
    }
    @Published private(set) var selectedMicrophoneDeviceID: String {
        didSet {
            UserDefaults.standard.set(
                selectedMicrophoneDeviceID,
                forKey: selectedMicrophoneDeviceStorageKey
            )
        }
    }
    @Published var availableMicrophones: [AudioDevice] = []
    @Published private(set) var systemDefaultMicrophoneName: String?

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
    private var activeRecordingTranscriptionEnabled: Bool?

    private var shouldTranscribeActiveRecording: Bool {
        activeRecordingTranscriptionEnabled ?? transcriptionEnabled
    }

    /// Whether the transcription choice that would actually run right now
    /// (the active recording's choice while recording, otherwise the choice
    /// queued up for the next recording) streams live audio (Apple Live,
    /// API Realtime) and therefore cannot tolerate the combined System
    /// Default + System Audio source.
    @MainActor
    private var currentNoteBrowserTranscriptionChoiceIsLiveOnly: Bool {
        switch currentNoteBrowserTranscriptionChoice {
        case .appleLive, .apiRealtime:
            return true
        case .apiStandard, .nativeWhisper, .legacyMlxWhisper:
            return false
        }
    }

    /// Whether the currently active recording is relying on a transcriber
    /// that streams live audio (Apple Live, API Realtime) and therefore
    /// cannot tolerate a mid-recording switch to the combined
    /// System Default + System Audio source.
    @MainActor
    private var isActiveRecordingUsingLiveOnlyTranscription: Bool {
        guard isRecording, shouldTranscribeActiveRecording else { return false }
        return currentNoteBrowserTranscriptionChoiceIsLiveOnly
    }

    /// Whether `inputID` can be selected right now without breaking live
    /// transcription: during an active recording, without breaking the
    /// active recording's live transcriber; otherwise, without queueing up
    /// a source that would immediately force the next recording's live-only
    /// transcription choice to turn off. Used by both the recording
    /// overlay's input switcher and the Note Browser's input picker.
    @MainActor
    func isAudioSourceSelectable(_ source: AudioRecordingSource) -> Bool {
        guard source == .microphoneAndSystemAudio, isRecording else {
            return true
        }
        return !isActiveRecordingUsingLiveOnlyTranscription
    }

    @MainActor
    func isAudioInputSelectable(_ inputID: String) -> Bool {
        isAudioSourceSelectable(AudioRecordingSource(inputID: inputID))
    }

    @MainActor
    var selectedAudioSource: AudioRecordingSource {
        AudioRecordingSource(inputID: activeAudioInputID ?? selectedMicrophoneID)
    }

    @MainActor
    var selectedAudioSourceID: String {
        selectedAudioSource.id
    }

    @MainActor
    func selectAudioSource(_ source: AudioRecordingSource) {
        guard isAudioSourceSelectable(source) else { return }

        let inputID = source == .microphone
            ? selectedMicrophoneDeviceID
            : source.id
        if isRecording {
            switchActiveRecordingInput(to: inputID)
        } else {
            selectedMicrophoneID = inputID
        }
    }

    @MainActor
    func selectAudioSource(withID sourceID: String) {
        selectAudioSource(AudioRecordingSource(inputID: sourceID))
    }

    @MainActor
    func selectMicrophoneDevice(_ deviceID: String) {
        guard !isRecording else { return }
        let normalizedID = AudioInputDevice.normalizedMicrophoneDeviceID(deviceID)
        selectedMicrophoneDeviceID = normalizedID
        if AudioInputDevice.audioSourceID(for: selectedMicrophoneID)
            == AudioInputDevice.defaultMicrophoneID {
            selectedMicrophoneID = normalizedID
        }
    }

    @MainActor
    func selectedMicrophoneDisplayName() -> String {
        if selectedMicrophoneDeviceID == AudioInputDevice.defaultMicrophoneID {
            return systemDefaultMicrophoneDisplayName()
        }
        return availableMicrophones.first(where: {
            $0.uid == selectedMicrophoneDeviceID
        })?.name ?? localizedCatalogString("Selected Microphone")
    }

    @MainActor
    func systemDefaultMicrophoneDisplayName() -> String {
        AudioInputDevice.systemDefaultDisplayName(
            deviceName: systemDefaultMicrophoneName,
            defaultTitle: localizedCatalogString("System Default"),
            format: localizedCatalogString("System Default (%@)")
        )
    }

    @MainActor
    private func currentRecordingAudioSelection() -> RecordingAudioSelection {
        RecordingAudioSelection(
            inputID: selectedMicrophoneID,
            microphoneDeviceID: selectedMicrophoneDeviceID
        )
    }

    @MainActor
    private func accessibleCurrentRecordingAudioSelection() async -> RecordingAudioSelection? {
        while true {
            let selection = currentRecordingAudioSelection()
            guard await ensureRecordingInputAccess(for: selection) else {
                return nil
            }
            if selection == currentRecordingAudioSelection() {
                return selection
            }
        }
    }

    private var activeAudioInputID: String?
    private var activeInputSwitchToken: UUID?
    private var isActiveInputSwitchPhysicalStopInProgress = false
    private var isCancelConfirmationShowing = false
    private var overlayTranscriptionID: UUID = UUID()
    private var foregroundTranscriptionJobID: UUID?
    private var activeTranscriptionJobs: [UUID: TranscriptionJob] = [:]
    private var pendingAudioImportJobIDs: Set<UUID> = []
    let localAIServerManager: LocalAIServerManager
    private let localAIWorkflow: LocalAIModelWorkflow
    @Published private(set) var localAIInstallStates: [String: LocalAIModelInstallViewState] = [:]
    @Published private(set) var contextModelCapabilityWarning: String?
    @Published private var pendingLocalAISelections: [AIProcessingFeature: String] = [:]

    @Published var postProcessingBackendChoice: AIProcessingBackendChoice {
        didSet {
            let normalizedChoice = Self.normalizedAIProcessingBackendChoice(
                postProcessingBackendChoice,
                fallbackCloudModelID: postProcessingModel,
                defaultCloudModelID: Self.defaultPostProcessingModel
            )
            if normalizedChoice != postProcessingBackendChoice {
                postProcessingBackendChoice = normalizedChoice
            } else {
                AIProcessingBackendChoiceStore.save(
                    postProcessingBackendChoice,
                    defaults: .standard,
                    key: postProcessingBackendChoiceStorageKey
                )
                if case .cloud(let modelID) = postProcessingBackendChoice,
                   postProcessingModel != modelID {
                    postProcessingModel = modelID
                }
            }
        }
    }

    @Published var contextBackendChoice: AIProcessingBackendChoice {
        didSet {
            let normalizedChoice = Self.normalizedAIProcessingBackendChoice(
                contextBackendChoice,
                fallbackCloudModelID: contextModel,
                defaultCloudModelID: Self.defaultContextModel
            )
            if normalizedChoice != contextBackendChoice {
                contextBackendChoice = normalizedChoice
            } else {
                AIProcessingBackendChoiceStore.save(
                    contextBackendChoice,
                    defaults: .standard,
                    key: contextBackendChoiceStorageKey
                )
                if case .cloud(let modelID) = contextBackendChoice,
                   contextModel != modelID {
                    contextModel = modelID
                }
                rebuildContextService()
            }
        }
    }

    @Published var meetingSummaryBackendChoice: AIProcessingBackendChoice {
        didSet {
            let normalizedChoice = Self.normalizedAIProcessingBackendChoice(
                meetingSummaryBackendChoice,
                fallbackCloudModelID: meetingSummaryModel,
                defaultCloudModelID: Self.defaultMeetingSummaryModel
            )
            if normalizedChoice != meetingSummaryBackendChoice {
                meetingSummaryBackendChoice = normalizedChoice
            } else {
                AIProcessingBackendChoiceStore.save(
                    meetingSummaryBackendChoice,
                    defaults: .standard,
                    key: meetingSummaryBackendChoiceStorageKey
                )
                if case .cloud(let modelID) = meetingSummaryBackendChoice,
                   meetingSummaryModel != modelID {
                    meetingSummaryModel = modelID
                }
            }
        }
    }

    private var contextService: AppContextService
    private var settingsDraftCommits: [UUID: () -> Void] = [:]
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
    private var isModelDownloadQuitAlertPresented = false
    private var isModelTerminationCleanupPending = false
    private var shouldTerminateAfterTranscription = false
    private var pendingAudioOnlyStopIDs: Set<UUID> = []
    private var audioDeviceObservers: [NSObjectProtocol] = []
    private var defaultInputDeviceListener: AudioObjectPropertyListenerBlock?
    private var defaultInputDeviceListenerAddress: AudioObjectPropertyAddress?
    private var needsMicrophoneRefreshAfterRecording = false
    private let dependencies: AppStateDependencies
    var storageLayout: AppStateStorageLayout { dependencies.storageLayout }
    var noteAssetStore: NoteAssetStore { NoteAssetStore(storageLayout: storageLayout) }
    var credentialStore: CredentialStore {
        CredentialStore(layout: dependencies.credentialStorageLayout)
    }
    private let historyWorkflow: HistoryArchiveRecoveryWorkflow
    private var pipelineHistoryStore: PipelineHistoryStore
    private var recordingJournalStore: RecordingJournalStore
    private var cloudTranscriptionJobStore: CloudTranscriptionJobStore
    @MainActor private let cloudTranscriptionHistoryCoordinator =
        CloudTranscriptionHistoryCoordinator()
    private var activeSegmentedJournalController: SegmentedRecordingJournalController?
    private var activeRecordingStorageFailureID: UUID?
    private let recordingJournalFinalizationQueue = DispatchQueue(
        label: "com.woosublee.quill.recording-journal.finalization",
        qos: .userInitiated
    )
    private var pendingRecordingJournalFinalizationCount = 0
    private var pendingRecordingStartCount = 0
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
    private var realtimeLanguageConfiguration: RealtimeTranscriptionLanguageConfiguration?
    private var criticalDictationActivityState = CriticalDictationActivityState()
    private var activeAudioInterruption: ActiveAudioInterruption?
    private var pendingOverlayDismissToken: UUID?
    private var shouldMonitorHotkeys = false
    private var isApplyingNoteBrowserTranscriptionChoice = false
    private var isCapturingShortcut = false
    private var isAwaitingMicrophonePermission = false
    private var isAwaitingSpeechRecognitionPermission = false
    private var pendingMicrophonePermissionContext: PendingRecordingPermissionContext?
    private var pendingSpeechPermissionContext: PendingRecordingPermissionContext?
    private let postTranscriptionUpdateReminderDuration: TimeInterval = 7

    init(dependencies: AppStateDependencies = .live) {
        self.dependencies = dependencies
        let nativeWhisperWorkflow = NativeWhisperModelWorkflow(
            dependencies: dependencies.nativeWhisper
        )
        self.nativeWhisperWorkflow = nativeWhisperWorkflow
        nativeWhisperInstallStatus = nativeWhisperWorkflow.initialState.installStatus
        nativeWhisperInstallProgress = nativeWhisperWorkflow.initialState.installProgress
        let storageLayout = dependencies.storageLayout
        let historyWorkflow = HistoryArchiveRecoveryWorkflow(
            storageLayout: storageLayout,
            makeHistoryStore: dependencies.makePipelineHistoryStore
        )
        let meetingSummaryWorkflow = MeetingSummaryWorkflow(
            dependencies: MeetingSummaryWorkflowDependencies(
                makeGenerator: dependencies.makeMeetingSummaryGenerator,
                now: { Date() }
            )
        )
        let transcriptionRetryWorkflow = TranscriptionRetryWorkflow()
        let historyStartup = historyWorkflow.prepareStartup()
        self.historyWorkflow = historyWorkflow
        self.meetingSummaryWorkflow = meetingSummaryWorkflow
        self.transcriptionRetryWorkflow = transcriptionRetryWorkflow
        pipelineHistoryStore = historyStartup.activeStore
        let audioDirectory = storageLayout.audioDirectory
        recordingJournalStore = RecordingJournalStore(
            audioDirectory: audioDirectory
        )
        cloudTranscriptionJobStore = CloudTranscriptionJobStore(
            jobsDirectory: storageLayout.cloudTranscriptionJobsDirectory,
            temporaryRoot: storageLayout.cloudTranscriptionTemporaryDirectory
        )
        UserDefaults.standard.removeObject(forKey: "force_http2_transcription")
        Self.migrateModelStorageKeys()
        let hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedSetup")
        Self.seedFirstInstallDefaultsIfNeeded(
            defaults: .standard,
            hasCompletedSetup: hasCompletedSetup
        )
        let hasStoredTranscriptionEnabled = UserDefaults.standard.object(
            forKey: transcriptionEnabledStorageKey
        ) != nil
        let transcriptionEnabled = hasStoredTranscriptionEnabled
            ? UserDefaults.standard.bool(forKey: transcriptionEnabledStorageKey)
            : true
        if hasCompletedSetup && !hasStoredTranscriptionEnabled {
            UserDefaults.standard.set(true, forKey: transcriptionEnabledStorageKey)
        }
        let initialCredentialStore = CredentialStore(
            layout: dependencies.credentialStorageLayout
        )
        let apiKey = Self.loadStoredAPIKey(
            account: apiKeyStorageKey,
            credentialStore: initialCredentialStore
        )
        let apiBaseURL = Self.loadStoredAPIBaseURL(
            account: "api_base_url",
            credentialStore: initialCredentialStore
        )
        let transcriptionModel = UserDefaults.standard.string(forKey: transcriptionModelStorageKey) ?? Self.defaultTranscriptionModel
        let transcriptionAPIURL = Self.loadOptionalStoredAPIValue(
            account: transcriptionAPIURLStorageKey,
            credentialStore: initialCredentialStore
        )
        let transcriptionAPIKey = Self.loadStoredAPIKey(
            account: transcriptionAPIKeyStorageKey,
            credentialStore: initialCredentialStore
        )
        let meetingSummarySettingsInitialized = UserDefaults.standard.bool(
            forKey: meetingSummarySettingsInitializedStorageKey
        )
        let rememberedPostProcessingModel = Self.normalizedCloudModelID(
            UserDefaults.standard.string(forKey: postProcessingModelStorageKey) ?? "",
            defaultModelID: Self.defaultPostProcessingModel
        )
        let postProcessingFallbackModel = UserDefaults.standard.string(
            forKey: postProcessingFallbackModelStorageKey
        ) ?? Self.defaultPostProcessingFallbackModel
        let rememberedContextModel = Self.normalizedCloudModelID(
            Self.loadStoredContextModel(key: contextModelStorageKey),
            defaultModelID: Self.defaultContextModel
        )
        let postProcessingBackendChoice = Self.normalizedAIProcessingBackendChoice(
            AIProcessingBackendChoiceStore.load(
                defaults: .standard,
                key: postProcessingBackendChoiceStorageKey,
                fallbackCloudModelID: rememberedPostProcessingModel
            ),
            fallbackCloudModelID: rememberedPostProcessingModel,
            defaultCloudModelID: Self.defaultPostProcessingModel
        )
        let contextBackendChoice = Self.normalizedAIProcessingBackendChoice(
            AIProcessingBackendChoiceStore.load(
                defaults: .standard,
                key: contextBackendChoiceStorageKey,
                fallbackCloudModelID: rememberedContextModel
            ),
            fallbackCloudModelID: rememberedContextModel,
            defaultCloudModelID: Self.defaultContextModel
        )
        let postProcessingModel = switch postProcessingBackendChoice {
        case .cloud(let modelID): modelID
        case .localAI: rememberedPostProcessingModel
        }
        let contextModel = switch contextBackendChoice {
        case .cloud(let modelID): modelID
        case .localAI: rememberedContextModel
        }
        let rememberedMeetingSummaryModel: String
        let meetingSummaryFallbackModel: String
        let meetingSummaryBackendChoice: AIProcessingBackendChoice
        if meetingSummarySettingsInitialized {
            rememberedMeetingSummaryModel = Self.normalizedCloudModelID(
                UserDefaults.standard.string(
                    forKey: meetingSummaryModelStorageKey
                ) ?? "",
                defaultModelID: Self.defaultMeetingSummaryModel
            )
            meetingSummaryFallbackModel = UserDefaults.standard.string(
                forKey: meetingSummaryFallbackModelStorageKey
            ) ?? Self.defaultMeetingSummaryFallbackModel
            meetingSummaryBackendChoice = Self.normalizedAIProcessingBackendChoice(
                AIProcessingBackendChoiceStore.load(
                    defaults: .standard,
                    key: meetingSummaryBackendChoiceStorageKey,
                    fallbackCloudModelID: rememberedMeetingSummaryModel
                ),
                fallbackCloudModelID: rememberedMeetingSummaryModel,
                defaultCloudModelID: Self.defaultMeetingSummaryModel
            )
        } else {
            rememberedMeetingSummaryModel = postProcessingModel
            meetingSummaryFallbackModel = postProcessingFallbackModel
            meetingSummaryBackendChoice = postProcessingBackendChoice
        }
        let meetingSummaryModel = switch meetingSummaryBackendChoice {
        case .cloud(let modelID): modelID
        case .localAI: rememberedMeetingSummaryModel
        }
        let outputLanguage = UserDefaults.standard.string(
            forKey: outputLanguageStorageKey
        ) ?? ""
        let meetingSummaryOutputLanguage = meetingSummarySettingsInitialized
            ? UserDefaults.standard.string(
                forKey: meetingSummaryOutputLanguageStorageKey
            ) ?? ""
            : outputLanguage

        UserDefaults.standard.set(
            postProcessingModel,
            forKey: postProcessingModelStorageKey
        )
        UserDefaults.standard.set(contextModel, forKey: contextModelStorageKey)
        UserDefaults.standard.set(
            meetingSummaryModel,
            forKey: meetingSummaryModelStorageKey
        )
        UserDefaults.standard.set(
            meetingSummaryFallbackModel,
            forKey: meetingSummaryFallbackModelStorageKey
        )
        UserDefaults.standard.set(
            meetingSummaryOutputLanguage,
            forKey: meetingSummaryOutputLanguageStorageKey
        )
        AIProcessingBackendChoiceStore.save(
            postProcessingBackendChoice,
            defaults: .standard,
            key: postProcessingBackendChoiceStorageKey
        )
        AIProcessingBackendChoiceStore.save(
            contextBackendChoice,
            defaults: .standard,
            key: contextBackendChoiceStorageKey
        )
        AIProcessingBackendChoiceStore.save(
            meetingSummaryBackendChoice,
            defaults: .standard,
            key: meetingSummaryBackendChoiceStorageKey
        )
        let localAIServerManager = dependencies.localAI.makeServerManager()
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
        let showRealtimeTranscriptionOption = UserDefaults.standard.bool(
            forKey: showRealtimeTranscriptionOptionStorageKey
        )
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
        let disableMeetingSummary = meetingSummarySettingsInitialized
            ? UserDefaults.standard.bool(forKey: disableMeetingSummaryStorageKey)
            : true
        let noteBrowserEnabled = UserDefaults.standard.object(forKey: noteBrowserEnabledStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: noteBrowserEnabledStorageKey)
        let transcriptionLanguage = TranscriptionLanguage.find(
            code: UserDefaults.standard.string(forKey: transcriptionLanguageStorageKey) ?? "ko"
        )
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
        var savedHistory: [PipelineHistoryItem] = []
        var cloudReconciliation: CloudTranscriptionReconciliation?

        if historyStartup.permitsNormalHistoryStartup {
            Self.recoverRecordingJournalsBeforeHistoryLoad(
                recordingJournalStore: recordingJournalStore,
                historyStore: pipelineHistoryStore,
                storageLayout: storageLayout
            )
            let transcriptDirectory = storageLayout.transcriptDirectory
            savedHistory = pipelineHistoryStore.loadAllHistory()
            if pipelineHistoryStore.availability == .ready {
                var referenceTrust = pipelineHistoryStore.referenceTrust
                var shouldBootstrapAssetReferenceSnapshot = false
                let loadedAudioFileNames = Set(savedHistory.compactMap(\.audioFileName))
                let loadedTranscriptFileNames = Set(savedHistory.compactMap(\.transcriptFileName))
                if !pipelineHistoryStore.hadPersistentStoreAtLoad,
                   Self.hasStoredAssets(
                       audioDirectory: audioDirectory,
                       transcriptDirectory: transcriptDirectory
                   ) {
                    Self.markAssetReferencesIncomplete(
                        storageRoot: audioDirectory.deletingLastPathComponent()
                    )
                    referenceTrust = .recovered
                } else {
                    switch pipelineHistoryStore.assetReferenceSnapshotState(
                        audioFileNames: loadedAudioFileNames,
                        transcriptFileNames: loadedTranscriptFileNames
                    ) {
                    case .matches:
                        break
                    case .missing:
                        if Self.hasUnreferencedStoredAssets(
                            audioDirectory: audioDirectory,
                            transcriptDirectory: transcriptDirectory,
                            referencedAudioFileNames: loadedAudioFileNames,
                            referencedTranscriptFileNames: loadedTranscriptFileNames
                        ) {
                            Self.markAssetReferencesIncomplete(
                                storageRoot: audioDirectory.deletingLastPathComponent()
                            )
                            referenceTrust = .recovered
                        } else {
                            shouldBootstrapAssetReferenceSnapshot = true
                            referenceTrust = .unavailable
                        }
                    case .mismatch, .unavailable:
                        Self.markAssetReferencesIncomplete(
                            storageRoot: audioDirectory.deletingLastPathComponent()
                        )
                        referenceTrust = .recovered
                    }
                }
                let startupNoteAssetStore = NoteAssetStore(
                    storageLayout: storageLayout
                )
                if referenceTrust.permitsStartupReferenceCleanup {
                    var removedStoredFiles: [DeletedPipelineHistoryAssets] = []
                    do {
                        removedStoredFiles = try pipelineHistoryStore.trim(to: maxPipelineHistoryCount)
                    } catch {
                        print("Failed to trim pipeline history during init: \(error)")
                    }
                    let survivingHistory = removedStoredFiles.isEmpty
                        ? savedHistory
                        : pipelineHistoryStore.loadAllHistory()
                    let canDeleteTrimmedAssets =
                        pipelineHistoryStore.availability == .ready
                        && pipelineHistoryStore.referenceTrust
                            .permitsStartupReferenceCleanup
                    let deletableAssets = canDeleteTrimmedAssets
                        ? Self.deletableAssets(
                            removed: removedStoredFiles,
                            survivingHistory: survivingHistory
                        )
                        : []
                    let deletableAudioFileNames = Set(
                        deletableAssets.compactMap(\.audioFileName)
                    )
                    let deletableTranscriptFileNames = Set(
                        deletableAssets.compactMap(\.transcriptFileName)
                    )
                    var deletedAudioFileNames = Set<String>()
                    var deletedTranscriptFileNames = Set<String>()
                    for removedAssets in removedStoredFiles {
                        cloudTranscriptionJobStore.invalidateSession(
                            historyID: removedAssets.historyID
                        )
                        let audioFileName = removedAssets.audioFileName.flatMap {
                            deletableAudioFileNames.contains($0)
                                && deletedAudioFileNames.insert($0).inserted
                                ? $0
                                : nil
                        }
                        let transcriptFileName =
                            removedAssets.transcriptFileName.flatMap {
                                deletableTranscriptFileNames.contains($0)
                                    && deletedTranscriptFileNames.insert($0).inserted
                                    ? $0
                                    : nil
                            }
                        try? startupNoteAssetStore.deleteAssets(
                            audioFileName: audioFileName,
                            transcriptFileName: transcriptFileName
                        )
                        try? cloudTranscriptionJobStore.delete(
                            historyID: removedAssets.historyID,
                            session: nil
                        )
                    }
                    if !removedStoredFiles.isEmpty {
                        savedHistory = survivingHistory
                        referenceTrust = pipelineHistoryStore.referenceTrust
                    }
                } else {
                    print("Skipping startup history cleanup because asset references are unavailable.")
                }
                savedHistory = Self.markInterruptedRecoveryPlaceholders(
                    in: savedHistory,
                    store: pipelineHistoryStore
                )
                try? cloudTranscriptionJobStore.removeStaleTemporaryArtifacts()
                cloudReconciliation = cloudTranscriptionJobStore.reconcile(
                    history: savedHistory,
                    audioRoot: audioDirectory
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
                if shouldBootstrapAssetReferenceSnapshot {
                    _ = pipelineHistoryStore.bootstrapAssetReferenceSnapshot(
                        audioFileNames: referencedAudioFileNames,
                        transcriptFileNames: referencedTranscriptFileNames
                    )
                }
                let protectedInflightAudioFileNames = Self.protectedInflightAudioFileNames(
                    store: recordingJournalStore
                )
                if referenceTrust.permitsStartupReferenceCleanup {
                    let sweepReferenceTrust = referenceTrust
                    let sweepNow = Date()
                    Task.detached(priority: .background) {
                        startupNoteAssetStore.sweepOrphans(
                            referencedAudioFileNames: referencedAudioFileNames,
                            referencedTranscriptFileNames: referencedTranscriptFileNames,
                            protectedInflightAudioFileNames: protectedInflightAudioFileNames,
                            referenceTrust: sweepReferenceTrust,
                            now: sweepNow
                        )
                    }
                }
            } else {
                print("Skipping history startup work because persistent history is unavailable.")
            }
        } else if historyStartup.permitsUnresolvedArchiveStartup {
            Self.recoverRecordingJournalsBeforeHistoryLoad(
                recordingJournalStore: recordingJournalStore,
                historyStore: pipelineHistoryStore,
                storageLayout: storageLayout
            )
            savedHistory = pipelineHistoryStore.loadAllHistory()
            if pipelineHistoryStore.availability == .ready {
                savedHistory = Self.markInterruptedRecoveryPlaceholders(
                    in: savedHistory,
                    store: pipelineHistoryStore
                )
                try? cloudTranscriptionJobStore.removeStaleTemporaryArtifacts()
                cloudReconciliation = cloudTranscriptionJobStore.reconcile(
                    history: savedHistory,
                    audioRoot: audioDirectory
                )
                let historyStore = pipelineHistoryStore
                do {
                    savedHistory = try LegacyNoteTitleMigration.migrate(history: savedHistory) { item in
                        try historyStore.update(item)
                    }
                } catch {
                    print("Failed to migrate legacy note titles: \(error)")
                }
            }
            print("Skipping automatic archive snapshot cleanup because an archived history remains unresolved.")
        } else {
            print("Skipping history startup work because persistent history is unavailable.")
        }
        let storedInputID = AudioInputDevice.normalized(
            UserDefaults.standard.string(forKey: selectedMicrophoneStorageKey) ?? ""
        )
        let storedMicrophoneDeviceID = UserDefaults.standard.string(
            forKey: selectedMicrophoneDeviceStorageKey
        )
        let selectedMicrophoneDeviceID = AudioInputDevice.normalizedMicrophoneDeviceID(
            storedMicrophoneDeviceID
                ?? (AudioInputDevice.isMicrophoneOnly(storedInputID) ? storedInputID : nil)
        )
        let selectedMicrophoneID = AudioInputDevice.isSpecialInput(storedInputID)
            ? storedInputID
            : selectedMicrophoneDeviceID
        let shouldRestoreMutedAudio = UserDefaults.standard.bool(forKey: pendingMutedAudioRestoreStorageKey)

        self.localAIServerManager = localAIServerManager
        let localAIWorkflow = LocalAIModelWorkflow(
            dependencies: dependencies.localAI,
            serverManager: localAIServerManager
        )
        self.localAIWorkflow = localAIWorkflow
        self.contextService = Self.makeAppContextService(
            choice: contextBackendChoice,
            apiKey: apiKey,
            baseURL: apiBaseURL,
            customContextPrompt: customContextPrompt,
            contextScreenshotMaxDimension: contextScreenshotMaxDimension,
            localServerManager: localAIServerManager,
            localAIAvailability: dependencies.localAI.processingAvailability()
        )
        self.hasCompletedSetup = hasCompletedSetup
        self.transcriptionEnabled = transcriptionEnabled
        self.apiKey = apiKey
        self.apiBaseURL = apiBaseURL
        self.transcriptionAPIURL = transcriptionAPIURL
        self.transcriptionAPIKey = transcriptionAPIKey
        self.transcriptionModel = transcriptionModel
        self.postProcessingModel = postProcessingModel
        self.postProcessingFallbackModel = postProcessingFallbackModel
        self.contextModel = contextModel
        self.meetingSummaryModel = meetingSummaryModel
        self.meetingSummaryFallbackModel = meetingSummaryFallbackModel
        self.meetingSummaryOutputLanguage = meetingSummaryOutputLanguage
        self.postProcessingBackendChoice = postProcessingBackendChoice
        self.contextBackendChoice = contextBackendChoice
        self.contextModelCapabilityWarning = nil
        self.meetingSummaryBackendChoice = meetingSummaryBackendChoice
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
        self.showRealtimeTranscriptionOption = showRealtimeTranscriptionOption
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
        self.disableMeetingSummary = disableMeetingSummary
        self.noteBrowserEnabled = noteBrowserEnabled
        self.transcriptionLanguage = transcriptionLanguage
        self.outputLanguage = outputLanguage
        self.localTranscriptionModel = localTranscriptionModel
        self.soundVolume = soundVolume
        self.voiceMacros = initialMacros
        self.pipelineHistory = savedHistory
        self.isHistoryUnavailable = historyStartup.state.isHistoryUnavailable
        self.historyArchiveSafety = historyStartup.state.archiveSafety
        self.historyRecoverySnapshots = historyStartup.state.snapshots
        self.historyPersistenceWarning = historyStartup.state.showsPersistenceWarning
            ? QuillUserIssueRecord(code: .historyPersistenceUnavailable)
            : nil
        self.hasAccessibility = initialAccessibility
        self.hasScreenRecordingPermission = initialScreenCapturePermission
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.selectedMicrophoneDeviceID = selectedMicrophoneDeviceID
        self.selectedMicrophoneID = selectedMicrophoneID
        UserDefaults.standard.set(
            selectedMicrophoneDeviceID,
            forKey: selectedMicrophoneDeviceStorageKey
        )
        scheduleNoteBrowserTranscriptionModeNormalizationForSelectedInput()
        self.precomputeMacros()
        transcriptionRetryWorkflow.onEvent = { [weak self] event in
            self?.applyTranscriptionRetryWorkflowEvent(event)
        }
        self.nativeWhisperWorkflow.onEvent = { [weak self] event in
            self?.applyNativeWhisperModelWorkflowEvent(event)
        }
        self.localAIWorkflow.onEvent = { [weak self] event in
            self?.applyLocalAIModelWorkflowEvent(event)
        }
        if let cloudReconciliation {
            let cloudDependenciesFactory = dependencies
                .makeRetryCloudTranscriptionDependencies
            let postProcessingService = makePostProcessingService()
            let capturedVoiceMacros = initialMacros
            Task { @MainActor [weak self] in
                self?.scheduleCloudTranscriptionAutoResume(
                    cloudReconciliation,
                    cloudDependenciesFactory: cloudDependenciesFactory,
                    postProcessingService: postProcessingService,
                    voiceMacros: capturedVoiceMacros
                )
            }
        }

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

        historyWorkflow.onEvent = { [weak self] event in
            self?.applyHistoryWorkflowEvent(event)
        }
        meetingSummaryWorkflow.onEvent = { [weak self] event in
            self?.applyMeetingSummaryWorkflowEvent(event)
        }

        overlayManager.onStopButtonPressed = { [weak self] in
            DispatchQueue.main.async {
                self?.handleOverlayStopButtonPressed()
            }
        }
        overlayManager.onSelectInput = { [weak self] sourceID in
            DispatchQueue.main.async {
                self?.selectAudioSource(withID: sourceID)
            }
        }
        Task { @MainActor [weak self] in
            self?.meetingReminderOverlayManager.onStart = { [weak self] schedule in
                guard let self else { return }
                self.activeRecordingCalendarSnapshot = RecordingCalendarSnapshot(
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
                self.startRecordingFromCalendarReminder()
            }
        }

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                refreshAllLocalAIInstallStates()
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    refreshAllLocalAIInstallStates()
                }
            }
        }
    }

    deinit {
        removeAudioDeviceObservers()
    }

    @MainActor
    func startLocalAIIdleShutdownMonitoring() {
        localAIWorkflow.startIdleShutdownMonitoring()
    }

    @MainActor
    func stopLocalAIIdleShutdownMonitoring() {
        localAIWorkflow.stopIdleShutdownMonitoring()
    }

    @MainActor
    func localAIInstallState(
        for model: LocalAIModel
    ) -> LocalAIModelInstallViewState {
        localAIWorkflow.installState(for: model)
    }

    @MainActor
    func refreshAllLocalAIInstallStates() {
        localAIWorkflow.refreshAllInstallStates()
    }

    @MainActor
    func waitForLocalAIInstallStateRefresh() async {
        await localAIWorkflow.waitForInitialStatusRefresh()
    }

    @MainActor
    func waitForLocalAIInstallsToQuiesce() async {
        await localAIWorkflow.waitForInstallsToQuiesce()
    }

    @MainActor
    private func initializeMeetingSummarySettingsIfNeeded() {
        guard !UserDefaults.standard.bool(
            forKey: meetingSummarySettingsInitializedStorageKey
        ) else {
            return
        }

        if let readyChoice = readyAIProcessingChoice(
            preferred: meetingSummaryBackendChoice,
            for: .meetingSummary
        ) {
            applyAIProcessingChoice(readyChoice, for: .meetingSummary)
            disableMeetingSummary = false
        } else {
            disableMeetingSummary = true
        }
        UserDefaults.standard.set(
            true,
            forKey: meetingSummarySettingsInitializedStorageKey
        )
    }

    @MainActor
    private func applyLocalAIModelWorkflowEvent(
        _ event: LocalAIModelWorkflowEvent
    ) {
        switch event {
        case .stateChanged(let state):
            localAIInstallStates = state.installStates

        case .installOutcome(let model, let outcome):
            switch outcome {
            case .readyAndAvailable:
                applyReadyLocalAIModelToWaitingFeatures(model)
            case .succeededButUnavailable, .cancelled, .failed:
                clearPendingLocalAISelections(forModelID: model.id)
            }

        case .deletionOutcome:
            break

        case .initialStatusRefreshCompleted(let deferredModelIDs):
            normalizeAIProcessingChoices()
            initializeMeetingSummarySettingsIfNeeded()
            resumeDeferredLocalAIRequests(deferredModelIDs: deferredModelIDs)
        }
    }

    @MainActor
    private func resumeDeferredLocalAIRequests(deferredModelIDs: Set<String>) {
        let pendingModelIDs = Set(pendingLocalAISelections.values)
        for modelID in pendingModelIDs {
            guard let model = LocalAIModelCatalog.model(id: modelID),
                  !localAIWorkflow.isDeletionRequested(modelID) else {
                clearPendingLocalAISelections(forModelID: modelID)
                continue
            }
            guard isLocalAIModelAvailable(model) else {
                clearPendingLocalAISelections(forModelID: modelID)
                localAIWorkflow.markUnavailable(model)
                continue
            }
            if localAIInstallState(for: model).status == .ready {
                applyReadyLocalAIModelToWaitingFeatures(model)
            }
        }

        for modelID in deferredModelIDs {
            guard let model = LocalAIModelCatalog.model(id: modelID),
                  !localAIWorkflow.isDeletionRequested(modelID) else {
                clearPendingLocalAISelections(forModelID: modelID)
                continue
            }
            guard isLocalAIModelAvailable(model) else {
                clearPendingLocalAISelections(forModelID: modelID)
                localAIWorkflow.markUnavailable(model)
                continue
            }
            if localAIInstallState(for: model).status == .ready {
                applyReadyLocalAIModelToWaitingFeatures(model)
            } else {
                localAIWorkflow.startInstall(model)
            }
        }
    }

    @MainActor
    func currentAIProcessingChoice(
        for feature: AIProcessingFeature
    ) -> AIProcessingBackendChoice {
        switch feature {
        case .postProcessing: return postProcessingBackendChoice
        case .context: return contextBackendChoice
        case .meetingSummary: return meetingSummaryBackendChoice
        }
    }

    @MainActor
    private func applyAIProcessingChoice(
        _ choice: AIProcessingBackendChoice,
        for feature: AIProcessingFeature
    ) {
        guard currentAIProcessingChoice(for: feature) != choice else { return }
        switch feature {
        case .postProcessing:
            postProcessingBackendChoice = choice
        case .context:
            contextBackendChoice = choice
        case .meetingSummary:
            meetingSummaryBackendChoice = choice
        }
    }

    @MainActor
    private func setPendingLocalAIModelID(
        _ modelID: String?,
        for feature: AIProcessingFeature
    ) {
        guard pendingLocalAISelections[feature] != modelID else { return }
        if let modelID {
            pendingLocalAISelections[feature] = modelID
        } else {
            pendingLocalAISelections.removeValue(forKey: feature)
        }
    }

    @MainActor
    private func clearPendingLocalAISelections(forModelID modelID: String) {
        let filtered = pendingLocalAISelections.filter { $0.value != modelID }
        guard filtered != pendingLocalAISelections else { return }
        pendingLocalAISelections = filtered
    }

    @MainActor
    private func waitingFeatures(for model: LocalAIModel) -> [AIProcessingFeature] {
        pendingLocalAISelections.compactMap {
            $0.value == model.id ? $0.key : nil
        }
    }

    @MainActor
    func selectedOrPendingLocalAIModel(
        for feature: AIProcessingFeature
    ) -> LocalAIModel? {
        let currentChoice = currentAIProcessingChoice(for: feature)
        let modelID = pendingLocalAISelections[feature]
            ?? (currentChoice.isLocal ? currentChoice.modelID : nil)
        return modelID.flatMap(LocalAIModelCatalog.model(id:))
    }

    @MainActor
    func pendingLocalAIModelID(
        for feature: AIProcessingFeature
    ) -> String? {
        pendingLocalAISelections[feature]
    }

    @MainActor
    func discardPendingLocalAISelection(for feature: AIProcessingFeature) {
        setPendingLocalAIModelID(nil, for: feature)
    }

    @MainActor
    func discardUndownloadedLocalAISelections() {
        let retainedSelections = pendingLocalAISelections.filter { _, modelID in
            guard let model = LocalAIModelCatalog.model(id: modelID) else {
                return false
            }
            let state = localAIInstallState(for: model)
            return state.isInstalling
                || state.progress.isCancelled
                || state.issue != nil
        }
        guard retainedSelections != pendingLocalAISelections else { return }
        pendingLocalAISelections = retainedSelections
    }

    @MainActor
    func commitModelSettingsDrafts(
        transcriptionEnabled requestedTranscriptionEnabled: Bool,
        transcriptionChoice: TranscriptionBackendChoice,
        postProcessingEnabled requestedPostProcessingEnabled: Bool,
        postProcessingChoice: AIProcessingBackendChoice,
        contextEnabled requestedContextEnabled: Bool,
        contextChoice: AIProcessingBackendChoice,
        meetingSummaryEnabled requestedMeetingSummaryEnabled: Bool,
        meetingSummaryChoice: AIProcessingBackendChoice
    ) {
        discardUndownloadedLocalAISelections()

        if requestedTranscriptionEnabled,
           let readyChoice = readyNoteBrowserTranscriptionChoice(
                preferred: transcriptionChoice
           ) {
            applyNoteBrowserTranscriptionChoice(readyChoice)
            transcriptionEnabled = true
        } else {
            transcriptionEnabled = false
        }

        commitAIProcessingSettingsDraft(
            feature: .postProcessing,
            isEnabled: requestedPostProcessingEnabled,
            preferredChoice: postProcessingChoice
        )
        commitAIProcessingSettingsDraft(
            feature: .context,
            isEnabled: requestedContextEnabled,
            preferredChoice: contextChoice
        )
        commitAIProcessingSettingsDraft(
            feature: .meetingSummary,
            isEnabled: requestedMeetingSummaryEnabled,
            preferredChoice: meetingSummaryChoice
        )
    }

    @MainActor
    func reconcileModelSelectionsAfterSettingsDismissal() {
        commitModelSettingsDrafts(
            transcriptionEnabled: transcriptionEnabled,
            transcriptionChoice: currentNoteBrowserTranscriptionChoice,
            postProcessingEnabled: !disablePostProcessing,
            postProcessingChoice: postProcessingBackendChoice,
            contextEnabled: !disableContextCapture,
            contextChoice: contextBackendChoice,
            meetingSummaryEnabled: !disableMeetingSummary,
            meetingSummaryChoice: meetingSummaryBackendChoice
        )
    }

    @MainActor
    private func setAIProcessingFeatureEnabled(
        _ isEnabled: Bool,
        for feature: AIProcessingFeature
    ) {
        switch feature {
        case .postProcessing:
            disablePostProcessing = !isEnabled
        case .context:
            disableContextCapture = !isEnabled
        case .meetingSummary:
            disableMeetingSummary = !isEnabled
        }
    }

    @MainActor
    private func updateContextModelCapabilityWarning(
        for choice: AIProcessingBackendChoice? = nil
    ) {
        let choice = choice ?? contextBackendChoice
        guard !isAIProcessingChoiceCompatible(choice, for: .context) else {
            contextModelCapabilityWarning = nil
            return
        }
        contextModelCapabilityWarning = [
            localizedCatalogString("This model does not support screen Context."),
            localizedCatalogString("Choose an image-capable model to enable Context.")
        ].joined(separator: " ")
    }

    @MainActor
    private func commitAIProcessingSettingsDraft(
        feature: AIProcessingFeature,
        isEnabled: Bool,
        preferredChoice: AIProcessingBackendChoice
    ) {
        guard isEnabled,
              isAIProcessingChoiceCompatible(preferredChoice, for: feature),
              let readyChoice = readyAIProcessingChoice(
                preferred: preferredChoice,
                for: feature
              ) else {
            setAIProcessingFeatureEnabled(false, for: feature)
            if feature == .context { updateContextModelCapabilityWarning() }
            return
        }

        applyAIProcessingChoice(readyChoice, for: feature)
        setAIProcessingFeatureEnabled(true, for: feature)
        if feature == .context { updateContextModelCapabilityWarning() }
    }

    @MainActor
    func isLocalAIModelAvailable(_ model: LocalAIModel) -> Bool {
        guard localAIWorkflow.canonicalModel(for: model) != nil else {
            return false
        }
        return localAIWorkflow.isModelAvailable(model)
    }

    @MainActor
    func isAIProcessingChoiceAvailable(
        _ choice: AIProcessingBackendChoice,
        for feature: AIProcessingFeature
    ) -> Bool {
        guard isAIProcessingChoiceCompatible(choice, for: feature) else {
            return false
        }
        switch choice {
        case .cloud:
            return true
        case .localAI(let modelID):
            guard let model = LocalAIModelCatalog.model(id: modelID) else {
                return false
            }
            return isLocalAIModelAvailable(model)
        }
    }

    @MainActor
    func isAIProcessingBackendReady(
        for feature: AIProcessingFeature
    ) -> Bool {
        isAIProcessingChoiceReady(
            currentAIProcessingChoice(for: feature),
            for: feature
        )
    }

    @MainActor
    func isAIProcessingChoiceReady(
        _ choice: AIProcessingBackendChoice,
        for feature: AIProcessingFeature
    ) -> Bool {
        guard isAIProcessingChoiceCompatible(choice, for: feature) else {
            return false
        }
        switch choice {
        case .cloud:
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .localAI(let modelID):
            guard localAIWorkflow.state.hasCompletedInitialStatusRefresh,
                  let model = LocalAIModelCatalog.model(id: modelID),
                  isLocalAIModelAvailable(model) else {
                return false
            }
            return localAIInstallState(for: model).status == .ready
        }
    }

    @MainActor
    private func readyAIProcessingChoice(
        preferred: AIProcessingBackendChoice? = nil,
        for feature: AIProcessingFeature
    ) -> AIProcessingBackendChoice? {
        if let preferred {
            guard isAIProcessingChoiceCompatible(preferred, for: feature) else {
                return nil
            }
            if case .localAI(let modelID) = preferred,
               let model = LocalAIModelCatalog.model(id: modelID),
               !isLocalAIModelAvailable(model) {
                return nil
            }
            if isAIProcessingChoiceReady(preferred, for: feature) {
                return preferred
            }
        }
        let currentChoice = currentAIProcessingChoice(for: feature)
        guard isAIProcessingChoiceCompatible(currentChoice, for: feature) else {
            return nil
        }
        if case .localAI(let modelID) = currentChoice,
           let model = LocalAIModelCatalog.model(id: modelID),
           !isLocalAIModelAvailable(model) {
            return nil
        }
        if isAIProcessingChoiceReady(currentChoice, for: feature) {
            return currentChoice
        }

        let availability = dependencies.localAI.processingAvailability()
        if localAIWorkflow.state.hasCompletedInitialStatusRefresh, availability.isSupported {
            let readyModels = availability.availableModels.filter {
                $0.capabilities.supports(feature.modelFeature)
                    && (feature != .context || $0.capabilities.modalities.contains(.image))
                    && localAIInstallState(for: $0).status == .ready
            }
            let preferredModel = availability.recommendedModel.flatMap { recommended in
                readyModels.first { $0.id == recommended.id }
            } ?? readyModels.first
            if let preferredModel {
                return .localAI(modelID: preferredModel.id)
            }
        }

        if preferred?.isLocal == true || (preferred == nil && currentChoice.isLocal) {
            return nil
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let cloudChoice = AIProcessingBackendChoice.cloud(
            modelID: resolvedCloudModelID(for: feature)
        )
        return isAIProcessingChoiceCompatible(cloudChoice, for: feature)
            ? cloudChoice
            : nil
    }

    @MainActor
    private func unavailableLocalAIChoiceDisplay(
        for feature: AIProcessingFeature
    ) -> AIProcessingChoiceDisplay? {
        let choice = currentAIProcessingChoice(for: feature)
        guard case .localAI(let modelID) = choice else {
            return nil
        }
        let model = LocalAIModelCatalog.model(id: modelID)
        guard model == nil || !isLocalAIModelAvailable(model!) else {
            return nil
        }

        let unavailableReason: String
        let title: String
        if let model {
            title = model.displayName
            unavailableReason = localizedCatalogString(
                "This on-device model is unavailable and cannot be used on this Mac."
            )
        } else if modelID == "qwen2.5-1.5b-instruct" {
            title = "Qwen2.5 1.5B Instruct"
            unavailableReason = localizedCatalogString(
                "This on-device model is no longer available and cannot be used."
            )
        } else {
            title = localizedCatalogString("Previously selected on-device model")
            switch feature {
            case .context:
                unavailableReason = localizedCatalogString(
                    "The previously selected on-device model is no longer available. Context requires an image-capable model."
                )
            case .postProcessing, .meetingSummary:
                unavailableReason = localizedCatalogString(
                    "The previously selected on-device model is no longer available. Explicitly select Qwen2.5 7B to continue locally."
                )
            }
        }
        return AIProcessingChoiceDisplay(
            choice: choice,
            section: "On This Mac",
            title: title,
            subtitle: unavailableReason,
            isAvailable: false,
            unavailableReason: unavailableReason,
            isRecommended: false
        )
    }

    @MainActor
    func aiProcessingChoiceDisplays(
        for feature: AIProcessingFeature
    ) -> [AIProcessingChoiceDisplay] {
        let rememberedCloudModel = resolvedCloudModelID(for: feature)
        var cloudModelIDs: [String] = []
        for modelID in ModelConfiguration.llmModels + [rememberedCloudModel] {
            if !modelID.isEmpty, !cloudModelIDs.contains(modelID) {
                cloudModelIDs.append(modelID)
            }
        }
        let cloudDisplays = cloudModelIDs.compactMap { modelID -> AIProcessingChoiceDisplay? in
            let choice = AIProcessingBackendChoice.cloud(modelID: modelID)
            guard isAIProcessingChoiceCompatible(choice, for: feature) else {
                return nil
            }
            return AIProcessingChoiceDisplay(
                choice: choice,
                section: "Cloud",
                title: modelID,
                subtitle: nil,
                isAvailable: true,
                unavailableReason: nil,
                isRecommended: false
            )
        }

        let unavailableLocalDisplays = unavailableLocalAIChoiceDisplay(
            for: feature
        ).map { [$0] } ?? []
        let availability = dependencies.localAI.processingAvailability()
        let localDisplays = LocalAIModelCatalog.all.compactMap {
            model -> AIProcessingChoiceDisplay? in
            let choice = AIProcessingBackendChoice.localAI(modelID: model.id)
            guard isAIProcessingChoiceCompatible(choice, for: feature),
                  availability.isModelSupported(model) else {
                return nil
            }
            return AIProcessingChoiceDisplay(
                choice: choice,
                section: "On This Mac",
                title: model.displayName,
                subtitle: ByteCountFormatter.string(
                    fromByteCount: model.approximateBytes,
                    countStyle: .file
                ),
                isAvailable: true,
                unavailableReason: nil,
                isRecommended: model.id == availability.recommendedModel?.id
            )
        }
        return cloudDisplays + unavailableLocalDisplays + localDisplays
    }

    @MainActor
    func selectAIProcessingBackendChoice(
        _ choice: AIProcessingBackendChoice,
        for feature: AIProcessingFeature
    ) {
        guard isAIProcessingChoiceCompatible(choice, for: feature) else {
            if feature == .context {
                disableContextCapture = true
                updateContextModelCapabilityWarning(for: choice)
            }
            return
        }
        switch choice {
        case .cloud(let modelID):
            setPendingLocalAIModelID(nil, for: feature)
            switch feature {
            case .postProcessing:
                if postProcessingModel != modelID {
                    postProcessingModel = modelID
                }
            case .context:
                if contextModel != modelID {
                    contextModel = modelID
                }
            case .meetingSummary:
                if meetingSummaryModel != modelID {
                    meetingSummaryModel = modelID
                }
            }
            applyAIProcessingChoice(choice, for: feature)

        case .localAI(let modelID):
            guard let model = LocalAIModelCatalog.model(id: modelID),
                  isLocalAIModelAvailable(model),
                  !localAIWorkflow.isDeletionRequested(modelID) else {
                return
            }
            guard localAIWorkflow.state.hasCompletedInitialStatusRefresh else {
                setPendingLocalAIModelID(modelID, for: feature)
                return
            }
            if localAIInstallState(for: model).status == .ready {
                setPendingLocalAIModelID(nil, for: feature)
                applyAIProcessingChoice(choice, for: feature)
            } else {
                setPendingLocalAIModelID(modelID, for: feature)
            }
        }
    }

    @MainActor
    func installLocalAIModel(
        _ model: LocalAIModel,
        autoSelectFor feature: AIProcessingFeature? = nil
    ) {
        guard !isModelTerminationCleanupPending,
              let canonicalModel = localAIWorkflow.canonicalModel(for: model),
              localAIWorkflow.isModelAvailable(canonicalModel),
              !localAIWorkflow.isDeletionRequested(model.id) else {
            return
        }
        if let feature {
            let choice = AIProcessingBackendChoice.localAI(modelID: canonicalModel.id)
            if isAIProcessingChoiceCompatible(choice, for: feature) {
                setPendingLocalAIModelID(model.id, for: feature)
            } else if feature == .context {
                disableContextCapture = true
                updateContextModelCapabilityWarning(for: choice)
            }
        }
        localAIWorkflow.startInstall(canonicalModel)
    }

    @MainActor
    private func applyReadyLocalAIModelToWaitingFeatures(_ model: LocalAIModel) {
        guard isLocalAIModelAvailable(model),
              localAIInstallState(for: model).status == .ready else {
            clearPendingLocalAISelections(forModelID: model.id)
            localAIWorkflow.markUnavailable(model)
            return
        }
        let choice = AIProcessingBackendChoice.localAI(modelID: model.id)
        for feature in waitingFeatures(for: model) {
            setPendingLocalAIModelID(nil, for: feature)
            guard isAIProcessingChoiceCompatible(choice, for: feature) else {
                setAIProcessingFeatureEnabled(false, for: feature)
                if feature == .context {
                    updateContextModelCapabilityWarning(for: choice)
                }
                continue
            }
            applyAIProcessingChoice(choice, for: feature)
        }
    }

    @MainActor
    func cancelPendingLocalAISelection(
        for feature: AIProcessingFeature
    ) {
        setPendingLocalAIModelID(nil, for: feature)
    }

    @MainActor
    func cancelLocalAIInstall(_ model: LocalAIModel) {
        guard localAIWorkflow.cancelInstall(model) else { return }
        clearPendingLocalAISelections(forModelID: model.id)
    }

    @MainActor
    private func normalizedAIProcessingChoice(
        _ choice: AIProcessingBackendChoice,
        for feature: AIProcessingFeature
    ) -> AIProcessingBackendChoice? {
        guard isAIProcessingChoiceCompatible(choice, for: feature) else {
            return nil
        }
        switch choice {
        case .cloud:
            return choice
        case .localAI(let modelID):
            guard let selectedModel = LocalAIModelCatalog.model(id: modelID) else {
                return nil
            }
            let availability = dependencies.localAI.processingAvailability()
            guard availability.isModelSupported(selectedModel) else {
                return nil
            }
            if localAIInstallState(for: selectedModel).status == .ready {
                return choice
            }
            let installed = availability.availableModels.filter {
                localAIInstallState(for: $0).status == .ready
            }
            let preferred = availability.recommendedModel.flatMap { recommended in
                installed.first { $0.id == recommended.id }
            } ?? installed.first
            if let preferred {
                return .localAI(modelID: preferred.id)
            }
            return nil
        }
    }

    @MainActor
    private func normalizeAIProcessingChoices() {
        guard localAIWorkflow.state.hasCompletedInitialStatusRefresh else { return }
        for feature in AIProcessingFeature.allCases {
            let current = currentAIProcessingChoice(for: feature)
            guard isAIProcessingChoiceCompatible(current, for: feature) else {
                setAIProcessingFeatureEnabled(false, for: feature)
                if feature == .context { updateContextModelCapabilityWarning() }
                continue
            }
            if feature == .context { updateContextModelCapabilityWarning() }
            if let normalized = normalizedAIProcessingChoice(
                current,
                for: feature
            ) {
                if normalized != current {
                    applyAIProcessingChoice(normalized, for: feature)
                }
                continue
            }

            if current.isLocal {
                setAIProcessingFeatureEnabled(false, for: feature)
                continue
            }

            let rememberedCloudModel = resolvedCloudModelID(for: feature)
            applyAIProcessingChoice(
                .cloud(modelID: rememberedCloudModel),
                for: feature
            )
            setAIProcessingFeatureEnabled(false, for: feature)
        }
    }

    @MainActor
    func deleteLocalAIModel(_ model: LocalAIModel) {
        guard localAIWorkflow.deleteModel(model) else { return }
        clearPendingLocalAISelections(forModelID: model.id)
    }

    private func removeAudioDeviceObservers() {
        let notificationCenter = NotificationCenter.default
        for observer in audioDeviceObservers {
            notificationCenter.removeObserver(observer)
        }
        audioDeviceObservers.removeAll()

        if let defaultInputDeviceListener, var defaultInputDeviceListenerAddress {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultInputDeviceListenerAddress,
                DispatchQueue.main,
                defaultInputDeviceListener
            )
        }
        defaultInputDeviceListener = nil
        defaultInputDeviceListenerAddress = nil
    }

    private static func loadStoredAPIKey(
        account: String,
        credentialStore: CredentialStore
    ) -> String {
        if let storedKey = credentialStore.load(account: account), !storedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return storedKey
        }
        return ""
    }

    private func persistAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        persistCredential(prefix: "Unable to save API key") {
            if trimmed.isEmpty {
                try credentialStore.delete(account: apiKeyStorageKey)
            } else {
                try credentialStore.save(trimmed, account: apiKeyStorageKey)
            }
        }
    }

    private func persistCredential(
        prefix: String,
        _ operation: () throws -> Void
    ) {
        do {
            try operation()
        } catch {
            errorMessage = LocalizedUserMessage.providerFailure(
                prefix: localizedCatalogString(prefix),
                providerDetail: error.localizedDescription
            )
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

    private static func loadStoredAPIBaseURL(
        account: String,
        credentialStore: CredentialStore
    ) -> String {
        if let stored = credentialStore.load(account: account), !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

    static func makeAIProcessingBackendExecutor(
        choice: AIProcessingBackendChoice,
        apiKey: String,
        baseURL: String,
        localServerManager: LocalAIServerManager,
        localAIAvailability: LocalAIProcessingAvailability
    ) -> AIProcessingBackendExecutor {
        AIProcessingBackendExecutor(
            choice: choice,
            cloudBaseURL: baseURL,
            cloudAPIKey: apiKey,
            localServerManager: localServerManager,
            localAIAvailability: localAIAvailability
        )
    }

    func makeAIProcessingBackendExecutor(
        choice: AIProcessingBackendChoice
    ) -> AIProcessingBackendExecutor {
        Self.makeAIProcessingBackendExecutor(
            choice: choice,
            apiKey: apiKey,
            baseURL: apiBaseURL,
            localServerManager: localAIServerManager,
            localAIAvailability: dependencies.localAI.processingAvailability()
        )
    }

    @MainActor
    private func meetingSummaryGeneratorConfiguration()
        -> MeetingSummaryGeneratorConfiguration
    {
        MeetingSummaryGeneratorConfiguration(
            backendExecutor: makeAIProcessingBackendExecutor(
                choice: meetingSummaryBackendChoice
            ),
            cloudFallbackModelID: meetingSummaryBackendChoice.isLocal
                ? nil
                : meetingSummaryFallbackModel
        )
    }

    static func makePostProcessingService(
        choice: AIProcessingBackendChoice,
        apiKey: String,
        baseURL: String,
        cloudFallbackModelID: String,
        instructionExecutionGuardEnabled: Bool,
        localServerManager: LocalAIServerManager,
        localAIAvailability: LocalAIProcessingAvailability
    ) -> PostProcessingService {
        PostProcessingService(
            backendExecutor: makeAIProcessingBackendExecutor(
                choice: choice,
                apiKey: apiKey,
                baseURL: baseURL,
                localServerManager: localServerManager,
                localAIAvailability: localAIAvailability
            ),
            cloudFallbackModelID: choice.isLocal ? nil : cloudFallbackModelID,
            instructionExecutionGuardEnabled: instructionExecutionGuardEnabled,
            transport: postProcessingTransport
        )
    }

    func makePostProcessingService(
        choice: AIProcessingBackendChoice? = nil
    ) -> PostProcessingService {
        Self.makePostProcessingService(
            choice: choice ?? postProcessingBackendChoice,
            apiKey: apiKey,
            baseURL: apiBaseURL,
            cloudFallbackModelID: postProcessingFallbackModel,
            instructionExecutionGuardEnabled: instructionExecutionGuardEnabled,
            localServerManager: localAIServerManager,
            localAIAvailability: dependencies.localAI.processingAvailability()
        )
    }

    static func makeAppContextService(
        choice: AIProcessingBackendChoice,
        apiKey: String,
        baseURL: String,
        customContextPrompt: String,
        contextScreenshotMaxDimension: Int,
        localServerManager: LocalAIServerManager,
        localAIAvailability: LocalAIProcessingAvailability
    ) -> AppContextService {
        AppContextService(
            backendExecutor: makeAIProcessingBackendExecutor(
                choice: choice,
                apiKey: apiKey,
                baseURL: baseURL,
                localServerManager: localServerManager,
                localAIAvailability: localAIAvailability
            ),
            customContextPrompt: customContextPrompt,
            contextModel: choice.modelID,
            screenshotMaxDimension: CGFloat(
                normalizedContextScreenshotMaxDimension(
                    contextScreenshotMaxDimension
                )
            )
        )
    }

    func makeAppContextService(
        choice: AIProcessingBackendChoice? = nil
    ) -> AppContextService {
        Self.makeAppContextService(
            choice: choice ?? contextBackendChoice,
            apiKey: apiKey,
            baseURL: apiBaseURL,
            customContextPrompt: customContextPrompt,
            contextScreenshotMaxDimension: contextScreenshotMaxDimension,
            localServerManager: localAIServerManager,
            localAIAvailability: dependencies.localAI.processingAvailability()
        )
    }

    private func rebuildContextService() {
        contextService = makeAppContextService()
    }

    private func persistAPIBaseURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        persistCredential(prefix: "Unable to save API base URL") {
            if trimmed.isEmpty || trimmed == Self.defaultAPIBaseURL {
                try credentialStore.delete(account: apiBaseURLStorageKey)
            } else {
                try credentialStore.save(trimmed, account: apiBaseURLStorageKey)
            }
        }
    }

    private func persistOptionalAPIValue(_ value: String, account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        persistCredential(prefix: "Unable to save the provider value") {
            if trimmed.isEmpty {
                try credentialStore.delete(account: account)
            } else {
                try credentialStore.save(trimmed, account: account)
            }
        }
    }

    private static func loadOptionalStoredAPIValue(
        account: String,
        credentialStore: CredentialStore
    ) -> String {
        let stored = credentialStore.load(account: account) ?? ""
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
            transcriptionModel: transcriptionModel,
            nativeWhisperExecution: nativeWhisperExecutionSnapshot(
                useLocalTranscription: useLocalTranscription,
                localTranscriptionModel: localTranscriptionModel,
                useLegacyMlxWhisper: useLegacyMlxWhisper
            )
        )
    }

    private func nativeWhisperExecutionSnapshot(
        for choice: TranscriptionBackendChoice
    ) -> NativeWhisperExecutionSnapshot? {
        guard case .nativeWhisper = choice else { return nil }
        return dependencies.nativeWhisper.makeExecutionSnapshot()
    }

    private func nativeWhisperExecutionSnapshot(
        useLocalTranscription: Bool,
        localTranscriptionModel: TranscriptionModel,
        useLegacyMlxWhisper: Bool
    ) -> NativeWhisperExecutionSnapshot? {
        guard useLocalTranscription,
              !localTranscriptionModel.isAppleSpeech,
              !useLegacyMlxWhisper else {
            return nil
        }
        return dependencies.nativeWhisper.makeExecutionSnapshot()
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

    private enum StoppedAudioRecording {
        case transcribable(fileURL: URL, recoverableJournalID: UUID?)
        case recoveredWithoutTranscription(RecoveredRecordingArtifact)
        case preservedForRecovery(recordingID: UUID, message: String)
        case empty
    }

    private enum StoppedRecordingCompletion {
        case transcriptionJob(UUID)
        case audioOnly(UUID)
    }

    enum MCPStopRecordingOutcome {
        case notRecording
        case transcribing
        case savingAudioOnly
    }

    func openHistoryDataFolder() {
        NSWorkspace.shared.open(storageLayout.rootDirectory)
    }

    func openHistoryRecoveryFolder() {
        NSWorkspace.shared.open(
            storageLayout.rootDirectory.appendingPathComponent("Recovery", isDirectory: true)
        )
    }

    @MainActor
    private func applyMeetingSummaryWorkflowEvent(
        _ event: MeetingSummaryWorkflowEvent
    ) {
        switch event {
        case .stateChanged(let state):
            applyMeetingSummaryWorkflowState(state)
        case .itemPersisted(let item):
            guard let index = pipelineHistory.firstIndex(where: {
                $0.id == item.id
            }) else { return }
            pipelineHistory[index] = item
        }
    }

    @MainActor
    private func applyMeetingSummaryWorkflowState(
        _ state: MeetingSummaryWorkflowState
    ) {
        meetingSummaryGeneratingNoteIDs = state.generatingNoteIDs
    }

    @MainActor
    private func applyTranscriptionRetryWorkflowEvent(
        _ event: TranscriptionRetryWorkflowEvent
    ) {
        switch event {
        case .stateChanged(let state):
            applyTranscriptionRetryWorkflowState(state)

        case .itemPersisted(let item, let effects):
            if let index = pipelineHistory.firstIndex(where: {
                $0.id == item.id
            }) {
                pipelineHistory[index] = item
            }
            if effects.advancesWarningGeneration {
                incrementNoteRetryGeneration(for: item.id)
            }
            if effects.invalidatesMeetingSummary {
                meetingSummaryWorkflow.invalidate(noteID: item.id)
            }

        case .completed(_, let outcome):
            switch outcome {
            case .succeeded(let completion), .fallback(let completion):
                if let transcript = completion.interactiveTranscript {
                    copyRetryTranscriptToPasteboardIfNeeded(transcript)
                }
                if let cleanupFailureDescription =
                    completion.cleanupFailureDescription
                {
                    errorMessage = LocalizedUserMessage.providerFailure(
                        prefix: localizedCatalogString(
                            "Unable to finish cloud transcription"
                        ),
                        providerDetail: cleanupFailureDescription
                    )
                }

            case .persistenceFailed(let issue):
                errorMessage = issue.presentation().compactMessage

            case .failed, .cancelled, .stale:
                break
            }
        }
    }

    @MainActor
    private func applyTranscriptionRetryWorkflowState(
        _ state: TranscriptionRetryWorkflowState
    ) {
        retryingItemIDs.subtract(transcriptionRetryWorkflowItemIDs)
        retryingItemIDs.formUnion(state.retryingNoteIDs)
        transcriptionRetryWorkflowItemIDs = state.retryingNoteIDs

        for noteID in transcriptionRetryWorkflowProgressIDs {
            cloudTranscriptionProgressByHistoryID.removeValue(forKey: noteID)
        }
        cloudTranscriptionProgressByHistoryID.merge(
            state.progressByNoteID,
            uniquingKeysWith: { _, workflowProgress in workflowProgress }
        )
        transcriptionRetryWorkflowProgressIDs = Set(
            state.progressByNoteID.keys
        )
    }

    @MainActor
    private func applyHistoryWorkflowEvent(
        _ event: HistoryWorkflowEvent
    ) {
        switch event {
        case .stateChanged(let state):
            applyHistoryWorkflowState(state)
        case .installRuntime(let replacement):
            applyHistoryRuntimeReplacement(replacement)
        case .failed(let failure):
            applyHistoryWorkflowFailure(failure)
        case .performPostAction(let postAction):
            if postAction == .openRecovery {
                openHistoryRecoverySettings()
            }
        }
    }

    @MainActor
    private func applyHistoryWorkflowState(
        _ state: HistoryWorkflowState
    ) {
        historyArchiveSafety = state.archiveSafety
        isHistoryArchiveTransitioning = state.archiveActivity != .idle
        historyRecoverySnapshots = state.snapshots
        historyRecoveryInspections = state.inspections
        historyRecoveryInspectionSnapshotID = state.inspectionSnapshotID
        isHistoryRecoveryOperationInProgress =
            state.recoveryOperation != .idle
        historyRecoveryOperationMessage = recoveryOperationMessage(
            for: state.recoveryOperation
        )
        historyRecoveryImportResult = state.importResult
        isHistoryUnavailable = state.isHistoryUnavailable
        historyPersistenceWarning = state.showsPersistenceWarning
            ? QuillUserIssueRecord(code: .historyPersistenceUnavailable)
            : nil
    }

    @MainActor
    private func applyHistoryRuntimeReplacement(
        _ replacement: HistoryRuntimeReplacement
    ) {
        switch replacement {
        case .fresh(let runtime):
            transcriptionRetryWorkflow.forgetAll()
            pipelineHistoryStore = runtime.historyStore
            recordingJournalStore = runtime.recordingJournalStore
            cloudTranscriptionJobStore = runtime.cloudTranscriptionJobStore
            pipelineHistory = []
            retryingItemIDs = []
            pendingAudioImportJobIDs = []
            cloudTranscriptionProgressByHistoryID = [:]
            meetingSummaryWorkflow.forgetAll()
            forgetAllWarningBannerState()
        case .recovered(let historyStore, let history):
            pipelineHistoryStore = historyStore
            pipelineHistory = history
        }
    }

    @MainActor
    private func recoveryOperationMessage(
        for operation: HistoryRecoveryWorkflowOperation
    ) -> String? {
        switch operation {
        case .idle:
            return nil
        case .importing:
            return localizedCatalogString("Recovering history…")
        case .cancellingScheduledDeletion:
            return localizedCatalogString("Cancelling scheduled deletion…")
        case .deletingSnapshot:
            return localizedCatalogString("Deleting recovery snapshot…")
        }
    }

    @MainActor
    private func applyHistoryWorkflowFailure(
        _ failure: HistoryWorkflowFailure
    ) {
        switch failure {
        case .historyUnavailable,
             .archiveTransitionFailed,
             .freshStoreVerificationFailed:
            errorMessage = historyUnavailableMessage
        case .recoveryImportFailed,
             .activeStoreReopenFailed:
            errorMessage = localizedCatalogString(
                "History recovery could not be completed."
            )
        case .snapshotOperationFailed:
            errorMessage = localizedCatalogString(
                "Recovery snapshot operation could not be completed."
            )
        case .inspectionFailed:
            break
        }
    }

    @MainActor
    private func historyWorkflowAdmissionContext()
        -> HistoryWorkflowAdmissionContext {
        HistoryWorkflowAdmissionContext(
            isRecording: isRecording,
            isTranscribing: isTranscribing,
            hasRetryWork: !retryingItemIDs.isEmpty,
            hasActiveTranscriptionJobs: !activeTranscriptionJobs.isEmpty,
            hasPendingAudioImports: !pendingAudioImportJobIDs.isEmpty,
            hasCloudHistoryWork:
                cloudTranscriptionHistoryCoordinator.hasActiveWork,
            hasMeetingSummaryWork:
                !meetingSummaryGeneratingNoteIDs.isEmpty,
            hasActiveRecordingJournal:
                activeRecordingID != nil
                    || activeSegmentedJournalController != nil,
            hasPendingRecordingFinalization:
                pendingRecordingJournalFinalizationCount != 0,
            hasPendingRecordingStart: pendingRecordingStartCount != 0,
            hasPendingAudioOnlyStops: !pendingAudioOnlyStopIDs.isEmpty
        )
    }

    @MainActor
    func openHistoryRecoverySettings() {
        refreshHistoryRecoverySnapshots()
        guard !historyRecoverySnapshots.isEmpty else { return }
        selectedSettingsTab = .recovery
        beginHistoryRecoveryInspection()
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }

    @MainActor
    func refreshHistoryRecoverySnapshots() {
        historyWorkflow.refreshSnapshots()
    }

    @MainActor
    func beginHistoryRecoveryInspection() {
        historyWorkflow.beginInspection(activeHistory: pipelineHistory)
    }

    @MainActor
    func ensureHistoryRecoveryInspection() {
        historyWorkflow.ensureInspection(activeHistory: pipelineHistory)
    }

    @MainActor
    @discardableResult
    func retryHistoryRecoveryInspection(id: UUID) -> Bool {
        historyWorkflow.retryInspection(
            id: id,
            activeHistory: pipelineHistory
        ) == .accepted
    }

    @MainActor
    func invalidateHistoryRecoveryInspectionResults() {
        historyWorkflow.invalidateInspection(
            activeHistory: pipelineHistory,
            shouldReschedule:
                selectedSettingsTab == .recovery
                    && !isHistoryRecoveryOperationInProgress
        )
    }

    @MainActor
    @discardableResult
    func importHistoryRecoverySnapshot(id: UUID) -> Bool {
        guard requireAvailableHistoryForMutation() else { return false }
        return historyWorkflow.requestImport(
            snapshotID: id,
            context: historyWorkflowAdmissionContext(),
            currentStore: pipelineHistoryStore,
            activeHistory: pipelineHistory,
            shouldRescheduleInspection: selectedSettingsTab == .recovery
        ) == .accepted
    }

    @MainActor
    @discardableResult
    func cancelHistoryRecoveryScheduledDeletion(id: UUID) -> Bool {
        historyWorkflow.requestCancelScheduledDeletion(
            snapshotID: id,
            activeStore: pipelineHistoryStore,
            activeHistory: pipelineHistory,
            shouldRescheduleInspection: selectedSettingsTab == .recovery
        ) == .accepted
    }

    @MainActor
    @discardableResult
    func deleteHistoryRecoverySnapshot(id: UUID) -> Bool {
        historyWorkflow.requestDeleteSnapshot(
            snapshotID: id,
            activeStore: pipelineHistoryStore,
            activeHistory: pipelineHistory,
            shouldRescheduleInspection: selectedSettingsTab == .recovery
        ) == .accepted
    }

    private static func recoverRecordingJournalsBeforeHistoryLoad(
        recordingJournalStore: RecordingJournalStore,
        historyStore: PipelineHistoryStore,
        storageLayout: AppStateStorageLayout
    ) {
        let executor = RecordingJournalRecoveryExecutor(
            store: recordingJournalStore
        )
        let historyBridge = RecordingRecoveryHistory(
            journalStore: recordingJournalStore,
            historyStore: historyStore
        )
        let noteAssetStore = NoteAssetStore(
            storageLayout: storageLayout
        )
        for result in executor.recoverAll() {
            switch result {
            case .recovered(let artifact):
                do {
                    let removedAssets = try historyBridge.persist(
                        artifact,
                        maxCount: Int.max
                    )
                    if !removedAssets.isEmpty,
                       historyStore.referenceTrust.permitsStartupReferenceCleanup {
                        let survivingHistory = historyStore.loadAllHistory()
                        guard historyStore.availability == .ready,
                              historyStore.referenceTrust
                            .permitsStartupReferenceCleanup else {
                            continue
                        }
                        let deletable = Self.deletableAssets(
                            removed: removedAssets,
                            survivingHistory: survivingHistory
                        )
                        for assets in deletable {
                            try? noteAssetStore.deleteAssets(
                                audioFileName: assets.audioFileName,
                                transcriptFileName: assets.transcriptFileName
                            )
                        }
                    }
                } catch {
                    print("Failed to persist recovered recording \(artifact.recordingID): \(error)")
                }
            case .discarded:
                continue
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
                candidate.protectedPermanentFileName
                    ?? candidate.promotion?.fileName
            }
        )
    }

    private static func hasStoredAssets(
        audioDirectory: URL,
        transcriptDirectory: URL
    ) -> Bool {
        let fileManager = FileManager.default
        for directory in [audioDirectory, transcriptDirectory] {
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            guard let fileNames = try? fileManager.contentsOfDirectory(
                atPath: directory.path
            ) else {
                return true
            }
            if fileNames.contains(where: { $0 != "inflight" }) {
                return true
            }
        }
        return false
    }

    private static func hasUnreferencedStoredAssets(
        audioDirectory: URL,
        transcriptDirectory: URL,
        referencedAudioFileNames: Set<String>,
        referencedTranscriptFileNames: Set<String>
    ) -> Bool {
        let fileManager = FileManager.default
        let directories = [
            (audioDirectory, referencedAudioFileNames),
            (transcriptDirectory, referencedTranscriptFileNames)
        ]
        for (directory, referencedFileNames) in directories {
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            guard let fileNames = try? fileManager.contentsOfDirectory(
                atPath: directory.path
            ) else {
                return true
            }
            if fileNames.contains(where: {
                $0 != "inflight" && !referencedFileNames.contains($0)
            }) {
                return true
            }
        }
        return false
    }

    private static func markAssetReferencesIncomplete(storageRoot: URL) {
        let markerURL = storageRoot
            .appendingPathComponent("History Recovery", isDirectory: true)
            .appendingPathComponent(
                "asset-references-incomplete",
                isDirectory: true
            )
        do {
            try FileManager.default.createDirectory(
                at: markerURL,
                withIntermediateDirectories: true
            )
        } catch {
            print("Failed to preserve incomplete history-reference evidence: \(error)")
        }
    }

    func loadTranscript(from fileName: String) -> String? {
        try? noteAssetStore.loadTranscript(fileName: fileName)
    }

    static func fileSizeBytes(for fileURL: URL) -> Int64? {
        (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map { Int64($0) }
    }

    private func recordingJournalID(
        forAudioFileName fileName: String
    ) -> UUID? {
        guard fileName.hasSuffix(".wav") else { return nil }
        let identifier = String(fileName.dropLast(4))
        guard let recordingID = UUID(uuidString: identifier),
              let manifest = try? recordingJournalStore.loadManifest(
                  recordingID: recordingID
              ),
              manifest.promotion?.fileName == fileName else {
            return nil
        }
        return recordingID
    }

    static func deletableAssets(
        removed: [DeletedPipelineHistoryAssets],
        survivingHistory: [PipelineHistoryItem]
    ) -> [DeletedPipelineHistoryAssets] {
        let referencedAudioFileNames = Set(
            survivingHistory.compactMap(\.audioFileName)
        )
        let referencedTranscriptFileNames = Set(
            survivingHistory.compactMap(\.transcriptFileName)
        )
        return removed.map { assets in
            DeletedPipelineHistoryAssets(
                historyID: assets.historyID,
                audioFileName: assets.audioFileName.flatMap {
                    referencedAudioFileNames.contains($0) ? nil : $0
                },
                transcriptFileName: assets.transcriptFileName.flatMap {
                    referencedTranscriptFileNames.contains($0) ? nil : $0
                }
            )
        }.filter {
            $0.audioFileName != nil || $0.transcriptFileName != nil
        }
    }

    @MainActor
    private func cleanupDeletedPipelineHistoryAssets(
        _ assets: DeletedPipelineHistoryAssets,
        survivingHistory: [PipelineHistoryItem]? = nil
    ) {
        transcriptionRetryWorkflow.forget(noteID: assets.historyID)
        cloudTranscriptionHistoryCoordinator.cancelAndInvalidate(
            historyID: assets.historyID,
            store: cloudTranscriptionJobStore
        )
        cloudTranscriptionProgressByHistoryID.removeValue(
            forKey: assets.historyID
        )
        retryingItemIDs.remove(assets.historyID)
        let resolvedSurvivingHistory = survivingHistory
            ?? pipelineHistoryStore.loadAllHistory()
        let canDeleteAssets = survivingHistory != nil
            || (
                pipelineHistoryStore.availability == .ready
                    && pipelineHistoryStore.referenceTrust
                        .permitsStartupReferenceCleanup
            )
        let deletable = canDeleteAssets
            ? Self.deletableAssets(
                removed: [assets],
                survivingHistory: resolvedSurvivingHistory
            )
            : []
        for assets in deletable {
            try? noteAssetStore.deleteAssets(
                audioFileName: assets.audioFileName,
                transcriptFileName: assets.transcriptFileName
            )
        }
        try? cloudTranscriptionJobStore.delete(
            historyID: assets.historyID,
            session: nil
        )
    }

    static func normalizeInterruptedHistoryItem(
        _ item: PipelineHistoryItem
    ) -> PipelineHistoryItem {
        item.normalizedAfterProcessInterruption()
    }

    private static func markInterruptedRecoveryPlaceholders(
        in history: [PipelineHistoryItem],
        store: PipelineHistoryStore
    ) -> [PipelineHistoryItem] {
        history.map { item in
            let updated = normalizeInterruptedHistoryItem(item)
            guard updated.postProcessingStatus != item.postProcessingStatus else {
                return item
            }
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
    private func startSelectedAudioRecorder(
        selection: RecordingAudioSelection
    ) async throws -> DegradedCombinedCaptureSource? {
        let inputID = selection.inputID
        let controller = try makeActiveSegmentedJournalController(inputID: inputID)
        attachSegmentedJournalSinks(controller.activeSegment, inputID: inputID)
        do {
            let degradedSource = try await startPhysicalAudioRecorder(selection: selection)
            controller.startCheckpointing { [weak self] error in
                DispatchQueue.main.async {
                    self?.reportRecordingJournalCheckpointFailure(error)
                }
            }
            return degradedSource
        } catch {
            detachSegmentedJournalSinks()
            activeSegmentedJournalController = nil
            activeRecordingID = nil
            cancelPhysicalAudioRecorder(inputID: inputID) { [weak self] in
                self?.discardSegmentedJournal(controller)
            }
            throw error
        }
    }

    @MainActor
    private func startPhysicalAudioRecorder(
        selection: RecordingAudioSelection
    ) async throws -> DegradedCombinedCaptureSource? {
        let inputID = selection.inputID
        let microphoneUsedSystemDefaultFallback: Bool
        var degradedSource: DegradedCombinedCaptureSource?
        switch AudioRecordingSource(inputID: inputID) {
        case .microphone:
            let result = try audioRecorder.startRecording(deviceUID: inputID)
            microphoneUsedSystemDefaultFallback = result.usedSystemDefaultFallback
        case .systemAudio:
            try await systemAudioRecorder.startRecording()
            microphoneUsedSystemDefaultFallback = false
        case .microphoneAndSystemAudio:
            let result = try await systemDefaultAndSystemAudioRecorder.startRecording(
                microphoneDeviceUID: selection.microphoneDeviceID
            )
            microphoneUsedSystemDefaultFallback =
                result.microphoneUsedSystemDefaultFallback
            degradedSource = result.missingSource
        }

        if microphoneUsedSystemDefaultFallback {
            applySystemDefaultMicrophoneFallback(for: inputID)
        }
        return degradedSource
    }

    @MainActor
    private func applySystemDefaultMicrophoneFallback(for inputID: String) {
        selectedMicrophoneDeviceID = AudioInputDevice.defaultMicrophoneID
        if AudioInputDevice.isMicrophoneOnly(inputID) {
            selectedMicrophoneID = AudioInputDevice.defaultMicrophoneID
            activeAudioInputID = AudioInputDevice.defaultMicrophoneID
        }
        refreshOverlayInputOptions()
    }

    /// The message a partial combined start surfaces, naming which source
    /// is missing and which one recording continues with.
    static func degradedCombinedCaptureMessage(missing: DegradedCombinedCaptureSource) -> String {
        switch missing {
        case .microphone:
            return localizedCatalogString("No mic — recording with System Audio only")
        case .systemAudio:
            return localizedCatalogString("No System Audio — recording with Mic only")
        }
    }

    @MainActor
    private func showDegradedCombinedCaptureNoticeIfNeeded(_ degradedSource: DegradedCombinedCaptureSource?) {
        guard let degradedSource else { return }
        overlayManager.showDegradedCombinedCaptureNotice(
            Self.degradedCombinedCaptureMessage(missing: degradedSource),
            reminderFrame: meetingReminderOverlayManager.visibleOverlayFrame
        )
    }

    private func journalSourceRequests(
        for inputID: String
    ) -> [RecordingJournalSegmentSourceRequest] {
        if AudioInputDevice.isSystemDefaultAndSystemAudio(inputID) {
            return [
                RecordingJournalSegmentSourceRequest(id: UUID(), kind: .microphone),
                RecordingJournalSegmentSourceRequest(id: UUID(), kind: .systemAudio)
            ]
        }
        return [RecordingJournalSegmentSourceRequest(
            id: UUID(),
            kind: AudioInputDevice.isSystemAudio(inputID)
                ? .systemAudio
                : .microphone
        )]
    }

    private func attachSegmentedJournalSinks(
        _ handle: SegmentedRecordingJournalSegmentHandle,
        inputID: String
    ) {
        audioRecorder.normalizedPCM16Sink = handle.microphoneSink
        systemAudioRecorder.normalizedPCM16Sink = handle.systemAudioSink
    }

    private func detachSegmentedJournalSinks() {
        audioRecorder.normalizedPCM16Sink = nil
        systemAudioRecorder.normalizedPCM16Sink = nil
    }

    @MainActor
    private func makeActiveSegmentedJournalController(
        inputID: String
    ) throws -> SegmentedRecordingJournalController {
        if let activeSegmentedJournalController {
            return activeSegmentedJournalController
        }
        let recordingID = activeRecordingID ?? UUID()
        activeRecordingID = recordingID
        let startedAt = Date(
            timeIntervalSince1970: floor(Date().timeIntervalSince1970 * 1_000) / 1_000
        )
        let request = SegmentedRecordingJournalCreateRequest(
            recordingID: recordingID,
            segmentID: UUID(),
            startedAt: startedAt,
            monotonicAnchorNanoseconds: RecordingMonotonicClock.nowNanoseconds(),
            sources: journalSourceRequests(for: inputID),
            pipeline: recordingPipelineSnapshot()
        )
        let controller = try SegmentedRecordingJournalController(
            request: request,
            store: recordingJournalStore,
            onTerminalPersistenceFailure: { [weak self] sourceFailure in
                Task { @MainActor [weak self] in
                    self?.handleRecordingJournalPersistenceFailure(sourceFailure)
                }
            },
            makeWriter: { try RecordingPCMJournalWriter(session: $0, store: $1) }
        )
        activeSegmentedJournalController = controller
        return controller
    }

    @MainActor
    private func handleRecordingJournalPersistenceFailure(
        _ sourceFailure: RecordingJournalSourcePersistenceFailure
    ) {
        guard isRecording,
              activeRecordingTriggerMode != nil,
              let controller = activeSegmentedJournalController,
              controller.recordingID == sourceFailure.recordingID,
              activeRecordingStorageFailureID == nil else {
            return
        }
        let physicalStopInProgress = isActiveInputSwitchPhysicalStopInProgress
        prepareForRecordingJournalPersistenceFailure(sourceFailure)
        if physicalStopInProgress { return }

        let inputID = activeAudioInputID ?? selectedMicrophoneID
        stopPhysicalAudioRecorder(inputID: inputID) { [weak self] temporaryURLs in
            guard let self else {
                for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
                return
            }
            self.finishRecordingAfterJournalPersistenceFailure(
                controller: controller,
                sourceFailure: sourceFailure,
                temporaryURLs: temporaryURLs
            )
        }
    }

    @MainActor
    private func handleRecordingJournalPersistenceFailure(
        _ sourceFailure: RecordingJournalSourcePersistenceFailure,
        alreadyStoppedTemporaryURLs temporaryURLs: [URL]
    ) {
        guard isRecording,
              activeRecordingTriggerMode != nil,
              let controller = activeSegmentedJournalController,
              controller.recordingID == sourceFailure.recordingID,
              activeRecordingStorageFailureID == nil else {
            for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
            return
        }
        prepareForRecordingJournalPersistenceFailure(sourceFailure)
        finishRecordingAfterJournalPersistenceFailure(
            controller: controller,
            sourceFailure: sourceFailure,
            temporaryURLs: temporaryURLs
        )
    }

    @MainActor
    private func prepareForRecordingJournalPersistenceFailure(
        _ sourceFailure: RecordingJournalSourcePersistenceFailure
    ) {
        activeRecordingStorageFailureID = sourceFailure.recordingID
        detachSegmentedJournalSinks()
        activeInputSwitchToken = nil
        isActiveInputSwitchPhysicalStopInProgress = false
        cancelPendingShortcutStart()
        cancelRecordingInitializationTimer()
        clearAudioRecorderCallbacks()
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        capturedContext = nil
        liveTranscriber?.cancel()
        liveTranscriber = nil
        tearDownRealtimeService()
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        currentSessionIntent = .dictation
        activeRecordingStartedAt = nil
        activeRecordingCalendarSnapshot = nil
        activeRecordingTranscriptionEnabled = nil
        isRecording = false
        restoreAudioInterruptionIfNeeded()
        syncCriticalDictationActivity()

        let message = localizedCatalogString(
            sourceFailure.failure.reason.overlayLocalizationKey
        )
        statusText = localizedCatalogString(
            sourceFailure.failure.reason.titleLocalizationKey
        )
        errorMessage = message
        overlayManager.showRecordingNotice(
            message,
            reminderFrame: meetingReminderOverlayManager.visibleOverlayFrame
        )
    }

    private func finishRecordingAfterJournalPersistenceFailure(
        controller: SegmentedRecordingJournalController,
        sourceFailure: RecordingJournalSourcePersistenceFailure,
        temporaryURLs: [URL]
    ) {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        recordingJournalFinalizationQueue.async {
            let result = self.recoverRecordingAfterJournalPersistenceFailure(
                controller: controller
            )
            Task { @MainActor [weak self] in
                self?.completeRecordingStorageFailureRecovery(
                    result,
                    sourceFailure: sourceFailure
                )
            }
        }
    }

    private func recoverRecordingAfterJournalPersistenceFailure(
        controller: SegmentedRecordingJournalController
    ) -> Result<RecoveredRecordingArtifact, Error> {
        do {
            _ = try controller.closeAfterPersistenceFailure()
            let artifact = try SegmentedRecordingArtifactFinalizer(
                store: recordingJournalStore,
                mixdownService: AudioMixdownService()
            ).finalizeAndPromote(recordingID: controller.recordingID)
            let manifest = try recordingJournalStore.loadManifest(
                recordingID: controller.recordingID
            )
            return .success(RecoveredRecordingArtifact(
                recordingID: artifact.recordingID,
                audioURL: artifact.destinationURL,
                promotion: artifact.promotion,
                manifest: manifest,
                mode: artifact.mode
            ))
        } catch {
            return .failure(error)
        }
    }

    @MainActor
    private func completeRecordingStorageFailureRecovery(
        _ result: Result<RecoveredRecordingArtifact, Error>,
        sourceFailure: RecordingJournalSourcePersistenceFailure
    ) {
        defer {
            activeSegmentedJournalController = nil
            activeRecordingID = nil
            activeRecordingStorageFailureID = nil
            cleanupActiveAudioRecordersIfIdle()
            restoreAudioInterruptionIfNeeded()
            refreshAvailableMicrophonesIfNeeded()
        }

        switch result {
        case .success(let recovered):
            if let liveNoteID = currentRecordingLiveNoteID {
                currentRecordingLiveNoteID = nil
                pipelineHistory.removeAll { $0.id == liveNoteID }
                if let deletedAssets = try? pipelineHistoryStore.delete(id: liveNoteID) {
                    cleanupDeletedPipelineHistoryAssets(deletedAssets)
                }
            }
            do {
                let removedAssets = try RecordingRecoveryHistory(
                    journalStore: recordingJournalStore,
                    historyStore: pipelineHistoryStore
                ).persist(recovered, maxCount: maxPipelineHistoryCount)
                for assets in removedAssets {
                    cleanupDeletedPipelineHistoryAssets(assets)
                }
                if let item = pipelineHistoryStore.loadAllHistory().first(where: {
                    $0.id == recovered.recordingID
                }), item.isIncompleteTranscription {
                    try pipelineHistoryStore.update(
                        item.markInterruptedBeforeCompletion()
                    )
                }
                pipelineHistory = Self.markInterruptedRecoveryPlaceholders(
                    in: pipelineHistoryStore.loadAllHistory(),
                    store: pipelineHistoryStore
                )
                let context = RecoveredRecordingContext(
                    mode: recovered.mode,
                    interruptionReason: recovered.interruptionReason
                )
                statusText = localizedCatalogString(context.titleLocalizationKey)
                errorMessage = context.localizedDescription()
            } catch {
                showRecordingStorageRecoveryFailure(error)
            }
        case .failure(let error):
            showRecordingStorageRecoveryFailure(error)
        }
    }

    @MainActor
    private func showRecordingStorageRecoveryFailure(_ error: Error) {
        os_log(
            .error,
            log: recordingLog,
            "recording storage recovery failed: %{public}@",
            error.localizedDescription
        )
        let message = localizedCatalogString(
            "Free up space or restore storage access, then relaunch Quill to recover the audio."
        )
        statusText = localizedCatalogString("Error")
        errorMessage = message
        overlayManager.showError(message)
    }

    @MainActor
    private func reportRecordingJournalCheckpointFailure(_ error: Error) {
        let message = localizedCatalogString(
            "Unexpected quit recovery is unavailable for this recording. Recording continues normally."
        )
        errorMessage = LocalizedUserMessage.providerFailure(
            prefix: message,
            providerDetail: error.localizedDescription
        )
        overlayManager.showRecordingNotice(
            message,
            reminderFrame: meetingReminderOverlayManager.visibleOverlayFrame
        )
    }

    private func stopPhysicalAudioRecorder(
        inputID: String,
        completion: @escaping ([URL]) -> Void
    ) {
        if AudioInputDevice.isSystemDefaultAndSystemAudio(inputID) {
            systemDefaultAndSystemAudioRecorder.stopRecordingSources { sources in
                completion([sources.microphoneURL, sources.systemAudioURL].compactMap { $0 })
            }
        } else if AudioInputDevice.isSystemAudio(inputID) {
            systemAudioRecorder.stopRecording { url in
                completion([url].compactMap { $0 })
            }
        } else {
            audioRecorder.stopRecording { url in
                completion([url].compactMap { $0 })
            }
        }
    }

    private func cancelPhysicalAudioRecorder(
        inputID: String,
        completion: @escaping () -> Void
    ) {
        if AudioInputDevice.isSystemDefaultAndSystemAudio(inputID) {
            systemDefaultAndSystemAudioRecorder.cancelRecording(completion: completion)
        } else if AudioInputDevice.isSystemAudio(inputID) {
            systemAudioRecorder.cancelRecording(completion: completion)
        } else {
            audioRecorder.cancelRecording(completion: completion)
        }
    }

    private func stopActiveAudioRecorder(
        completion: @escaping (StoppedAudioRecording) -> Void
    ) {
        let inputID = activeAudioInputID ?? selectedMicrophoneID
        stopPhysicalAudioRecorder(inputID: inputID) { [weak self] temporaryURLs in
            guard let self else {
                for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
                completion(.empty)
                return
            }
            self.detachSegmentedJournalSinks()
            self.finishStoppedSegmentedRecording(
                temporaryURLs: temporaryURLs,
                completion: completion
            )
        }
    }

    private func finishStoppedSegmentedRecording(
        temporaryURLs: [URL],
        completion: @escaping (StoppedAudioRecording) -> Void
    ) {
        guard let controller = activeSegmentedJournalController else {
            for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
            completion(.empty)
            return
        }
        activeSegmentedJournalController = nil
        activeRecordingID = nil
        activeInputSwitchToken = nil
        isActiveInputSwitchPhysicalStopInProgress = false
        recordingJournalFinalizationQueue.async {
            do {
                try controller.stopAndClose()
                let artifact = try SegmentedRecordingArtifactFinalizer(
                    store: self.recordingJournalStore,
                    mixdownService: AudioMixdownService()
                ).finalizeAndPromote(recordingID: controller.recordingID)
                let promotedManifest = try self.recordingJournalStore.loadManifest(
                    recordingID: artifact.recordingID
                )
                DispatchQueue.main.async {
                    for url in temporaryURLs where url.path != artifact.destinationURL.path {
                        try? FileManager.default.removeItem(at: url)
                    }
                    switch artifact.mode {
                    case .complete:
                        completion(.transcribable(
                            fileURL: artifact.destinationURL,
                            recoverableJournalID: nil
                        ))
                    case .partial:
                        let recovered = RecoveredRecordingArtifact(
                            recordingID: artifact.recordingID,
                            audioURL: artifact.destinationURL,
                            promotion: artifact.promotion,
                            manifest: promotedManifest,
                            mode: .partial
                        )
                        completion(.recoveredWithoutTranscription(recovered))
                    case .microphoneOnly, .systemAudioOnly:
                        completion(.preservedForRecovery(
                            recordingID: controller.recordingID,
                            message: "Unexpected segmented recovery mode"
                        ))
                    }
                }
            } catch {
                if controller.terminalPersistenceFailure != nil {
                    let result = self.recoverRecordingAfterJournalPersistenceFailure(
                        controller: controller
                    )
                    DispatchQueue.main.async {
                        for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
                        switch result {
                        case .success(let recovered):
                            completion(.recoveredWithoutTranscription(recovered))
                        case .failure(let recoveryError):
                            completion(.preservedForRecovery(
                                recordingID: controller.recordingID,
                                message: recoveryError.localizedDescription
                            ))
                        }
                    }
                    return
                }
                os_log(
                    .error,
                    log: recordingLog,
                    "segmented journal finalization failed: %{public}@",
                    error.localizedDescription
                )
                try? controller.preserveForRecovery()
                DispatchQueue.main.async {
                    for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
                    completion(.preservedForRecovery(
                        recordingID: controller.recordingID,
                        message: error.localizedDescription
                    ))
                }
            }
        }
    }

    private func cancelActiveAudioRecorder() {
        let inputID = activeAudioInputID ?? selectedMicrophoneID
        activeInputSwitchToken = nil
        isActiveInputSwitchPhysicalStopInProgress = false
        detachSegmentedJournalSinks()
        cancelPhysicalAudioRecorder(inputID: inputID) { [weak self] in
            self?.discardActiveSegmentedJournal()
        }
    }

    private func discardActiveSegmentedJournal() {
        detachSegmentedJournalSinks()
        let controller = activeSegmentedJournalController
        activeSegmentedJournalController = nil
        activeRecordingID = nil
        activeInputSwitchToken = nil
        isActiveInputSwitchPhysicalStopInProgress = false
        discardSegmentedJournal(controller)
    }

    private func discardSegmentedJournal(
        _ controller: SegmentedRecordingJournalController?
    ) {
        guard let controller else { return }
        do {
            try controller.discard()
        } catch {
            os_log(
                .error,
                log: recordingLog,
                "failed to delete segmented recording journal: %{public}@",
                error.localizedDescription
            )
        }
    }

    private func preserveActiveSegmentedJournalForRecovery() {
        detachSegmentedJournalSinks()
        let controller = activeSegmentedJournalController
        activeSegmentedJournalController = nil
        activeRecordingID = nil
        activeInputSwitchToken = nil
        isActiveInputSwitchPhysicalStopInProgress = false
        if let controller {
            try? controller.preserveForRecovery()
        }
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
                postProcessingEnabled: shouldTranscribeActiveRecording && !disablePostProcessing,
                preferredModelID: postProcessingModel,
                fallbackModelID: postProcessingFallbackModel,
                outputLanguage: outputLanguage,
                contextCaptureEnabled: shouldTranscribeActiveRecording && !disableContextCapture,
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

    /// Switches the audio input while retaining all prior segments under one
    /// durable recording manifest.
    @MainActor
    func switchActiveRecordingInput(to newInputID: String) {
        guard isRecording,
              activeInputSwitchToken == nil,
              let controller = activeSegmentedJournalController else {
            return
        }
        let currentInputID = activeAudioInputID ?? selectedMicrophoneID
        guard !AudioInputDevice.isSameInput(newInputID, currentInputID) else {
            return
        }
        guard canAccessRecordingInput(newInputID) else {
            errorMessage = recordingInputAccessErrorMessage(for: newInputID)
            overlayManager.showRecordingNotice(
                recordingInputAccessNotice(for: newInputID),
                reminderFrame: meetingReminderOverlayManager.visibleOverlayFrame
            )
            return
        }
        // Combined-source selection is already disabled in both input pickers
        // while a live-only transcriber is active; this is a silent defensive
        // guard against any bypass, not a user-facing error path.
        guard isAudioInputSelectable(newInputID) else {
            return
        }

        let newSelection = RecordingAudioSelection(
            inputID: newInputID,
            microphoneDeviceID: selectedMicrophoneDeviceID
        )
        let switchToken = UUID()
        activeInputSwitchToken = switchToken
        isActiveInputSwitchPhysicalStopInProgress = true
        tearDownLiveTranscriberOffMainThread()
        tearDownRealtimeService()
        setActiveRecorderPCMHandler(nil)
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        stopPhysicalAudioRecorder(inputID: currentInputID) { [weak self] temporaryURLs in
            guard let self else {
                for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
                return
            }
            self.isActiveInputSwitchPhysicalStopInProgress = false
            guard self.activeInputSwitchToken == switchToken,
                  self.isRecording else {
                if self.activeRecordingStorageFailureID == controller.recordingID,
                   let sourceFailure = controller.terminalPersistenceFailure {
                    self.finishRecordingAfterJournalPersistenceFailure(
                        controller: controller,
                        sourceFailure: sourceFailure,
                        temporaryURLs: temporaryURLs
                    )
                    return
                }
                for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
                return
            }
            self.detachSegmentedJournalSinks()
            do {
                let handle = try controller.switchSegment(
                    segmentID: UUID(),
                    sources: self.journalSourceRequests(for: newInputID)
                )
                for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
                self.attachSegmentedJournalSinks(handle, inputID: newInputID)
                self.selectedMicrophoneID = newInputID
                self.activeAudioInputID = newInputID
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
                            self?.finishAfterInputSwitchStartFailure(
                                error,
                                switchToken: switchToken
                            )
                        }
                    }
                )
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let degradedSource = try await self.startPhysicalAudioRecorder(selection: newSelection)
                        await MainActor.run {
                            guard self.activeInputSwitchToken == switchToken,
                                  self.isRecording else { return }
                            self.activeInputSwitchToken = nil
                            self.isActiveInputSwitchPhysicalStopInProgress = false
                            self.audioLevelCancellable = self.activeRecorderAudioLevelPublisher(
                                inputID: newInputID
                            )
                            .receive(on: DispatchQueue.main)
                            .sink { [weak self] level in
                                self?.overlayManager.updateAudioLevel(level)
                            }
                            self.showDegradedCombinedCaptureNoticeIfNeeded(degradedSource)
                        }
                    } catch {
                        await MainActor.run {
                            self.finishAfterInputSwitchStartFailure(
                                error,
                                switchToken: switchToken
                            )
                        }
                    }
                }
            } catch {
                if let sourceFailure = controller.terminalPersistenceFailure {
                    self.handleRecordingJournalPersistenceFailure(
                        sourceFailure,
                        alreadyStoppedTemporaryURLs: temporaryURLs
                    )
                    return
                }
                for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
                self.activeInputSwitchToken = nil
                self.isActiveInputSwitchPhysicalStopInProgress = false
                self.preserveActiveSegmentedJournalForRecovery()
                self.handleRecordingFailure(error)
            }
        }
    }

    @MainActor
    private func finishAfterInputSwitchStartFailure(
        _ error: Error,
        switchToken: UUID
    ) {
        guard activeInputSwitchToken == switchToken, isRecording else { return }
        activeInputSwitchToken = nil
        isActiveInputSwitchPhysicalStopInProgress = false
        let issue = userIssue(
            for: error,
            fallbackCode: .recordingInputFailed
        )
        errorMessage = issue.record.presentation().compactMessage
        overlayManager.showRecordingNotice(
            localizedCatalogString("Failed to switch audio input. Saving the recorded audio."),
            reminderFrame: meetingReminderOverlayManager.visibleOverlayFrame
        )
        stopAndTranscribe()
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
            return "Couldn't switch input: Microphone + System Audio needs Microphone and Screen & System Audio Recording access (System Settings > Privacy & Security). \(tail)"
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

    /// Audio source choices shown in the recording overlay's input switcher.
    /// Limited to the source modes — the meaningful mid-recording choice — rather
    /// than the full hardware microphone list.
    @MainActor
    private func recordingOverlayInputOptions() -> [RecordingOverlayInputOption] {
        let usesSystemDefault = selectedMicrophoneDeviceID
            == AudioInputDevice.defaultMicrophoneID
        let microphoneName = usesSystemDefault
            ? "Microphone"
            : selectedMicrophoneDisplayName()
        let combinedName = usesSystemDefault
            ? AudioRecordingSource.microphoneAndSystemAudio.titleKey
            : localizedCatalogFormat("%@ + System Audio", microphoneName)
        return AudioRecordingSource.allCases.map { source in
            let name: String
            let isStaticQuillName: Bool
            switch source {
            case .microphone:
                name = microphoneName
                isStaticQuillName = usesSystemDefault
            case .systemAudio:
                name = source.titleKey
                isStaticQuillName = true
            case .microphoneAndSystemAudio:
                name = combinedName
                isStaticQuillName = usesSystemDefault
            }
            return RecordingOverlayInputOption(
                id: source.id,
                name: name,
                isStaticQuillName: isStaticQuillName,
                isEnabled: isAudioSourceSelectable(source)
            )
        }
    }

    @MainActor
    private func refreshOverlayInputOptions() {
        overlayManager.updateInputOptions(
            recordingOverlayInputOptions(),
            selectedID: selectedAudioSourceID
        )
    }

    @MainActor
    private func synchronizeHistoryPersistenceState() {
        applyHistoryWorkflowState(
            historyWorkflow.synchronize(activeStore: pipelineHistoryStore)
        )
    }

    @MainActor
    @discardableResult
    private func requireAvailableHistoryForMutation() -> Bool {
        synchronizeHistoryPersistenceState()
        switch HistoryWorkflowAdmission.mutation(
            state: historyWorkflow.state
        ) {
        case .accepted:
            return true
        case .rejected(.archiveTransitionInProgress):
            errorMessage = localizedCatalogString(
                "Archiving recording history is still in progress."
            )
        case .rejected(.recoveryOperationInProgress):
            errorMessage = localizedCatalogString(
                "History recovery is still in progress."
            )
        default:
            errorMessage = historyUnavailableMessage
        }
        return false
    }

    @MainActor
    @discardableResult
    func archiveOldHistoryAndStartFresh(
        postAction: HistoryArchivePostAction = .startFresh
    ) -> Bool {
        synchronizeHistoryPersistenceState()
        let result = historyWorkflow.requestArchive(
            context: historyWorkflowAdmissionContext(),
            currentStore: pipelineHistoryStore,
            postAction: postAction
        )
        if result == .rejected(.applicationBusy) {
            errorMessage = localizedCatalogString(
                "Finish the current recording or transcription before archiving history."
            )
        } else if result == .rejected(.historyUnavailable) {
            errorMessage = historyUnavailableMessage
        }
        return result == .accepted
    }

    @MainActor
    func clearPipelineHistory() {
        guard requireAvailableHistoryForMutation() else { return }
        let historyIDs = pipelineHistory.map(\.id)
        for historyID in historyIDs {
            transcriptionRetryWorkflow.cancel(noteID: historyID)
            cloudTranscriptionHistoryCoordinator.cancelAndInvalidate(
                historyID: historyID,
                store: cloudTranscriptionJobStore
            )
        }
        do {
            let removedStoredFiles = try pipelineHistoryStore.clearAll(
                requiresDurableStore: true,
                beforeDeleting: { assets in
                    for asset in assets {
                        cloudTranscriptionHistoryCoordinator.cancelAndInvalidate(
                            historyID: asset.historyID,
                            store: cloudTranscriptionJobStore
                        )
                    }
                }
            )
            pipelineHistory = []
            for removedAssets in removedStoredFiles {
                cleanupDeletedPipelineHistoryAssets(
                    removedAssets,
                    survivingHistory: []
                )
            }
            transcriptionRetryWorkflow.forgetAll()
            meetingSummaryWorkflow.forgetAll()
            forgetAllWarningBannerState()
        } catch {
            errorMessage = LocalizedUserMessage.providerFailure(prefix: localizedCatalogString("Unable to clear run history"), providerDetail: error.localizedDescription)
        }
    }

    @MainActor
    func deleteHistoryEntry(id: UUID) {
        guard requireAvailableHistoryForMutation(),
              let index = pipelineHistory.firstIndex(where: { $0.id == id }) else { return }
        transcriptionRetryWorkflow.cancel(noteID: id)
        cloudTranscriptionHistoryCoordinator.cancelAndInvalidate(
            historyID: id,
            store: cloudTranscriptionJobStore
        )
        do {
            if let deletedAssets = try pipelineHistoryStore.delete(
                id: id,
                requiresDurableStore: true,
                beforeDeleting: { assets in
                    cloudTranscriptionHistoryCoordinator.cancelAndInvalidate(
                        historyID: assets.historyID,
                        store: cloudTranscriptionJobStore
                    )
                }
            ) {
                cleanupDeletedPipelineHistoryAssets(deletedAssets)
            }
            pipelineHistory.remove(at: index)
            meetingSummaryWorkflow.forget(noteID: id)
            forgetWarningBannerState(for: id)
        } catch {
            errorMessage = LocalizedUserMessage.providerFailure(prefix: localizedCatalogString("Unable to delete run history entry"), providerDetail: error.localizedDescription)
        }
    }

    @MainActor
    func updateHistoryItemTitle(id: UUID, title: String) {
        guard requireAvailableHistoryForMutation(),
              let index = pipelineHistory.firstIndex(where: { $0.id == id }) else { return }
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

    @MainActor
    func meetingSummaryAvailability(
        for item: PipelineHistoryItem
    ) -> MeetingSummaryAvailability {
        if meetingSummaryGeneratingNoteIDs.contains(item.id) {
            return .generationInProgress
        }
        guard item.intent == .dictation else {
            return .transcriptUnavailable
        }
        if item.isIncompleteTranscription {
            return .transcriptionInProgress
        }
        guard item.machineStatus == .completed else {
            return .transcriptUnavailable
        }
        guard !meetingSummarySource(for: item).normalizedTranscript.isEmpty else {
            return .transcriptUnavailable
        }
        guard !disableMeetingSummary else {
            return .featureDisabled
        }
        guard isAIProcessingBackendReady(for: .meetingSummary) else {
            return .modelUnavailable
        }
        return .available
    }

    @MainActor
    func meetingSummarySource(
        for item: PipelineHistoryItem
    ) -> MeetingSummarySource {
        MeetingSummaryWorkflow.availabilitySource(for: item)
    }

    @MainActor
    private func meetingSummaryWorkflowRequest(
        for item: PipelineHistoryItem
    ) -> MeetingSummaryWorkflowRequest {
        let backendKind: MeetingSummaryBackendKind =
            meetingSummaryBackendChoice.isLocal ? .local : .cloud
        return MeetingSummaryWorkflowRequest(
            noteID: item.id,
            initialItem: item,
            requestedOutputLanguage: meetingSummaryOutputLanguage,
            configuredBackendKind: backendKind,
            configuredModelID: meetingSummaryBackendChoice.modelID,
            providerHost: backendKind == .cloud
                ? URL(string: apiBaseURL)?.host
                : nil,
            generatorConfiguration: meetingSummaryGeneratorConfiguration()
        )
    }

    @MainActor
    private func meetingSummaryHistoryAccess()
        -> MeetingSummaryHistoryAccess
    {
        let store = pipelineHistoryStore
        return MeetingSummaryHistoryAccess(
            durability: { store.durability },
            item: { id in
                let history = store.loadAllHistory()
                guard store.availability == .ready else {
                    throw PipelineHistoryStoreError.storeUnavailable
                }
                return history.first(where: { $0.id == id })
            },
            persist: { item, requiresDurableStore in
                try store.update(
                    item,
                    requiresDurableStore: requiresDurableStore
                )
            }
        )
    }

    @MainActor
    func generateMeetingSummary(id: UUID) async throws {
        guard let startItem = pipelineHistory.first(where: { $0.id == id }) else {
            throw MeetingSummaryError.invalidInput
        }
        guard meetingSummaryAvailability(for: startItem) == .available else {
            throw MeetingSummaryError.invalidInput
        }

        let outcome = await meetingSummaryWorkflow.generate(
            request: meetingSummaryWorkflowRequest(for: startItem),
            history: meetingSummaryHistoryAccess()
        )
        switch outcome {
        case .verifiedSuccess, .unverifiedSuccess:
            return
        case .invalidInput:
            throw MeetingSummaryError.invalidInput
        case .sourceChanged:
            throw MeetingSummaryError.sourceChanged
        case .generationFailed(let error):
            throw error
        case .persistenceFailed:
            throw QuillUserIssueError.historyPersistenceUnavailable()
        }
    }

    @MainActor
    func consumeMeetingSummaryPendingReveal(id: UUID) -> Bool {
        meetingSummaryWorkflow.consumePendingReveal(noteID: id)
    }

    @MainActor
    func setMeetingSummaryActionCompleted(
        noteID: UUID,
        actionID: UUID,
        isCompleted: Bool
    ) throws {
        guard requireAvailableHistoryForMutation(),
              let noteIndex = pipelineHistory.firstIndex(
            where: { $0.id == noteID }
        ), var envelope = pipelineHistory[noteIndex].meetingSummary,
        let actionIndex = envelope.content.actionItems.firstIndex(
            where: { $0.id == actionID }
        ) else {
            throw MeetingSummaryError.invalidInput
        }

        envelope.content.actionItems[actionIndex].isCompleted = isCompleted
        let updated = pipelineHistory[noteIndex].withMeetingSummary(envelope)
        try pipelineHistoryStore.update(updated)
        pipelineHistory[noteIndex] = updated
    }

    @MainActor
    func deleteMeetingSummary(noteID: UUID) throws {
        guard requireAvailableHistoryForMutation(),
              let noteIndex = pipelineHistory.firstIndex(
            where: { $0.id == noteID }
        ) else {
            throw MeetingSummaryError.invalidInput
        }
        let existing = pipelineHistory[noteIndex]
        let hasSavedSummary = existing.meetingSummary != nil
        let hasCurrentHardFailure = existing.meetingSummaryAttempt?.outcome == .failed
            && existing.meetingSummaryAttempt?.isCurrent(
                for: meetingSummarySource(for: existing)
            ) == true
        guard hasSavedSummary || hasCurrentHardFailure else {
            throw MeetingSummaryError.invalidInput
        }

        let updated = existing
            .withMeetingSummary(nil)
            .withMeetingSummaryAttempt(nil)
        do {
            try pipelineHistoryStore.update(
                updated,
                requiresDurableStore: true
            )
        } catch {
            throw QuillUserIssueError.historyPersistenceUnavailable()
        }
        pipelineHistory[noteIndex] = updated
        meetingSummaryWorkflow.invalidate(noteID: noteID)
    }

    @MainActor
    func updateTranscript(id: UUID, text: String) {
        guard requireAvailableHistoryForMutation(),
              let item = pipelineHistory.first(where: { $0.id == id }) else { return }
        // 파일에도 동기화해서 앱 재시작 후 폴백 로딩 시에도 일관성 유지
        if let fileName = item.transcriptFileName {
            let fileURL = storageLayout.transcriptDirectory.appendingPathComponent(fileName)
            try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        let replacementSpokenLanguage: SpokenLanguageResolution?
        switch item.spokenLanguage?.source {
        case .transcriptInferred, .unavailable:
            replacementSpokenLanguage = SpokenLanguageResolver.resolve(
                requestedLanguageCode: item.transcriptionLanguageCode,
                engineLanguageCode: nil,
                transcript: text
            )
        case .configured, .engineDetected:
            replacementSpokenLanguage = item.spokenLanguage
        case nil:
            replacementSpokenLanguage = nil
        }
        let updated = item.copying(
            meetingSummaryJSON: item.meetingSummaryJSON,
            spokenLanguageCode: replacementSpokenLanguage?.languageCode,
            spokenLanguageResolution: replacementSpokenLanguage?.source,
            meetingSummaryAttempt: item.meetingSummaryAttempt,
            customTitle: item.customTitle,
            postProcessedTranscript: text
        )
        do {
            try pipelineHistoryStore.update(updated)
            if let index = pipelineHistory.firstIndex(where: { $0.id == id }) {
                pipelineHistory[index] = updated
            }
            transcriptionRetryWorkflow.invalidate(noteID: id)
            meetingSummaryWorkflow.invalidate(noteID: id)
        } catch {
            errorMessage = LocalizedUserMessage.providerFailure(prefix: localizedCatalogString("Failed to save transcript edit"), providerDetail: error.localizedDescription)
        }
    }

    @MainActor
    func importAudioFile(_ fileURL: URL, mode: NoteBrowserTranscriptionMode) {
        guard requireAvailableHistoryForMutation() else { return }
        importAudioFile(fileURL, choice: preferredAudioImportChoice(for: mode))
    }

    @MainActor
    func importAudioFile(_ fileURL: URL, choice: TranscriptionBackendChoice) {
        guard requireAvailableHistoryForMutation() else { return }
        guard !choice.usesCloudAPI || hasTranscriptionAPIKey else {
            openProviderSettings()
            return
        }

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
            pressEnterCommandEnabled: isPressEnterVoiceCommandEnabled,
            nativeWhisperExecution: nativeWhisperExecutionSnapshot(for: choice),
            cloudDependencies: Self
                .audioImportCloudTranscriptionDependenciesFactory(),
            postProcessingService: makePostProcessingService()
        )
        let jobID = UUID()
        let noteID = UUID()
        let startedAt = Date()
        let importContextSummary = AudioImportOptions.importContextSummary(for: fileURL.lastPathComponent)
        pendingAudioImportJobIDs.insert(jobID)
        let noteAssetStore = noteAssetStore

        Task { [weak self] in
            let savedAudioFile: SavedAudioFile
            do {
                savedAudioFile = try await noteAssetStore
                    .saveSecurityScopedAudio(from: fileURL)
            } catch {
                self?.pendingAudioImportJobIDs.remove(jobID)
                self?.errorMessage = localizedCatalogString("Unable to save the audio file. Check disk space or file permissions and try again.")
                return
            }
            guard let self else {
                try? noteAssetStore.deleteAudio(fileName: savedAudioFile.fileName)
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
                postProcessingStatus: configuration.useLocalTranscription
                    ? "importing"
                    : PipelineHistoryItem.cloudTranscribingStatus,
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
                    cleanupDeletedPipelineHistoryAssets(removedAssets)
                }
            } catch {
                self.pendingAudioImportJobIDs.remove(jobID)
                try? noteAssetStore.deleteAudio(fileName: savedAudioFile.fileName)
                let issue = self.userIssue(for: error)
                self.errorMessage = issue.record.presentation().compactMessage
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
            self.pendingAudioImportJobIDs.remove(jobID)
            self.updateTranscriptionJob(jobID) {
                $0.liveNoteID = noteID
                $0.audioFileName = savedAudioFile.fileName
            }
            let cloudExecutionContext = self.prepareCloudTranscriptionJob(
                historyID: noteID,
                useLocalTranscription: configuration.useLocalTranscription,
                completionPolicy: TranscriptionCompletionSnapshot(
                    postProcessingEnabled: configuration.postProcessingEnabled,
                    outputLanguage: configuration.outputLanguage,
                    pressEnterCommandEnabled: configuration.pressEnterCommandEnabled
                )
            )

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
                    let transcriptionService = try configuration.makeTranscriptionService(
                        cloudExecutionContext: cloudExecutionContext
                    )
                    let transcription = try await transcriptionService.transcribe(fileURL: savedAudioFile.fileURL)
                    try Task.checkCancellation()
                    let parsedTranscript = Self.parseTranscriptCommands(
                        from: transcription.text,
                        pressEnterCommandEnabled: configuration.pressEnterCommandEnabled
                    )
                    let result = await Self.processTranscript(
                        parsedTranscript.transcript,
                        intent: .dictation,
                        context: importedContext,
                        postProcessingService: configuration.makePostProcessingService(),
                        precomputedMacros: self.precomputedMacros,
                        customVocabulary: configuration.customVocabulary,
                        customSystemPrompt: configuration.customSystemPrompt,
                        outputLanguage: configuration.outputLanguage,
                        spokenLanguage: transcription.spokenLanguage,
                        postProcessingEnabled: configuration.postProcessingEnabled
                    )
                    try Task.checkCancellation()
                    guard isCurrentCloudTranscriptionExecution(
                        historyID: noteID,
                        context: cloudExecutionContext,
                        requiresCloudExecution: !configuration.useLocalTranscription
                    ) else {
                        self.finishTranscriptionJob(jobID)
                        return
                    }
                    let processingStatus = result.userIssueRecord?.persistedStatus
                        ?? Self.statusMessage(
                            for: result.outcome,
                            parsedTranscript: parsedTranscript
                        )
                    let historySaved = self.recordPipelineHistoryEntry(
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
                        spokenLanguage: transcription.spokenLanguage,
                        customVocabularyOverride: configuration.customVocabulary,
                        customSystemPromptOverride: configuration.customSystemPrompt,
                        aiProcessingOutcome: result.aiProcessingOutcome
                    )
                    self.completeCloudTranscriptionHistory(
                        historyID: noteID,
                        context: cloudExecutionContext,
                        historySaved: historySaved
                    )
                    self.finishTranscriptionJob(jobID)
                } catch is CancellationError {
                    guard isCurrentCloudTranscriptionExecution(
                        historyID: noteID,
                        context: cloudExecutionContext,
                        requiresCloudExecution: !configuration.useLocalTranscription
                    ) else {
                        self.finishTranscriptionJob(jobID)
                        return
                    }
                    self.finishCloudTranscriptionJob(
                        historyID: noteID,
                        context: cloudExecutionContext
                    )
                    self.finishTranscriptionJob(jobID)
                } catch {
                    let issue = self.userIssue(
                        for: error,
                        fallbackCode: configuration.useLocalTranscription
                            ? .localTranscriptionFailed
                            : .providerConfigurationInvalid,
                        modelID: configuration.useLocalTranscription
                            ? configuration.localTranscriptionModel.id
                            : configuration.transcriptionModel
                    )
                    guard !Task.isCancelled,
                          isCurrentCloudTranscriptionExecution(
                            historyID: noteID,
                            context: cloudExecutionContext,
                            requiresCloudExecution: !configuration.useLocalTranscription
                          ) else {
                        self.finishTranscriptionJob(jobID)
                        return
                    }
                    self.finishCloudTranscriptionJob(
                        historyID: noteID,
                        context: cloudExecutionContext
                    )
                    self.recordPipelineHistoryEntry(
                        jobID: jobID,
                        rawTranscript: "",
                        postProcessedTranscript: "",
                        postProcessingPrompt: "",
                        systemPrompt: configuration.systemPrompt,
                        context: importedContext,
                        processingStatus: issue.persistedStatus,
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
            self.installCloudTranscriptionTask(
                task,
                historyID: noteID,
                context: cloudExecutionContext
            )
        }
    }

    func storedAudioURL(for item: PipelineHistoryItem) -> URL? {
        noteAssetStore.storedAudioURL(for: item)
    }

    @MainActor
    func noteBrowserStoredAudioURL(for item: PipelineHistoryItem) -> URL? {
        guard let audioURL = storedAudioURL(for: item),
              FileManager.default.fileExists(atPath: audioURL.path) else {
            return nil
        }
        return audioURL
    }

    @MainActor
    func noteBrowserRetryAvailability(
        for item: PipelineHistoryItem
    ) -> NoteBrowserRetryAvailability {
        guard let audioURL = noteBrowserStoredAudioURL(for: item) else {
            return .noAudio
        }
        let options = retryOptions(for: audioURL)
        if let retryChoice = options.explicitRetryChoice {
            return options.isChoiceReady(retryChoice)
                ? .ready
                : .needsProviderConfiguration
        }
        return options.supportedChoices.isEmpty
            ? .needsModelSetup
            : .needsModelSelection
    }

    @MainActor
    private func retryOptions(for audioURL: URL) -> AudioImportOptions {
        let allowsOversizedCanonicalCloud = audioURL.pathExtension.lowercased()
            == "wav"
            && (try? CanonicalPCM16WAV.validateFile(at: audioURL)) != nil
        return AudioImportOptions(
            fileExtension: audioURL.pathExtension,
            currentChoice: currentNoteBrowserTranscriptionChoice,
            apiStandardModelID: resolvedStandardTranscriptionModelID,
            fileSizeBytes: Self.fileSizeBytes(for: audioURL),
            hasAPIKey: hasTranscriptionAPIKey,
            hasNativeLocalWhisperModel: hasNativeLocalWhisperModel,
            legacyLocalWhisperModels: installedLegacyLocalWhisperModels,
            nativeWhisperModelID: NativeWhisperModelCatalog.recommended.id,
            nativeWhisperDisplayName: NativeWhisperModelCatalog.recommended.displayName,
            allowsOversizedCanonicalCloud: allowsOversizedCanonicalCloud
        )
    }

    @MainActor
    func retryTranscription(item: PipelineHistoryItem) {
        guard requireAvailableHistoryForMutation() else { return }
        guard !retryingItemIDs.contains(item.id) else { return }
        guard noteBrowserRetryAvailability(for: item) == .ready else { return }

        do {
            let request = try transcriptionRetryWorkflowRequest(for: item)
            if transcriptionRetryWorkflow.startManual(
                request: request,
                runtime: transcriptionRetryWorkflowRuntime()
            ) {
                cloudTranscriptionProgressByHistoryID.removeValue(
                    forKey: item.id
                )
            }
        } catch {
            let issue = userIssue(
                for: error,
                fallbackCode: .audioUnreadable
            )
            errorMessage = issue.record.presentation().compactMessage
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
    private func transcriptionRetryWorkflowRequest(
        for item: PipelineHistoryItem
    ) throws -> TranscriptionRetryWorkflowRequest {
        guard let audioFileName = item.audioFileName,
              let audioURL = noteBrowserStoredAudioURL(for: item) else {
            throw TranscriptionError.submissionFailed(
                "Audio file not found for retry."
            )
        }

        let options = retryOptions(for: audioURL)
        guard let retryChoice = options.explicitRetryChoice else {
            let reason = options.displayRows.first(where: {
                $0.choice == currentNoteBrowserTranscriptionChoice
            })?.unavailableReason
                ?? "Selected transcription method is unavailable."
            throw TranscriptionError.submissionFailed(reason)
        }
        let configuration = audioImportConfiguration(for: retryChoice)
        let isAudioOnly = item.machineStatus == .audioOnly
        let usesStoredContext = !isAudioOnly && !disableContextCapture
        let storedContextIsUsable = usesStoredContext
            && !Self.isPlaceholderContextSummary(item.contextSummary)
        let restoredContext = AppContext(
            appName: isAudioOnly ? nil : item.contextAppName,
            bundleIdentifier: isAudioOnly ? nil : item.contextBundleIdentifier,
            windowTitle: isAudioOnly ? nil : item.contextWindowTitle,
            selectedText: isAudioOnly ? nil : item.capturedSelection,
            currentActivity: storedContextIsUsable ? item.contextSummary : "",
            contextSystemPrompt: isAudioOnly ? nil : item.contextSystemPrompt,
            contextPrompt: isAudioOnly ? nil : item.contextPrompt,
            screenshotDataURL: isAudioOnly ? nil : item.contextScreenshotDataURL,
            screenshotMimeType: !isAudioOnly
                && item.contextScreenshotDataURL != nil
                ? "image/jpeg"
                : nil,
            screenshotError: nil,
            userIssueRecord: usesStoredContext && !storedContextIsUsable
                ? QuillUserIssueRecord(code: .contextUnavailable)
                : nil
        )
        let restoredIntent = SessionIntent.fromPersisted(
            intent: item.intent,
            selectedText: item.selectedText
        )
        let retryCustomVocabulary = isAudioOnly
            ? customVocabulary
            : item.customVocabulary
        let retryCustomSystemPrompt = isAudioOnly
            ? customSystemPrompt
            : item.customSystemPrompt
        let storedTranscriptionLanguage = TranscriptionLanguage.find(
            code: item.transcriptionLanguageCode
        )
        let completion = TranscriptionCompletionSnapshot(
            postProcessingEnabled: !disablePostProcessing,
            outputLanguage: outputLanguage,
            pressEnterCommandEnabled: isPressEnterVoiceCommandEnabled
        )

        let execution: TranscriptionExecutionSnapshot
        let failureContext: TranscriptionRetryFailureContext
        if configuration.useLocalTranscription {
            execution = .local(
                LocalTranscriptionExecutionSnapshot(
                    model: configuration.localTranscriptionModel,
                    localWhisperPath: localWhisperPath.isEmpty
                        ? nil
                        : localWhisperPath,
                    useLegacyMlxWhisper: configuration.useLegacyMlxWhisper,
                    language: storedTranscriptionLanguage,
                    nativeWhisperExecution: nativeWhisperExecutionSnapshot(
                        for: retryChoice
                    )
                ),
                completion
            )
            failureContext = TranscriptionRetryFailureContext(
                fallbackCode: .localTranscriptionFailed,
                providerHost: nil,
                modelID: configuration.localTranscriptionModel.id,
                localBackend: configuration.useLegacyMlxWhisper
                    ? "Legacy MLX Whisper"
                    : "Native Whisper"
            )
        } else {
            let cloud = try CloudTranscriptionExecutionSnapshot(
                baseURL: resolvedTranscriptionBaseURL,
                apiKey: resolvedTranscriptionAPIKey,
                model: configuration.transcriptionModel,
                language: storedTranscriptionLanguage.whisperArgument,
                encodedUploadCeilingBytes: 20_000_000
            )
            execution = .cloud(cloud, completion)
            failureContext = TranscriptionRetryFailureContext(
                fallbackCode: .providerConfigurationInvalid,
                providerHost: cloud.baseURL.host,
                modelID: cloud.model,
                localBackend: nil
            )
        }

        let capturedService = makePostProcessingService()
        let capturedMacros = voiceMacros
        let capturedIntent = restoredIntent
        let capturedContext = restoredContext
        let capturedVocabulary = retryCustomVocabulary
        let capturedSystemPrompt = retryCustomSystemPrompt
        let capturedCompletion = completion
        let processing = TranscriptionRetryProcessingBehavior { transcription in
            await Self.processRetryTranscription(
                transcription,
                intent: capturedIntent,
                context: capturedContext,
                postProcessingService: capturedService,
                voiceMacros: capturedMacros,
                customVocabulary: capturedVocabulary,
                customSystemPrompt: capturedSystemPrompt,
                completion: capturedCompletion,
                trimsFinalTranscript: true
            )
        }

        return TranscriptionRetryWorkflowRequest(
            origin: .manual,
            deliveryPolicy: .interactive,
            initialItem: item,
            sourceIdentity: TranscriptionRetrySourceIdentity(
                noteID: item.id,
                noteTimestamp: item.timestamp,
                audioFileName: audioFileName
            ),
            audioURL: audioURL,
            execution: execution,
            cloudDependencies: dependencies
                .makeRetryCloudTranscriptionDependencies(),
            processing: processing,
            historyMetadata: TranscriptionRetryHistoryMetadata(
                customVocabulary: retryCustomVocabulary,
                customSystemPrompt: retryCustomSystemPrompt,
                usedLocalTranscription: configuration.useLocalTranscription,
                usedPostProcessing: completion.postProcessingEnabled,
                transcriptionLanguageCode: storedTranscriptionLanguage.code,
                localTranscriptionModelID:
                    configuration.localTranscriptionModel.id,
                successDebugStatus: "Retried"
            ),
            failureContext: failureContext
        )
    }

    @MainActor
    private func transcriptionRetryWorkflowRuntime()
        -> TranscriptionRetryWorkflowRuntime
    {
        let historyStore = pipelineHistoryStore
        let assetStore = noteAssetStore
        let jobStore = cloudTranscriptionJobStore
        let coordinator = cloudTranscriptionHistoryCoordinator
        return TranscriptionRetryWorkflowRuntime(
            history: TranscriptionRetryHistoryAccess(
                durability: { historyStore.durability },
                item: { id in
                    let history = historyStore.loadAllHistory()
                    guard historyStore.availability == .ready else {
                        throw PipelineHistoryStoreError.storeUnavailable
                    }
                    return history.first(where: { $0.id == id })
                },
                persist: { item, requiresDurableStore in
                    try historyStore.update(
                        item,
                        requiresDurableStore: requiresDurableStore
                    )
                }
            ),
            assets: TranscriptionRetryAssetAccess(
                saveTranscript: { rawTranscript, postProcessedTranscript in
                    try assetStore.saveTranscript(
                        rawTranscript: rawTranscript,
                        postProcessedTranscript: postProcessedTranscript
                    )
                },
                deleteTranscript: { fileName in
                    try assetStore.deleteTranscript(fileName: fileName)
                }
            ),
            cloud: TranscriptionRetryCloudAccess(
                jobStore: jobStore,
                cancelExistingExecution: { historyID in
                    coordinator.cancelAndInvalidate(
                        historyID: historyID,
                        store: jobStore
                    )
                }
            )
        )
    }

    @MainActor
    private static func processRetryTranscription(
        _ transcription: TranscriptionResult,
        intent: SessionIntent,
        context: AppContext,
        postProcessingService: PostProcessingService,
        voiceMacros: [VoiceMacro],
        customVocabulary: String,
        customSystemPrompt: String,
        completion: TranscriptionCompletionSnapshot,
        trimsFinalTranscript: Bool
    ) async -> TranscriptionRetryProcessingResult {
        let parsedTranscript = parseTranscriptCommands(
            from: transcription.text,
            pressEnterCommandEnabled: completion.pressEnterCommandEnabled
        )
        let macros = voiceMacros.map { macro in
            PrecomputedMacro(
                original: macro,
                normalizedCommand: normalize(macro.command)
            )
        }
        let result = await processTranscript(
            parsedTranscript.transcript,
            intent: intent,
            context: context,
            postProcessingService: postProcessingService,
            precomputedMacros: macros,
            customVocabulary: customVocabulary,
            customSystemPrompt: customSystemPrompt,
            outputLanguage: completion.outputLanguage,
            spokenLanguage: transcription.spokenLanguage,
            postProcessingEnabled: completion.postProcessingEnabled
        )
        let disposition: TranscriptionRetryProcessingDisposition
        switch result.outcome {
        case .postProcessingRawFallback,
             .postProcessingFailedFallback,
             .commandModeFailedFallback:
            disposition = .fallback
        default:
            disposition = .succeeded
        }
        let status = result.userIssueRecord?.persistedStatus
            ?? context.userIssueRecord?.persistedStatus
            ?? statusMessage(
                for: result.outcome,
                parsedTranscript: parsedTranscript,
                isRetry: true
            )
        return TranscriptionRetryProcessingResult(
            rawTranscript: parsedTranscript.transcript,
            finalTranscript: trimsFinalTranscript
                ? result.finalTranscript.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                : result.finalTranscript,
            prompt: result.prompt,
            postProcessingStatus: status,
            aiProcessingOutcome: result.aiProcessingOutcome,
            spokenLanguage: transcription.spokenLanguage,
            disposition: disposition
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

    @MainActor
    func openProviderSettings() {
        selectedSettingsTab = .models
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }

    func openMicrophoneSettings() {
        openPrivacySettingsPane("Privacy_Microphone")
    }

    func openSpeechRecognitionSettings() {
        openPrivacySettingsPane("Privacy_SpeechRecognition")
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
        let microphoneSnapshot = AudioDevice.inputDeviceSnapshot()
        availableMicrophones = microphoneSnapshot.devices
        systemDefaultMicrophoneName = microphoneSnapshot.defaultInputDeviceName
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

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshAvailableMicrophones()
            }
        }
        guard AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            listener
        ) == noErr else {
            return
        }
        defaultInputDeviceListener = listener
        defaultInputDeviceListenerAddress = address
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
    func registerSettingsDraftCommit(_ commit: @escaping () -> Void) -> UUID {
        let registrationID = UUID()
        settingsDraftCommits[registrationID] = commit
        return registrationID
    }

    @MainActor
    func unregisterSettingsDraftCommit(_ registrationID: UUID) {
        settingsDraftCommits[registrationID] = nil
    }

    @MainActor
    func commitSettingsDraftsBeforeRecordingStart() {
        let commits = Array(settingsDraftCommits.values)
        commits.forEach { $0() }
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
    @discardableResult
    func startRecordingFromMCP() -> Bool {
        guard requireAvailableHistoryForMutation() else { return false }
        if transcriptionEnabled {
            lastTranscript = ""
        }
        mcpLastRecordingFailed = false
        shortcutSessionController.beginManual(mode: .toggle)
        startRecording(triggerMode: .toggle)
        return true
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
        guard !isRecording else {
            activeRecordingCalendarSnapshot = nil
            return
        }
        if transcriptionEnabled {
            lastTranscript = ""
        }
        shortcutSessionController.beginManual(mode: .toggle)
        startRecording(triggerMode: .toggle, onStarted: onStarted)
    }

    @MainActor
    func stopRecordingFromMCP() -> MCPStopRecordingOutcome {
        guard isRecording else { return .notRecording }
        let shouldTranscribe = shouldTranscribeActiveRecording
        stopAndTranscribe()
        return shouldTranscribe ? .transcribing : .savingAudioOnly
    }

    @MainActor
    private func handleOverlayStopButtonPressed() {
        guard isRecording, activeRecordingTriggerMode == .toggle else { return }
        stopAndTranscribe()
    }

    @MainActor
    func requestTerminationWhileRecording() -> NSApplication.TerminateReply {
        if !pendingAudioOnlyStopIDs.isEmpty, !shouldConfirmTermination {
            shouldTerminateAfterTranscription = true
            return .terminateLater
        }
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

    @MainActor
    private var hasActiveModelDownload: Bool {
        isInstallingNativeWhisper || localAIWorkflow.hasActiveInstalls
    }

    @MainActor
    private func cancelNativeWhisperInstallIfNeeded() {
        guard isInstallingNativeWhisper else { return }
        cancelNativeWhisperInstall()
    }

    @MainActor
    private func cancelAllLocalAIInstalls() {
        pendingLocalAISelections.removeAll()
        for model in LocalAIModelCatalog.all {
            cancelLocalAIInstall(model)
        }
    }

    @MainActor
    func requestTerminationAfterModelCleanup(
        replyIsAlreadyPending: Bool = false
    ) -> NSApplication.TerminateReply {
        guard !isModelTerminationCleanupPending else { return .terminateLater }
        guard !isModelDownloadQuitAlertPresented else { return .terminateCancel }

        if hasActiveModelDownload {
            isModelDownloadQuitAlertPresented = true
            let response = Self.modelDownloadQuitAlertPresenter()
            isModelDownloadQuitAlertPresented = false
            guard response == .alertFirstButtonReturn else {
                if replyIsAlreadyPending {
                    Self.applicationTerminationReply(false)
                }
                return .terminateCancel
            }
        }

        cancelNativeWhisperInstallIfNeeded()
        cancelAllLocalAIInstalls()
        stopLocalAIIdleShutdownMonitoring()
        isModelTerminationCleanupPending = true
        nativeWhisperWorkflow.beginTerminationCleanup()
        localAIWorkflow.beginTerminationCleanup()
        let manager = localAIServerManager
        Task { [weak self] in
            guard let self else { return }
            await self.waitForNativeWhisperInstallToQuiesce()
            await self.waitForLocalAIInstallsToQuiesce()
            await manager.stop()
            await MainActor.run {
                Self.applicationTerminationReply(true)
            }
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
        guard shouldTerminateAfterTranscription,
              !isRecording,
              !isTranscribing,
              pendingAudioOnlyStopIDs.isEmpty else { return }
        shouldTerminateAfterTranscription = false
        _ = requestTerminationAfterModelCleanup(replyIsAlreadyPending: true)
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
                cleanupDeletedPipelineHistoryAssets(deletedAssets)
            }
        }
        if let job = foregroundTranscriptionJob(), let id = job.liveNoteID {
            updateTranscriptionJob(job.id) { $0.liveNoteID = nil }
            pipelineHistory.removeAll { $0.id == id }
            if let deletedAssets = try? pipelineHistoryStore.delete(id: id) {
                cleanupDeletedPipelineHistoryAssets(deletedAssets)
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
        activeRecordingTranscriptionEnabled = nil
        currentSessionIntent = .dictation
        isRecording = false
        errorMessage = nil
        debugStatusMessage = "Cancelled"
        let cancelledStatus = localizedCatalogString("Cancelled")
        statusText = cancelledStatus
        dismissTranscribingOverlay()
        tearDownRealtimeService()
        cancelActiveAudioRecorder()
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
        if let audioFileName = job.audioFileName,
           !pipelineHistory.contains(where: {
               $0.audioFileName == audioFileName
           }) {
            try? noteAssetStore.deleteAudio(
                fileName: audioFileName
            )
        }
        if let liveNoteID = job.liveNoteID {
            pipelineHistory.removeAll { $0.id == liveNoteID }
            if let deletedAssets = try? pipelineHistoryStore.delete(id: liveNoteID) {
                cleanupDeletedPipelineHistoryAssets(deletedAssets)
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
        guard requireAvailableHistoryForMutation() else { return }
        guard !isRecording else { return }
        commitSettingsDraftsBeforeRecordingStart()
        let t0 = CFAbsoluteTimeGetCurrent()
        os_log(.info, log: recordingLog, "startRecording() entered")

        // 전사 중이면 기존 transcribing overlay/indicator를 정리하고 소유권만 넘긴다.
        if isTranscribing {
            dismissTranscribingOverlay(resetOverlayOwner: true)
            foregroundTranscriptionJobID = nil
        }

        let scheduledSelectionSnapshot = pendingSelectionSnapshot
        let scheduledSelectionSnapshotTask = pendingSelectionSnapshotTask
        let scheduledManualCommandInvocation = pendingManualCommandInvocation
        cancelPendingShortcutStart()

        pendingRecordingStartCount += 1
        Task { [weak self] in
            guard let self else { return }
            defer { self.pendingRecordingStartCount -= 1 }
            let manualCommandRequested = scheduledSelectionSnapshot != nil
                ? scheduledManualCommandInvocation
                : hotkeyManager.currentPressedModifiers.contains(commandModeManualModifier.shortcutModifier)
            guard await prepareRecordingStart(
                triggerMode: triggerMode,
                selectionSnapshot: scheduledSelectionSnapshot,
                selectionSnapshotTask: scheduledSelectionSnapshotTask,
                manualCommandRequested: manualCommandRequested,
                startedAt: t0
            ) else {
                activeRecordingCalendarSnapshot = nil
                return
            }
            guard requireAvailableHistoryForMutation() else {
                activeRecordingCalendarSnapshot = nil
                return
            }
            guard let audioSelection = await accessibleCurrentRecordingAudioSelection() else {
                if !isAwaitingMicrophonePermission {
                    activeRecordingCalendarSnapshot = nil
                }
                return
            }
            guard requireAvailableHistoryForMutation() else {
                activeRecordingCalendarSnapshot = nil
                return
            }
            os_log(.info, log: recordingLog, "audio input access check passed: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            if AudioInputDevice.isMicrophoneOnly(audioSelection.inputID) {
                applyAudioInterruptionIfNeeded()
            }
            beginRecording(
                triggerMode: triggerMode,
                audioSelection: audioSelection,
                onStarted: onStarted
            )
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
        transcriptionEnabled && (!disableAutoPaste || isCommandModeEnabled)
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
        if !transcriptionEnabled {
            currentSessionIntent = .dictation
            overlayManager.setRecordingTriggerMode(triggerMode, animated: false)
            return true
        }
        guard !currentNoteBrowserTranscriptionChoice.usesCloudAPI
            || hasTranscriptionAPIKey else {
            let issue = QuillUserIssueRecord(code: .providerConfigurationInvalid)
            errorMessage = issue.presentation().compactMessage
            statusText = localizedCatalogString("API key required")
            debugStatusMessage = "Cloud transcription requires provider configuration"
            activeRecordingTriggerMode = nil
            currentSessionIntent = .dictation
            shortcutSessionController.reset()
            openProviderSettings()
            return false
        }

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
        pendingSpeechPermissionContext = PendingRecordingPermissionContext(
            triggerMode: triggerMode,
            selectionSnapshot: selectionSnapshot,
            manualCommandRequested: manualCommandRequested
        )
        hotkeyManager.stop()
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        activeRecordingID = nil
        activeRecordingTranscriptionEnabled = nil
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
    private func ensureRecordingInputAccess(
        for selection: RecordingAudioSelection
    ) async -> Bool {
        switch AudioRecordingSource(inputID: selection.inputID) {
        case .microphone:
            return ensureMicrophoneAccess()
        case .systemAudio:
            return await ensureSystemAudioAccess()
        case .microphoneAndSystemAudio:
            return await ensureSystemDefaultAndSystemAudioAccess()
        }
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
        let message = localizedCatalogString("Microphone + System Audio recording needs Microphone and Screen & System Audio Recording access. Enable both in System Settings > Privacy & Security.")
        errorMessage = message
        statusText = localizedCatalogString("Microphone + System Audio Required")
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
                    let pendingContext = strongSelf.pendingMicrophonePermissionContext
                    strongSelf.pendingMicrophonePermissionContext = nil
                    strongSelf.isAwaitingMicrophonePermission = false
                    strongSelf.restartHotkeyMonitoring()

                    guard let pendingContext else {
                        strongSelf.pendingRecordingStartCount -= 1
                        return
                    }
                    if granted {
                        strongSelf.errorMessage = nil
                        if pendingContext.triggerMode == .toggle {
                            Task { @MainActor [weak strongSelf] in
                                guard let strongSelf else { return }
                                defer { strongSelf.pendingRecordingStartCount -= 1 }
                                guard await strongSelf.prepareRecordingStart(
                                    triggerMode: .toggle,
                                    selectionSnapshot: pendingContext.selectionSnapshot,
                                    manualCommandRequested: pendingContext.manualCommandRequested
                                ) else { return }
                                guard strongSelf.requireAvailableHistoryForMutation() else {
                                    strongSelf.activeRecordingCalendarSnapshot = nil
                                    return
                                }
                                guard let audioSelection = await strongSelf.accessibleCurrentRecordingAudioSelection() else { return }
                                guard strongSelf.requireAvailableHistoryForMutation() else {
                                    strongSelf.activeRecordingCalendarSnapshot = nil
                                    return
                                }
                                strongSelf.shortcutSessionController.beginManual(mode: .toggle)
                                if AudioInputDevice.isMicrophoneOnly(audioSelection.inputID) {
                                    strongSelf.applyAudioInterruptionIfNeeded()
                                }
                                strongSelf.beginRecording(
                                    triggerMode: .toggle,
                                    audioSelection: audioSelection
                                )
                            }
                        } else {
                            strongSelf.pendingRecordingStartCount -= 1
                            strongSelf.currentSessionIntent = .dictation
                            strongSelf.statusText = localizedCatalogString("Microphone access granted. Press and hold again to record.")
                            strongSelf.scheduleReadyStatusReset(
                                after: 2,
                                matching: [localizedCatalogString("Microphone access granted. Press and hold again to record.")]
                            )
                        }
                    } else {
                        strongSelf.pendingRecordingStartCount -= 1
                        strongSelf.activeRecordingCalendarSnapshot = nil
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
        pendingRecordingStartCount += 1
        isAwaitingMicrophonePermission = true
        pendingMicrophonePermissionContext = PendingRecordingPermissionContext(
            triggerMode: triggerMode,
            selectionSnapshot: selectionSnapshot,
            manualCommandRequested: manualCommandRequested
        )
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
    private func beginRecording(
        triggerMode: RecordingTriggerMode,
        audioSelection: RecordingAudioSelection,
        onStarted: (@MainActor () -> Void)? = nil
    ) {
        os_log(.info, log: recordingLog, "beginRecording() entered")
        clearPendingOverlayDismissToken()
        overlayTranscriptionID = UUID()
        errorMessage = nil
        let audioInputID = audioSelection.inputID
        activeRecordingID = UUID()
        let supportsLiveTranscription = AudioRecordingSource(
            inputID: audioInputID
        ).supportsLiveTranscription
        activeRecordingTranscriptionEnabled = transcriptionEnabled
        let shouldTranscribe = shouldTranscribeActiveRecording

        if shouldTranscribe,
           supportsLiveTranscription,
           useLocalTranscription,
           localTranscriptionModel.isAppleSpeech {
            refreshSpeechRecognitionAuthorizationStatus()
            switch speechRecognitionAuthorizationStatus {
            case .authorized:
                break
            case .notDetermined:
                guard let triggerMode = activeRecordingTriggerMode else {
                    activeRecordingID = nil
                    activeRecordingTranscriptionEnabled = nil
                    return
                }
                prepareForSpeechRecognitionPermissionPrompt(
                    triggerMode: triggerMode,
                    selectionSnapshot: pendingSelectionSnapshot,
                    manualCommandRequested: currentSessionIntent.isManualCommand
                )
                requestSpeechRecognitionAccess { [weak self] granted in
                    guard let self else { return }
                    let pendingContext = self.pendingSpeechPermissionContext
                    self.pendingSpeechPermissionContext = nil
                    self.isAwaitingSpeechRecognitionPermission = false
                    self.restartHotkeyMonitoring()

                    guard let pendingContext else {
                        self.activeRecordingID = nil
                        return
                    }
                    if granted {
                        self.errorMessage = nil
                        if pendingContext.triggerMode == .toggle {
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                guard await self.prepareRecordingStart(
                                    triggerMode: .toggle,
                                    selectionSnapshot: pendingContext.selectionSnapshot,
                                    manualCommandRequested: pendingContext.manualCommandRequested
                                ) else { return }
                                guard let audioSelection = await self.accessibleCurrentRecordingAudioSelection() else { return }
                                self.shortcutSessionController.beginManual(mode: .toggle)
                                if AudioInputDevice.isMicrophoneOnly(audioSelection.inputID) {
                                    self.applyAudioInterruptionIfNeeded()
                                }
                                self.beginRecording(
                                    triggerMode: .toggle,
                                    audioSelection: audioSelection,
                                    onStarted: onStarted
                                )
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
                        self.activeRecordingCalendarSnapshot = nil
                        self.activeRecordingID = nil
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
                activeRecordingCalendarSnapshot = nil
                activeRecordingID = nil
                activeRecordingTranscriptionEnabled = nil
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

        if shouldTranscribe, supportsLiveTranscription {
            startRealtimeStreamingIfEnabled()
        }

        // Start engine on background thread so UI isn't blocked
        if shouldTranscribe,
           supportsLiveTranscription,
           useLocalTranscription,
           let transcriber = localTranscriptionModel.makeLiveTranscriber() {
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
                        let degradedSource = try await self.startSelectedAudioRecorder(selection: audioSelection)
                        let actualRecordingStartedAt = Date()
                        await MainActor.run {
                            self.markRecordingStarted(actualRecordingStartedAt)
                            if self.isRecording, self.activeRecordingTriggerMode != nil {
                                onStarted?()
                            }
                            self.showDegradedCombinedCaptureNoticeIfNeeded(degradedSource)
                        }
                        os_log(.info, log: recordingLog, "selected audio recorder start done: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    }
                    await MainActor.run {
                        guard self.isRecording, self.activeRecordingTriggerMode != nil else { return }
                        if shouldTranscribe {
                            self.startContextCapture()
                        }
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
                    let degradedSource = try await self.startSelectedAudioRecorder(selection: audioSelection)
                    let actualRecordingStartedAt = Date()
                    os_log(.info, log: recordingLog, "selected audio recorder start done: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    await MainActor.run {
                        self.markRecordingStarted(actualRecordingStartedAt)
                        guard self.isRecording, self.activeRecordingTriggerMode != nil else { return }
                        onStarted?()
                        if shouldTranscribe {
                            self.startContextCapture()
                        }
                        self.audioLevelCancellable = self.activeRecorderAudioLevelPublisher(inputID: audioInputID)
                            .receive(on: DispatchQueue.main)
                            .sink { [weak self] level in
                                self?.overlayManager.updateAudioLevel(level)
                            }
                        self.showDegradedCombinedCaptureNoticeIfNeeded(degradedSource)
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
        preserveActiveSegmentedJournalForRecovery()
        clearAudioRecorderCallbacks()
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        capturedContext = nil
        activeRecordingStartedAt = nil
        activeRecordingCalendarSnapshot = nil
        activeRecordingTranscriptionEnabled = nil
        if let liveNoteID = currentRecordingLiveNoteID {
            currentRecordingLiveNoteID = nil
            pipelineHistory.removeAll { $0.id == liveNoteID }
            if let deletedAssets = try? pipelineHistoryStore.delete(id: liveNoteID) {
                cleanupDeletedPipelineHistoryAssets(deletedAssets)
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
        let issue = userIssue(
            for: error,
            fallbackCode: .recordingInputFailed
        )
        errorMessage = issue.record.presentation().compactMessage
        statusText = localizedCatalogString("Error")
        dismissTranscribingOverlay()
        refreshAvailableMicrophonesIfNeeded()
    }

    private func userIssue(
        for error: Error,
        fallbackCode: QuillUserIssueCode = .unknown,
        localBackend: String? = nil,
        modelID: String? = nil
    ) -> QuillUserIssueError {
        if let issue = error as? QuillUserIssueError {
            return issue
        }
        if let code = Self.urlErrorCode(in: error) {
            return QuillUserIssueError.cloudTransport(
                URLError(code),
                providerHost: URL(string: resolvedTranscriptionBaseURL)?.host,
                modelID: modelID ?? resolvedStandardTranscriptionModelID
            )
        }
        let nsError = error as NSError
        return QuillUserIssueError(
            record: QuillUserIssueRecord(
                code: fallbackCode,
                context: QuillUserIssueContext(
                    providerHost: localBackend == nil
                        ? URL(string: resolvedTranscriptionBaseURL)?.host
                        : nil,
                    modelID: modelID,
                    localBackend: localBackend
                )
            ),
            privateDiagnostic: "\(nsError.domain) \(nsError.code)"
        )
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
                normalizedCommand: Self.normalize(macro.command)
            )
        }
    }

    private static func normalize(_ text: String) -> String {
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

    private static func findMatchingMacro(
        for transcript: String,
        in macros: [PrecomputedMacro]
    ) -> VoiceMacro? {
        let normalizedTranscript = normalize(transcript)
        guard !normalizedTranscript.isEmpty else { return nil }

        return macros.first {
            normalizedTranscript == $0.normalizedCommand
        }?.original
    }

    static func aiProcessingFailureReason(
        for error: Error,
        fallback: String
    ) -> String {
        if case .requestTimedOut = error as? PostProcessingError {
            return "request-timed-out"
        }
        return fallback
    }

    private enum TranscriptProcessingOutcome {
        case skippedEmptyRawTranscript
        case voiceMacro(command: String)
        case postProcessingDisabled
        case postProcessingSucceeded
        case postProcessingSkippedCooldown
        case postProcessingRawFallback(reason: AIValidationFailure)
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
            case .postProcessingSucceeded:
                return isRetry ? "Post-processing succeeded (retried)" : "Post-processing succeeded"
            case .postProcessingSkippedCooldown:
                return "Post-processing skipped while configured models cool down"
            case .postProcessingRawFallback:
                return localizedCatalogString("Post-processing was not applied; the original transcript was kept.")
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

    private static func processTranscript(
        _ rawTranscript: String,
        intent: SessionIntent,
        context: AppContext,
        postProcessingService: PostProcessingService,
        precomputedMacros: [PrecomputedMacro],
        customVocabulary: String,
        customSystemPrompt: String,
        outputLanguage: String,
        spokenLanguage: SpokenLanguageResolution,
        postProcessingEnabled: Bool
    ) async -> (
        finalTranscript: String,
        outcome: TranscriptProcessingOutcome,
        prompt: String,
        userIssueRecord: QuillUserIssueRecord?,
        aiProcessingOutcome: AIProcessingOutcome
    ) {
        let trimmedRawTranscript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedRawTranscript.isEmpty else {
            return ("", .skippedEmptyRawTranscript, "", nil, .failed(reason: "empty-raw-transcript"))
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
                return (result.transcript, outcome, result.prompt, nil, .succeeded)
            } catch {
                let issue = postProcessingService.userIssue(
                    for: error,
                    operation: .commandTransform
                )
                os_log(
                    .error,
                    log: recordingLog,
                    "Edit mode failed: %{private}@",
                    issue.privateDiagnostic
                )
                return (
                    selectedText,
                    .commandModeFailedFallback(invocation: invocation),
                    "",
                    issue.record,
                    .failed(
                        reason: Self.aiProcessingFailureReason(
                            for: error,
                            fallback: "command-transform-failed"
                        )
                    )
                )
            }
        }

        if let macro = findMatchingMacro(
            for: trimmedRawTranscript,
            in: precomputedMacros
        ) {
            os_log(.info, log: recordingLog, "Voice macro triggered: %{public}@", macro.command)
            return (macro.payload, .voiceMacro(command: macro.command), "", nil, .succeeded)
        }

        if !postProcessingEnabled {
            return (rawTranscript, .postProcessingDisabled, "", nil, .succeeded)
        }

        do {
            let result = try await postProcessingService.postProcess(
                transcript: trimmedRawTranscript,
                context: context,
                customVocabulary: customVocabulary,
                customSystemPrompt: customSystemPrompt,
                outputLanguage: outputLanguage,
                spokenLanguage: spokenLanguage
            )
            let outcome: TranscriptProcessingOutcome = result.skippedDueToCooldown
                ? .postProcessingSkippedCooldown
                : .postProcessingSucceeded
            return (result.transcript, outcome, result.prompt, nil, .succeeded)
        } catch {
            let issue = postProcessingService.userIssue(for: error)
            os_log(
                .error,
                log: recordingLog,
                "Post-processing failed: %{private}@",
                issue.privateDiagnostic
            )
            if case let .outputRejected(reason) = error as? PostProcessingError {
                return (
                    trimmedRawTranscript,
                    .postProcessingRawFallback(reason: reason),
                    "",
                    issue.record,
                    .rawFallback(reason: reason)
                )
            }
            let fallbackReason: String
            if case .emptyOutput = error as? PostProcessingError {
                fallbackReason = "empty-output"
            } else {
                fallbackReason = "post-processing-failed"
            }
            let failureReason = Self.aiProcessingFailureReason(
                for: error,
                fallback: fallbackReason
            )
            return (
                trimmedRawTranscript,
                .postProcessingFailedFallback,
                "",
                issue.record,
                .failed(reason: failureReason)
            )
        }
    }

    private static let realtimeCommitTimeoutSeconds: TimeInterval = 10

    /// Race an async operation against a timeout. If the timeout wins, the
    /// operation is cancelled (so its own cancellation handler can clean up)
    /// and `RealtimeTranscriptionError.commitTimedOut` is thrown.
    static func raceRealtimeCommitAgainstTimeout(
        timeoutSeconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw RealtimeTranscriptionError.commitTimedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw RealtimeTranscriptionError.commitTimedOut
            }
            return result
        }
    }

    /// Await the realtime WebSocket's final transcript. If it errors out (or
    /// was never started) fall back to the file-based POST so the user still
    /// gets a transcript. Runs the realtime commit and file upload in that
    /// strict order to avoid paying for both when realtime succeeds.
    private static func resolveRawTranscript(
        realtimeService: RealtimeTranscriptionService?,
        fileService: TranscriptionService,
        fileURL: URL,
        requestedLanguageCode: String
    ) async throws -> TranscriptionResult {
        if let realtimeService {
            do {
                try Task.checkCancellation()
                let text = try await Self.raceRealtimeCommitAgainstTimeout(
                    timeoutSeconds: realtimeCommitTimeoutSeconds
                ) {
                    try await withTaskCancellationHandler {
                        try await realtimeService.commitAndAwaitFinal()
                    } onCancel: {
                        realtimeService.cancel()
                    }
                }
                return TranscriptionResult(
                    text: text,
                    spokenLanguage: SpokenLanguageResolver.resolve(
                        requestedLanguageCode: requestedLanguageCode,
                        engineLanguageCode: nil,
                        transcript: text
                    )
                )
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
        let resolvedContext: AppContext
        if let sessionContext {
            resolvedContext = sessionContext
        } else if let inFlightContext = await inFlightContextTask?.value {
            resolvedContext = inFlightContext
        } else {
            resolvedContext = fallbackContextAtStop()
        }
        return Self.sanitizedCapturedContext(
            resolvedContext,
            contextCaptureDisabled: disableContextCapture
        )
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
        transcription: TranscriptionResult,
        intent: SessionIntent,
        context: AppContext,
        postProcessingService: PostProcessingService,
        customVocabulary: String,
        customSystemPrompt: String,
        outputLanguage: String,
        postProcessingEnabled: Bool,
        pressEnterCommandEnabled: Bool
    ) async throws -> StoppedTranscriptionCompletionSummary {
        let parsedTranscript = Self.parseTranscriptCommands(
            from: transcription.text,
            pressEnterCommandEnabled: pressEnterCommandEnabled
        )
        try Task.checkCancellation()
        await MainActor.run { [weak self] in
            self?.debugStatusMessage = "Running post-processing"
        }
        let result = await Self.processTranscript(
            parsedTranscript.transcript,
            intent: intent,
            context: context,
            postProcessingService: postProcessingService,
            precomputedMacros: precomputedMacros,
            customVocabulary: customVocabulary,
            customSystemPrompt: customSystemPrompt,
            outputLanguage: outputLanguage,
            spokenLanguage: transcription.spokenLanguage,
            postProcessingEnabled: postProcessingEnabled
        )
        try Task.checkCancellation()
        let processingStatus = result.userIssueRecord?.persistedStatus
            ?? context.userIssueRecord?.persistedStatus
            ?? Self.statusMessage(
                for: result.outcome,
                parsedTranscript: parsedTranscript
            )
        let outcomeWasPostProcessingFailedFallback: Bool
        switch result.outcome {
        case .postProcessingRawFallback, .postProcessingFailedFallback:
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
            spokenLanguage: transcription.spokenLanguage,
            outcomeWasPostProcessingFailedFallback: outcomeWasPostProcessingFailedFallback,
            aiProcessingOutcome: result.aiProcessingOutcome
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
            let historyID = activeTranscriptionJobs[jobID]?.liveNoteID
                ?? jobID
            let cloudContext = activeCloudTranscriptionContext(
                historyID: historyID,
                useLocalTranscription: settings.useLocalTranscription
            )
            guard isCurrentCloudTranscriptionExecution(
                historyID: historyID,
                context: cloudContext,
                requiresCloudExecution: !settings.useLocalTranscription
            ) else {
                finishTranscriptionJob(jobID, overlayID: overlayID)
                return
            }
            let historySaved = recordPipelineHistoryEntry(
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
                spokenLanguage: completion.spokenLanguage,
                customVocabularyOverride: settings.customVocabulary,
                customSystemPromptOverride: settings.customSystemPrompt,
                calendarMatch: calendarMatch,
                aiProcessingOutcome: completion.aiProcessingOutcome
            )
            completeCloudTranscriptionHistory(
                historyID: historyID,
                context: cloudContext,
                historySaved: historySaved
            )
            if let journalRecordingID = audioFileName.flatMap(
                recordingJournalID(forAudioFileName:)
            ) {
                discardRecordingJournalAfterSuccessfulTranscription(
                    recordingID: journalRecordingID
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
    private func completeStoppedRecording(
        _ completion: StoppedRecordingCompletion,
        overlayID: UUID,
        updateOwnedUI: () -> Void
    ) {
        cleanupActiveAudioRecordersIfIdle()
        if overlayTranscriptionID == overlayID {
            updateOwnedUI()
        }

        switch completion {
        case .transcriptionJob(let jobID):
            finishTranscriptionJob(jobID, overlayID: overlayID)
        case .audioOnly(let recordingID):
            pendingAudioOnlyStopIDs.remove(recordingID)
            terminateIfReady()
        }
    }

    @MainActor
    private func stopAndTranscribe() {
        guard activeRecordingStorageFailureID == nil else { return }
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
        let shouldTranscribe = shouldTranscribeActiveRecording
        activeRecordingTranscriptionEnabled = nil
        let recordingCalendarSnapshot = activeRecordingCalendarSnapshot
        let recordingStartedAt = activeRecordingStartedAt
        let recordingEndedAt = Date()
        activeRecordingStartedAt = nil
        activeRecordingCalendarSnapshot = nil

        if !shouldTranscribe {
            let audioOnlyOverlayID = overlayTranscriptionID
            capturedContext = nil
            contextCaptureTask?.cancel()
            contextCaptureTask = nil
            liveTranscriber?.cancel()
            liveTranscriber = nil
            setActiveRecorderPCMHandler(nil)
            stopAndSaveAudioOnly(
                recordingID: jobID,
                recordingStartedAt: recordingStartedAt,
                recordingEndedAt: recordingEndedAt,
                calendarSnapshot: recordingCalendarSnapshot,
                overlayID: audioOnlyOverlayID
            )
            return
        }

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

        let postProcessingService = makePostProcessingService()
        let capturedApiKey = resolvedTranscriptionAPIKey
        let capturedApiBaseURL = resolvedTranscriptionBaseURL
        let capturedUseLocalTranscription = useLocalTranscription
        let capturedLocalWhisperPath = localWhisperPath
        let capturedUseLegacyMlxWhisper = useLegacyMlxWhisper
        let capturedTranscriptionLanguage = transcriptionLanguage
        let capturedLocalTranscriptionModel = localTranscriptionModel
        let capturedTranscriptionModel = transcriptionModel
        let capturedNativeWhisperExecution = nativeWhisperExecutionSnapshot(
            useLocalTranscription: capturedUseLocalTranscription,
            localTranscriptionModel: capturedLocalTranscriptionModel,
            useLegacyMlxWhisper: capturedUseLegacyMlxWhisper
        )
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
            usedPostProcessing: !disablePostProcessing
        )
        let capturedLiveTranscriber = liveTranscriber
        let capturedPressEnterCommandEnabled = isPressEnterVoiceCommandEnabled
        let capturedNoteAssetStore = noteAssetStore
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
                    let transcription = TranscriptionResult(
                        text: rawTranscript,
                        spokenLanguage: SpokenLanguageResolver.resolve(
                            requestedLanguageCode: capturedSettings.transcriptionLanguage.code,
                            engineLanguageCode: nil,
                            transcript: rawTranscript
                        )
                    )
                    let savedAudioFile = transcriber.recordedAudioURL.flatMap { url -> SavedAudioFile? in
                        let saved = try? capturedNoteAssetStore.saveAudio(from: url)
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
                        transcription: transcription,
                        intent: sessionIntent,
                        context: appContext,
                        postProcessingService: postProcessingService,
                        customVocabulary: capturedCustomVocabulary,
                        customSystemPrompt: capturedCustomSystemPrompt,
                        outputLanguage: capturedOutputLanguage,
                        postProcessingEnabled: capturedSettings.usedPostProcessing,
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
                    let issue = self.userIssue(
                        for: error,
                        fallbackCode: .localTranscriptionFailed,
                        localBackend: "Apple Speech",
                        modelID: capturedSettings.localTranscriptionModel.id
                    )
                    let resolvedContext = await self.resolveStoppedRecordingContext(
                        sessionContext: sessionContext,
                        inFlightContextTask: inFlightContextTask
                    )
                    let errorAudioFile = transcriber.recordedAudioURL.flatMap { url -> SavedAudioFile? in
                        let saved = try? capturedNoteAssetStore.saveAudio(from: url)
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
                            processingStatus: issue.persistedStatus,
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
                        let compactMessage = issue.record.presentation().compactMessage
                        self.errorMessage = compactMessage
                        self.statusText = localizedCatalogString("Error")
                        self.overlayManager.showError(compactMessage)
                        self.lastPostProcessedTranscript = ""
                        self.lastRawTranscript = ""
                        self.lastContextSummary = ""
                        self.lastPostProcessingStatus = issue.persistedStatus
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

        stopActiveAudioRecorder { [weak self] stoppedRecording in
            guard let self else { return }
            let fileURL: URL
            let recoverableJournalID: UUID?
            switch stoppedRecording {
            case .transcribable(let transcribableURL, let journalID):
                fileURL = transcribableURL
                recoverableJournalID = journalID
            case .recoveredWithoutTranscription(let recovered):
                self.persistRecoveredRecordingWithoutTranscription(
                    recovered,
                    completion: .transcriptionJob(jobID),
                    overlayID: myOverlayID
                )
                return
            case .preservedForRecovery(_, let message):
                self.errorMessage = localizedCatalogString(
                    "Audio was preserved for recovery."
                ) + " " + message
                self.statusText = localizedCatalogString("Error")
                self.dismissTranscribingOverlay()
                self.tearDownRealtimeService()
                self.cleanupActiveAudioRecordersIfIdle()
                self.finishTranscriptionJob(jobID)
                return
            case .empty:
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

            let savedAudioFile = try? capturedNoteAssetStore
                .adoptOrSaveStoppedAudio(from: fileURL)
            let transcriptionFileURL = savedAudioFile?.fileURL ?? fileURL
            if let savedAudioFile {
                let recoveryContext = sessionContext ?? self.fallbackContextAtStop()
                let activeJob = self.activeTranscriptionJobs[jobID]
                let didPersistRecoveryPlaceholder = self.createTranscriptionRecoveryPlaceholder(
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
                    recordingEndedAt: activeJob?.recordingEndedAt,
                    postProcessingStatusOverride: capturedUseLocalTranscription
                        ? nil
                        : PipelineHistoryItem.cloudTranscribingStatus
                )
                if didPersistRecoveryPlaceholder,
                   let recoverableJournalID {
                    do {
                        try recordingJournalStore.removeInflightRecording(
                            recordingID: recoverableJournalID
                        )
                    } catch {
                        os_log(
                            .error,
                            log: recordingLog,
                            "failed to remove fallback recording journal: %{public}@",
                            error.localizedDescription
                        )
                    }
                }
            } else {
                self.updateTranscriptionJob(jobID) { $0.audioFileName = nil }
            }
            let cloudHistoryID = activeTranscriptionJobs[jobID]?.liveNoteID
                ?? jobID
            let cloudExecutionContext = self.prepareCloudTranscriptionJob(
                historyID: cloudHistoryID,
                useLocalTranscription: capturedUseLocalTranscription,
                completionPolicy: TranscriptionCompletionSnapshot(
                    postProcessingEnabled: capturedSettings.usedPostProcessing,
                    outputLanguage: capturedOutputLanguage,
                    pressEnterCommandEnabled: capturedPressEnterCommandEnabled
                )
            )
            let activeRealtime = self.realtimeService
            let activeRealtimeLanguageConfiguration = self.realtimeLanguageConfiguration
            self.realtimeService = nil
            self.realtimeLanguageConfiguration = nil
            self.setActiveRecorderPCMHandler(nil)

            if self.overlayTranscriptionID == myOverlayID {
                self.prepareTranscribingOverlay(for: myOverlayID, statusText: "Transcribing...", debugStatus: "Transcribing audio")
            }

            let task = Task { [weak self] in
                guard let self else { return }
                defer { activeRealtime?.cancel() }
                do {
                    let transcription: TranscriptionResult
                    let liveResult = try await capturedLiveTranscriber?.finalize()
                    if let text = liveResult, !text.isEmpty {
                        transcription = TranscriptionResult(
                            text: text,
                            spokenLanguage: SpokenLanguageResolver.resolve(
                                requestedLanguageCode: capturedSettings.transcriptionLanguage.code,
                                engineLanguageCode: nil,
                                transcript: text
                            )
                        )
                    } else {
                        let transcriptionService = try TranscriptionService(
                            apiKey: capturedApiKey,
                            baseURL: capturedApiBaseURL,
                            useLocalTranscription: capturedUseLocalTranscription,
                            localWhisperPath: capturedLocalWhisperPath.isEmpty ? nil : capturedLocalWhisperPath,
                            useLegacyMlxWhisper: capturedUseLegacyMlxWhisper,
                            transcriptionLanguage: capturedTranscriptionLanguage,
                            localTranscriptionModel: capturedLocalTranscriptionModel,
                            transcriptionModel: capturedTranscriptionModel,
                            nativeWhisperExecution: capturedNativeWhisperExecution,
                            cloudExecutionContext: cloudExecutionContext
                        )
                        transcription = try await Self.resolveRawTranscript(
                            realtimeService: activeRealtime,
                            fileService: transcriptionService,
                            fileURL: transcriptionFileURL,
                            requestedLanguageCode: activeRealtimeLanguageConfiguration?.requestedLanguageCode
                                ?? capturedSettings.transcriptionLanguage.code
                        )
                    }
                    try Task.checkCancellation()
                    let isCurrentCloudExecution = await MainActor.run {
                        self.isCurrentCloudTranscriptionExecution(
                            historyID: cloudHistoryID,
                            context: cloudExecutionContext,
                            requiresCloudExecution: !capturedUseLocalTranscription
                        )
                    }
                    guard isCurrentCloudExecution else { return }
                    let rawTranscript = transcription.text
                    await MainActor.run {
                        self.bootstrapLastTranscriptForPasteAgain(rawTranscript, pressEnterCommandEnabled: capturedPressEnterCommandEnabled)
                    }
                    let appContext = await self.resolveStoppedRecordingContext(
                        sessionContext: sessionContext,
                        inFlightContextTask: inFlightContextTask
                    )
                    let completion = try await self.makeStoppedTranscriptionCompletionSummary(
                        transcription: transcription,
                        intent: sessionIntent,
                        context: appContext,
                        postProcessingService: postProcessingService,
                        customVocabulary: capturedCustomVocabulary,
                        customSystemPrompt: capturedCustomSystemPrompt,
                        outputLanguage: capturedOutputLanguage,
                        postProcessingEnabled: capturedSettings.usedPostProcessing,
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
                        self.finishCloudTranscriptionJob(
                            historyID: cloudHistoryID,
                            context: cloudExecutionContext
                        )
                        self.finishTranscriptionJob(jobID, overlayID: myOverlayID)
                    }
                } catch {
                    let issue = self.userIssue(
                        for: error,
                        fallbackCode: capturedUseLocalTranscription
                            ? .localTranscriptionFailed
                            : .providerConfigurationInvalid,
                        modelID: capturedUseLocalTranscription
                            ? capturedLocalTranscriptionModel.id
                            : capturedTranscriptionModel
                    )
                    let resolvedContext = await self.resolveStoppedRecordingContext(
                        sessionContext: sessionContext,
                        inFlightContextTask: inFlightContextTask
                    )
                    let calendarMatch = await self.calendarMatchForHistoryItem(jobID: jobID)
                    await MainActor.run {
                        guard self.isCurrentCloudTranscriptionExecution(
                            historyID: cloudHistoryID,
                            context: cloudExecutionContext,
                            requiresCloudExecution: !capturedUseLocalTranscription
                        ) else {
                            self.finishTranscriptionJob(
                                jobID,
                                overlayID: myOverlayID
                            )
                            return
                        }
                        self.finishCloudTranscriptionJob(
                            historyID: cloudHistoryID,
                            context: cloudExecutionContext
                        )
                        self.recordPipelineHistoryEntry(
                            jobID: jobID,
                            rawTranscript: "",
                            postProcessedTranscript: "",
                            postProcessingPrompt: "",
                            systemPrompt: Self.resolvedSystemPrompt(capturedSettings.customSystemPrompt),
                            context: resolvedContext,
                            processingStatus: issue.persistedStatus,
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
                        let compactMessage = issue.record.presentation().compactMessage
                        self.errorMessage = compactMessage
                        self.statusText = localizedCatalogString("Error")
                        self.overlayManager.showError(compactMessage)
                        self.lastPostProcessedTranscript = ""
                        self.lastRawTranscript = ""
                        self.lastContextSummary = ""
                        self.lastPostProcessingStatus = issue.persistedStatus
                        self.lastPostProcessingPrompt = ""
                        self.lastContextScreenshotDataURL = resolvedContext.screenshotDataURL
                        self.lastContextScreenshotStatus = resolvedContext.screenshotError
                            ?? "available (\(resolvedContext.screenshotMimeType ?? "image"))"
                        self.finishTranscriptionJob(jobID, overlayID: myOverlayID)
                    }
                }
            }
            self.updateTranscriptionJob(jobID) { $0.task = task }
            self.installCloudTranscriptionTask(
                task,
                historyID: cloudHistoryID,
                context: cloudExecutionContext
            )
        }
    }

    @MainActor
    private func stopAndSaveAudioOnly(
        recordingID: UUID,
        recordingStartedAt: Date?,
        recordingEndedAt: Date,
        calendarSnapshot: RecordingCalendarSnapshot?,
        overlayID: UUID
    ) {
        pendingAudioOnlyStopIDs.insert(recordingID)
        isRecording = false
        restoreAudioInterruptionIfNeeded()
        refreshTranscribingState()
        errorMessage = nil
        tearDownRealtimeService()

        stopActiveAudioRecorder { [weak self] stoppedRecording in
            guard let self else { return }
            switch stoppedRecording {
            case .transcribable(let fileURL, _):
                guard let savedAudioFile = try? noteAssetStore
                    .adoptOrSaveStoppedAudio(from: fileURL) else {
                    self.completeStoppedRecording(
                        .audioOnly(recordingID),
                        overlayID: overlayID
                    ) {
                        self.errorMessage = localizedCatalogString("No audio recorded")
                        self.statusText = localizedCatalogString("Error")
                        self.dismissTranscribingOverlay()
                    }
                    return
                }

                Task { [weak self] in
                    guard let self else { return }
                    let calendarMatch = await self.calendarMatchForStoppedRecording(
                        recordingStartedAt: recordingStartedAt,
                        recordingEndedAt: recordingEndedAt,
                        calendarSnapshot: calendarSnapshot
                    )
                    await MainActor.run {
                        self.persistAudioOnlyRecording(
                            recordingID: recordingID,
                            recordingStartedAt: recordingStartedAt,
                            recordingEndedAt: recordingEndedAt,
                            calendarMatch: calendarMatch,
                            audioFileName: savedAudioFile.fileName,
                            overlayID: overlayID
                        )
                    }
                }

            case .recoveredWithoutTranscription(let recovered):
                self.persistRecoveredRecordingWithoutTranscription(
                    recovered,
                    completion: .audioOnly(recordingID),
                    overlayID: overlayID
                )

            case .preservedForRecovery(_, let message):
                self.completeStoppedRecording(
                    .audioOnly(recordingID),
                    overlayID: overlayID
                ) {
                    self.errorMessage = localizedCatalogString("Audio was preserved for recovery.") + " " + message
                    self.statusText = localizedCatalogString("Error")
                    self.dismissTranscribingOverlay()
                }

            case .empty:
                self.mcpLastRecordingFailed = true
                self.completeStoppedRecording(
                    .audioOnly(recordingID),
                    overlayID: overlayID
                ) {
                    self.errorMessage = localizedCatalogString("No audio recorded")
                    self.statusText = localizedCatalogString("Error")
                    self.dismissTranscribingOverlay()
                }
            }
        }
    }

    @MainActor
    private func scheduleCloudTranscriptionAutoResume(
        _ reconciliation: CloudTranscriptionReconciliation,
        cloudDependenciesFactory:
            @escaping @Sendable () -> CloudTranscriptionDependencies,
        postProcessingService: PostProcessingService,
        voiceMacros: [VoiceMacro]
    ) {
        guard hasTranscriptionAPIKey else { return }

        let runtime: CloudTranscriptionExecutionSnapshot
        do {
            runtime = try CloudTranscriptionExecutionSnapshot(
                baseURL: resolvedTranscriptionBaseURL,
                apiKey: resolvedTranscriptionAPIKey,
                model: resolvedStandardTranscriptionModelID,
                language: transcriptionLanguage.whisperArgument,
                encodedUploadCeilingBytes: 20_000_000
            )
        } catch {
            return
        }

        let input = TranscriptionRetryStartupInput(
            reconciliation: reconciliation,
            runtime: runtime,
            history: pipelineHistory,
            audioDirectory: storageLayout.audioDirectory,
            cloudDependenciesFactory: cloudDependenciesFactory,
            makeProcessingBehavior: { item, completion in
                let intent = SessionIntent.fromPersisted(
                    intent: item.intent,
                    selectedText: item.selectedText
                )
                let context = AppContext(
                    appName: item.contextAppName,
                    bundleIdentifier: item.contextBundleIdentifier,
                    windowTitle: item.contextWindowTitle,
                    selectedText: item.capturedSelection,
                    currentActivity: item.contextSummary,
                    contextSystemPrompt: item.contextSystemPrompt,
                    contextPrompt: item.contextPrompt,
                    screenshotDataURL: item.contextScreenshotDataURL,
                    screenshotMimeType: item.contextScreenshotDataURL != nil
                        ? "image/jpeg"
                        : nil,
                    screenshotError: nil
                )
                let customVocabulary = item.customVocabulary
                let customSystemPrompt = item.customSystemPrompt
                return TranscriptionRetryProcessingBehavior { transcription in
                    await Self.processRetryTranscription(
                        transcription,
                        intent: intent,
                        context: context,
                        postProcessingService: postProcessingService,
                        voiceMacros: voiceMacros,
                        customVocabulary: customVocabulary,
                        customSystemPrompt: customSystemPrompt,
                        completion: completion,
                        trimsFinalTranscript: false
                    )
                }
            }
        )
        transcriptionRetryWorkflow.resumeAtStartup(
            input: input,
            runtime: transcriptionRetryWorkflowRuntime()
        )
    }

    @MainActor
    private func installCloudTranscriptionTask(
        _ task: Task<Void, Never>,
        historyID: UUID,
        context: CloudTranscriptionExecutionContext?
    ) {
        guard let context else { return }
        cloudTranscriptionHistoryCoordinator.install(
            task: task,
            historyID: historyID,
            session: context.session
        )
    }

    @MainActor
    private func isCurrentCloudTranscriptionExecution(
        historyID: UUID,
        context: CloudTranscriptionExecutionContext?,
        requiresCloudExecution: Bool
    ) -> Bool {
        guard let context else { return !requiresCloudExecution }
        return cloudTranscriptionHistoryCoordinator.isActive(
            historyID: historyID,
            session: context.session
        )
    }

    @MainActor
    private func prepareCloudTranscriptionJob(
        historyID: UUID,
        useLocalTranscription: Bool,
        completionPolicy: TranscriptionCompletionSnapshot
    ) -> CloudTranscriptionExecutionContext? {
        guard !useLocalTranscription else { return nil }
        let session = cloudTranscriptionJobStore.beginSession(
            historyID: historyID
        )
        cloudTranscriptionHistoryCoordinator.activate(
            historyID: historyID,
            session: session
        )
        let checkpointStore = cloudTranscriptionJobStore.checkpointStore(
            session: session,
            completionPolicy: completionPolicy.cloudJobPolicy
        )
        return CloudTranscriptionExecutionContext(
            historyID: historyID,
            session: session,
            checkpointStore: checkpointStore,
            progress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.updateCloudTranscriptionProgress(
                        progress,
                        historyID: historyID,
                        session: session
                    )
                }
            }
        )
    }

    @MainActor
    private func activeCloudTranscriptionContext(
        historyID: UUID,
        useLocalTranscription: Bool
    ) -> CloudTranscriptionExecutionContext? {
        guard !useLocalTranscription else { return nil }
        return cloudTranscriptionHistoryCoordinator.context(
            historyID: historyID,
            store: cloudTranscriptionJobStore
        )
    }

    @MainActor
    private func updateCloudTranscriptionProgress(
        _ progress: CloudTranscriptionProgress,
        historyID: UUID,
        session: CloudTranscriptionJobSession
    ) {
        let displayProgress: CloudTranscriptionDisplayProgress
        switch progress {
        case .planned(let completed, let total):
            displayProgress = CloudTranscriptionDisplayProgress(
                completedChunkCount: completed,
                totalChunkCount: total,
                activeAttempt: nil
            )
        case .uploading(let index, let total, let attempt):
            displayProgress = CloudTranscriptionDisplayProgress(
                completedChunkCount: index,
                totalChunkCount: total,
                activeAttempt: attempt
            )
        case .completed(let total):
            displayProgress = CloudTranscriptionDisplayProgress(
                completedChunkCount: total,
                totalChunkCount: total,
                activeAttempt: nil
            )
        }
        guard cloudTranscriptionHistoryCoordinator.updateProgress(
            displayProgress,
            historyID: historyID,
            session: session
        ) else {
            return
        }
        cloudTranscriptionProgressByHistoryID[historyID] = displayProgress
    }

    @MainActor
    private func completeCloudTranscriptionHistory(
        historyID: UUID,
        context: CloudTranscriptionExecutionContext?,
        historySaved: Bool
    ) {
        guard let context,
              isCurrentCloudTranscriptionExecution(
                historyID: historyID,
                context: context,
                requiresCloudExecution: true
              ) else {
            return
        }
        defer {
            finishCloudTranscriptionJob(
                historyID: historyID,
                context: context
            )
        }
        guard historySaved,
              (try? cloudTranscriptionJobStore.load(historyID: historyID)) != nil else {
            return
        }
        do {
            try cloudTranscriptionJobStore.deleteCompletedJob(
                historyID: historyID,
                session: context.session
            )
        } catch {
            errorMessage = LocalizedUserMessage.providerFailure(
                prefix: localizedCatalogString(
                    "Unable to finish cloud transcription"
                ),
                providerDetail: error.localizedDescription
            )
        }
    }

    @MainActor
    private func finishCloudTranscriptionJob(
        historyID: UUID,
        context: CloudTranscriptionExecutionContext?
    ) {
        guard let context,
              isCurrentCloudTranscriptionExecution(
                historyID: historyID,
                context: context,
                requiresCloudExecution: true
              ) else {
            return
        }
        cloudTranscriptionHistoryCoordinator.finish(
            historyID: historyID,
            session: context.session
        )
        cloudTranscriptionJobStore.invalidateSession(historyID: historyID)
        cloudTranscriptionProgressByHistoryID.removeValue(forKey: historyID)
        retryingItemIDs.remove(historyID)
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
                cleanupDeletedPipelineHistoryAssets(removedAssets)
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
            spokenLanguageCode: existing.spokenLanguageCode,
            spokenLanguageResolution: existing.spokenLanguageResolution,
            meetingSummaryAttempt: existing.meetingSummaryAttempt,
            localTranscriptionModelID: existing.localTranscriptionModelID,
            transcriptFileName: existing.transcriptFileName,
            contextAppName: existing.contextAppName,
            contextBundleIdentifier: existing.contextBundleIdentifier,
            contextWindowTitle: existing.contextWindowTitle,
            customTitle: existing.customTitle,
            meetingSummaryJSON: existing.meetingSummaryJSON
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

    enum AudioOnlyPersistenceFailureCleanupDecision: Equatable {
        case preserve
        case deleteUnreferencedAudio
    }

    static func audioOnlyPersistenceFailureCleanupDecision(
        hasJournalOwner: Bool,
        historyIsAvailableAndDurable: Bool,
        historyIsReadable: Bool,
        recordingIDExistsInHistory: Bool
    ) -> AudioOnlyPersistenceFailureCleanupDecision {
        guard !hasJournalOwner,
              historyIsAvailableAndDurable,
              historyIsReadable,
              !recordingIDExistsInHistory else {
            return .preserve
        }
        return .deleteUnreferencedAudio
    }

    @MainActor
    private func persistAudioOnlyRecording(
        recordingID: UUID,
        recordingStartedAt: Date?,
        recordingEndedAt: Date,
        calendarMatch: CalendarEventMatch?,
        audioFileName: String,
        overlayID: UUID
    ) {
        let item = PipelineHistoryItem.audioOnly(
            id: recordingID,
            timestamp: recordingEndedAt,
            recordingStartedAt: recordingStartedAt,
            recordingEndedAt: recordingEndedAt,
            calendarMatch: calendarMatch,
            audioFileName: audioFileName,
            transcriptionLanguageCode: transcriptionLanguage.code,
            localTranscriptionModelID: localTranscriptionModel.id
        )
        let journalRecordingID = recordingJournalID(
            forAudioFileName: audioFileName
        )

        do {
            let removed = try appendPipelineHistoryItem(item)
            for assets in removed {
                cleanupDeletedPipelineHistoryAssets(assets)
            }
            if let journalRecordingID {
                completePromotedRecordingJournal(
                    recordingID: journalRecordingID
                )
            }
            mcpLastRecordingFailed = false
            completeStoppedRecording(
                .audioOnly(recordingID),
                overlayID: overlayID
            ) {
                self.statusText = localizedCatalogString("Recording saved")
                self.debugStatusMessage = "Recording saved"
                self.errorMessage = nil
                self.dismissTranscribingOverlay()
                self.scheduleReadyStatusReset(
                    after: 3,
                    matching: [localizedCatalogString("Recording saved")]
                )
            }
        } catch {
            let historyWasAvailableAndDurable =
                pipelineHistoryStore.availability == .ready
                && pipelineHistoryStore.durability == .durable
            let historyWasReadable = historyWasAvailableAndDurable
                && pipelineHistoryStore.verifyHistoryReadable()
            let history = historyWasReadable
                ? pipelineHistoryStore.loadAllHistory()
                : []
            let audioFileIsReferenced = history.contains {
                $0.audioFileName == audioFileName
            }
            let historyIsStillAvailableAndDurable =
                pipelineHistoryStore.availability == .ready
                && pipelineHistoryStore.durability == .durable
            let cleanupDecision = Self
                .audioOnlyPersistenceFailureCleanupDecision(
                    hasJournalOwner: journalRecordingID != nil,
                    historyIsAvailableAndDurable:
                        historyWasAvailableAndDurable
                        && historyIsStillAvailableAndDurable,
                    historyIsReadable: historyWasReadable,
                    recordingIDExistsInHistory: history.contains {
                        $0.id == recordingID
                    } || audioFileIsReferenced
                )
            if cleanupDecision == .deleteUnreferencedAudio {
                try? noteAssetStore.deleteAudio(
                    fileName: audioFileName
                )
            }
            let message = userIssue(for: error).record.presentation().compactMessage
            completeStoppedRecording(
                .audioOnly(recordingID),
                overlayID: overlayID
            ) {
                self.errorMessage = message
                self.statusText = localizedCatalogString("Error")
                self.dismissTranscribingOverlay()
            }
        }
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
    private func persistRecoveredRecordingWithoutTranscription(
        _ recovered: RecoveredRecordingArtifact,
        completion: StoppedRecordingCompletion,
        overlayID: UUID
    ) {
        let presentation: (errorMessage: String, statusText: String)
        do {
            let removedAssets = try RecordingRecoveryHistory(
                journalStore: recordingJournalStore,
                historyStore: pipelineHistoryStore
            ).persist(recovered, maxCount: maxPipelineHistoryCount)
            for assets in removedAssets {
                cleanupDeletedPipelineHistoryAssets(assets)
            }
            if let item = pipelineHistoryStore.loadAllHistory().first(where: {
                $0.id == recovered.recordingID
            }) {
                let normalized = item.isIncompleteTranscription
                    ? item.markInterruptedBeforeCompletion()
                    : item
                if normalized.postProcessingStatus != item.postProcessingStatus {
                    try pipelineHistoryStore.update(normalized)
                }
            }
            pipelineHistory = Self.markInterruptedRecoveryPlaceholders(
                in: pipelineHistoryStore.loadAllHistory(),
                store: pipelineHistoryStore
            )
            presentation = (
                localizedCatalogString(recovered.mode.descriptionLocalizationKey),
                localizedCatalogString(recovered.mode.titleLocalizationKey)
            )
        } catch {
            presentation = (
                LocalizedUserMessage.providerFailure(
                    prefix: localizedCatalogString("Unable to save recovery entry"),
                    providerDetail: error.localizedDescription
                ),
                localizedCatalogString("Error")
            )
        }
        tearDownRealtimeService()
        completeStoppedRecording(
            completion,
            overlayID: overlayID
        ) {
            self.errorMessage = presentation.errorMessage
            self.statusText = presentation.statusText
            self.dismissTranscribingOverlay()
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
        recordingEndedAt: Date?,
        postProcessingStatusOverride: String? = nil
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
            contextWindowTitle: context.windowTitle,
            postProcessingStatusOverride: postProcessingStatusOverride
        )
        do {
            let removedStoredFiles = try pipelineHistoryStore.upsert(
                item,
                maxCount: maxPipelineHistoryCount,
                requiresDurableStore: true
            )
            for removedAssets in removedStoredFiles {
                cleanupDeletedPipelineHistoryAssets(removedAssets)
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

    private func calendarMatchForStoppedRecording(
        recordingStartedAt: Date?,
        recordingEndedAt: Date,
        calendarSnapshot: RecordingCalendarSnapshot?
    ) async -> CalendarEventMatch? {
        if let calendarSnapshot,
           let calendarID = calendarSnapshot.calendarID,
           let eventID = calendarSnapshot.eventID,
           let title = calendarSnapshot.title,
           let start = calendarSnapshot.startDate,
           let end = calendarSnapshot.endDate {
            let matchSource = CalendarMatchSource(
                rawValue: calendarSnapshot.matchSource ?? ""
            ) ?? .calendarNotification
            let attendees = calendarSnapshot.attendeeNames.map {
                CalendarEventAttendee(
                    displayName: $0,
                    email: nil,
                    responseStatus: nil,
                    isOptional: false,
                    isSelf: false
                )
            }
            return CalendarEventMatch(
                calendarID: calendarID,
                eventID: eventID,
                title: title,
                start: start,
                end: end,
                attendees: attendees,
                matchSource: matchSource,
                titleState: .applied
            )
        }

        guard let recordingStartedAt else { return nil }
        return await calendarEventMatch(
            recordingStartedAt: recordingStartedAt,
            recordingEndedAt: recordingEndedAt
        )
    }

    private func calendarEventMatch(
        recordingStartedAt: Date,
        recordingEndedAt: Date
    ) async -> CalendarEventMatch? {
        guard recordingEndedAt > recordingStartedAt else { return nil }
        let selectedCalendarIDs = await MainActor.run {
            googleCalendarConnection.selectedCalendarIDs
        }
        guard !selectedCalendarIDs.isEmpty else { return nil }

        do {
            guard let token = try await validGoogleCalendarToken() else {
                await MainActor.run {
                    markGoogleCalendarNeedsReconnect(
                        feature: .recordingMatch,
                        message: localizedCatalogString("Google Calendar needs reconnecting. Calendar-based note titles may be unavailable.")
                    )
                }
                return nil
            }
            let fetchResult = await Self.googleCalendarServiceFactory()
                .fetchEventsWithDiagnostics(
                    accessToken: token.accessToken,
                    calendarIDs: Array(selectedCalendarIDs),
                    timeMin: recordingStartedAt,
                    timeMax: recordingEndedAt
                )
            await MainActor.run {
                if fetchResult.failedCalendarIDs.isEmpty {
                    markGoogleCalendarHealthy(feature: .recordingMatch)
                } else {
                    markGoogleCalendarTemporarilyUnavailable(
                        feature: .recordingMatch,
                        message: localizedCatalogString("Some Google calendars could not be refreshed. Calendar-based note titles may be incomplete.")
                    )
                }
            }
            guard let event = CalendarEventMatcher.bestMatch(
                recordingStartedAt: recordingStartedAt,
                recordingEndedAt: recordingEndedAt,
                events: fetchResult.events
            ) else { return nil }
            return event.match(
                accountID: token.accountEmail,
                source: .overlapSuggestion,
                titleState: .suggested
            )
        } catch {
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
        return await calendarEventMatch(
            recordingStartedAt: recordingStartedAt,
            recordingEndedAt: recordingEndedAt
        )
    }

    @MainActor
    @discardableResult
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
        spokenLanguage: SpokenLanguageResolution? = nil,
        customVocabularyOverride: String? = nil,
        customSystemPromptOverride: String? = nil,
        calendarMatch: CalendarEventMatch? = nil,
        aiProcessingOutcome: AIProcessingOutcome = .succeeded
    ) -> Bool {
        guard !isHistoryRecoveryOperationInProgress else { return false }
        let existingID = activeTranscriptionJobs[jobID]?.liveNoteID
        let existingEntry = existingID.flatMap { id in
            pipelineHistory.first(where: { $0.id == id })
        }
        let previousTranscriptFileName = existingEntry?.transcriptFileName
        let transcriptFileName = try? noteAssetStore.saveTranscript(
            rawTranscript: rawTranscript,
            postProcessedTranscript: postProcessedTranscript
        )
        updateTranscriptionJob(jobID) {
            $0.liveNoteID = nil
            $0.audioFileName = audioFileName
        }
        let journalRecordingID = audioFileName.flatMap(
            recordingJournalID(forAudioFileName:)
        )
        let isJournalAudioFile = journalRecordingID != nil
        let entryID = existingID ?? (journalRecordingID ?? UUID())
        let effectiveSpokenLanguage = spokenLanguage ?? existingEntry?.spokenLanguage
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
            aiProcessingOutcome: aiProcessingOutcome.pipelineHistoryStatus,
            debugStatus: debugStatusMessage,
            customVocabulary: customVocabularyOverride ?? customVocabulary,
            customSystemPrompt: customSystemPromptOverride ?? customSystemPrompt,
            audioFileName: audioFileName,
            usedLocalTranscription: useLocalTranscriptionOverride ?? useLocalTranscription,
            usedContextCapture: usedContextCaptureOverride ?? !disableContextCapture,
            usedPostProcessing: usedPostProcessingOverride ?? !disablePostProcessing,
            transcriptionLanguageCode: transcriptionLanguageCodeOverride ?? transcriptionLanguage.code,
            spokenLanguageCode: effectiveSpokenLanguage?.languageCode,
            spokenLanguageResolution: effectiveSpokenLanguage?.source,
            meetingSummaryAttempt: existingEntry?.meetingSummaryAttempt,
            localTranscriptionModelID: localTranscriptionModelIDOverride ?? localTranscriptionModel.id,
            transcriptFileName: transcriptFileName,
            contextAppName: context.appName,
            contextBundleIdentifier: context.bundleIdentifier,
            contextWindowTitle: context.windowTitle,
            customTitle: existingEntry?.customTitle,
            meetingSummaryJSON: existingEntry?.meetingSummaryJSON
        )
        var historySaved = false
        do {
            if existingID != nil {
                try pipelineHistoryStore.update(entry)
                if let previousTranscriptFileName,
                   previousTranscriptFileName != transcriptFileName,
                   !pipelineHistory.contains(where: {
                       $0.id != existingID
                           && $0.transcriptFileName == previousTranscriptFileName
                   }) {
                    try? noteAssetStore.deleteTranscript(
                        fileName: previousTranscriptFileName
                    )
                }
            } else {
                let removedStoredFiles = try appendPipelineHistoryItem(entry)
                for removedAssets in removedStoredFiles {
                    cleanupDeletedPipelineHistoryAssets(removedAssets)
                }
            }
            updatePipelineHistoryItem(entry)
            historySaved = true
            if let journalRecordingID {
                completePromotedRecordingJournal(
                    recordingID: journalRecordingID
                )
            }
        } catch {
            if existingID == nil, !isJournalAudioFile {
                try? noteAssetStore.deleteAssets(
                    audioFileName: audioFileName,
                    transcriptFileName: transcriptFileName
                )
            } else if let transcriptFileName {
                try? noteAssetStore.deleteTranscript(
                    fileName: transcriptFileName
                )
            }
            let issue = self.userIssue(for: error)
            errorMessage = issue.record.presentation().compactMessage
        }

        // MCP notification
        if historySaved,
           !postProcessedTranscript.isEmpty,
           let callback = onTranscriptionCompleted {
            let context = mcpAdditionalContext
            mcpAdditionalContext = ""
            callback(postProcessedTranscript, context)
        }
        return historySaved
    }

    private func startRealtimeStreamingIfEnabled() {
        guard realtimeStreamingEnabled, !useLocalTranscription else { return }
        let trimmedBase = resolvedTranscriptionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else {
            os_log(.info, log: recordingLog, "realtime streaming requested but base URL is empty — skipping")
            return
        }
        let model = realtimeStreamingModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let realtimeLanguageConfiguration = RealtimeTranscriptionLanguageConfiguration(
            transcriptionLanguage: transcriptionLanguage
        )
        let config = RealtimeTranscriptionService.Configuration(
            baseURL: trimmedBase,
            apiKey: resolvedTranscriptionAPIKey,
            model: model,
            language: realtimeLanguageConfiguration.requestLanguage
        )
        let service = RealtimeTranscriptionService(config: config)
        do {
            try service.start()
        } catch {
            os_log(.error, log: recordingLog, "failed to start realtime service: %{public}@", error.localizedDescription)
            return
        }
        realtimeService = service
        self.realtimeLanguageConfiguration = realtimeLanguageConfiguration
        setActiveRecorderPCMHandler { [weak service] data in
            service?.appendPCM16(data)
        }
    }

    private func tearDownRealtimeService() {
        setActiveRecorderPCMHandler(nil)
        realtimeService?.cancel()
        realtimeService = nil
        realtimeLanguageConfiguration = nil
    }

    /// Detaches the active live transcriber and tears it down off the main
    /// thread. Cancelling/deallocating an Apple Speech session is synchronous
    /// and can stall for a few hundred ms; doing it inline (e.g. from the
    /// audio-source menu action that triggers a mid-recording input switch)
    /// keeps the menu open and freezes the UI. The reference is dropped from
    /// AppState immediately; cancel() and dealloc run on a background queue.
    @MainActor
    private func tearDownLiveTranscriberOffMainThread() {
        guard let transcriber = liveTranscriber else { return }
        liveTranscriber = nil
        DispatchQueue.global(qos: .utility).async {
            transcriber.cancel()
        }
    }

    @MainActor
    private func startContextCapture() {
        contextCaptureTask?.cancel()
        capturedContext = nil

        guard isAIProcessingChoiceCompatible(contextBackendChoice, for: .context) else {
            disableContextCapture = true
            updateContextModelCapabilityWarning()
            lastContextSummary = "Context unavailable"
            lastPostProcessingStatus = "Context unavailable"
            lastContextScreenshotDataURL = nil
            lastContextScreenshotStatus = "Unavailable"
            return
        }

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

        let contextService = contextService
        contextCaptureTask = Task { [weak self] in
            guard let self else { return nil }
            let context = await contextService.collectContext()
            guard !Task.isCancelled else { return nil }
            await MainActor.run {
                guard !Task.isCancelled else { return }
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
                self.lastPostProcessingStatus = context.userIssueRecord?.persistedStatus
                    ?? "App context captured"
                self.handleScreenshotCaptureIssue(context.screenshotError)
            }
            return context
        }
    }

    // Old notes may still carry the stop-time placeholder sentence in their
    // stored contextSummary; both that literal and a genuinely empty summary
    // count as "no usable context" rather than real captured activity.
    private static func isPlaceholderContextSummary(_ summary: String) -> Bool {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return trimmed == "Could not refresh app context at stop time; using text-only post-processing."
    }

    // Context is only worth injecting into post-processing when it was
    // successfully captured: real (non-placeholder) activity text, and no
    // issue of any severity was recorded while collecting it. A recorded
    // issue means the capture failed, even when it is only ever shown to
    // the user as a warning.
    private static func isUsableCapturedContext(_ context: AppContext) -> Bool {
        guard !isPlaceholderContextSummary(context.currentActivity) else { return false }
        guard context.userIssueRecord == nil else { return false }
        return true
    }

    // Context capture being turned off is intentional and already produces an
    // empty, issue-free context (see fallbackContextAtStop). Only sanitize
    // when capture is enabled but did not actually succeed: drop the
    // placeholder/error text instead of injecting it, and surface a warning
    // (not an error) so the note still shows as completed.
    private static func sanitizedCapturedContext(
        _ context: AppContext,
        contextCaptureDisabled: Bool
    ) -> AppContext {
        guard !contextCaptureDisabled else { return context }
        guard !isUsableCapturedContext(context) else { return context }
        return AppContext(
            appName: context.appName,
            bundleIdentifier: context.bundleIdentifier,
            windowTitle: context.windowTitle,
            selectedText: context.selectedText,
            currentActivity: "",
            contextSystemPrompt: context.contextSystemPrompt,
            contextPrompt: context.contextPrompt,
            screenshotDataURL: context.screenshotDataURL,
            screenshotMimeType: context.screenshotMimeType,
            screenshotError: context.screenshotError,
            userIssueRecord: context.userIssueRecord ?? QuillUserIssueRecord(code: .contextUnavailable)
        )
    }

    private func fallbackContextAtStop() -> AppContext {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let windowTitle = focusedWindowTitle(for: frontmostApp)
        // Context capture being off is an intentional setting, not a failure.
        // Leave currentActivity empty so post-processing runs genuinely
        // text-only (empty CONTEXT in the prompt, nothing to echo back) and the
        // note shows no context line — instead of injecting a placeholder
        // sentence that reads like an error.
        let currentActivity = disableContextCapture
            ? ""
            : "Could not refresh app context at stop time; using text-only post-processing."
        let screenshotError = disableContextCapture
            ? "Context capture disabled"
            : "No app context captured before stop"
        return AppContext(
            appName: frontmostApp?.localizedName,
            bundleIdentifier: frontmostApp?.bundleIdentifier,
            windowTitle: windowTitle,
            selectedText: nil,
            currentActivity: currentActivity,
            contextSystemPrompt: resolvedContextSystemPrompt(),
            contextPrompt: nil,
            screenshotDataURL: nil,
            screenshotMimeType: nil,
            screenshotError: screenshotError
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

            // Permission errors are fatal — preserve committed audio for recovery.
            tearDownRealtimeService()
            preserveActiveSegmentedJournalForRecovery()
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
