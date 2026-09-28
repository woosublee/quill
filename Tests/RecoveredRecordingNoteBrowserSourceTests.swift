import Foundation

@main
struct RecoveredRecordingNoteBrowserSourceTests {
    static func main() throws {
        let source = try String(
            contentsOfFile: "Sources/NoteBrowserView.swift",
            encoding: .utf8
        )
        let appStateSource = try String(
            contentsOfFile: "Sources/AppState.swift",
            encoding: .utf8
        )

        precondition(source.contains("private var isRecoveredRecording: Bool"))
        precondition(source.contains("private var recoveredRecordingContext: RecoveredRecordingContext"))
        precondition(source.contains("item.recoveredRecordingContext"))
        precondition(source.contains("private var recoveryTitle: String"))
        precondition(source.contains("private var recoveryPresentation: QuillUserIssuePresentation"))
        precondition(source.contains("localizedCatalogString(recoveredRecordingContext.titleLocalizationKey)"))
        precondition(source.contains("body: recoveredRecordingContext.localizedResult()"))
        precondition(source.contains("suggestion: recoveredRecordingContext.localizedCause() ?? \"\""))
        // A recovered recording uses the same centered empty state as a
        // failed note, with the recovery icon and a Transcribe action.
        precondition(source.contains("presentation: recoveryPresentation"))
        precondition(source.contains("actionTitleOverride: \"Transcribe\""))
        precondition(source.contains("systemImageOverride: \"arrow.clockwise\""))
        // A failed note has no header indicator; its empty state explains.
        precondition(!source.contains(".help(\"Transcription failed\")"))
        precondition(source.contains("NoteAudioPlayerView(audioURL: storedAudioURL)"))
        precondition(source.contains("appState.retryTranscription(item: item)"))
        precondition(source.contains("case .needsModelSelection, .needsProviderConfiguration:"))
        precondition(source.contains("appState.openProviderSettings()"))
        precondition(appStateSource.contains("func openProviderSettings()"))
        precondition(appStateSource.contains("selectedSettingsTab = .models"))
        precondition(appStateSource.contains("NotificationCenter.default.post(name: .showSettings, object: nil)"))
        precondition(source.contains("appState.deleteHistoryEntry(id: id)"))
        precondition(source.contains("Image(systemName: \"arrow.clockwise.circle\")"))
        precondition(source.contains(".foregroundStyle(.orange.opacity(QuillContrast.opacity(0.7, increased: increasesContrast)))"))
        precondition(source.contains("if isRecoveredRecording {"))
        precondition(source.contains("} else if isError {"))
        precondition(source.contains("appState.cloudTranscriptionProgressByHistoryID[item.id]"))
        precondition(source.contains("cloudProgress: appState.cloudTranscriptionProgressByHistoryID[item.id]"))
        // Cloud chunk progress, "Transcribing…", and "Post-processing…" share
        // one stage label in the note detail.
        precondition(source.contains("Text(verbatim: processingStatusText)"))
        precondition(source.contains("? cloudProgressText"))
        precondition(source.contains("appState.postProcessingNoteIDs.contains(item.id)"))
        precondition(source.contains("actionState.showsRetryButton"))
        precondition(source.contains("NoteFileExportView("))
        precondition(source.contains("Image(systemName: \"square.and.arrow.down\")"))
        precondition(source.contains("Image(systemName: \"ellipsis\")"))
        try testRetryWithoutReadyModelUsesToast(source)
        testEmptyHistoryShowsOneEmptyState(source)
        testNoteBrowserHeaderLayout(source)
        try testAudioOnlyNoteUsesDedicatedNormalState()
        try testInputPickerSwitchesActiveRecordingInput(source)
        try testInputMenuCatcherDisablesAndLocalizesSources(source)
        try testNoteDetailAccessibility(source)
        testNoteListKeyboardAndVoiceOver(source)
        testNoteBrowserRespectsDisplayPreferences(source)
        testMenuPillsAreKeyboardAndVoiceOverAccessible(source)
        try testRecoveryImportPreservesSelectedListPosition(source)

        print("RecoveredRecordingNoteBrowserSourceTests passed")
    }

