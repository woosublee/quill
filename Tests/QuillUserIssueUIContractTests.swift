import Foundation

@main
struct QuillUserIssueUIContractTests {
    static func main() throws {
        let issueView = try source("Sources/QuillUserIssueView.swift")
        let noteBrowser = try source("Sources/NoteBrowserView.swift")
        let setup = try source("Sources/SetupView.swift")
        let settings = try source("Sources/SettingsView.swift")
        let menuBar = try source("Sources/MenuBarView.swift")
        let appState = try source("Sources/AppState.swift")
        let historyRecovery = try source("Sources/HistoryRecoveryView.swift")

        try testSharedRenderer(issueView)
        try testNoteBrowserUsesStructuredErrorAndWarningUI(noteBrowser)
        try testNoteBrowserSeparatesRecoveryAndRetryCapability(noteBrowser)
        try testSetupOmitsRequiredTranscriptionTest(setup)
        try testSettingsTestsUseStructuredIssues(settings)
        try testRunLogSanitizesMachineStatuses(settings)
        try testRecoveryActionsUseExistingRoutes(noteBrowser, appState)
        try testDismissibleBannerScopedToWarningStyle(issueView, noteBrowser, appState)
        try testSummaryRetryUsesSummarySpecificCopy(issueView)
        try testSummaryInvalidationDoesNotBecomeTransientFailure(noteBrowser)
        try testHistoryUnavailableProtectionAndArchiveNotice(
            noteBrowser, settings, menuBar, appState, historyRecovery
        )
        try testNonDurableHistoryWarningIsVisibleAndDoesNotExposeBackups(
            menuBar,
            appState
        )
        try testRecoveryImportOutcomePersistsOutsideProgressOverlay(
            appState,
            historyRecovery
        )
        try testRecoveryCountGrammarUsesSingularCatalogKeys(historyRecovery)
        print("QuillUserIssueUIContractTests passed")
    }

