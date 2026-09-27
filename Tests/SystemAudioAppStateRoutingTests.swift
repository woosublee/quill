import Foundation

@main
struct SystemAudioAppStateRoutingTests {
    static func main() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let setupSource = try String(contentsOfFile: "Sources/SetupView.swift", encoding: .utf8)
        let noteBrowserSource = try String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)

        precondition(AudioRecordingSource(inputID: "device-uid") == .microphone)
        precondition(AudioRecordingSource(inputID: AudioInputDevice.systemAudioID) == .systemAudio)
        precondition(
            AudioRecordingSource(
                inputID: AudioInputDevice.systemDefaultAndSystemAudioID
            ) == .microphoneAndSystemAudio
        )
        precondition(AudioRecordingSource.microphone.requiresMicrophonePermission)
        precondition(!AudioRecordingSource.microphone.requiresSystemAudioPermission)
        precondition(!AudioRecordingSource.systemAudio.requiresMicrophonePermission)
        precondition(AudioRecordingSource.systemAudio.requiresSystemAudioPermission)
        precondition(AudioRecordingSource.microphoneAndSystemAudio.requiresMicrophonePermission)
        precondition(AudioRecordingSource.microphoneAndSystemAudio.requiresSystemAudioPermission)
        precondition(!AudioRecordingSource.microphoneAndSystemAudio.supportsLiveTranscription)

        let physicalStartBody = try functionBody(named: "startPhysicalAudioRecorder", in: source)
        precondition(physicalStartBody.contains("AudioRecordingSource(inputID:"))
        precondition(physicalStartBody.contains("systemDefaultAndSystemAudioRecorder.startRecording"))
        precondition(physicalStartBody.contains("microphoneDeviceUID: selection.microphoneDeviceID"))
        precondition(physicalStartBody.contains("systemAudioRecorder.startRecording"))
        precondition(physicalStartBody.contains("audioRecorder.startRecording"))
        precondition(physicalStartBody.contains("applySystemDefaultMicrophoneFallback"))
        precondition(physicalStartBody.contains("degradedSource = result.missingSource"))
        precondition(!physicalStartBody.contains("systemDefaultAndSystemAudioRecorder.currentMissingSource"))

        let inputAccessBody = try functionBody(named: "ensureRecordingInputAccess", in: source)
        precondition(inputAccessBody.contains("switch AudioRecordingSource(inputID: selection.inputID)"))
        precondition(inputAccessBody.contains("case .microphone:"))
        precondition(inputAccessBody.contains("case .systemAudio:"))
        precondition(inputAccessBody.contains("case .microphoneAndSystemAudio:"))

        let beginRecordingBody = try functionBody(named: "beginRecording", in: source)
        precondition(beginRecordingBody.contains(".supportsLiveTranscription"))
        precondition(beginRecordingBody.contains("startRealtimeStreamingIfEnabled()"))
        precondition(beginRecordingBody.contains("startSelectedAudioRecorder("))
        precondition(beginRecordingBody.contains("sessionID: recordingSessionID"))

        let accessibleSelectionBody = try functionBody(
            named: "accessibleCurrentRecordingAudioSelection",
            in: source
        )
        precondition(accessibleSelectionBody.contains("let selection = currentRecordingAudioSelection()"))
        precondition(accessibleSelectionBody.contains("ensureRecordingInputAccess("))
        precondition(accessibleSelectionBody.contains("startRequestID: startRequestID"))
        precondition(accessibleSelectionBody.contains("selection == currentRecordingAudioSelection()"))

        precondition(noteBrowserSource.contains("sections: [\"Cloud\", \"On This Mac\"].map"))
        precondition(!noteBrowserSource.contains("transcriptionChoiceDisplays(in: \"Legacy mlx-whisper\")"))
        precondition(noteBrowserSource.contains(".disabled(!display.isAvailable)"))
        precondition(source.contains("private struct PendingRecordingPermissionContext"))
        precondition(source.contains("pendingMicrophonePermissionContext"))
        precondition(source.contains("pendingSpeechPermissionContext"))
        precondition(source.contains(
            "let resumeTask = Task { @MainActor [weak strongSelf] in"
        ))
        precondition(source.contains(
            "let resumeTask = Task { @MainActor [weak self] in"
        ))
        precondition(!source.contains("pendingMicrophonePermissionAudioSelection"))
        precondition(!source.contains("pendingSpeechPermissionAudioSelection"))

        let systemDefaultAndSystemAudioAccessBody = try functionBody(named: "ensureSystemDefaultAndSystemAudioAccess", in: source)
        let microphoneUndeterminedBranch = """
        if microphoneStatus == .notDetermined {
            _ = ensureMicrophoneAccess(
                startRequestID: startRequestID,
                onStarted: onStarted
            )
            return false
        }
"""
        precondition(
            systemDefaultAndSystemAudioAccessBody.contains(microphoneUndeterminedBranch),
            "System Default + System Audio should always request microphone access instead of treating Screen & System Audio alone as enough"
        )
        precondition(
            systemDefaultAndSystemAudioAccessBody.contains("guard microphoneGranted else"),
            "System Default + System Audio should require microphone permission before starting"
        )
        precondition(
            systemDefaultAndSystemAudioAccessBody.contains("guard systemGranted else"),
            "System Default + System Audio should require Screen & System Audio permission before starting"
        )
        precondition(
            !systemDefaultAndSystemAudioAccessBody.contains("microphoneGranted || systemGranted"),
            "System Default + System Audio should not start with only one permission granted"
        )
        precondition(
            source.contains("needs Microphone and Screen & System Audio Recording access"),
            "System Default + System Audio error text should describe both required permissions"
        )

        precondition(!setupSource.contains("testSystemAudioRecorder"))
        precondition(!setupSource.contains("testSystemDefaultAndSystemAudioRecorder"))
        precondition(!setupSource.contains("Picker(\"Input:\""))
        precondition(!setupSource.contains("startSystemDefaultAndSystemAudioTestRecording()"))
        precondition(!setupSource.contains("testTranscriptionStep"))

        print("SystemAudioAppStateRoutingTests passed")
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
