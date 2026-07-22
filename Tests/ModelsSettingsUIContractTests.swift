import Foundation

@main
struct ModelsSettingsUIContractTests {
    static func main() throws {
        let settings = try source("Sources/SettingsView.swift")
        let appDelegate = try source("Sources/AppDelegate.swift")
        let appState = try source("Sources/AppState.swift")
        let postProcessing = try source("Sources/PostProcessingService.swift")
        let context = try source("Sources/AppContextService.swift")
        let modelConfiguration = try source("Sources/ModelConfiguration.swift")
        let currentSpec = try source("docs/superpowers/specs/2026-07-17-model-first-settings-redesign.md")

        testUIOnlyBoundary(appState: appState)
        testExistingProviderRoutingRemains(postProcessing: postProcessing, context: context)
        testExistingModelCatalogRemains(modelConfiguration)
        testExistingModelLifecycleRemains(settings)
        try testModelFirstTopLevelStructure(settings)
        testCloudAPIReadinessPresentation(settings)
        try testTranscriptionUsesNativePickerAndExistingChoiceAPI(settings)
        testNativeDropdownUsesPendingContextualManagement(settings)
        testNativeManagementRegressionGuards(settings: settings, appDelegate: appDelegate, appState: appState)
        testReviewRegressionGuards(settings)
        testPostProcessingUsesExplicitSwitchAndExistingState(settings)
        testContextUsesExplicitSwitchAndExistingState(settings)
        try testAutoPasteLivesInShortcutsClipboard(settings)
        testTranscriptionDetailsAreManagementOnly(settings)
        testManagementRowsKeepSelectionAsDefaultBehavior(settings)
        try testTranscriptionCardHasIndependentToggle()
        try testMenuBarUsesRecordingCopyWhenTranscriptionIsOff()
        testCurrentSpecDocumentsCorrectedLayout(currentSpec)
        print("ModelsSettingsUIContractTests passed")
    }

    private static func testUIOnlyBoundary(appState: String) {
        for forbidden in [
            "postProcessingBackendStorageKey",
            "postProcessingFallbackBackendStorageKey",
            "contextBackendStorageKey",
            "localAIBaseURLStorageKey",
            "localAIAPIKeyStorageKey",
            "showRealtimeTranscriptionOptionStorageKey",
            "showLegacyTranscriptionOptionStorageKey"
        ] {
            precondition(!appState.contains(forbidden), "UI-only work added functional state: \(forbidden)")
        }

        for existing in [
            "@Published var disablePostProcessing: Bool",
            "@Published var preserveExactWording: Bool",
            "@Published var disableContextCapture: Bool",
            "@Published var disableAutoPaste: Bool",
            "@Published var realtimeStreamingEnabled: Bool",
            "@Published var showLegacyMlxWhisperOptions: Bool",
            "func setNoteBrowserTranscriptionChoice(_ choice: TranscriptionBackendChoice)"
        ] {
            precondition(appState.contains(existing), "Missing existing state/action: \(existing)")
        }
    }

    private static func testExistingProviderRoutingRemains(
        postProcessing: String,
        context: String
    ) {
        precondition(postProcessing.contains("private let apiKey: String"))
        precondition(postProcessing.contains("private let baseURL: String"))
        precondition(postProcessing.contains("preferredFallbackModel"))
        precondition(context.contains("private let apiKey: String"))
        precondition(context.contains("private let baseURL: String"))
        precondition(context.contains("if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty"))
    }

    private static func testExistingModelCatalogRemains(_ source: String) {
        for model in [
            "llama-3.3-70b-versatile",
            "llama-3.1-8b-instant",
            "meta-llama/llama-4-scout-17b-16e-instruct",
            "openai/gpt-oss-20b",
            "openai/gpt-oss-120b",
            "qwen/qwen3-32b",
            "qwen/qwen3.6-27b",
            "whisper-large-v3",
            "whisper-large-v3-turbo"
        ] {
            precondition(source.contains("\"\(model)\""), "Missing existing model: \(model)")
        }
    }