    private static func testNoteBrowserHeaderLayout(_ source: String) {
        let titleRow = block(
            source,
            from: "private var sidebarTitleRow: some View {",
            to: "private var sidebarHeader: some View {"
        )
        // First row shares the title bar: count, search, import, Select/Done.
        precondition(!titleRow.contains("selectedCountText"))
        precondition(!source.contains("noteCountText"))
        precondition(titleRow.contains("headerIconButton(\"magnifyingglass\""))
        precondition(titleRow.contains(".keyboardShortcut(\"f\", modifiers: .command)"))
        precondition(titleRow.contains("headerIconButton(\"waveform.badge.plus\", help: \"Import Audio File\")"))
        precondition(titleRow.contains("Button(\"Done\") { selection.endSelectionMode() }"))
        precondition(titleRow.contains("Button(\"Select\") { beginSelection() }"))
        precondition(titleRow.contains(".disabled(selection.showsSelectionUI)"))
        precondition(titleRow.contains(".background(WindowDragArea())"))
        precondition(!source.contains("Text(verbatim: \"Recordings\")"))

        let header = block(
            source,
            from: "private var sidebarHeader: some View {",
            to: "/// True once the first note has scrolled under the header."
        )
        // Fixed-width source and model controls, Select All under Done, and a
        // header that is always translucent so fast scrolls never show through.
        precondition(header.contains("inputPickerMenu\n                    transcriptionModelMenu"))
        precondition(header.contains("if isSearchOpen && !selection.showsSelectionUI {\n                    searchField"))
        precondition(header.contains("} else if selection.showsSelectionUI {\n                    Text(verbatim: selectedCountText)"))
        precondition(header.contains("Button(\"Select All\")"))
        precondition(header.contains("Text(verbatim: selectedCountText)"))
        precondition(header.contains(".background(QuillTransparency.background(.ultraThinMaterial, reduceTransparency: reduceTransparency))"))
        precondition(source.contains(".frame(width: 66, height: 26)"))
        precondition(source.contains("if appState.selectedAudioSource == .microphoneAndSystemAudio {"))
        precondition(source.contains(".ignoresSafeArea(.container, edges: .top)"))

        let search = block(
            source,
            from: "private var searchField: some View {",
            to: "private func selectionMark(for id: UUID)"
        )
        precondition(search.contains(".onExitCommand { closeSearch() }"))
        precondition(search.contains("if !isFocused && searchText.isEmpty"))

        let panel = block(
            source,
            from: "private var sidebarPanel: some View {",
            to: "private var noteList: some View {"
        )
        precondition(panel.contains("if !selection.showsSelectionUI {\n                floatingRecordButton"))
        precondition(source.contains(".padding(.bottom, selection.showsSelectionUI ? 6 : 72)"))
    }

    private static func testEmptyHistoryShowsOneEmptyState(_ source: String) {
        let listEmpty = block(
            source,
            from: "private var emptyListState: some View {",
            to: "// MARK: - Detail"
        )
        // The sidebar shows one quiet line; the detail pane has the icon and hint.
        precondition(listEmpty.contains("Text(\"No recordings yet\")"))
        precondition(!listEmpty.contains("Image(systemName:"))
        precondition(!listEmpty.contains("No Recordings"))
        let detailEmpty = block(
            source,
            from: "private var emptyDetailNoRecordings: some View {",
            to: "// MARK: - Horizontally Scrollable Title Field"
        )
        precondition(detailEmpty.contains("Image(systemName: \"mic\")"))
        precondition(detailEmpty.contains("Start your first recording with the Record button or your shortcut."))
    }

