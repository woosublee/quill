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
        let modelDropdown = try source("Sources/ModelDropdownView.swift")
        let localAIModelRow = (try? source("Sources/LocalAIModelRowView.swift")) ?? ""
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
        testAIProcessingBackendPickersAndLocalRows(
            settings: settings,
            modelDropdown: modelDropdown,
            localAIModelRow: localAIModelRow
        )
        try testAutoPasteLivesInShortcutsClipboard(settings)
        testTranscriptionDetailsAreManagementOnly(settings)
        testManagementRowsKeepSelectionAsDefaultBehavior(settings)
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
        precondition(postProcessing.contains("private let backendExecutor: AIProcessingBackendExecutor"))
        precondition(postProcessing.contains("preferredFallbackModel"))
        precondition(postProcessing.contains("cloudBaseURL: baseURL"))
        precondition(postProcessing.contains("cloudAPIKey: apiKey"))
        precondition(context.contains("private let backendExecutor: AIProcessingBackendExecutor"))
        precondition(context.contains("cloudBaseURL: baseURL"))
        precondition(context.contains("cloudAPIKey: apiKey"))
        precondition(context.contains("if backendExecutor.isConfigured"))
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

        precondition(!postProcessing.contains(".disabled(!hasConfiguredCloudAPIKey)"))
        precondition(!postProcessing.contains(".opacity(hasConfiguredCloudAPIKey ? 1 : 0.45)"))
        precondition(!context.contains(".disabled(!hasConfiguredCloudAPIKey)"))
        precondition(!context.contains(".opacity(hasConfiguredCloudAPIKey ? 1 : 0.45)"))
        precondition(postProcessing.contains("if postProcessingUsesCloud && !hasConfiguredCloudAPIKey"))
        precondition(context.contains("if contextUsesCloud && !hasConfiguredCloudAPIKey"))
        precondition(postProcessing.contains("localizedCatalogString(\n                        appState.disablePostProcessing"))
        precondition(context.contains("localizedCatalogString(\n                        appState.disableContextCapture"))
        precondition(postProcessing.contains("Add an API key in Cloud Provider to enable Post-processing."))
        precondition(postProcessing.contains("Post-processing is on, but cloud processing is unavailable until an API key is configured."))
        precondition(context.contains("Add an API key in Cloud Provider to enable Context."))
        precondition(context.contains("Context is on, but AI context analysis is unavailable until an API key is configured."))
        precondition(!postProcessingDetails.contains(".disabled(!hasConfiguredCloudAPIKey)"))
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
        precondition(picker.components(separatedBy: "ForEach([\"Cloud\", \"On This Mac\"]").count == 5)
        precondition(picker.components(separatedBy: "Section(localizedCatalogString(section))").count == 5)
        precondition(!picker.contains("Legacy mlx-whisper\"], id: \\.self"))
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
        precondition(appDelegate.contains("appState.requestTerminationAfterModelCleanup()"))
        precondition(!appDelegate.contains("requestTerminationWhileNativeWhisperInstalling()"))
        precondition(appState.contains("func requestTerminationAfterModelCleanup("))
        precondition(appState.contains("Quit while models are downloading?"))
        precondition(
            appState.contains(
                "Quill will cancel unfinished model downloads and delete partial files before quitting."
            )
        )
        precondition(appState.contains("Quit and Cancel Downloads"))

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
            to: "\n    private func customStandardAPIModelDraft"
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
            "customAIProcessingModelSetting(",
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
            "customAIProcessingModelSetting(",
            "defaultModel: AppState.defaultPostProcessingFallbackModel",
            "selection: $appState.outputLanguage",
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

    private static func testAIProcessingBackendPickersAndLocalRows(
        settings: String,
        modelDropdown: String,
        localAIModelRow: String
    ) {
        let models = block(
            in: settings,
            from: "struct ModelsSettingsView",
            to: "// MARK: - Shortcuts Settings"
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
            to: "\n    private var contextDetails"
        )
        let contextDetails = block(
            in: models,
            from: "private var contextDetails: some View",
            to: "\n    private func customAIProcessingModelSetting("
        )
        let customModelSetting = block(
            in: models,
            from: "private func customAIProcessingModelSetting(",
            to: "\n    private func applyCustomAIProcessingModel("
        )
        let customModelApply = block(
            in: models,
            from: "private func applyCustomAIProcessingModel(",
            to: "\n    private var transcriptionLanguageSetting"
        )
        let customModelDraft = block(
            in: models,
            from: "private func customAIProcessingModelDraft(",
            to: "\n    private func customStandardAPIModelDraft"
        )
        let systemPrompt = block(
            in: models,
            from: "private var systemPromptSection: some View",
            to: "\n    private func runSystemPromptTest()"
        )
        let contextPrompt = block(
            in: models,
            from: "private var contextPromptSection: some View",
            to: "\n    private func runContextPromptTest()"
        )
        let choiceBinding = block(
            in: models,
            from: "private func aiProcessingChoiceBinding(",
            to: "\n    private func handleAIProcessingChoiceSelection("
        )
        let choiceSelection = block(
            in: models,
            from: "private func handleAIProcessingChoiceSelection(",
            to: "\n    private func setRetainedLocalAIModelID("
        )
        let retainedSetter = block(
            in: models,
            from: "private func setRetainedLocalAIModelID(",
            to: "\n    private func retainedLocalAIModelID("
        )
        let retainedGetter = block(
            in: models,
            from: "private func retainedLocalAIModelID(",
            to: "\n    private func syncCloudModelDraft("
        )
        let draftSync = block(
            in: models,
            from: "private func syncCloudModelDraft(",
            to: "\n    private func managedLocalAIResolverInput("
        )
        let retainedResolver = block(
            in: models,
            from: "private func managedLocalAIResolverInput(",
            to: "\n    private func aiProcessingChoiceMenuLabel("
        )
        let pureResolver = block(
            in: localAIModelRow,
            from: "struct LocalAIManagedModelResolver",
            to: "struct LocalAIModelRowView"
        )
        let olderMenuItem = block(
            in: models,
            from: "private func aiProcessingChoiceMenuItem(",
            to: "\n    @ViewBuilder\n    private func aiProcessingChoicePicker("
        )
        let processingPicker = block(
            in: models,
            from: "@ViewBuilder\n    private func aiProcessingChoicePicker(",
            to: "\n    private var currentTranscriptionUsesAPI"
        )
        let viewLifecycle = block(
            in: models,
            from: ".onAppear {",
            to: "\n    private var hasConfiguredCloudAPIKey"
        )
        let cloudChoiceSelection = block(
            in: choiceSelection,
            from: "case .cloud(let modelID):",
            to: "case .localAI(let modelID):"
        )
        guard let localChoiceStart = choiceSelection.range(
            of: "case .localAI(let modelID):"
        ) else {
            preconditionFailure("Missing Local AI picker selection branch")
        }
        let localChoiceSelection = String(
            choiceSelection[localChoiceStart.lowerBound...]
        )

        precondition(models.contains("aiProcessingChoicePicker(for: .postProcessing)"))
        precondition(models.contains("aiProcessingChoicePicker(for: .context)"))
        precondition(models.contains("Picker(\"Model\", selection:"))
        precondition(models.contains("ForEach([\"Cloud\", \"On This Mac\"]"))
        precondition(models.contains("Section(localizedCatalogString(section))"))
        precondition(models.contains("LocalAIModelRowView("))
        precondition(models.contains("aiProcessingChoiceMenuLabel"))
        precondition(models.contains("Text(aiProcessingChoiceMenuLabel(currentDisplay))"))

        precondition(choiceBinding.contains("get: { appState.currentAIProcessingChoice(for: feature) }"))
        precondition(choiceBinding.contains("handleAIProcessingChoiceSelection($0, for: feature)"))
        precondition(cloudChoiceSelection.contains("appState.selectAIProcessingBackendChoice(choice, for: feature)"))
        precondition(cloudChoiceSelection.contains("syncCloudModelDraft(modelID, for: feature)"))
        precondition(cloudChoiceSelection.contains("reconcileRetainedLocalAIModel(for: feature)"))
        precondition(!cloudChoiceSelection.contains("setRetainedLocalAIModelID(nil, for: feature)"))
        precondition(localChoiceSelection.contains("appState.selectAIProcessingBackendChoice(choice, for: feature)"))
        precondition(localChoiceSelection.contains("appState.pendingLocalAIModelID(for: feature) == modelID"))
        precondition(localChoiceSelection.contains("appState.currentAIProcessingChoice(for: feature) == choice"))
        precondition(localChoiceSelection.contains("setRetainedLocalAIModelID(modelID, for: feature)"))
        guard let localSelectionCall = localChoiceSelection.range(
            of: "appState.selectAIProcessingBackendChoice(choice, for: feature)"
        ), let localAcceptanceCheck = localChoiceSelection.range(
            of: "appState.pendingLocalAIModelID(for: feature) == modelID"
        ), let localRetainedSet = localChoiceSelection.range(
            of: "setRetainedLocalAIModelID(modelID, for: feature)"
        ) else {
            preconditionFailure("Missing accepted Local AI picker selection flow")
        }
        precondition(localSelectionCall.lowerBound < localAcceptanceCheck.lowerBound)
        precondition(localAcceptanceCheck.lowerBound < localRetainedSet.lowerBound)
        precondition(draftSync.contains("case .postProcessing where focusedCustomAIProcessingFeature != .postProcessing:"))
        precondition(draftSync.contains("postProcessingModelDraft = customAIProcessingModelDraft(for: modelID)"))
        precondition(draftSync.contains("case .context where focusedCustomAIProcessingFeature != .context:"))
        precondition(draftSync.contains("contextModelDraft = customAIProcessingModelDraft(for: modelID)"))
        precondition(retainedSetter.contains("guard retainedPostProcessingLocalModelID != modelID else { return }"))
        precondition(retainedSetter.contains("guard retainedContextLocalModelID != modelID else { return }"))
        precondition(retainedGetter.contains("retainedPostProcessingLocalModelID"))
        precondition(retainedGetter.contains("retainedContextLocalModelID"))
        precondition(retainedResolver.contains("LocalAIManagedModelResolver.Input("))
        precondition(retainedResolver.contains("pendingModelID: appState.pendingLocalAIModelID(for: feature)"))
        precondition(retainedResolver.contains("retainedModelID: retainedModelID"))
        precondition(retainedResolver.contains("currentChoice: appState.currentAIProcessingChoice(for: feature)"))
        precondition(retainedResolver.contains("retainedIsInstalling: retainedState?.isInstalling ?? false"))
        precondition(retainedResolver.contains("retainedProgressIsCancelled: retainedState?.progress.isCancelled ?? false"))
        precondition(retainedResolver.contains("retainedHasIssue: retainedState?.issue != nil"))
        precondition(retainedResolver.contains("resolution.reconciledRetainedModelID"))
        precondition(retainedResolver.contains("aiProcessingChoiceDisplays(for: feature).contains"))
        precondition(!retainedResolver.contains("selectedOrPendingLocalAIModel"))

        precondition(pureResolver.contains("struct Input: Equatable"))
        precondition(pureResolver.contains("struct Resolution: Equatable"))
        precondition(pureResolver.contains("var retainedIsActionable: Bool"))
        precondition(pureResolver.contains("let pendingModel = input.pendingModelID.flatMap"))
        precondition(pureResolver.contains("let retainedModel = input.retainedModelID.flatMap"))
        precondition(pureResolver.contains("case .localAI(let currentModelID) = input.currentChoice"))
        precondition(pureResolver.contains("input.retainedIsActionable"))
        precondition(pureResolver.contains("reconciledRetainedModelID"))

        precondition(olderMenuItem.contains("Toggle(isOn: Binding("))
        precondition(olderMenuItem.contains("get: { binding.wrappedValue == display.choice }"))
        precondition(olderMenuItem.contains("if isSelected { binding.wrappedValue = display.choice }"))
        precondition(olderMenuItem.contains("Text(aiProcessingChoiceMenuLabel(display))"))
        precondition(olderMenuItem.contains(".disabled(!display.isAvailable)"))
        precondition(processingPicker.contains("Menu {"))
        precondition(processingPicker.contains("aiProcessingChoiceMenuItem("))
        precondition(processingPicker.contains("binding: binding"))

        precondition(postProcessing.contains("managedLocalAIModel(for: .postProcessing)"))
        precondition(postProcessing.contains("feature: .postProcessing"))
        precondition(postProcessing.contains("appState.postProcessingBackendChoice"))
        precondition(context.contains("managedLocalAIModel(for: .context)"))
        precondition(context.contains("feature: .context"))
        precondition(context.contains("appState.contextBackendChoice"))
        precondition(context.contains("Local Context uses app and window text only. Screenshots stay on this Mac."))

        precondition(postProcessingDetails.contains("customAIProcessingModelSetting("))
        precondition(postProcessingDetails.contains("draft: $postProcessingModelDraft"))
        precondition(postProcessingDetails.contains("feature: .postProcessing"))
        precondition(postProcessingDetails.components(separatedBy: "ModelDropdownView(").count == 2)
        precondition(postProcessingDetails.contains("textDraft: $postProcessingFallbackModelDraft"))
        precondition(postProcessingDetails.contains(".disabled(postProcessingUsesLocal)"))
        precondition(postProcessingDetails.contains("Cloud fallback is only used when Post-processing uses a cloud model."))
        precondition(!postProcessingDetails.contains(".disabled(!hasConfiguredCloudAPIKey)"))
        precondition(contextDetails.contains("customAIProcessingModelSetting("))
        precondition(contextDetails.contains("draft: $contextModelDraft"))
        precondition(contextDetails.contains("feature: .context"))
        precondition(!contextDetails.contains("ModelDropdownView("))
        precondition(!contextDetails.contains("Reset to Default"))
        precondition(!contextDetails.contains(".disabled(!hasConfiguredCloudAPIKey)"))

        precondition(customModelSetting.contains("Text(\"Custom API Model\")"))
        precondition(customModelSetting.contains("TextField(\"e.g. provider/custom-model\", text: draft)"))
        precondition(customModelSetting.contains(".focused($focusedCustomAIProcessingFeature, equals: feature)"))
        precondition(customModelSetting.contains(".onSubmit { applyCustomAIProcessingModel(draft, for: feature) }"))
        precondition(customModelSetting.contains("Button(\"Use Model\")"))
        precondition(customModelSetting.contains("Enter an API model ID that is not listed above. Use the main Model menu to return to a listed model."))
        precondition(!customModelSetting.contains("onChange(of: focusedCustomAIProcessingFeature"))
        precondition(!customModelSetting.contains("Reset to Default"))
        precondition(customModelApply.contains("let modelID = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)"))
        precondition(customModelApply.contains("guard !modelID.isEmpty else { return }"))
        precondition(customModelApply.contains("handleAIProcessingChoiceSelection(.cloud(modelID: modelID), for: feature)"))
        precondition(customModelDraft.contains("!ModelConfiguration.llmModels.contains(trimmed)"))

        precondition(!models.contains("initializeManagedLocalAIModels"))
        precondition(viewLifecycle.contains("reconcileRetainedLocalAIModels()"))
        precondition(viewLifecycle.contains(".onChange(of: managedLocalAIReconciliationInputs)"))
        precondition(viewLifecycle.contains("postProcessingModelDraft = customAIProcessingModelDraft(for: appState.postProcessingModel)"))
        precondition(viewLifecycle.contains("contextModelDraft = customAIProcessingModelDraft(for: appState.contextModel)"))
        precondition(viewLifecycle.contains(".onChange(of: appState.postProcessingModel)"))
        precondition(viewLifecycle.contains("focusedCustomAIProcessingFeature != .postProcessing"))
        precondition(viewLifecycle.contains("postProcessingModelDraft = customAIProcessingModelDraft(for: value)"))
        precondition(viewLifecycle.contains(".onChange(of: appState.contextModel)"))
        precondition(viewLifecycle.contains("focusedCustomAIProcessingFeature != .context"))
        precondition(viewLifecycle.contains("contextModelDraft = customAIProcessingModelDraft(for: value)"))

        precondition(modelDropdown.contains("@Binding var isEditing: Bool"))
        precondition(modelDropdown.contains("isEditing: Binding<Bool> = .constant(false)"))
        precondition(modelDropdown.contains("self._isEditing = isEditing"))
        precondition(modelDropdown.contains("isEditing = focused"))

        precondition(systemPrompt.contains("appState.isAIProcessingBackendReady(for: .postProcessing)"))
        precondition(contextPrompt.contains("appState.isAIProcessingBackendReady(for: .context)"))
        precondition(models.contains("let service = appState.makePostProcessingService()"))
        precondition(!models.contains("let service = PostProcessingService("))

        precondition(!localAIModelRow.isEmpty, "Missing LocalAIModelRowView source")
        precondition(localAIModelRow.contains("appState.localAIInstallState(for: model)"))
        precondition(localAIModelRow.contains("appState.pendingLocalAIModelID(for: feature)"))
        precondition(localAIModelRow.contains("model.localizedDescription()"))
        precondition(localAIModelRow.contains("state.progress.localizedDisplayText()"))
        precondition(localAIModelRow.contains("appState.installLocalAIModel(model, autoSelectFor: feature)"))
        precondition(localAIModelRow.contains("appState.cancelLocalAIInstall(model)"))
        precondition(localAIModelRow.contains("appState.deleteLocalAIModel(model)"))
        precondition(localAIModelRow.contains("if state.isInstalling, state.progress.isCancelled"))
        precondition(localAIModelRow.contains(".accessibilityLabel(\"Cancel Local AI model download\")"))
        precondition(localAIModelRow.contains(".accessibilityLabel(\"Delete Model\")"))
        precondition(localAIModelRow.contains("localizedCatalogString(isSelected ? \"Selected\" : \"Not selected\")"))
        precondition(localAIModelRow.contains("QuillUserIssueView("))
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
