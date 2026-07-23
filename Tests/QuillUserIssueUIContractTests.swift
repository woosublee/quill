import Foundation

@main
struct QuillUserIssueUIContractTests {
    static func main() throws {
        let issueView = try source("Sources/QuillUserIssueView.swift")
        let noteBrowser = try source("Sources/NoteBrowserView.swift")
        let setup = try source("Sources/SetupView.swift")
        let settings = try source("Sources/SettingsView.swift")
        let appState = try source("Sources/AppState.swift")

        try testSharedRenderer(issueView)
        try testNoteBrowserUsesStructuredErrorAndWarningUI(noteBrowser)
        try testNoteBrowserSeparatesRecoveryAndRetryCapability(noteBrowser)
        try testSetupOmitsRequiredTranscriptionTest(setup)
        try testSettingsTestsUseStructuredIssues(settings)
        try testRunLogSanitizesMachineStatuses(settings)
        try testRecoveryActionsUseExistingRoutes(noteBrowser, appState)
        try testDismissibleBannerScopedToWarningStyle(issueView, noteBrowser, appState)
        print("QuillUserIssueUIContractTests passed")
    }

    private static func testSharedRenderer(_ source: String) throws {
        for marker in [
            "struct QuillUserIssueView: View",
            "presentation.title",
            "presentation.body",
            "presentation.suggestion",
            "presentation.detailsRows",
            "DisclosureGroup(\"Details\")",
            "presentation.recoveryAction"
        ] {
            try expect(source.contains(marker), "shared issue renderer contains \(marker)")
        }
        try expect(
            source.contains("if !presentation.suggestion.isEmpty"),
            "shared issue renderer omits empty recovery suggestions"
        )
    }

    private static func testNoteBrowserUsesStructuredErrorAndWarningUI(
        _ source: String
    ) throws {
        try expect(
            source.contains("NoteBrowserRecoveryPresentation.presentation("),
            "Note Browser resolves contextual current-locale issue presentation"
        )
        try expect(source.contains("QuillUserIssueView("), "Note Browser uses shared issue renderer")
        try expect(source.contains("style: .warningBanner"), "completed warning uses a compact banner")
        try expect(source.contains("performRecoveryAction("), "Note Browser routes contextual recovery")
        try expect(
            !source.contains("Text(item.postProcessingStatus.replacingOccurrences"),
            "Note Browser never renders persisted raw status"
        )
    }

    private static func testNoteBrowserSeparatesRecoveryAndRetryCapability(
        _ source: String
    ) throws {
        try expect(
            source.contains("NoteBrowserRecoveryPresentation.presentation("),
            "Note Browser builds contextual recovery presentation"
        )
        try expect(
            source.contains("actionState.showsRetryButton"),
            "stored audio keeps retry visible independently from issue action"
        )
        try expect(
            !source.contains("issuePresentation?.recoveryAction == .retryTranscription"),
            "retry visibility no longer depends on the issue primary action"
        )
        try expect(
            source.contains("Choose Local Whisper or API Standard to retry this recording."),
            "retry with an unsupported selection guides model selection"
        )
        try expect(
            source.contains("Set up Local Whisper or API Standard to retry this recording."),
            "retry without a prepared backend guides model setup"
        )
        try expect(
            source.contains("NoteBrowserToastView("),
            "Note Browser renders a pill-anchored toast"
        )
        try expect(
            source.contains(".opacity(disabled ? 0.35 : 1)"),
            "disabled toolbar actions are visually distinct"
        )
        try expect(
            source.contains("No transcript text to copy."),
            "disabled copy explains why it is unavailable"
        )
    }

    private static func testSetupOmitsRequiredTranscriptionTest(_ source: String) throws {
        try expect(!source.contains("testTranscriptionStep"), "Setup omits the required transcription test screen")
        try expect(!source.contains("@State private var testIssue"), "Setup does not retain test transcription issue state")
        try expect(!source.contains("makeTranscriptionService()"), "Setup completion does not require a transcription request")
    }

    private static func testSettingsTestsUseStructuredIssues(_ source: String) throws {
        try expect(source.contains("@State private var systemTestIssue: QuillUserIssueRecord?"), "Settings stores system prompt issue")
        try expect(source.contains("@State private var contextTestIssue: QuillUserIssueRecord?"), "Settings stores Context prompt issue")
        try expect(source.contains("@State private var keyValidationIssue: QuillUserIssueRecord?"), "Settings stores provider validation issue")
        try expect(source.contains("QuillUserIssueView("), "Settings uses shared issue renderer")
        try expect(!source.contains("systemTestError = error.localizedDescription"), "System prompt test hides raw errors")
        try expect(source.contains("systemTestIssue = service.userIssue(for: error).record"), "System prompt test uses service mapping")
        let systemTestIssueView = block(
            source,
            from: "if let issue = systemTestIssue {",
            to: "if let output = systemTestOutput {"
        )
        try expect(
            systemTestIssueView.contains("action: settingsTestRecoveryAction("),
            "System prompt test uses shared recovery routing"
        )
        let contextTestIssueView = block(
            source,
            from: "if let issue = contextTestIssue {",
            to: "if let error = contextTestError {"
        )
        try expect(
            contextTestIssueView.contains("action: settingsTestRecoveryAction("),
            "Context prompt test uses shared recovery routing"
        )
        try expect(
            source.contains("case .openProviderSettings, .openModelsSettings")
                && !source.contains("appState.openProviderSettings()"),
            "Settings prompt issues omit no-op Provider navigation"
        )
        try expect(
            source.contains("contextTestIssue = context.userIssueRecord"),
            "Context prompt test surfaces structured Context issues"
        )
    }