    private static func testRetryWithoutReadyModelUsesToast(
        _ source: String
    ) throws {
        let retryAction = block(
            source,
            from: "private func retryTranscription()",
            to: "private func showToast("
        )
        // An unready or unusable selected model opens the transcription
        // picker; only "no model at all" falls back to a toast.
        let pickerBranch = block(
            retryAction,
            from: "case .needsModelSelection, .needsProviderConfiguration:",
            to: "case .needsModelSetup:"
        )
        precondition(pickerBranch.contains("appState.noteBrowserRetryOptions(for: item)"))
        precondition(pickerBranch.contains("retryChoiceRequest = RetryChoiceRequest(options: options)"))
        precondition(!pickerBranch.contains("appState.openProviderSettings()"))
        let setupBranch = block(
            retryAction,
            from: "case .needsModelSetup:",
            to: "case .noAudio:"
        )
        precondition(setupBranch.contains("showToast("))
        precondition(setupBranch.contains("Set up a model in Settings to retry transcription."))

        // Retrying covers the body with a loading layer instead of replacing it.
        precondition(source.contains("if isRetrying {\n                            retryingOverlay"))
        precondition(source.contains(".fill(Color(nsColor: .textBackgroundColor).opacity(0.35))"))

        // The layer says "Post-processing…" while a retry cleans up its transcript.
        precondition(source.contains("appState.postProcessingNoteIDs.contains(item.id)"))
        precondition(source.contains("Text(retryingStatusText)"))
        precondition(source.contains("isAudioOnly ? \"Transcribing...\" : \"Retranscribing...\""))

        // Retry state is published once per update, so the layer does not blink.
        let appStateSource = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let applyState = block(
            appStateSource,
            from: "private func applyTranscriptionRetryWorkflowState(",
            to: "private func applyHistoryWorkflowEvent("
        )
        precondition(!applyState.contains("retryingItemIDs.subtract("))
        precondition(!applyState.contains("retryingItemIDs.formUnion("))
        precondition(applyState.contains("retryingItemIDs = retryingIDs"))
        precondition(applyState.contains("cloudTranscriptionProgressByHistoryID = progressByHistoryID"))
        precondition(appStateSource.contains("self?.postProcessingNoteIDs.insert(retryNoteID)"))
        precondition(appStateSource.contains("self?.postProcessingNoteIDs.remove(retryNoteID)"))

        // The Settings run log offers the same picker when retry needs a model.
        let settingsSource = try String(contentsOfFile: "Sources/SettingsView.swift", encoding: .utf8)
        precondition(settingsSource.contains("retryChoiceRequest = RetryChoiceRequest(options: options)"))
        precondition(settingsSource.contains("appState.retryTranscription(item: item, choice: choice)"))
    }

    private static func testInputPickerSwitchesActiveRecordingInput(
        _ source: String
    ) throws {
        let inputPickerMenu = block(
            source,
            from: "private var inputPickerMenu: some View {",
            to: "private var sidebarPanel: some View {"
        )
        precondition(inputPickerMenu.contains("InputMenuCatcher(configuration:"))
        precondition(inputPickerMenu.contains("AudioRecordingSource.allCases.map"))
        precondition(inputPickerMenu.contains("onSelectSource: appState.selectAudioSource(withID:)"))
        precondition(inputPickerMenu.contains("onSelectMicrophone: appState.selectMicrophoneDevice"))
        precondition(inputPickerMenu.contains("selectedSourceID: appState.selectedAudioSourceID"))
        precondition(inputPickerMenu.contains("selectedMicrophoneID: appState.selectedMicrophoneDeviceID"))
        precondition(inputPickerMenu.contains("microphoneSelectionEnabled: !appState.isRecording"))
        precondition(inputPickerMenu.contains("filter { !appState.isAudioSourceSelectable($0) }"))
    }