    private static func testSharedRenderer(_ source: String) throws {
        for marker in [
            "struct QuillUserIssueView: View",
            "presentation.title",
            "presentation.body",
            "presentation.suggestion",
            "presentation.detailsRows",
            "presentation.recoveryAction",
            // Suggestion and diagnostics live behind an info popover.
            ".popover(isPresented: $showsDetails",
            "struct QuillInfoNotice: View",
            "case .retryPostProcessing:"
        ] {
            try expect(source.contains(marker), "shared issue renderer contains \(marker)")
        }
        try expect(
            !source.contains("DisclosureGroup(\"Details\")"),
            "the details disclosure row is replaced by the info popover"
        )
        try expect(
            source.contains("if !presentation.suggestion.isEmpty"),
            "shared issue renderer omits empty recovery suggestions"
        )
        try expect(
            source.contains("ViewThatFits(in: .horizontal)"),
            "the one-line banner hides a reason that would be cut off"
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
            source.contains("case .needsModelSelection, .needsProviderConfiguration:")
                && source.contains("retryChoiceRequest = RetryChoiceRequest(options: options)"),
            "retry without a usable selected model opens the transcription picker"
        )
        try expect(
            source.contains("Set up a model in Settings to retry transcription."),
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
        try expect(
            bannerView.contains("detailsButton"),
            "banner style offers shared structured details behind the info button"
        )
        let fullView = block(
            issueView,
            from: "private var fullView: some View {",
            to: "private var bannerView: some View {"
        )
        try expect(!fullView.contains("dismissButton"), "centered error card never renders a dismiss control")
        try expect(!fullView.contains("onDismiss"), "centered error card ignores onDismiss entirely")

        try expect(
            !noteBrowser.contains("private var shouldShowWarningBanner: Bool"),
            "warning visibility does not calculate the presentation twice"
        )
        let warningBannerUsage = block(
            noteBrowser,
            from: "if !isWarningBannerDismissed,",
            to: "NoteTextView("
        )
        try expect(
            warningBannerUsage.contains("!appState.retryingItemIDs.contains(item.id)"),
            "previous warning stays hidden while retranscription is in progress"
        )
        try expect(
            warningBannerUsage.contains("let warningPresentation"),
            "warning presentation is evaluated only after cheap visibility guards"
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
        let retryEvents = block(
            appState,
            from: "private func applyTranscriptionRetryWorkflowEvent(",
            to: "private func applyTranscriptionRetryWorkflowState("
        )
        let warningGenerationEffects = block(
            retryEvents,
            from: "if effects.advancesWarningGeneration {",
            to: "if effects.invalidatesMeetingSummary {"
        )
        try expect(
            warningGenerationEffects.contains(
                "incrementNoteRetryGeneration(for: item.id)"
            ),
            "persisted Retry warning effects invalidate stale dismissals"
        )
    }

    private static func testSummaryInvalidationDoesNotBecomeTransientFailure(
        _ source: String
    ) throws {
        let generation = block(
            source,
            from: "private func generateSummary() {",
            to: "\n    private func deleteSummary"
        )
        try expect(
            generation.contains("if let error = error as? MeetingSummaryError, error == .sourceChanged {"),
            "source and lifecycle invalidation return without a transient Summary failure"
        )
    }

    private static func testSummaryRetryUsesSummarySpecificCopy(
        _ source: String
    ) throws {
        try expect(
            source.contains("var actionTitleOverride: String?"),
            "shared issue renderer accepts a context-specific retry title"
        )
        try expect(
            source.contains("actionTitleOverride ?? actionTitle"),
            "summary retry copy overrides the transcription retry title"
        )
    }

    private static func testNonDurableHistoryWarningIsVisibleAndDoesNotExposeBackups(
        _ menuBar: String,
        _ appState: String
    ) throws {
        try expect(
            appState.contains("@Published private(set) var historyPersistenceWarning"),
            "AppState publishes a session-only history persistence warning"
        )
        try expect(
            appState.contains(".historyPersistenceUnavailable"),
            "AppState uses the structured non-durable history warning"
        )
        try expect(
            menuBar.contains("appState.historyPersistenceWarning"),
            "Menu Bar shows the non-durable history warning"
        )
        try expect(
            !menuBar.contains("backupName"),
            "Menu Bar never exposes a history recovery backup name"
        )
        try expect(
            !menuBar.contains("History Recovery"),
            "Menu Bar never exposes a history recovery path"
        )
    }

    private static func testRecoveryImportOutcomePersistsOutsideProgressOverlay(
        _ appState: String,
        _ historyRecovery: String
    ) throws {
        try expect(
            appState.contains(
                "@Published private(set) var historyRecoveryImportResult"
            )
                && appState.contains(
                    "historyRecoveryImportResult = state.importResult"
                ),
            "workflow partial recovery outcomes reach AppState after the operation ends"
        )
        try expect(
            historyRecovery.contains("appState.historyRecoveryImportResult")
                && historyRecovery.contains("Some history could not be recovered."),
            "Recovery renders a partial import outcome independently of its progress overlay"
        )
        let overlay = block(
            historyRecovery,
            from: ".overlay {",
            to: ".onAppear {"
        )
        try expect(
            !overlay.contains("historyRecoveryImportResult"),
            "partial recovery feedback does not disappear with the progress overlay"
        )
    }

    private static func testRecoveryCountGrammarUsesSingularCatalogKeys(
        _ historyRecovery: String
    ) throws {
        try expect(
            historyRecovery.contains("private func localizedRecoveryRecordCount(")
                && historyRecovery.contains("%lld record found.")
                && historyRecovery.contains("Import %lld record…")
                && historyRecovery.contains("%lld record is ready to import.")
                && historyRecovery.contains("%lld record is already in the current history.")
                && historyRecovery.contains("%lld record conflicts with the current history."),
            "Recovery record counts choose singular catalog keys before formatting"
        )
    }

    private static func testHistoryUnavailableProtectionAndArchiveNotice(
        _ noteBrowser: String,
        _ settings: String,
        _ menuBar: String,
        _ appState: String,
        _ historyRecovery: String
    ) throws {
        try expect(
            appState.contains("@Published private(set) var isHistoryUnavailable = false"),
            "AppState publishes an explicit history-unavailable state"
        )
        try expect(
            appState.contains("func archiveOldHistoryAndStartFresh(")
                && appState.contains("func openHistoryRecoverySettings()")
                && appState.contains("@Published private(set) var historyRecoverySnapshots"),
            "AppState exposes archive post-actions and recovery settings state"
        )
        for source in [noteBrowser, settings, menuBar] {
            try expect(
                source.contains("appState.isHistoryUnavailable"),
                "every history surface retains the protected state"
            )
            try expect(
                source.contains("HistoryUnavailableRecoveryActions"),
                "every protected history surface uses shared recovery actions"
            )
        }
        try expect(
            !noteBrowser.contains("HistoryArchiveNoticeView")
                && !settings.contains("HistoryArchiveNoticeView"),
            "Note Browser and Run Log leave archive management to Settings Recovery"
        )
        try expect(
            settings.contains("HistoryRecoverySettingsView()")
                && settings.contains("tab != .recovery || !appState.historyRecoverySnapshots.isEmpty"),
            "Settings exposes Recovery only when a snapshot exists"
        )
        try expect(
            settings.contains("case .recovery where !appState.historyRecoverySnapshots.isEmpty:")
                && settings.contains("case .recovery:\n                    GeneralSettingsView()"),
            "Settings falls back to General when an asynchronous snapshot deletion hides Recovery"
        )
        try expect(
            menuBar.contains("Button(\"Recovery…\")")
                && menuBar.contains("appState.openHistoryRecoverySettings()"),
            "Menu Bar routes published snapshots to Settings Recovery"
        )
        try expect(
            menuBar.contains("appState.isHistoryRecoveryOperationInProgress")
                && !menuBar.contains("historyRecoveryInspectionSnapshotID"),
            "Menu Bar blocks recording only while recovery changes active history"
        )
        try expect(
            noteBrowser.contains("if appState.isHistoryUnavailable"),
            "Note Browser checks protected state before normal history"
        )
        for marker in [
            "Recover Earlier History…",
            "Start Fresh…",
            "Archive and Open Recovery",
            "Archive and Start Fresh",
            "Open Data Folder",
            ".confirmationDialog(",
            "role: .destructive",
            "postAction: .openRecovery",
            "postAction: .startFresh",
            "struct HistoryRecoverySettingsView",
            "ensureHistoryRecoveryInspection()",
            "Unable to Inspect",
            "Retry Inspection",
            "Import %lld records…",
            "Cancel Scheduled Deletion",
            "Delete Recovery Snapshot…"
        ] {
            try expect(historyRecovery.contains(marker), "recovery UI contains \(marker)")
        }
        try expect(
            !historyRecovery.contains("Check Recovery Contents"),
            "Recovery automatically inspects snapshots instead of requiring a manual preflight button"
        )
        try expect(
            !historyRecovery.contains("HistoryArchiveNoticeView")
                && !historyRecovery.contains("backupName")
                && !historyRecovery.contains("History Recovery"),
            "recovery UI omits archive notices and internal paths"
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
