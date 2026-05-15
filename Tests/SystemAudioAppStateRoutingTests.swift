import Foundation

@main
struct SystemAudioAppStateRoutingTests {
    static func main() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)

        precondition(source.contains("let systemAudioRecorder = SystemAudioRecorder()"))
        precondition(source.contains("private var activeAudioInputID: String?"))
        precondition(source.contains("ensureRecordingInputAccess(for: audioInputID)"))
        precondition(source.contains("AudioInputDevice.isSystemAudio(inputID)"))
        precondition(source.contains("ensureSystemAudioAccess()"))
        precondition(source.contains("startSelectedAudioRecorder(inputID: audioInputID)"))
        precondition(source.contains("stopActiveAudioRecorder"))
        precondition(source.contains("cancelActiveAudioRecorder()"))
        precondition(source.contains("cleanupActiveAudioRecordersIfIdle()"))
        precondition(source.contains("setActiveRecorderPCMHandler"))
        precondition(source.contains("activeRecorderAudioLevelPublisher"))
        precondition(source.contains("systemAudioRecorder.stopRecording"))
        precondition(source.contains("systemAudioRecorder.cancelRecording"))
        precondition(source.contains("systemAudioRecorder.cleanup"))
        precondition(source.contains("!AudioInputDevice.isSystemAudio(audioInputID)"))

        print("SystemAudioAppStateRoutingTests passed")
    }
}