    /// Note detail controls are real controls for Tab and VoiceOver, and
    /// informational ones are read in words (#390).
    private static func testNoteDetailAccessibility(_ source: String) throws {
        let metaTag = block(
            source,
            from: "private func metaTag(_ label: String, active: Bool, help tooltip: LocalizedStringKey) -> some View {",
            to: "// MARK: Content"
        )
        precondition(!metaTag.contains("Button("), "Metadata tags are plain text, not no-op buttons")
        precondition(metaTag.contains(".help(tooltip)"))
        precondition(!source.contains("Button(action: {})"), "No no-op buttons in the Note Browser")
        precondition(source.contains(".accessibilityLabel(Text(verbatim: statusBadgesSpokenText))"))
        precondition(source.contains("\"Transcription language: %@\""))
        precondition(source.contains(".accessibilityLabel(Text(\"Recording recovered after an unexpected shutdown\"))"))
        precondition(source.contains("textView.setAccessibilityLabel(localizedCatalogString(\"Note Title\"))"))
        precondition(source.contains("textView.setAccessibilityPlaceholderValue(placeholder)"))
        // Tab leaves the one-line title instead of typing a tab.
        precondition(source.contains("override func insertTab(_ sender: Any?) {\n        window?.selectNextKeyView(sender)"))
        precondition(source.contains("override func insertBacktab(_ sender: Any?) {\n        window?.selectPreviousKeyView(sender)"))
        precondition(source.contains("textView.setAccessibilityLabel(localizedCatalogString(\"Transcript\"))"))
        precondition(source.contains(".announcement: localizedCatalogString(\"Copied\")"))

        let player = block(
            source,
            from: "struct NoteAudioPlayerView: View {",
            to: "private func seek(toFraction fraction: Double) {"
        )
        for expected in [
            ".accessibilityLabel(Text(isPlaying ? \"Pause\" : \"Play\"))",
            ".accessibilityLabel(Text(\"Playback position\"))",
            ".accessibilityAdjustableAction { direction in",
            ".onMoveCommand { direction in",
            ".accessibilityLabel(Text(\"Volume\"))",
            "private func seek(by seconds: TimeInterval) {"
        ] {
            precondition(player.contains(expected), "Missing audio player accessibility: \(expected)")
        }

        let summary = try String(contentsOfFile: "Sources/MeetingSummaryView.swift", encoding: .utf8)
        precondition(summary.contains(".accessibilityAddTraits(.isHeader)"), "Summary sections are headings")
    }

    /// The note list is reachable with Tab, ↑/↓ move the open note, the
    /// open row turns accent-colored while the list has focus, and each row
    /// reads as one element with its state in words (#389).
    private static func testNoteListKeyboardAndVoiceOver(_ source: String) {
        let headerButton = block(
            source,
            from: "private func headerIconButton(",
            to: "/// The first row shares the title bar"
        )
        precondition(!headerButton.contains(".focusable(false)"), "Search and Import are keyboard reachable")
        precondition(headerButton.contains(".accessibilityLabel(Text(help))"))
        for expected in [
            "@FocusState private var isNoteListFocused: Bool",
            ".focused($isNoteListFocused)",
            ".onMoveCommand { direction in\n                        moveListFocus(direction, proxy: proxy)",
            "isKeyboardHighlighted: isNoteListFocused",
            ".accessibilityAction(named: Text(\"Select\"))",
            ".accessibilityAction(named: Text(\"Delete…\"))",
            "? Color.accentColor.opacity(0.85)",
            "NoteListRowAccessibility.label(",
            ".accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)",
            // The moved-to row stays visible between the header and Record button.
            "proxy.scrollTo(nextID, anchor: .center)",
            // A dot matching the accent color stays visible on the focused row.
            ".strokeBorder(Color.white.opacity(0.9), lineWidth: 1)"
        ] {
            precondition(source.contains(expected), "Missing note list accessibility: \(expected)")
        }
    }

    private static func testInputMenuCatcherDisablesAndLocalizesSources(
        _ source: String
    ) throws {
        let catcher = block(
            source,
            from: "private struct InputMenuCatcher: NSViewRepresentable {",
            to: "@objc private func pickSource("
        )
        // NSMenu defaults to auto-enabling every item with a valid target/action,
        // which would mask our disabled source; turn that off so isEnabled sticks.
        precondition(catcher.contains("menu.autoenablesItems = false"))
        precondition(catcher.contains("private var configuration: AudioInputMenuConfiguration?"))
        precondition(catcher.contains("item.isEnabled = !configuration.disabledSourceIDs.contains(option.id)"))
        precondition(catcher.contains("item.isEnabled = configuration.microphoneSelectionEnabled"))
        // Quill-authored labels must be localized; real device names stay verbatim.
        precondition(catcher.contains("option.isStaticQuillName"))
        precondition(catcher.contains("localizedCatalogString(option.name)"))
        precondition(catcher.contains(": option.name"))
        precondition(catcher.contains("final class CatcherView: MenuButtonCatcherView {"))
        precondition(catcher.contains("menuAccessibilityValue = configuration.accessibilityValue"))
    }