    private static func testExistingModelLifecycleRemains(_ settings: String) {
        let native = block(
            in: settings,
            from: "struct NativeWhisperModelRowView",
            to: "struct ModelRowView"
        )
        guard let legacyStart = settings.range(of: "struct ModelRowView") else {
            preconditionFailure("Unable to locate ModelRowView")
        }
        let legacy = String(settings[legacyStart.lowerBound...])

        for expected in [
            "Button(\"Download\")",
            "cancelNativeWhisperInstall()",
            "Delete Model",
            "deleteNativeWhisperModel()",
            "nativeWhisperInstallError"
        ] {
            precondition(native.contains(expected), "Missing Native lifecycle UI: \(expected)")
        }

        for expected in [
            "Button(\"Download\")",
            "cancelDownload()",
            "Delete Model",
            "deleteCache()",
            "onDeleted()",
            "QuillUserIssueView"
        ] {
            precondition(legacy.contains(expected), "Missing Legacy lifecycle UI: \(expected)")
        }
    }

    private static func testModelFirstTopLevelStructure(_ source: String) throws {
        let models = block(
            in: source,
            from: "struct ModelsSettingsView",
            to: "// MARK: - Shortcuts Settings"
        )
        guard let cloudProvider = models.range(of: "SettingsCard(\"Cloud Provider\""),
              let transcription = models.range(of: "SettingsCard(\"Transcription\""),
              let postProcessing = models.range(of: "SettingsCard(\"Post-processing\""),
              let context = models.range(of: "SettingsCard(\"Context\"") else {
            preconditionFailure("Missing peer Settings cards")
        }
        precondition(cloudProvider.lowerBound < transcription.lowerBound)
        precondition(transcription.lowerBound < postProcessing.lowerBound)
        precondition(postProcessing.lowerBound < context.lowerBound)
        precondition(!models.contains("SettingsCard(\"AI Models\""))
        precondition(!models.contains("SettingsCard(\"After Transcription\""))
        precondition(!models.contains("afterTranscriptionSection"))
        precondition(!models.contains("autoPasteEnabled"))
        precondition(!models.contains("Picker(\"Transcription Mode\""))
        precondition(!models.contains("@State private var showingLocalTranscriptionSettings"))
    }

    private static func testCloudAPIReadinessPresentation(_ source: String) {
        let models = block(
            in: source,
            from: "struct ModelsSettingsView",
            to: "// MARK: - Shortcuts Settings"
        )
        let provider = block(
            in: models,
            from: "private var cloudProviderSection: some View",
            to: "\n    private var currentTranscriptionDisplay"
        )
        let postProcessing = block(
            in: models,
            from: "private var postProcessingFeatureSection: some View",
            to: "\n    private var contextEnabled"
        )
        let context = block(
            in: models,
            from: "private var contextFeatureSection: some View",
            to: "\n    private var postProcessingDetails"
        )
        let postProcessingDetails = block(
            in: models,
            from: "private var postProcessingDetails: some View",
            to: "\n    private var transcriptionLanguageSetting"
        )

        precondition(models.contains("private var hasConfiguredCloudAPIKey: Bool"))
        precondition(models.contains("!appState.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty"))
        precondition(!provider.contains("API Key not configured"))
        precondition(provider.contains("API Key configured"))
        precondition(provider.contains("Validating..."))
        precondition(models.contains("appState.hasTranscriptionAPIKey"))
        precondition(models.contains("Cloud transcription requires an API key. Add one in Cloud Provider or use the transcription override in Details."))

        for feature in [postProcessing, context] {
            precondition(feature.components(separatedBy: ".disabled(!hasConfiguredCloudAPIKey)").count >= 3)
            precondition(feature.components(separatedBy: ".opacity(hasConfiguredCloudAPIKey ? 1 : 0.45)").count >= 3)
        }
        precondition(postProcessing.contains("Add an API key in Cloud Provider to enable Post-processing."))
        precondition(postProcessing.contains("Post-processing is on, but cloud processing is unavailable until an API key is configured."))
        precondition(context.contains("Add an API key in Cloud Provider to enable Context."))
        precondition(context.contains("Context is on, but AI context analysis is unavailable until an API key is configured."))
        precondition(postProcessingDetails.contains(".disabled(!hasConfiguredCloudAPIKey)"))
        precondition(!postProcessingDetails.contains("postProcessingDetails\n                    .disabled(!hasConfiguredCloudAPIKey)"))
        precondition(!context.contains("contextPromptSection\n                    .disabled(!hasConfiguredCloudAPIKey)"))
    }

