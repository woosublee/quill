import Foundation

@main
struct SystemAudioAppStateRoutingTests {
    static func main() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let setupSource = try String(contentsOfFile: "Sources/SetupView.swift", encoding: .utf8)

        precondition(source.contains("let systemAudioRecorder = SystemAudioRecorder()"))
        precondition(source.contains("lazy var meetingAudioRecorder = MeetingAudioRecorder("))
        precondition(source.contains("meetingAudioRecorder.cleanup()"))
        precondition(source.contains("meetingAudioRecorder.onRecordingReady = nil"))
        precondition(source.contains("meetingAudioRecorder.onRecordingFailure = nil"))
        precondition(source.contains("AudioInputDevice.isMeetingAudio(inputID)"))
        precondition(source.contains("return meetingAudioRecorder.$audioLevel.eraseToAnyPublisher()"))
        precondition(source.contains("meetingAudioRecorder.startRecording()"))
        precondition(source.contains("meetingAudioRecorder.stopRecording(completion: completion)"))
        precondition(source.contains("meetingAudioRecorder.cancelRecording()"))
        precondition(source.contains("AudioInputDevice.isMicrophoneOnly(audioInputID)"))
        precondition(source.contains("private func ensureMeetingAudioAccess() async -> Bool"))
        precondition(source.contains("let supportsLiveTranscription = !AudioInputDevice.isMeetingAudio(audioInputID)"))
        precondition(source.contains("if supportsLiveTranscription {\n            startRealtimeStreamingIfEnabled()\n        }"))
        precondition(source.contains("private var activeAudioInputID: String?"))
        precondition(source.contains("ensureRecordingInputAccess(for: audioInputID)"))
        precondition(source.contains("AudioInputDevice.isSystemAudio(inputID)"))
        precondition(source.contains("ensureSystemAudioAccess()"))
        precondition(source.contains("requestScreenCapturePermissionForRecordingStart()"))
        precondition(source.contains("CGRequestScreenCaptureAccess()"))
        precondition(source.contains("func requestScreenCapturePermissionForRecordingStart() async -> Bool"))
        precondition(source.contains("await Task.detached(priority: .userInitiated) {\n            CGRequestScreenCaptureAccess()\n        }.value"))
        precondition(source.contains("guard await ensureRecordingInputAccess(for: audioInputID) else { return }"))
        precondition(source.contains("private func ensureRecordingInputAccess(for inputID: String) async -> Bool"))
        precondition(source.contains("let granted = await requestScreenCapturePermissionForRecordingStart()"))
        precondition(source.contains("startSelectedAudioRecorder(inputID: audioInputID)"))
        precondition(source.contains("stopActiveAudioRecorder"))
        precondition(source.contains("cancelActiveAudioRecorder()"))
        precondition(source.contains("cleanupActiveAudioRecordersIfIdle()"))
        precondition(source.contains("setActiveRecorderPCMHandler"))
        precondition(source.contains("activeRecorderAudioLevelPublisher"))
        precondition(source.contains("systemAudioRecorder.stopRecording"))
        precondition(source.contains("systemAudioRecorder.cancelRecording"))
        precondition(source.contains("systemAudioRecorder.cleanup"))
        precondition(source.contains("AudioInputDevice.isMicrophoneOnly(audioInputID)"))

        let meetingAudioAccessBody = try functionBody(named: "ensureMeetingAudioAccess", in: source)
        let microphoneUndeterminedBranch = """
        if microphoneStatus == .notDetermined {
            let systemGranted = hasScreenCapturePermission()
            hasScreenRecordingPermission = systemGranted
            if systemGranted {
                return true
            }
            _ = ensureMicrophoneAccess()
            return false
        }
"""
        precondition(
            meetingAudioAccessBody.contains(microphoneUndeterminedBranch),
            "Meeting Audio access must proceed when Screen & System Audio is already granted while still prompting for microphone access when neither source is available"
        )

        precondition(setupSource.contains("@State private var testSystemAudioRecorder: SystemAudioRecorder? = nil"))
        precondition(setupSource.contains("@State private var testMeetingAudioRecorder: MeetingAudioRecorder? = nil"))
        precondition(setupSource.contains("case idle, starting, recording"))
        precondition(setupSource.contains("Picker(\"Input:\""))
        precondition(setupSource.contains("AudioInputDevice.isMeetingAudio(appState.selectedMicrophoneID)"))
        precondition(setupSource.contains("startMeetingAudioTestRecording()"))
        precondition(setupSource.contains("AudioInputDevice.isSystemAudio(appState.selectedMicrophoneID)"))
        precondition(setupSource.contains("let microphoneRecorder = AudioRecorder()"))
        precondition(setupSource.contains("let systemAudioRecorder = SystemAudioRecorder()"))
        precondition(setupSource.contains("let recorder = SystemAudioRecorder()"))
        precondition(setupSource.contains("let recorder = MeetingAudioRecorder("))
        precondition(setupSource.contains("try await recorder.startRecording()"))
        precondition(setupSource.contains("testSystemAudioRecorder = recorder"))
        precondition(setupSource.contains("testSystemAudioRecorder?.stopRecording"))
        precondition(setupSource.contains("testMeetingAudioRecorder?.stopRecording"))
        precondition(setupSource.contains("testPhase == .starting"))
        precondition(setupSource.contains("guard testPhase == .starting else { return }"))
        precondition(setupSource.contains("testSystemAudioRecorder?.cancelRecording()"))
        precondition(setupSource.contains("testMeetingAudioRecorder?.cancelRecording()"))
        precondition(setupSource.contains("testMeetingAudioRecorder = nil"))
        precondition(setupSource.contains("private func clearTestRecordingState()"))
        precondition(setupSource.contains("testAudioLevelCancellable?.cancel()\n        testAudioLevelCancellable = nil\n        testAudioLevel = 0.0\n        testHotkeyHarness.isTranscribing = false"))
        precondition(countOccurrences(of: "clearTestRecordingState()", in: setupSource) >= 2)

        print("SystemAudioAppStateRoutingTests passed")
    }

    private static func countOccurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private static func functionBody(named name: String, in text: String) throws -> String {
        let signature = "private func \(name)"
        guard let signatureRange = text.range(of: signature),
              let openBrace = text[signatureRange.upperBound...].firstIndex(of: "{") else {
            throw testFailure("Missing function \(name)")
        }

        var depth = 0
        var index = openBrace
        while index < text.endIndex {
            let character = text[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let bodyStart = text.index(after: openBrace)
                    return String(text[bodyStart..<index])
                }
            }
            index = text.index(after: index)
        }

        throw testFailure("Missing closing brace for function \(name)")
    }

    private static func testFailure(_ message: String) -> NSError {
        NSError(domain: "SystemAudioAppStateRoutingTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