    /// The source and model pills open their menus from the keyboard and
    /// VoiceOver too, not only on a click.
    private static func testMenuPillsAreKeyboardAndVoiceOverAccessible(
        _ source: String
    ) {
        let base = block(
            source,
            from: "class MenuButtonCatcherView: NSView {",
            to: "/// Transparent click target over the whole model pill"
        )
        for expected in [
            "override var acceptsFirstResponder: Bool { isMenuEnabled }",
            "isMenuEnabled && NSApp.isFullKeyboardAccessEnabled",
            "case 49, 36, 76, 125: // Space, Return, Enter, Down Arrow",
            "override func drawFocusRingMask()",
            "override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }",
            "override func accessibilityLabel() -> String? { menuAccessibilityLabel }",
            "override func accessibilityValue() -> Any? { menuAccessibilityValue }",
            "override func accessibilityPerformPress() -> Bool {"
        ] {
            precondition(base.contains(expected), "Missing menu pill accessibility: \(expected)")
        }
        precondition(source.contains("accessibilityLabel: localizedCatalogString(\"Audio Source\")"))
        precondition(source.contains("accessibilityLabel: localizedCatalogString(\"Transcription Method\")"))
        precondition(source.contains("accessibilityValue: transcriptionSelectionDetailLabel"))
        precondition(source.contains("accessibilityValue: audioInputSummary"))
    }

    private static func testAudioOnlyNoteUsesDedicatedNormalState() throws {
        let source = try String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)
        precondition(source.contains("item.machineStatus == .audioOnly"))
        precondition(
            source.components(separatedBy: "localizedCatalogString(\"Audio only\")").count >= 3
        )
        precondition(!source.contains("Text(\"Audio only\")"))
        precondition(source.contains("Text(\"Audio recording\")"))
        precondition(source.contains("help: \"Audio-only recording\""))
        precondition(source.contains("Saved without transcription. You can transcribe it later."))
        precondition(source.contains("Transcribe audio"))
        precondition(source.contains(".fill(Color.blue.opacity(0.08))"))
        precondition(source.contains(".foregroundStyle(.blue.opacity(0.75))"))