    private static func testTranscriptionUsesNativePickerAndExistingChoiceAPI(_ source: String) throws {
        let models = block(
            in: source,
            from: "struct ModelsSettingsView",
            to: "// MARK: - Shortcuts Settings"
        )
        let picker = block(
            in: models,
            from: "private var transcriptionChoicePickerControl: some View",
            to: "\n    private var currentTranscriptionUsesAPI"
        )

        precondition(models.contains("private var transcriptionChoice: Binding<TranscriptionBackendChoice>"))
        precondition(models.contains("get: { appState.currentNoteBrowserTranscriptionChoice }"))
        precondition(models.contains("set: { handleTranscriptionChoiceSelection($0) }"))
        precondition(models.contains("@State private var showRealtimeTranscriptionOption = false"))
        precondition(models.contains("private var transcriptionChoiceDisplays: [TranscriptionChoiceDisplay]"))
        precondition(models.contains("private var standardAPIModelIDs: [String]"))
        precondition(models.contains("ModelConfiguration.transcriptionModels"))
        precondition(models.contains("appState.noteBrowserTranscriptionChoiceDisplays"))
        precondition(models.contains("showRealtimeTranscriptionOption || appState.realtimeStreamingEnabled"))
        precondition(models.contains("appState.showLegacyMlxWhisperOptions"))
        precondition(models.contains("appState.noteBrowserTranscriptionDisplay(for: .apiStandard(modelID: modelID))"))
        precondition(models.contains("appState.transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)"))
        precondition(models.contains("!modelIDs.contains(currentModelID)"))
        precondition(picker.contains("transcriptionChoiceDisplays.filter { $0.section == section }"))
        precondition(picker.contains("if #available(macOS 14.0, *)"))
        precondition(picker.contains("Picker(\"Model\", selection: transcriptionChoice)"))
        precondition(picker.contains("Section(section)"))
        precondition(picker.contains(".selectionDisabled(!canSelectTranscriptionDisplay(display))"))
        precondition(picker.contains("transcriptionChoiceMenuItem(display)"))
        precondition(picker.contains(".disabled(!canSelectTranscriptionDisplay(display))"))
        precondition(picker.contains(".pickerStyle(.menu)"))
        precondition(picker.contains(".frame(minWidth: 280, maxWidth: 320, alignment: .leading)"))
        precondition(picker.contains("Menu {"))
        precondition(!models.contains("Required · Always On"))
        precondition(models.contains("Toggle(\"Show Realtime transcription option\", isOn: $showRealtimeTranscriptionOption)"))
        precondition(!models.contains("Toggle(\"Show Realtime transcription option\", isOn: $appState.realtimeStreamingEnabled)"))
    }

    private static func testNativeDropdownUsesPendingContextualManagement(_ source: String) {
        let models = block(
            in: source,
            from: "struct ModelsSettingsView",
            to: "// MARK: - Shortcuts Settings"
        )
        let transcription = block(
            in: models,
            from: "private var transcriptionFeatureSection: some View",
            to: "\n    private var postProcessingEnabled"
        )
        let legacyDetails = block(
            in: models,
            from: "private var legacyTranscriptionSettings: some View",
            to: "\n    private var outputLanguageSetting"
        )
        let nativeRow = block(
            in: source,
            from: "struct NativeWhisperModelRowView",
            to: "struct ModelRowView"
        )

        precondition(models.contains("@State private var pendingNativeModelID: String?"))
        precondition(!models.contains("@State private var nativeInstallAutoSelectModelID: String?"))
        precondition(models.contains("NativeWhisperModelCatalog.all.map"))
        precondition(models.contains("handleTranscriptionChoiceSelection($0)"))
        precondition(models.contains("pendingNativeModelID = modelID"))
        precondition(models.contains("appState.isNoteBrowserTranscriptionChoiceAvailable(choice)"))
        precondition(models.contains("appState.cancelNativeWhisperAutoSelection()"))
        precondition(models.contains("private var managedNativeModel: NativeWhisperModel?"))
        precondition(models.contains("private func transcriptionChoiceMenuLabel(_ display: TranscriptionChoiceDisplay) -> String"))
        precondition(models.contains("Download required"))
        precondition(models.contains("Downloading..."))
        precondition(transcription.contains("NativeWhisperModelRowView("))
        precondition(!transcription.contains("onDownloadStarted:"))
        precondition(!transcription.contains("nativeInstallAutoSelectModelID = model.id"))
        precondition(!models.contains(".onChange(of: appState.nativeWhisperInstallStatus)"))
        precondition(!legacyDetails.contains("NativeWhisperModelRowView("))
        precondition(legacyDetails.contains("DisclosureGroup(\"Advanced Legacy mlx-whisper\")"))
        precondition(legacyDetails.contains("isOn: $appState.showLegacyMlxWhisperOptions"))
        precondition(legacyDetails.contains("ForEach(TranscriptionModel.all.filter { !$0.isAppleSpeech })"))
        precondition(nativeRow.contains("let onDownloadStarted: () -> Void"))
        precondition(nativeRow.contains("onDownloadStarted: @escaping () -> Void = {}"))
        precondition(nativeRow.components(separatedBy: "onDownloadStarted()").count >= 3)
    }

