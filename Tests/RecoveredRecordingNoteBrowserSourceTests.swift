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
        precondition(source.contains("private var recoveryDescription: String"))
        precondition(source.contains("localizedCatalogString(recoveredRecordingContext.titleLocalizationKey)"))
        precondition(source.contains("recoveredRecordingContext.localizedDescription()"))
        precondition(source.contains("Text(recoveryTitle)"))
        precondition(source.contains("Text(recoveryDescription)"))
        precondition(source.contains("NoteAudioPlayerView(audioURL: storedAudioURL)"))
        precondition(source.contains("appState.retryTranscription(item: item)"))
        precondition(source.contains("case .needsModelSelection, .needsProviderConfiguration:"))
        precondition(source.contains("appState.openProviderSettings()"))
        precondition(appStateSource.contains("func openProviderSettings()"))
        precondition(appStateSource.contains("selectedSettingsTab = .models"))
        precondition(appStateSource.contains("NotificationCenter.default.post(name: .showSettings, object: nil)"))
        precondition(source.contains("appState.deleteHistoryEntry(id: id)"))
        precondition(source.contains("Image(systemName: \"arrow.clockwise.circle\")"))
        precondition(source.contains(".foregroundStyle(.orange.opacity(0.7))"))
        precondition(source.contains("if isRecoveredRecording {"))
        precondition(source.contains("} else if isError {"))
        precondition(source.contains("appState.cloudTranscriptionProgressByHistoryID[item.id]"))
        precondition(source.contains("cloudProgress: appState.cloudTranscriptionProgressByHistoryID[item.id]"))
        precondition(source.contains("if isCloudTranscribing {"))
        precondition(source.contains("Text(cloudProgressText)"))
        precondition(source.contains("actionState.showsRetryButton"))
        precondition(source.contains("NoteFileExportView("))
        precondition(source.contains("Image(systemName: \"square.and.arrow.down\")"))
        precondition(source.contains("Image(systemName: \"ellipsis\")"))
        try testRetryWithoutReadyModelUsesToast(source)
        try testAudioOnlyNoteUsesDedicatedNormalState()
        try testInputPickerSwitchesActiveRecordingInput(source)
        try testInputMenuCatcherDisablesAndLocalizesSources(source)
        try testRecoveryImportPreservesSelectedListPosition(source)

        print("RecoveredRecordingNoteBrowserSourceTests passed")
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

    private static func testInputMenuCatcherDisablesAndLocalizesSources(
        _ source: String
    ) throws {
        let catcher = block(
            source,
            from: "final class CatcherView: NSView {",
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
            to: "private func transcriptionChoiceMenuItem"
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
            to: ".frame(width: 280)"
        )
        try expect(
            reader.contains(".id(item.id)")
                && reader.contains(".onChange(of: recoveryScrollRestoreRequest?.id)")
                && reader.contains("restoreRecoveryScrollPosition(")
                && reader.contains("request: recoveryScrollRestoreRequest"),
            "ScrollViewReader observes the scheduled recovery request and restores the matching row"
        )
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