        let row = block(
            source,
            from: "private struct NoteListRow: View",
            to: "// MARK: - Note Detail View"
        )
        let header = block(
            row,
            from: "HStack(spacing: 4) {",
            to: "Text(displayData.displayTitle)"
        )
        precondition(header.contains("if displayData.status == .audioOnly"))
        precondition(header.contains("localizedCatalogString(\"Audio only\")"))
        let audioOnlyStatus = block(
            row,
            from: "case .audioOnly:",
            to: "case .recovered:"
        )
        precondition(audioOnlyStatus.contains(".fill(Color.green)"))
        precondition(!audioOnlyStatus.contains(".fill(Color.blue)"))
    }

    private static func testRecoveryImportPreservesSelectedListPosition(
        _ source: String
    ) throws {
        let selectionUpdate = block(
            source,
            from: ".onReceive(appState.$pipelineHistory) { newHistory in",
            to: "private var historyUnavailableView: some View"
        )
        try expect(
            selectionUpdate.contains("let isRecoveryImport = appState.isHistoryRecoveryOperationInProgress")
                && selectionUpdate.contains("if isRecoveryImport {")
                && selectionUpdate.contains("scheduleRecoveryScrollRestore(for: current)"),
            "Recovery imports schedule the existing selection as the list restore anchor"
        )

        let restore = block(
            source,
            from: "private func restoreRecoveryScrollPosition(",
            to: "private var transcriptionSelectionLabel: String"
        )
        try expect(
            restore.contains("filteredHistory.contains(where: { $0.id == request.itemID })")
                && restore.contains("DispatchQueue.main.async")
                && restore.contains("proxy.scrollTo(request.itemID, anchor: .center)"),
            "scroll restoration keeps an active search filter unchanged and scrolls asynchronously"
        )

        let reader = block(
            source,
            from: "ScrollViewReader { proxy in",
            to: "private var searchField: some View {"
        )
        try expect(
            reader.contains(".id(item.id)")
                && reader.contains(".onChange(of: recoveryScrollRestoreRequest?.id)")
                && reader.contains("restoreRecoveryScrollPosition(")
                && reader.contains("request: recoveryScrollRestoreRequest"),
            "ScrollViewReader observes the scheduled recovery request and restores the matching row"
        )
    }

    /// #395: Reduce Motion, Increase Contrast, Differentiate Without Color,
    /// and Reduce Transparency each change the Note Browser only when on.
    private static func testNoteBrowserRespectsDisplayPreferences(_ source: String) {
        // The spinner restarts from 0 when it reappears after Reduce Motion
        // is turned off, so it can't stay frozen at 360.
        precondition(source.contains("rotation = 0\n                withAnimation(.linear(duration: 0.75).repeatForever(autoreverses: false))"))

        // Reduce Motion: the list spinner and the REC dot stop looping.
        let spinner = block(source, from: "private struct YellowSpinner: View {", to: "// MARK: - Live Recording Badge")
        precondition(spinner.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"))
        precondition(spinner.contains("if reduceMotion {"))
        precondition(spinner.contains("Image(systemName: \"hourglass\")"))
        precondition(spinner.contains(".repeatForever(autoreverses: false)"))
        let badge = block(source, from: "private struct LiveRecordingBadge: View {", to: "private struct RecordingElapsedTitle")
        precondition(badge.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"))
        precondition(badge.contains("if reduceMotion {"))
        precondition(badge.contains(".repeatForever(autoreverses: true)"))

        // Increase Contrast: row date, badges, and detail metadata strengthen.
        let row = block(source, from: "private struct NoteListRow: View {", to: "private struct SidebarCapsuleButtonStyle")
        precondition(row.contains("@Environment(\\.colorSchemeContrast) private var colorSchemeContrast"))
        precondition(row.contains(": Color.secondary.opacity(metaOpacity(0.7))"))
        precondition(row.contains("QuillContrast.fillOpacity(0.08, increased: increasesContrast)"))
        let detail = block(source, from: "private struct NoteDetailView: View {", to: "private struct SummaryIssueViewAction")
        precondition(detail.contains("@Environment(\\.colorSchemeContrast) private var colorSchemeContrast"))
        precondition(detail.contains("QuillContrast.hierarchicalStyle(.tertiary, increased: increasesContrast)"))
        precondition(detail.contains("QuillContrast.hierarchicalStyle(.quaternary, increased: increasesContrast)"))
        precondition(detail.contains("QuillContrast.opacity(active ? 0.7 : 0.5, increased: increasesContrast)"))
        precondition(!detail.contains(".foregroundStyle(.quaternary)"))

        // Differentiate Without Color: failed gets a symbol only when on; the
        // default red dot stays.
        precondition(row.contains("@Environment(\\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor"))
        precondition(row.contains(
            "case .fail:\n            if differentiateWithoutColor {\n"
                + "                // Differentiate Without Color"
        ))
        precondition(row.contains("Image(systemName: \"exclamationmark.triangle.fill\")"))
        precondition(row.contains(
            "            } else {\n                Circle()\n                    .fill(Color.red)\n                    .frame(width: 6, height: 6)"
        ))

        // Reduce Transparency: sidebar, header, and floating toolbars are opaque.
        let materialSwaps = source.components(
            separatedBy: "QuillTransparency.background(.ultraThinMaterial, reduceTransparency: reduceTransparency)"
        ).count - 1
        precondition(materialSwaps == 3, "Header, sidebar, and multi-select delete button")
        precondition(!source.contains(".background(.ultraThinMaterial)"))
        precondition(detail.contains(
            "if reduceTransparency {\n                Capsule().fill(QuillTransparency.opaqueBackgroundColor)"
        ))
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw NoteBrowserSourceTestFailure(message) }
    }

    private static func block(
        _ source: String,
        from startMarker: String,
        to endMarker: String
    ) -> String {
        guard let start = source.range(of: startMarker),
              let end = source.range(
                of: endMarker,
                range: start.upperBound..<source.endIndex
              ) else {
            preconditionFailure("Expected source block from \(startMarker) to \(endMarker)")
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }
}

private struct NoteBrowserSourceTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
