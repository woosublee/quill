import Foundation

@main
struct PromptsSettingsUIContractTests {
    static func main() throws {
        let tabs = try source("Sources/CalendarIntegrationModels.swift")
        let settings = try source("Sources/SettingsView.swift")

        testNavigation(tabs: tabs, settings: settings)
        testCardOrder(settings)
        testPromptPersistence(settings)
        testPromptModificationDatesRequireContentChange(settings)
        testPromptDraftsCommitOnFocusLoss(settings)
        testBackendAwareTests(settings)
        testInstructionGuard(settings)
        testScreenshotResolutionStaysOut(settings)

        print("PromptsSettingsUIContractTests passed")
    }

    private static func testNavigation(tabs: String, settings: String) {
        precondition(tabs.contains("case prompts"), "Missing Prompts settings tab")
        precondition(
            tabs.contains("[.general, .appearance, .models, .prompts, .shortcuts, .input, .calendar, .sync, .recovery, .about, .runLog, .debug]"),
            "Prompts must appear between Models and Shortcuts"
        )
        precondition(tabs.contains("case .prompts: return \"Prompts\""))
        precondition(tabs.contains("case .prompts: return \"text.bubble\""))
        precondition(settings.contains("case .prompts:\n                    PromptsSettingsView()"))
    }

    private static func testCardOrder(_ source: String) {
        let prompts = promptsBlock(source)
        guard let system = prompts.range(of: "SettingsCard(\"System Prompt\""),
              let guardCard = prompts.range(of: "SettingsCard(\"Instruction Guard\""),
              let context = prompts.range(of: "SettingsCard(\"Context Prompt\"") else {
            preconditionFailure("Missing Prompt settings cards")
        }
        precondition(system.lowerBound < guardCard.lowerBound)
        precondition(guardCard.lowerBound < context.lowerBound)
    }

    private static func testPromptPersistence(_ source: String) {
        let prompts = promptsBlock(source)
        for expected in [
            "@State private var customSystemPromptInput: String = \"\"",
            "@State private var customContextPromptInput: String = \"\"",
            "PostProcessingService.defaultSystemPrompt",
            "AppContextService.defaultContextPrompt",
            "Quill always adds transcript-preservation rules and automatic short or long cleanup instructions after this prompt.",
            "appState.customSystemPrompt = trimmed",
            "appState.customSystemPromptLastModified = today",
            "appState.customContextPrompt = trimmed",
            "appState.customContextPromptLastModified = today",
            "Button(\"Switch to Default\")",
            "Button(\"Reset to Default\")"
        ] {
            precondition(prompts.contains(expected), "Missing Prompt persistence behavior: \(expected)")
        }
    }

    private static func testPromptModificationDatesRequireContentChange(_ source: String) {
        let prompts = promptsBlock(source)
        let systemCommit = block(
            in: prompts,
            from: "private func commitCustomSystemPrompt()",
            to: "private func commitCustomContextPrompt()"
        )
        let contextCommit = block(
            in: prompts,
            from: "private func commitCustomContextPrompt()",
            to: "private var hasConfiguredCloudAPIKey"
        )

        for (commit, storedPrompt, lastModified) in [
            (systemCommit, "appState.customSystemPrompt", "appState.customSystemPromptLastModified"),
            (contextCommit, "appState.customContextPrompt", "appState.customContextPromptLastModified")
        ] {
            let contentChange = "} else if \(storedPrompt) != trimmed {"
            guard let contentChangeRange = commit.range(of: contentChange),
                  let dateRange = commit.range(of: "let today = iso8601DayFormatter"),
                  let lastModifiedWrite = commit.range(of: "\(lastModified) = today") else {
                preconditionFailure(
                    "Prompt modification dates must be written only after a content change"
                )
            }
            precondition(
                contentChangeRange.lowerBound < dateRange.lowerBound
                    && dateRange.lowerBound < lastModifiedWrite.lowerBound,
                "Prompt modification dates are not refreshed by view dismissal, tests, or recording-start draft flushes"
            )
        }
    }

    private static func testPromptDraftsCommitOnFocusLoss(_ source: String) {
        let prompts = promptsBlock(source)
        for expected in [
            "@FocusState private var customSystemPromptFocused: Bool",
            "@FocusState private var customContextPromptFocused: Bool",
            "private func commitCustomSystemPrompt()",
            "private func commitCustomContextPrompt()",
            ".onDisappear {",
            "commitCustomSystemPrompt()",
            "commitCustomContextPrompt()",
            ".focused($customSystemPromptFocused)",
            ".focused($customContextPromptFocused)",
            ".onChange(of: customSystemPromptFocused)",
            ".onChange(of: customContextPromptFocused)",
            "@State private var settingsDraftCommitRegistrationID: UUID?",
            "appState.registerSettingsDraftCommit",
            "appState.unregisterSettingsDraftCommit"
        ] {
            precondition(prompts.contains(expected), "Missing focus-loss prompt persistence: \(expected)")
        }
        precondition(
            !prompts.contains(".onChange(of: customSystemPromptInput)"),
            "System prompt does not persist on every keystroke"
        )
        precondition(
            !prompts.contains(".onChange(of: customContextPromptInput)"),
            "Context prompt does not persist on every keystroke"
        )

        let systemRunner = block(
            in: prompts,
            from: "private func runSystemPromptTest()",
            to: "private var contextPromptSection"
        )
        let contextRunner = String(prompts[
            prompts.range(of: "private func runContextPromptTest()")!.lowerBound...
        ])
        precondition(
            systemRunner.range(of: "commitCustomSystemPrompt()")!.lowerBound
                < systemRunner.range(of: "let service = appState.makePostProcessingService()")!.lowerBound,
            "System prompt tests commit the latest draft before building a service"
        )
        precondition(
            contextRunner.range(of: "commitCustomContextPrompt()")!.lowerBound
                < contextRunner.range(of: "let service = appState.makeAppContextService()")!.lowerBound,
            "Context prompt tests commit the latest draft before collecting context"
        )
    }

    private static func testBackendAwareTests(_ source: String) {
        let prompts = promptsBlock(source)
        precondition(prompts.contains("appState.isAIProcessingBackendReady(for: .postProcessing)"))
        precondition(prompts.contains("appState.isAIProcessingBackendReady(for: .context)"))
        precondition(prompts.contains("let service = appState.makePostProcessingService()"))
        precondition(prompts.contains("let service = appState.makeAppContextService()"))
        precondition(!prompts.contains("let service = PostProcessingService("))
        precondition(prompts.contains("QuillUserIssueView("))
        precondition(prompts.contains("settingsTestRecoveryAction("))
        precondition(prompts.contains("providerConfigurationWarning("))
        precondition(prompts.contains("if postProcessingUsesCloud && !hasConfiguredCloudAPIKey"))
        precondition(prompts.contains("if contextUsesCloud && !hasConfiguredCloudAPIKey"))
    }

    private static func testInstructionGuard(_ source: String) {
        let prompts = promptsBlock(source)
        precondition(prompts.contains("isOn: $appState.instructionExecutionGuardEnabled"))
        precondition(prompts.contains("Prevent dictated prompts from being executed"))
    }

    private static func testScreenshotResolutionStaysOut(_ source: String) {
        let prompts = promptsBlock(source)
        precondition(!prompts.contains("Screenshot Resolution"))
        precondition(!prompts.contains("contextScreenshotMaxDimension"))
    }

    private static func promptsBlock(_ source: String) -> String {
        block(
            in: source,
            from: "struct PromptsSettingsView",
            to: "// MARK: - Shortcuts Settings"
        )
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
