import Foundation
import QuillSummaryFormatCore

@main
struct MeetingSummaryUIContractTests {
    static func main() throws {
        let settings = try source("Sources/SettingsView.swift")
        let noteBrowser = try source("Sources/NoteBrowserView.swift")
        let summaryView = try source("Sources/MeetingSummaryView.swift")
        testCardOrder(settings)
        testExistingFeatureSectionBodiesRemainIndependent(settings)
        testTranscriptFirstSummaryPresentation(
            noteBrowser: noteBrowser,
            summaryView: summaryView
        )
        testSummaryFailurePresentationContract(noteBrowser)
        testNoteListRowSummaryBadgeOrder(noteBrowser)
        testSearchOpensSummaryTabForSummaryOnlyMatches(noteBrowser)
        print("MeetingSummaryUIContractTests passed")
    }

    private static func testSearchOpensSummaryTabForSummaryOnlyMatches(_ noteBrowser: String) {
        // A source jump counts as the user's tab choice, and a blank query
        // isn't an active search.
        precondition(noteBrowser.contains("if isSearchActive {\n            userChoseContentModeDuringSearch = true\n        }\n        selectedContentMode = .transcript"))
        precondition(noteBrowser.contains("isSearchActive: isSearchActive,"))
        precondition(noteBrowser.contains("private var isSearchActive: Bool {\n        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty"))
    // The deferred search switch rechecks the person's choice before it runs.
    precondition(noteBrowser.contains("guard !cancelled() else { return }\n            selectedContentMode = .summary"))

        for expected in [
            "prefersSummaryTab: searchMatcher.matchesOnlyInSummary(item, query: searchText)",
            "isSearchActive: isSearchActive,",
            "let prefersSummaryTab: Bool",
            "applySearchTabPreference(prefersSummaryTab)",
            ".onChange(of: prefersSummaryTab) { newValue in",
            "userChoseContentModeDuringSearch = false"
        ] {
            precondition(noteBrowser.contains(expected), "Missing search Summary tab contract: \(expected)")
        }
        let applyBody = block(
            in: noteBrowser,
            from: "private func applySearchTabPreference(",
            to: "\n    private func revealSummaryIfPending"
        )
        precondition(
            applyBody.contains("guard prefersSummary, !userChoseContentModeDuringSearch"),
            "search must not override a tab the person picked during the current search"
        )
        precondition(
            applyBody.contains("switchToSummaryTab(unless: { userChoseContentModeDuringSearch })"),
            "search must reuse the deferred Summary tab switch"
        )
        precondition(
            !applyBody.contains(".transcript"),
            "search must never force the Transcript tab back"
        )
        let pickerBindingBody = block(
            in: noteBrowser,
            from: "private var userContentModeSelection: Binding<NoteContentMode> {",
            to: "\n    private func applySearchTabPreference"
        )
        precondition(
            pickerBindingBody.contains("userChoseContentModeDuringSearch = true"),
            "picking a tab during search must record the person's choice"
        )
    }

    private static func testNoteListRowSummaryBadgeOrder(_ noteBrowser: String) {
        guard let audioOnlyBadge = noteBrowser.range(
            of: "displayData.status == .audioOnly"
        ), let summaryBadge = noteBrowser.range(
            of: "displayData.hasMeetingSummary"
        ) else {
            preconditionFailure("Missing Note List row badge condition")
        }
        precondition(
            audioOnlyBadge.lowerBound < summaryBadge.lowerBound,
            "Audio only badge must appear before the Summary badge"
        )
    }

    private static func testCardOrder(_ source: String) {
        guard let postProcessingCard = source.range(
            of: "SettingsCard(\"Post-processing\""
        ), let contextCard = source.range(
            of: "SettingsCard(\"Context\""
        ), let meetingSummaryCard = source.range(
            of: "SettingsCard(\"Meeting Summary\""
        ) else {
            preconditionFailure("Missing model Settings card")
        }

        precondition(postProcessingCard.lowerBound < contextCard.lowerBound)
        precondition(contextCard.lowerBound < meetingSummaryCard.lowerBound)
    }