    private static func testNativeManagementRegressionGuards(
        settings: String,
        appDelegate: String,
        appState: String
    ) {
        let models = block(
            in: settings,
            from: "struct ModelsSettingsView",
            to: "// MARK: - Shortcuts Settings"
        )
        let nativeRow = block(
            in: settings,
            from: "struct NativeWhisperModelRowView",
            to: "struct ModelRowView"
        )
        let settingsWindow = block(
            in: appDelegate,
            from: "private func presentSettingsWindow()",
            to: "\n\n    func showSetupWindow()"
        )

        precondition(models.contains("initializeManagedNativeModel()"))
        precondition(models.contains("case .nativeWhisper(let modelID):"))
        precondition(models.contains("pendingNativeModelID = modelID"))
        precondition(!nativeRow.contains("refreshNativeWhisperInstallStatus()"))
        precondition(!settings.contains("cancelNativeWhisperInstallForSettingsClose()"))
        precondition(!appDelegate.contains("private final class SettingsWindowDelegate"))
        precondition(!appDelegate.contains("private final class SetupWindowDelegate"))
        precondition(!settingsWindow.contains("window.delegate = settingsWindowDelegate"))
        precondition(
            models.contains(
                "The download continues in the background while Quill is running."
            )
        )
        precondition(!appDelegate.contains("cancelNativeWhisperInstallForSettingsClose()"))
        precondition(!appDelegate.contains("cancelNativeWhisperInstallForSetupClose()"))
        precondition(appDelegate.contains("appState.requestTerminationWhileNativeWhisperInstalling()"))
        precondition(appState.contains("func requestTerminationWhileNativeWhisperInstalling() -> NSApplication.TerminateReply"))
        precondition(appState.contains("Quit while Local Whisper is downloading?"))

        precondition(nativeRow.contains("appState.cancelNativeWhisperInstall()"))
        precondition(nativeRow.contains("appState.willAutoSelectNativeWhisperWhenReady"))
        precondition(nativeRow.contains("Whisper will become active when the download finishes."))
        precondition(nativeRow.contains("Download continues in the background."))
        precondition(!models.contains("@State private var nativeInstallAutoSelectModelID"))
        precondition(models.contains("appState.cancelNativeWhisperAutoSelection()"))
    }

    private static func testReviewRegressionGuards(_ source: String) {
        let models = block(
            in: source,
            from: "struct ModelsSettingsView",
            to: "// MARK: - Shortcuts Settings"
        )
        let displays = block(
            in: models,
            from: "private var transcriptionChoiceDisplays: [TranscriptionChoiceDisplay]",
            to: "\n    private var transcriptionChoice"
        )
        let menuItem = block(
            in: models,
            from: "private func transcriptionChoiceMenuItem",
            to: "\n    private var transcriptionChoicePicker"
        )
        let outputLanguage = block(
            in: models,
            from: "private var outputLanguageSetting: some View",
            to: "\n    private var preserveExactWordingSetting"
        )
        let validation = block(
            in: models,
            from: "private func validateAndSaveKey()",
            to: "\n    // MARK: System Prompt"
        )

        precondition(displays.contains("case .legacyMlxWhisper:"))
        precondition(displays.contains("return display.isAvailable"))
        precondition(!displays.contains("appState.showLegacyMlxWhisperOptions"))
        precondition(menuItem.contains("handleTranscriptionChoiceSelection(display.choice)"))
        precondition(!menuItem.contains("appState.setNoteBrowserTranscriptionChoice(display.choice)"))
        precondition(outputLanguage.contains("private var isOutputLanguageAvailable: Bool"))
        precondition(outputLanguage.contains("!appState.disablePostProcessing || appState.isCommandModeEnabled"))
        precondition(outputLanguage.contains(".disabled(!isOutputLanguageAvailable)"))
        precondition(outputLanguage.contains(".opacity(isOutputLanguageAvailable ? 1 : 0.55)"))
        precondition(outputLanguage.contains("Output Language is unavailable while Post-processing and Edit Mode are off."))
        precondition(validation.contains("appState.apiKey = key"))
        precondition(!validation.contains("setNoteBrowserTranscriptionMode(.apiStandard)"))
    }

