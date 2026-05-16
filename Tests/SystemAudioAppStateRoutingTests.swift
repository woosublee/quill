import Foundation

@main
struct SystemAudioAppStateRoutingTests {
    static func main() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let setupSource = try String(contentsOfFile: "Sources/SetupView.swift", encoding: .utf8)
        let noteBrowserSource = try String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)

        precondition(source.contains("let systemAudioRecorder = SystemAudioRecorder()"))
        precondition(source.contains("lazy var systemDefaultAndSystemAudioRecorder = SystemDefaultAndSystemAudioRecorder("))
        precondition(source.contains("systemDefaultAndSystemAudioRecorder.cleanup()"))
        precondition(source.contains("systemDefaultAndSystemAudioRecorder.onRecordingReady = nil"))
        precondition(source.contains("systemDefaultAndSystemAudioRecorder.onRecordingFailure = nil"))
        precondition(source.contains("AudioInputDevice.isSystemDefaultAndSystemAudio(inputID)"))
        precondition(source.contains("return systemDefaultAndSystemAudioRecorder.$audioLevel.eraseToAnyPublisher()"))
        precondition(source.contains("systemDefaultAndSystemAudioRecorder.startRecording()"))
        precondition(source.contains("systemDefaultAndSystemAudioRecorder.stopRecording(completion: completion)"))
        precondition(source.contains("systemDefaultAndSystemAudioRecorder.cancelRecording()"))
        precondition(source.contains("AudioInputDevice.isMicrophoneOnly(audioInputID)"))
        precondition(source.contains("private func ensureSystemDefaultAndSystemAudioAccess() async -> Bool"))
        precondition(source.contains("let supportsLiveTranscription = !AudioInputDevice.isSystemDefaultAndSystemAudio(audioInputID)"))
        precondition(source.contains("if supportsLiveTranscription {\n            startRealtimeStreamingIfEnabled()\n        }"))
        precondition(source.contains("func isNoteBrowserTranscriptionModeAvailable(_ mode: NoteBrowserTranscriptionMode) -> Bool"))
        precondition(source.contains("normalizeNoteBrowserTranscriptionModeForSelectedInput()"))
        precondition(noteBrowserSource.contains("Picker(\"Transcription Mode\", selection: transcriptionModeSelection)"))
        precondition(noteBrowserSource.contains(".tag(NoteBrowserTranscriptionMode.apiStandard)"))
        precondition(noteBrowserSource.contains(".tag(NoteBrowserTranscriptionMode.apiRealtime)"))
        precondition(noteBrowserSource.contains(".tag(NoteBrowserTranscriptionMode.localWhisper)"))
        precondition(noteBrowserSource.contains(".tag(NoteBrowserTranscriptionMode.localAppleLive)"))
        precondition(noteBrowserSource.contains(".disabled(!appState.isNoteBrowserTranscriptionModeAvailable(.apiRealtime))"))
        precondition(noteBrowserSource.contains(".disabled(!appState.isNoteBrowserTranscriptionModeAvailable(.localAppleLive))"))
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
        precondition(source.contains("let audioInputID = strongSelf.selectedMicrophoneID"))
        precondition(source.contains("guard await strongSelf.ensureRecordingInputAccess(for: audioInputID) else { return }"))
        precondition(source.contains("if AudioInputDevice.isMicrophoneOnly(audioInputID) {\n                                    strongSelf.applyAudioInterruptionIfNeeded()\n                                }"))
        precondition(source.contains("let audioInputID = self.selectedMicrophoneID"))
        precondition(source.contains("if AudioInputDevice.isMicrophoneOnly(audioInputID) {\n                                    self.applyAudioInterruptionIfNeeded()\n                                }"))

        let systemDefaultAndSystemAudioAccessBody = try functionBody(named: "ensureSystemDefaultAndSystemAudioAccess", in: source)
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
            systemDefaultAndSystemAudioAccessBody.contains(microphoneUndeterminedBranch),
            "System Default + System Audio access must proceed when Screen & System Audio is already granted while still prompting for microphone access when neither source is available"
        )

        precondition(setupSource.contains("@State private var testSystemAudioRecorder: SystemAudioRecorder? = nil"))
        precondition(setupSource.contains("@State private var testSystemDefaultAndSystemAudioRecorder: SystemDefaultAndSystemAudioRecorder? = nil"))
        precondition(setupSource.contains("case idle, starting, recording"))
        precondition(setupSource.contains("Picker(\"Input:\""))
        precondition(setupSource.contains("AudioInputDevice.isSystemDefaultAndSystemAudio(appState.selectedMicrophoneID)"))
        precondition(setupSource.contains("startSystemDefaultAndSystemAudioTestRecording()"))
        precondition(setupSource.contains("AudioInputDevice.isSystemAudio(appState.selectedMicrophoneID)"))
        precondition(setupSource.contains("let microphoneRecorder = AudioRecorder()"))
        precondition(setupSource.contains("let systemAudioRecorder = SystemAudioRecorder()"))
        precondition(setupSource.contains("let recorder = SystemAudioRecorder()"))
        precondition(setupSource.contains("let recorder = SystemDefaultAndSystemAudioRecorder("))
        precondition(setupSource.contains("try await recorder.startRecording()"))
        precondition(setupSource.contains("testSystemAudioRecorder = recorder"))
        precondition(setupSource.contains("testSystemAudioRecorder?.stopRecording"))
        precondition(setupSource.contains("testSystemDefaultAndSystemAudioRecorder?.stopRecording"))
        precondition(setupSource.contains("testPhase == .starting"))
        precondition(setupSource.contains("guard testPhase == .starting else { return }"))
        precondition(setupSource.contains("testSystemAudioRecorder?.cancelRecording()"))
        precondition(setupSource.contains("testSystemAudioRecorder?.cleanup()"))
        precondition(setupSource.contains("testSystemDefaultAndSystemAudioRecorder?.cancelRecording()"))
        precondition(setupSource.contains("testSystemDefaultAndSystemAudioRecorder = nil"))
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