    private static func testExistingFeatureSectionBodiesRemainIndependent(
        _ source: String
    ) {
        let postProcessing = block(
            in: source,
            from: "private var postProcessingFeatureSection: some View",
            to: "\n    private var contextEnabled"
        )
        let context = block(
            in: source,
            from: "private var contextFeatureSection: some View",
            to: "\n    private var meetingSummaryEnabled"
        )

        for statement in [
            "Toggle(\"\", isOn: postProcessingEnabled)",
            "aiProcessingChoicePicker(for: .postProcessing)",
            "postProcessingDetails"
        ] {
            precondition(postProcessing.contains(statement))
        }
        for statement in [
            "Toggle(\"\", isOn: contextEnabled)",
            "aiProcessingChoicePicker(for: .context)",
            "contextDetails"
        ] {
            precondition(context.contains(statement))
        }
        precondition(!postProcessing.contains("meetingSummary"))
        precondition(!context.contains("meetingSummary"))
    }

    private static func testTranscriptFirstSummaryPresentation(
        noteBrowser: String,
        summaryView: String
    ) {
        for expected in [
            "enum NoteContentMode",
            "case transcript",
            "case summary",
            "@State private var selectedContentMode: NoteContentMode = .transcript",
            "Picker(\"Note Content\", selection: userContentModeSelection)",
            ".pickerStyle(.segmented)",
            "selectedContentMode = .transcript",
            "MeetingSummaryView(",
            "generateMeetingSummary(id: item.id, asCandidate: toCompare)",
            "private var noteHeader: some View",
            "NoteAudioBar(item: item, downloader: appState.noteAudioDownloader, onMessage: { showToast($0) })",
            "@State private var highlightedSourceQuote: String?",
            "highlightedSourceQuote: highlightedSourceQuote",
            "MeetingSummarySourceLocator.range(",
            "scrollRangeToVisible",
            // A source quote scrolls in with room above the top fade.
            "textView.scrollToVisible(rect.insetBy(dx: 0, dy: -Self.highlightScrollMargin))",
            "static let highlightScrollMargin: CGFloat = 32",
            ".accessibilityLabel(\"Note Content\")",
            "private var summaryToolbarAction: SummaryToolbarAction",
            "case .runSummary: summaryToolbarAction.helpText",
            "private var currentSummaryAttempt: MeetingSummaryAttempt? {",
            "summaryAttempt.isCurrent(sourceFingerprint: appState.meetingSummarySourceFingerprint(for: item))",
            "private var showsSummaryTab: Bool {",
            "summaryEnvelope != nil || (currentSummaryAttempt?.outcome == .failed && currentSummaryAttempt?.issue != nil) || summaryIssue != nil",
            "summaryActionIsDisabled",
            "handleSummaryAction",
            "@State private var showDeleteChoice = false",
            "\"What do you want to delete?\"",
            "Button(\"Delete Summary Only\") { deleteSummary() }",
            "Button(\"Delete Entire Note\", role: .destructive) { onDelete() }",
            ".keyboardShortcut(.defaultAction)",
            "sourceQuoteIsValid:",
            "consumeMeetingSummaryPendingReveal(id: item.id)",
            ".onChange(of: selectedContentMode) { newValue in",
            "onDelete:"
        ] {
            precondition(noteBrowser.contains(expected), "Missing Note Browser contract: \(expected)")
        }
        // The summary toolbar action follows the open tab, not
        // showsSummaryTab alone (the shared #690 table decides).
        precondition(noteBrowser.contains("tab: isShowingSummaryTab ? .summary : .transcript,"))
        let generateSummaryBody = block(
            in: noteBrowser,
            from: "private func generateSummary(toCompare: Bool = false) {",
            to: "\n    private func deleteSummary"
        )
        precondition(
            !generateSummaryBody.contains("revealSummaryIfPending"),
            "generateSummary must not race with onAppear/onChange by directly revealing the tab"
        )
        precondition(
            !generateSummaryBody.contains("selectedContentMode = .summary"),
            "generateSummary must not directly set selectedContentMode"
        )
        precondition(
            generateSummaryBody.contains("switchToSummaryTab()"),
            "generateSummary must switch to the Summary tab so a failed first-time generation is visible"
        )
        let revealSummaryIfPendingBody = block(
            in: noteBrowser,
            from: "private func revealSummaryIfPending() {",
            to: "\n    private func generateSummary"
        )
        precondition(
            revealSummaryIfPendingBody.contains("DispatchQueue.main.async"),
            "revealing the Summary tab defers selection so a freshly appearing segmented control settles first"
        )
        let meetingSummaryJSONOnChangeBody = block(
            in: noteBrowser,
            from: ".onChange(of: item.meetingSummaryJSON) { newValue in",
            to: "\n        .onChange(of: selectedContentMode)"
        )
        precondition(
            meetingSummaryJSONOnChangeBody.contains("newValue == nil"),
            "meetingSummaryJSON onChange must decide from its own newValue, not a stale self.item read"
        )
        precondition(
            !meetingSummaryJSONOnChangeBody.contains("showsSummaryTab"),
            "meetingSummaryJSON onChange must not rely on showsSummaryTab, which reads a potentially stale self.item"
        )

        for expected in [
            "struct MeetingSummaryView<Notices: View>: View",
            "@ViewBuilder notices: () -> Notices",
            "Overview",
            "Key Points",
            "Decisions",
            "Action Items",
            "Open Questions",
            "Label(\"View in Transcript\"",
            ".accessibilityLabel(item.task)",
            "sourceQuoteIsValid: (String) -> Bool",
            "private var summaryContent: some View",
            // #262: the summary is edited in place and saves on its own.
            "let onEditContent: (MeetingSummaryContent) -> Bool",
            "axis: .vertical",
            ".textFieldStyle(.plain)",
            ".onSubmit { insertPoint(after: point.id, in: points) }",
            ".onSubmit { insertAction(after: item.id) }",
            ".modifier(DeleteWhenEmpty(",
            // Each section ends in a row to type in, not a button that adds one.
            "ForEach(rowsWithNewRow(points))",
            "ForEach(actionsWithNewRow)",
            "prompt: Text(\"New Item\")",
            "prompt: Text(\"New Action Item\")",
            "Button(\"Revert to Original\")",
            "draftSaver.saveNow = { saveNow() }"
        ] {
            precondition(summaryView.contains(expected), "Missing Summary view contract: \(expected)")
        }
        // #262: typing still waiting to save counts before Regenerate, and
        // making a summary locks only the editing controls, not the notices.
        let summaryAction = block(
            in: noteBrowser,
            from: "private func handleSummaryAction() {",
            to: "\n    /// The picker's binding"
        )
        if let flush = summaryAction.range(of: "guard summaryDraftSaver.saveNow() else { return }"),
           let check = summaryAction.range(of: "savedSummary?.isEdited == true") {
            precondition(flush.lowerBound < check.lowerBound, "pending edits are saved before the edited check")
        } else {
            preconditionFailure("Regenerate must save pending summary edits first")
        }
        precondition(!summaryView.contains(".disabled(!isEditable)\n        .onChange(of: draft)"), "notices stay usable while a summary is made")
        // Retry Summary takes the same path, so it asks before replacing edits.
        precondition(noteBrowser.contains("case .retrySummary:\n            // Same path as the toolbar, so an edited summary asks first.\n            return SummaryIssueViewAction(\n                action: handleSummaryAction,"))
        precondition(summaryView.contains("guard onEditContent(draft) else { return false }"), "a failed save keeps the draft")

        // #262: an edited summary is regenerated as a candidate and compared
        // before anything replaces it; the choice pushes the other side out.
        precondition(noteBrowser.contains("Button(\"Make New Summary\") { generateSummary(toCompare: true) }"))
        precondition(noteBrowser.contains("MeetingSummaryComparisonView("))
        precondition(noteBrowser.contains("generateSummary(toCompare: savedSummary != nil)"), "every regenerate is compared first")
        precondition(noteBrowser.contains("isComparingCandidates: (summaryCandidate != nil && isShowingSummaryTab)\n                    || (showsTranscriptComparison && !isShowingSummaryTab)"), "the toolbar hides while comparing")
        // The toolbar follows the open tab: each tab's "make again" action
        // comes first, and Summary work started elsewhere opens its tab.
        // The note toolbar is the shared QuillNoteUI view and #690 table
        // (#697); the Note Browser only maps its state and actions.
        precondition(noteBrowser.contains("let state = NoteToolbarState.make(toolbarInput)\n        return NoteFloatingToolbar(\n            state: state,"))
        precondition(noteBrowser.contains("transcriptAction: actionState.showsRetryButton ? (isAudioOnly ? .transcribe : .retry) : nil,"))
        // #699: the first transcription and a cleanup alone stop from the
        // same ✕ the iPhone shows, each keeping what's saved.
        precondition(noteBrowser.contains("canCancelWork: canCancelToolbarWork,"))
        precondition(noteBrowser.contains("return appState.canCancelPostProcessing(noteID: item.id)"), "a cleanup offers ✕ only while it can stop")
        precondition(noteBrowser.contains(": appState.canCancelFirstTranscription(noteID: item.id)"))
        precondition(noteBrowser.contains("appState.cancelFirstTranscription(noteID: item.id)"))
        precondition(noteBrowser.contains("appState.cancelPostProcessing(noteID: item.id)"))
        // A press meant for the last button (or a quick second press) isn't a Cancel.
        precondition(noteBrowser.contains("&& now.timeIntervalSince(firstSlotChangedAt) > 0.6"))
        precondition(noteBrowser.contains(".onChange(of: state.firstSlot) { _ in\n            firstSlotChangedAt = Date()"))
        precondition(noteBrowser.contains("return appState.noteTranscriptionJobWork(noteID: item.id) ?? .none"), "the first transcription shows the toolbar")
        // #689: while a transcription runs, the same slot cancels it, like
        // the iPhone. Nothing is saved, so the current transcript stays.
        precondition(noteBrowser.contains("appState.cancelTranscriptionRetry(item: item)"))
        // #690: Cancel Summary stops the run and keeps the previous summary.
        precondition(noteBrowser.contains("appState.cancelMeetingSummary(noteID: item.id)"))
        let appStateForSummary = (try? String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)) ?? ""
        precondition(appStateForSummary.contains("meetingSummaryGenerationTasks.removeValue(forKey: noteID)?.cancel()"), "Cancel Summary stops the model request too")
        // The content picker keeps the indicator room in both segments
        // always, so neither changes width when a sign comes or goes.
        precondition(noteBrowser.contains("(Text(verbatim: Self.tabIndicatorRoom) + Text(\"Transcript\") + Text(verbatim: Self.tabIndicatorRoom))"))
        precondition(noteBrowser.contains("(Text(verbatim: Self.tabIndicatorRoom) + Text(\"Summary\") + Text(verbatim: Self.tabIndicatorRoom))"))
        precondition(!noteBrowser.contains("showsTranscriptTabIndicator ? \"\\u{2002}"), "no room that comes and goes")
        // The summary column keeps its width whatever notices show (it used
        // to shrink to its widest row during a retranscription).
        let summaryView = (try? String(contentsOfFile: "Sources/MeetingSummaryView.swift", encoding: .utf8)) ?? ""
        precondition(summaryView.contains(".frame(maxWidth: .infinity, alignment: .leading)\n            .frame(maxWidth: 760, alignment: .leading)"))
        precondition(noteBrowser.contains("return now.timeIntervalSince(firstSlotPressedAt) > 0.6"), "a double press isn't a Cancel")
        let appStateSource = (try? String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)) ?? ""
        precondition(appStateSource.contains("try? cloudTranscriptionJobStore.delete(historyID: item.id, session: nil)"), "a cancelled job doesn't resume at the next launch")
        precondition(appStateSource.contains("transcriptionRetryWorkflowItemIDs.contains(item.id) && !postProcessingNoteIDs.contains(item.id)"))
        precondition(noteBrowser.contains("canCreateSummary: summaryToolbarAction == .create ? !summaryActionIsDisabled : nil,"))
        precondition(noteBrowser.contains("if selectedContentMode != .summary {\n            switchToSummaryTab()\n        }"))
        precondition(noteBrowser.contains("private var summaryTabIndicator: some View"))
        let comparison = (try? String(contentsOfFile: "Sources/MeetingSummaryComparisonView.swift", encoding: .utf8)) ?? ""
        precondition(comparison.contains("@Environment(\\.accessibilityReduceMotion)"))
        precondition(comparison.contains(".timingCurve(0.2, 0.8, 0.2, 1, duration: duration)"))
        precondition(comparison.contains(".disabled(choice != nil)"), "a choice is made once")
        precondition(comparison.contains("if choice == nil {\n                choiceBar"), "the choice bar folds away with the push")
        precondition(comparison.contains("matchesEditor: isChosen"), "the chosen side is laid out like the editor")
        // Review fixes: a failed save reopens the choice, Return keeps the
        // current summary, and a vanished Summary tab hands back the transcript.
        precondition(comparison.contains("if !onUseNew() {\n                    withAnimation(animation) { choice = nil }"))
        precondition(comparison.contains("Button(labels.keepCurrent) { choose(.keepCurrent) }\n                .keyboardShortcut(.defaultAction)"))
        precondition(noteBrowser.contains(".onChange(of: showsSummaryTab) { shows in\n            if !shows, selectedContentMode == .summary {"))
        // #457: a retranscribed transcript is compared the same way, with
        // its own sign inside the Transcript segment.
        precondition(comparison.contains("struct SideBySideChoiceView<Side: View, ChosenHeader: View>: View"))
        precondition(comparison.contains("struct TranscriptComparisonView: View"))
        precondition(noteBrowser.contains("TranscriptComparisonView(\n                current: displayContent,"))
        precondition(noteBrowser.contains("private var transcriptTabIndicator: some View"))
        precondition(noteBrowser.contains("|| (showsTranscriptComparison && !isShowingSummaryTab)"), "the toolbar hides while comparing transcripts")
        // A retry with the same text skips the comparison and says so with the
        // Summary tab's status banner; other notices wait behind its "+1".
        precondition(noteBrowser.contains("let showsUnchangedNotice = appState.unchangedRetranscriptions[item.id]\n                    == item.displayedTranscript"), "the notice ends once the transcript changes")
        precondition(noteBrowser.contains("title: localizedCatalogString(\"The new transcript is the same as the current one.\")"))
        precondition(noteBrowser.contains("if !showsUnchangedNotice || areTranscriptNoticesExpanded,\n                   showsNothingToPostProcessNotice,"))
        precondition(noteBrowser.contains("if !showsUnchangedNotice || areTranscriptNoticesExpanded,\n                   !isWarningBannerDismissed,"))

        for unexpected in [
            "Quick review draft",
            "onDelete",
            "Delete Summary",
            "availability",
            "isStale",
            "onCreate",
            "onOpenModelSettings",
            "onCopyText",
            "isGenerating",
            "Divider()",
            ".help(\"Copy Section\")",
            ".help(\"Copy Action Item\")"
        ] {
            precondition(
                !summaryView.contains(unexpected),
                "Summary view should no longer contain: \(unexpected)"
            )
        }
    }

    private static func testSummaryFailurePresentationContract(
        _ noteBrowser: String
    ) {
        for expected in [
            "summaryEnvelope != nil || (currentSummaryAttempt?.outcome == .failed && currentSummaryAttempt?.issue != nil) || summaryIssue != nil",
            "issuePresentation()",
            "MeetingSummaryIssueAction.resolve",
            "summaryIssueAction(for: presentation)",
            "summaryFailureContent(",
            "QuillUserIssueView(",
            "style: .full",
            "action: summaryAction.action",
            "actionTitleOverride: summaryAction.actionTitleOverride",
            "private var summaryToolbarAction:",
            "case retry",
            "Retry Summary",
            "case .retry, .regenerate:",
            "arrow.triangle.2.circlepath",
            "private var canDeleteSummary:",
            "} else if canDeleteSummary {\n            showDeleteChoice = true\n        } else {\n            showDeleteConfirmation = true\n        }",
            "deleteMeetingSummary(noteID: item.id)",
            ".frame(maxWidth: .infinity, maxHeight: .infinity)"
        ] {
            precondition(noteBrowser.contains(expected), "Missing failure contract: \(expected)")
        }
        for unexpected in [
            "MeetingSummaryGenerationFailureView(",
            "View Transcript",
            "Clear Summary Failure",
            "showClearSummaryFailureConfirmation",
            "clearMeetingSummaryState(",
            "showDeleteSummaryConfirmation",
            "\"Delete this summary?\""
        ] {
            precondition(
                !noteBrowser.contains(unexpected),
                "Summary failures must use the shared non-scrolling error card, not: \(unexpected)"
            )
        }
        let fullFailureArea = block(
            in: noteBrowser,
            from: "private func summaryFailureContent(",
            to: "\n    @ViewBuilder\n    private var emptyContentState"
        )
        for unexpected in ["GeometryReader", "ScrollView", "Spacer(minLength: 48)", "Spacer(minLength: 92)"] {
            precondition(
                !fullFailureArea.contains(unexpected),
                "The shared summary error card must not force scrolling or fixed offsets: \(unexpected)"
            )
        }
        precondition(
            !FileManager.default.fileExists(
                atPath: "Sources/MeetingSummaryGenerationFailureView.swift"
            ),
            "The dedicated summary failure view is removed"
        )

        guard let summaryBranch = noteBrowser.range(of: "if let summaryEnvelope {"),
              let summaryView = noteBrowser.range(of: "MeetingSummaryView("),
              let failureBranch = noteBrowser.range(
                  of: "} else if let attempt = currentSummaryAttempt,"
              ) else {
            preconditionFailure("Missing saved-summary failure handling")
        }
        precondition(
            summaryBranch.lowerBound < summaryView.lowerBound
                && summaryView.lowerBound < failureBranch.lowerBound,
            "A saved summary must remain visible when a newer attempt failed"
        )

        let savedSummaryArea = block(
            in: noteBrowser,
            from: "if let summaryEnvelope {",
            to: "} else if let attempt = currentSummaryAttempt,"
        )
        precondition(
            savedSummaryArea.contains("summaryNotices"),
            "A saved summary shows its notices above the content"
        )
        let notices = block(
            in: noteBrowser,
            from: "private typealias SummaryNoticeKind = AppState.SummaryNoticeKind",
            to: "\n    private func summaryFailureContent("
        )
        for expected in [
            "summaryIssue?.presentation()",
            "let summaryAction = summaryIssueAction(for: presentation)",
            "style: .warningBanner",
            "action: summaryAction.action",
            "actionTitleOverride: summaryAction.actionTitleOverride",
            "isSummaryIssueBannerDismissed = true",
            "effectiveEvidenceVerification == .unverified",
            "Some evidence could not be verified.",
            "Transcript changed after this summary was generated.",
            "QuillStatusBanner(",
            "onDismiss: {",
            "QuillBannerExpansion(",
            "hiddenCount: notices.count - 1",
            "if areSummaryNoticesExpanded {"
        ] {
            precondition(
                notices.contains(expected),
                "Summary notices must stay visible, dismissible, and grouped: \(expected)"
            )
        }
        // Most important first: a failed attempt, then a stale transcript,
        // then unverified evidence, then availability.
        let order = [
            "kinds.append(.failure)",
            "kinds.append(.stale)",
            "kinds.append(.unverifiedEvidence)",
            "kinds.append(.featureDisabled)"
        ].map { marker -> String.Index in
            guard let range = notices.range(of: marker) else {
                preconditionFailure("Missing summary notice: \(marker)")
            }
            return range.lowerBound
        }
        precondition(order == order.sorted(), "Summary notices must keep their priority order")
        precondition(
            notices.contains("case .stale:\n            return appState.meetingSummarySourceFingerprint(for: item)"),
            "Dismissing the stale notice must last only until the transcript changes again"
        )
        // #619: the note view is rebuilt per note, so dismissals live in
        // AppState, not in the view.
        precondition(
            notices.contains("appState.dismissSummaryNotice(")
                && notices.contains("appState.isSummaryNoticeDismissed(")
                && !noteBrowser.contains("dismissedSummaryNoticeKeys")
                && !noteBrowser.contains("dismissedSummaryAttemptAt"),
            "Summary notice dismissals must outlast switching notes"
        )
        precondition(
            block(in: noteBrowser, from: "private func deleteSummary() {", to: "private func copyContent()")
                .contains("appState.forgetSummaryNoticeDismissals(noteID: item.id)"),
            "Deleting a summary must forget its notices' dismissals"
        )
    }

    private static func block(
        in source: String,
        from startMarker: String,
        to endMarker: String
    ) -> String {
        guard let start = source.range(of: startMarker),
              let end = source.range(
                  of: endMarker,
                  range: start.upperBound..<source.endIndex
              ) else {
            preconditionFailure(
                "Expected source block from \(startMarker) to \(endMarker)"
            )
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private static func source(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }
}