    private static func testRunLogSanitizesMachineStatuses(_ source: String) throws {
        let runLog = block(
            source,
            from: "struct RunLogEntryView: View",
            to: "struct PipelineStepView"
        )
        try expect(runLog.contains("if case .failed = item.machineStatus"), "Run Log reads typed failure state")
        try expect(runLog.contains("item.userIssuePresentation()?.body"), "Run Log displays safe localized issue copy")
        try expect(!runLog.contains("Text(item.postProcessingStatus)"), "Run Log hides persisted machine tokens")
    }

    private static func testRecoveryActionsUseExistingRoutes(
        _ noteBrowser: String,
        _ appState: String
    ) throws {
        try expect(noteBrowser.contains("appState.selectedSettingsTab = .models"), "provider and model actions open Models settings")
        try expect(noteBrowser.contains("NotificationCenter.default.post(name: .showSettings"), "settings action uses existing notification")
        try expect(noteBrowser.contains("appState.openMicrophoneSettings()"), "microphone action uses existing route")
        try expect(noteBrowser.contains("appState.openSpeechRecognitionSettings()"), "speech action uses existing route")
        try expect(noteBrowser.contains("appState.openScreenCaptureSettings()"), "screen action uses existing route")
        try expect(appState.contains("func openSpeechRecognitionSettings()"), "AppState exposes speech privacy route")
        try expect(!noteBrowser.contains("downloadModel()"), "error recovery never starts an implicit model download")
    }

    // Dismiss (X) is only meaningful for the compact .warningBanner style;
    // the centered .full error card must never grow a dismiss control.
    private static func testDismissibleBannerScopedToWarningStyle(
        _ issueView: String,
        _ noteBrowser: String,
        _ appState: String
    ) throws {
        try expect(
            issueView.contains("var onDismiss: (() -> Void)?"),
            "shared issue renderer accepts an optional dismiss handler"
        )
        let bannerView = block(
            issueView,
            from: "private var bannerView: some View {",
            to: "private var inlineView: some View {"
        )
        try expect(bannerView.contains("dismissButton"), "banner style renders the dismiss control")
        let fullView = block(
            issueView,
            from: "private var fullView: some View {",
            to: "private var bannerView: some View {"
        )
        try expect(!fullView.contains("dismissButton"), "centered error card never renders a dismiss control")
        try expect(!fullView.contains("onDismiss"), "centered error card ignores onDismiss entirely")

        let warningBannerUsage = block(
            noteBrowser,
            from: "if let warningPresentation, !isWarningBannerDismissed {",
            to: "NoteTextView(text: displayContent"
        )
        try expect(warningBannerUsage.contains("style: .warningBanner"), "sanity: this is the warning banner usage")
        try expect(warningBannerUsage.contains("onDismiss:"), "warning banner usage wires a dismiss handler")

        let errorCardUsage = block(
            noteBrowser,
            from: "if let issuePresentation {",
            to: ".fill(Color.primary.opacity(0.04))"
        )
        try expect(errorCardUsage.contains("QuillUserIssueView("), "sanity: this is the centered error card usage")
        try expect(!errorCardUsage.contains("onDismiss"), "centered error card usage never passes onDismiss")

        try expect(
            appState.contains("func isWarningBannerDismissed(noteID: UUID, code: QuillUserIssueCode) -> Bool"),
            "AppState exposes per-note, per-code dismissal lookup"
        )
        try expect(
            appState.contains("func dismissWarningBanner(noteID: UUID, code: QuillUserIssueCode)"),
            "AppState exposes a dismissal setter"
        )
        let retryBody = block(
            appState,
            from: "func retryTranscription(item: PipelineHistoryItem)",
            to: "private func copyRetryTranscriptToPasteboardIfNeeded"
        )
        try expect(
            retryBody.contains("incrementNoteRetryGeneration(for: item.id)"),
            "retry bumps the note's retry generation, invalidating stale dismissals"
        )
    }

    private static func source(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    private static func block(
        _ source: String,
        from startMarker: String,
        to endMarker: String
    ) -> String {
        guard let start = source.range(of: startMarker),
              let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else {
            preconditionFailure("Expected source block from \(startMarker) to \(endMarker)")
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else { throw TestFailure(label) }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
