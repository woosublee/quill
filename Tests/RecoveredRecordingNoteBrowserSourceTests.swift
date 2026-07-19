import Foundation

@main
struct RecoveredRecordingNoteBrowserSourceTests {
    static func main() throws {
        let source = try String(
            contentsOfFile: "Sources/NoteBrowserView.swift",
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
        precondition(source.contains("NoteAudioPlayerView(audioURL: audioURL)"))
        precondition(source.contains("appState.retryTranscription(item: item)"))
        precondition(source.contains("appState.deleteHistoryEntry(id: id)"))
        precondition(source.contains("Image(systemName: \"arrow.clockwise.circle\")"))
        precondition(source.contains(".foregroundStyle(.orange.opacity(0.7))"))
        precondition(source.contains("if isRecoveredRecording {"))
        precondition(source.contains("} else if isError {"))

        print("RecoveredRecordingNoteBrowserSourceTests passed")
    }
}