    private static func testContextUsesExplicitSwitchAndExistingState(_ source: String) {
        let models = block(
            in: source,
            from: "struct ModelsSettingsView",
            to: "// MARK: - Shortcuts Settings"
        )
        let context = block(
            in: models,
            from: "private var contextFeatureSection: some View",
            to: "\n    private var postProcessingDetails"
        )

        for expected in [
            "get: { !appState.disableContextCapture }",
            "set: { appState.disableContextCapture = !$0 }",
            "defaultModel: AppState.defaultContextModel",
            "contextPromptSection",
            "selection: $appState.contextScreenshotMaxDimension"
        ] {
            precondition(models.contains(expected), "Missing Context binding/configuration: \(expected)")
        }
        for expected in [
            "Toggle(\"\", isOn: contextEnabled)",
            ".toggleStyle(.switch)",
            ".accessibilityLabel(\"Context\")"
        ] {
            precondition(context.contains(expected), "Missing Context switch presentation: \(expected)")
        }
        precondition(!context.contains("Text(contextEnabled.wrappedValue ? \"On\" : \"Off\")"))
    }

    private static func testPostProcessingUsesExplicitSwitchAndExistingState(_ source: String) {
        let models = block(
            in: source,
            from: "struct ModelsSettingsView",
            to: "// MARK: - Shortcuts Settings"
        )
        let postProcessing = block(
            in: models,
            from: "private var postProcessingFeatureSection: some View",
            to: "\n    private var contextEnabled"
        )

        for expected in [
            "get: { !appState.disablePostProcessing }",
            "set: { appState.disablePostProcessing = !$0 }",
            "Toggle(\"\", isOn: postProcessingEnabled)",
            ".toggleStyle(.switch)",
            ".accessibilityLabel(\"Post-processing\")",
            "predefinedModels: ModelConfiguration.llmModels",
            "defaultModel: AppState.defaultPostProcessingModel",
            "defaultModel: AppState.defaultPostProcessingFallbackModel",
            "selection: $appState.outputLanguage",
            "isOn: $appState.preserveExactWording",
            "vocabularySection",
            "systemPromptSection",
            "instructionGuardSection"
        ] {
            precondition(models.contains(expected), "Missing Post-processing UI binding: \(expected)")
        }
        for expected in [
            "Toggle(\"\", isOn: postProcessingEnabled)",
            ".toggleStyle(.switch)",
            ".accessibilityLabel(\"Post-processing\")"
        ] {
            precondition(postProcessing.contains(expected), "Missing Post-processing switch presentation: \(expected)")
        }
        precondition(!postProcessing.contains("Text(postProcessingEnabled.wrappedValue ? \"On\" : \"Off\")"))
        precondition(!models.contains(".disabled(appState.disablePostProcessing || appState.useLocalTranscription)"))
    }

    private static func testAutoPasteLivesInShortcutsClipboard(_ source: String) throws {
        let models = block(
            in: source,
            from: "struct ModelsSettingsView",
            to: "// MARK: - Shortcuts Settings"
        )
        let shortcuts = block(
            in: source,
            from: "struct ShortcutsSettingsView",
            to: "// MARK: - Input Settings"
        )
        let clipboard = block(
            in: shortcuts,
            from: "private var clipboardSection: some View",
            to: "\n    private var macrosSection"
        )

        precondition(!models.contains("Paste Automatically"))
        precondition(clipboard.contains("Toggle(\"Paste Automatically\", isOn: Binding("))
        precondition(clipboard.contains("get: { !appState.disableAutoPaste }"))
        precondition(clipboard.contains("set: { appState.disableAutoPaste = !$0 }"))
        precondition(clipboard.contains("When off, Quill copies the transcript to the clipboard so you can paste it manually."))
        guard let autoPaste = clipboard.range(of: "Toggle(\"Paste Automatically\""),
              let preserveClipboard = clipboard.range(of: "Toggle(\"Preserve clipboard after paste\"") else {
            preconditionFailure("Missing Clipboard settings")
        }
        precondition(autoPaste.lowerBound < preserveClipboard.lowerBound)
    }

