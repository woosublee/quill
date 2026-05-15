import Foundation

@main
struct SystemAudioAppStateRoutingTests {
    static func main() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let setupSource = try String(contentsOfFile: "Sources/SetupView.swift", encoding: .utf8)

        precondition(source.contains("let systemAudioRecorder = SystemAudioRecorder()"))
        precondition(source.contains("private var activeAudioInputID: String?"))
        precondition(source.contains("ensureRecordingInputAccess(for: audioInputID)"))
        precondition(source.contains("AudioInputDevice.isSystemAudio(inputID)"))
        precondition(source.contains("ensureSystemAudioAccess()"))
        precondition(source.contains("requestScreenCapturePermissionForRecordingStart()"))
        precondition(source.contains("CGRequestScreenCaptureAccess()"))
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

        precondition(setupSource.contains("@State private var testSystemAudioRecorder: SystemAudioRecorder? = nil"))
        precondition(setupSource.contains("case idle, starting, recording"))
        precondition(setupSource.contains("Picker(\"Input:\""))
        precondition(setupSource.contains("AudioInputDevice.isSystemAudio(appState.selectedMicrophoneID)"))
        precondition(setupSource.contains("let recorder = SystemAudioRecorder()"))
        precondition(setupSource.contains("try await recorder.startRecording()"))
        precondition(setupSource.contains("testSystemAudioRecorder = recorder"))
        precondition(setupSource.contains("testSystemAudioRecorder?.stopRecording"))
        precondition(setupSource.contains("testPhase == .starting"))
        precondition(setupSource.contains("guard testPhase == .starting else { return }"))
        precondition(setupSource.contains("testSystemAudioRecorder?.cancelRecording()"))

        print("SystemAudioAppStateRoutingTests passed")
    }
}
