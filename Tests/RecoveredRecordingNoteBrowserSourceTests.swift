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
        precondition(source.contains("case .needsProviderConfiguration:"))
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
        let providerBranch = block(
            retryAction,
            from: "case .needsProviderConfiguration:",
            to: "case .noAudio:"
        )
        precondition(providerBranch.contains("showToast("))
        precondition(
            providerBranch.contains(
                "No transcription method is available. Configure an API key or install a Local Whisper model, then try again."
            )
        )
        precondition(!providerBranch.contains("appState.openProviderSettings()"))
    }

    private static func testInputPickerSwitchesActiveRecordingInput(
        _ source: String
    ) throws {
        let inputPickerMenu = block(
            source,
            from: "private var inputPickerMenu: some View {",
            to: "private var sidebarPanel: some View {"
        )
        precondition(inputPickerMenu.contains("appState.switchActiveRecordingInput(to: newInputID)"))
        precondition(inputPickerMenu.contains("appState.selectedMicrophoneID = newInputID"))
        precondition(
            inputPickerMenu.contains(
                "disabledSourceIDs: appState.isAudioInputSelectable("
            )
        )
        precondition(!inputPickerMenu.contains("if !appState.isRecording {"))
    }

    private static func testInputMenuCatcherDisablesAndLocalizesSources(
        _ source: String
    ) throws {
        let catcher = block(
            source,
            from: "final class CatcherView: NSView {",
            to: "@objc private func pick("
        )
        // NSMenu defaults to auto-enabling every item with a valid target/action,
        // which would mask our disabled source; turn that off so isEnabled sticks.
        precondition(catcher.contains("menu.autoenablesItems = false"))
        precondition(catcher.contains("item.isEnabled = !disabledSourceIDs.contains(option.id)"))
        // Quill-authored source labels must be localized; real device names verbatim.
        precondition(
            catcher.contains("isStaticQuillName ? String(localized: String.LocalizationValue(option.name)) : option.name")
        )
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