    private static func testTranscriptionDetailsAreManagementOnly(_ source: String) {
        let models = block(
            in: source,
            from: "struct ModelsSettingsView",
            to: "// MARK: - Shortcuts Settings"
        )
        let local = block(
            in: models,
            from: "private var legacyTranscriptionSettings: some View",
            to: "\n    private var outputLanguageSetting"
        )

        let customStandardAPI = block(
            in: models,
            from: "private var standardAPITranscriptionSetting: some View",
            to: "\n    private var realtimeTranscriptionSetting"
        )
        precondition(customStandardAPI.contains("Text(\"Custom Standard API Model\")"))
        precondition(customStandardAPI.contains("TextField(\"e.g. custom-transcription-model\", text: $transcriptionModelDraft)"))
        precondition(models.contains("transcriptionModelDraft = customStandardAPIModelDraft(for: appState.transcriptionModel)"))
        precondition(models.contains(".onChange(of: appState.transcriptionModel)"))
        precondition(models.contains("transcriptionModelDraft = customStandardAPIModelDraft(for: resolved)"))
        precondition(customStandardAPI.contains("Text(\"Add a custom model ID when it is not listed in the main Model menu.\")"))
        precondition(!customStandardAPI.contains("TextField(AppState.defaultTranscriptionModel"))
        precondition(!customStandardAPI.contains("ModelDropdownView("))
        precondition(!models.contains("title: \"Standard API Model\""))
        precondition(!local.contains("TranscriptionModel.find(id: \"apple-speech\")"))
        precondition(!local.contains("NativeWhisperModelRowView("))
        precondition(local.contains("ForEach(TranscriptionModel.all.filter { !$0.isAppleSpeech })"))
        precondition(local.components(separatedBy: "showsSelectionControl: false").count >= 2)
    }

    private static func testManagementRowsKeepSelectionAsDefaultBehavior(_ source: String) {
        let native = block(
            in: source,
            from: "struct NativeWhisperModelRowView",
            to: "struct ModelRowView"
        )
        guard let legacyStart = source.range(of: "struct ModelRowView") else {
            preconditionFailure("Unable to locate ModelRowView")
        }
        let legacy = String(source[legacyStart.lowerBound...])

        for row in [native, legacy] {
            precondition(row.contains("let showsSelectionControl: Bool"))
            precondition(row.contains("showsSelectionControl: Bool = true"))
            precondition(row.contains("if showsSelectionControl"))
        }
    }

    private static func testTranscriptionCardHasIndependentToggle() throws {
        let source = try String(contentsOfFile: "Sources/SettingsView.swift", encoding: .utf8)

        precondition(source.contains("private var transcriptionEnabled: Binding<Bool>"))
        precondition(source.contains("Toggle(\"\", isOn: transcriptionEnabled)"))
        precondition(source.contains(".accessibilityLabel(\"Transcription\")"))
        precondition(source.contains("appState.isTranscriptionConfigurationLocked"))
        precondition(source.contains("Record audio without creating a transcript."))
        precondition(source.contains(".disabled(!appState.transcriptionEnabled)"))
    }

    private static func testMenuBarUsesRecordingCopyWhenTranscriptionIsOff() throws {
        let source = try String(contentsOfFile: "Sources/MenuBarView.swift", encoding: .utf8)
        precondition(source.contains("appState.transcriptionEnabled"))
        precondition(source.contains("String(localized: \"Start Recording\")"))
        precondition(source.contains("String(localized: \"Start Dictating\")"))
    }

    private static func testCurrentSpecDocumentsCorrectedLayout(_ source: String) {
        precondition(source.contains("- **Status:** Native Whisper dropdown management follow-up and window-close regression fixes implemented; automated verification complete"))
        precondition(source.contains("direct Custom Standard API Model ID field"))
        precondition(source.contains("all predefined Standard API transcription models"))
        precondition(source.contains("without visible On/Off text"))
        precondition(source.contains("관리 영역은 radio/selection control을 표시하지 않는다"))
        precondition(source.contains("Paste Automatically is the first option in Shortcuts > Clipboard"))
        precondition(source.contains("The separate `Required · Always On` badge is not rendered"))
        precondition(source.contains("Cloud Provider, Transcription, Post-processing, Context의 네 peer card"))
        precondition(source.contains("persisted On/Off 모양은 유지"))
        precondition(source.contains("Settings 진입 시 key를 재검증하는 network request도 추가하지 않는다"))
    }

    private static func source(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    private static func block(in source: String, from start: String, to end: String) -> String {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            preconditionFailure("Unable to locate source block from \(start) to \(end)")
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}
