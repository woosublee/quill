import Foundation
import QuillUserIssueCore

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
        try testEmptyStatesReadDesignTokens(issueView, noteBrowser)
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
        try testMenuBarStatusItemHasAccessibilityLabel(try source("Sources/App.swift"))
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
            // The button keys come from the shared core (#191).
            "actionTitleOverride ?? presentation.recoveryAction.titleKey"
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
        try testBannersReadDesignTokens(source)
    }

    /// Banners, the info notice, and inline issue rows draw from
    /// QuillDesignTokens instead of literals (#736 step 3). Each view is
    /// checked on its own block so one view going back to literals fails.
    private static func testBannersReadDesignTokens(_ source: String) throws {
        // The one-line banner, its buttons, and the surface are shared with
        // the iPhone (#744); the Mac only forwards to them.
        let shared = try Self.source("Packages/QuillNoteUI/Sources/NoteBanner.swift")
        let surface = block(shared, from: "public struct NoteBannerSurface: View", to: "extension View {")
        for marker in [
            ".fill(QuillColor.fillBanner.color(for: colorScheme))",
            ".strokeBorder(QuillColor.hairlineStrong.color(for: colorScheme), lineWidth: 1)",
            ".quillShadow(.banner)",
        ] {
            try expect(surface.contains(marker), "banner surface reads the token \(marker)")
        }
        try expect(
            block(shared, from: "public func noteBannerBackground() -> some View {", to: "\n}")
                .contains("background(NoteBannerSurface())"),
            "the banner background is the shared surface on radius-9"
        )
        for (name, from, to, marker) in [
            ("status banner", "struct QuillStatusBanner: View", "/// The \"+N\" / \"Show Less\" pill", "NoteBanner("),
            ("expansion pill", "struct QuillBannerExpansionButton: View", "/// The close button", "NoteBannerExpansionButton(expansion: expansion, strings: .mac)"),
            ("close button", "struct QuillBannerDismissButton: View", "\n}", "NoteBannerDismissButton(label: localizedCatalogString(\"Dismiss\"), action: action)"),
            ("banner background", "func quillBannerBackground() -> some View {", "\n}", "noteBannerBackground()"),
        ] {
            try expect(block(source, from: from, to: to).contains(marker), "the Mac \(name) is the shared one")
        }
        for marker in [
            "typealias QuillBannerSurface = NoteBannerSurface",
            "typealias QuillBannerButtonSurface = NoteBannerButtonSurface",
        ] {
            try expect(source.contains(marker), "the Mac uses the shared \(marker)")
        }
        let views: [(name: String, text: String, from: String, to: String, markers: [String])] = [
            ("issue banner", source, "private var bannerView: some View {", "/// A compact box inside a settings form.", [
                ".quillTextStyle(.bannerTitle)", ".quillTextStyle(.callout)",
                ".background(QuillBannerSurface(cornerRadius: QuillRadius.radius9))",
            ]),
            ("inline issue row", source, "private var inlineView: some View {", "@ViewBuilder\n    private var dismissButton", [
                ".quillTextStyle(.bannerTitle)", ".quillTextStyle(.callout)",
                ".background(QuillBannerSurface(cornerRadius: QuillRadius.radius8))",
            ]),
            ("row button", shared, "public struct NoteBannerButtonSurface: View", "/// The surface behind", [
                "RoundedRectangle(cornerRadius: QuillRadius.radius6)",
                ".strokeBorder(QuillColor.hairline.color(for: colorScheme), lineWidth: 1)",
            ]),
            ("info notice", source, "struct QuillInfoNotice: View", "/// The text the shared banner", [
                ".quillTextStyle(.callout)", "HStack(spacing: QuillSpacing.space6)",
            ]),
            ("status banner", shared, "public struct NoteBanner: View", "/// The \"+N\" / \"Show Less\" pill", [
                ".quillTextStyle(.bannerTitle)", ".quillTextStyle(.callout)", ".noteBannerBackground()",
            ]),
        ]
        for view in views {
            let body = block(view.text, from: view.from, to: view.to)
            for marker in view.markers {
                try expect(body.contains(marker), "\(view.name) reads the token \(marker)")
            }
            for literal in [
                ".font(.system(size: 12))",
                ".font(.system(size: 12, weight: .semibold))",
                "Color.primary.opacity(0.045)",
                "radius: 1.5",
                "cornerRadius: 9",
                "cornerRadius: 8",
                "cornerRadius: 6",
            ] {
                try expect(!body.contains(literal), "\(view.name) no longer writes \(literal)")
            }
        }
    }

    /// Empty and issue states draw their disc, type, and spacing from
    /// QuillDesignTokens instead of literals (#736 step 4). Each state is
    /// checked on its own block so one going back to literals fails.
    private static func testEmptyStatesReadDesignTokens(
        _ issueView: String,
        _ noteBrowser: String
    ) throws {
        let disc = block(noteBrowser, from: "private struct EmptyStateDisc: View {", to: "private struct RecordingElapsedTitle: View {")
        for marker in [
            "var size: CGFloat = QuillControlSize.emptyDisc",
            ".fill(QuillColor.fillEmptyDisc.color(for: colorScheme))",
            "Circle().stroke(QuillColor.hairlineStrong.color(for: colorScheme), lineWidth: 1)",
            "style: StrokeStyle(lineWidth: 1, dash: [4])",
        ] {
            try expect(disc.contains(marker), "empty-state disc reads the token \(marker)")
        }
        let states: [(name: String, source: String, from: String, to: String, markers: [String])] = [
            ("issue page", issueView, "private var fullView: some View {", "private var bannerView: some View {", [
                ".quillTextStyle(.emptyTitle)", ".quillTextStyle(.emptyDetail)",
                "VStack(spacing: QuillSpacing.space8)", "HStack(spacing: QuillSpacing.space6)",
                "width: QuillControlSize.issueDisc, height: QuillControlSize.issueDisc",
                ".background(accentColor.opacity(QuillOpacity.issueDisc), in: Circle())",
            ]),
            ("list empty state", noteBrowser, "private var emptyListState: some View {", "// MARK: - Detail", [
                ".quillTextStyle(.emptyDetail)", ".padding(.horizontal, QuillSpacing.space20)",
            ]),
            ("no search results", noteBrowser, "private var emptyDetailNoSearchResults: some View {", "private var emptyDetailNoSelection: some View {", [
                "EmptyStateDisc(edge: .solid)", ".quillTextStyle(.emptyTitle)", ".quillTextStyle(.emptyDetail)",
                "VStack(spacing: QuillSpacing.space12)",
            ]),
            ("no selection", noteBrowser, "private var emptyDetailNoSelection: some View {", "private var emptyDetailNoRecordings: some View {", [
                "EmptyStateDisc(edge: .solid)", ".quillTextStyle(.emptyTitle)", ".quillTextStyle(.emptyDetail)",
                "VStack(spacing: QuillSpacing.space12)",
            ]),
            ("no recordings", noteBrowser, "private var emptyDetailNoRecordings: some View {", "// MARK: - Horizontally Scrollable Title Field", [
                "EmptyStateDisc(size: 96, edge: .dashed)", "VStack(spacing: QuillSpacing.space14)",
            ]),
            ("note empty content", noteBrowser, "private var emptyContentState: some View {", "private var emptyTranscriptPlaceholder: some View {", [
                ".quillTextStyle(.emptyTitle)", ".quillTextStyle(.emptyDetail)",
                "width: QuillControlSize.emptyDisc, height: QuillControlSize.emptyDisc",
                ".padding(.horizontal, QuillSpacing.space60)", "VStack(spacing: QuillSpacing.space14)",
            ]),
            ("empty transcript", noteBrowser, "private var emptyTranscriptPlaceholder: some View {", "private var noContentLabel: some View {", [
                ".quillTextStyle(.emptyDetail)", "VStack(spacing: QuillSpacing.space14)",
            ]),
            ("no content label", noteBrowser, "private var noContentLabel: some View {", "private func unrecoveredRecordingState(", [
                "EmptyStateDisc(edge: .none)", "VStack(spacing: QuillSpacing.space14)",
            ]),
        ]
        for state in states {
            let body = block(state.source, from: state.from, to: state.to)
            for marker in state.markers {
                try expect(body.contains(marker), "\(state.name) reads the token \(marker)")
            }
            for literal in [
                ".font(.system(size: 15, weight: .semibold))",
                ".font(.system(size: 12))",
                "Color.primary.opacity(0.04)",
                "Color.primary.opacity(0.08)",
                "width: 80, height: 80",
                ".padding(.horizontal, 60)",
                "width: 64, height: 64",
                ".quillTextStyle(.callout)",
            ] {
                try expect(!body.contains(literal), "\(state.name) no longer writes \(literal)")
            }
        }
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
            ((try? String(contentsOfFile: "Packages/QuillNoteUI/Sources/NoteFloatingToolbar.swift", encoding: .utf8)) ?? "")
                .contains(".opacity(isEnabled ? 1 : 0.35)"),
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
            from: "!isWarningBannerDismissed,\n                   let warningPresentation",
            to: "NoteTextView("
        )
        // #457: notices stay as they are while retranscribing, under the
        // progress layer, instead of disappearing.
        try expect(
            !warningBannerUsage.contains("!appState.retryingItemIDs.contains(item.id)"),
            "previous warning stays visible while retranscription is in progress"
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
            to: "EmptyStateDisc(edge: .none)"
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
            from: "private func generateSummary(toCompare: Bool = false) {",
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
            source.contains("actionTitleOverride ?? presentation.recoveryAction.titleKey"),
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
        // Recovery also holds Recently Deleted Notes, so it is always listed;
        // archived histories show inside it only when a snapshot exists.
        try expect(
            settings.contains("case .recovery:\n                    HistoryRecoverySettingsView()")
                && !settings.contains("tab != .recovery ||"),
            "Settings always exposes Recovery"
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

    private static func testMenuBarStatusItemHasAccessibilityLabel(_ app: String) throws {
        let label = block(app, from: "struct MenuBarLabel: View", to: "enum StampedMenuBarIcon")
        for marker in [
            ".accessibilityElement(children: .ignore)",
            ".accessibilityLabel(accessibilityStatusLabel)",
            "if appState.isRecording { return Text(\"Quill, recording\") }",
            "if appState.isTranscribing { return Text(\"Quill, transcribing\") }",
            "return Text(\"Quill, word added to vocabulary\")",
            "return Text(\"Quill\")",
        ] {
            guard label.contains(marker) else {
                throw TestFailure("Menu bar status item accessibility label is missing: \(marker)")
            }
        }
        // The visible icons must stay exactly as before.
        for marker in [
            "if appState.isRecording { return \"record.circle\" }",
            "if appState.isTranscribing { return \"ellipsis.circle\" }",
            "return \"waveform\"",
            "Image(systemName: \"checkmark\")",
        ] {
            guard label.contains(marker) else {
                throw TestFailure("Menu bar status item icon changed: \(marker)")
            }
        }
        guard app.contains("image.accessibilityDescription = String(localized: \"Quill\")") else {
            throw TestFailure("Stamped dev menu bar icon needs an accessibility description")
        }
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
