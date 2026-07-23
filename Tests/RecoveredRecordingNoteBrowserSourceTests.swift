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
        try testAudioOnlyNoteUsesDedicatedNormalState()

        print("RecoveredRecordingNoteBrowserSourceTests passed")
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
    }
}
