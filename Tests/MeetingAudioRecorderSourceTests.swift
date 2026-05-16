import Foundation

@main
struct MeetingAudioRecorderSourceTests {
    static func main() throws {
        let source = try String(contentsOfFile: "Sources/MeetingAudioRecorder.swift", encoding: .utf8)

        precondition(source.contains("final class MeetingAudioRecorder: ObservableObject"))
        precondition(source.contains("@Published var audioLevel: Float"))
        precondition(source.contains("var onRecordingReady: (() -> Void)?"))
        precondition(source.contains("var onRecordingFailure: ((Error) -> Void)?"))
        precondition(source.contains("init(microphoneRecorder: AudioRecorder, systemAudioRecorder: SystemAudioRecorder, mixdownService: AudioMixdownService = AudioMixdownService())"))
        precondition(source.contains("func startRecording() async throws"))
        precondition(source.contains("func stopRecording(completion: @escaping (URL?) -> Void)"))
        precondition(source.contains("func cancelRecording()"))
        precondition(source.contains("func cleanup()"))

        precondition(source.contains("let microphoneRecorder: AudioRecorder"))
        precondition(source.contains("let systemAudioRecorder: SystemAudioRecorder"))
        precondition(source.contains("let mixdownService: AudioMixdownService"))
        precondition(source.contains("try microphoneRecorder.startRecording(deviceUID: AudioInputDevice.defaultMicrophoneID)"))
        precondition(source.contains("try await systemAudioRecorder.startRecording()"))
        precondition(source.contains("guard microphoneStarted || systemStarted else"))
        precondition(source.contains("fireRecordingReadyOnce()"))
        precondition(source.contains("handleSourceFailure"), "MeetingAudioRecorder should aggregate child recorder failures before reporting overall failure")
        precondition(!source.contains("self?.onRecordingFailure?(error)"), "Child recorder failures should not be forwarded directly as overall failures")
        precondition(source.contains("subscribeToAudioLevelsIfNeeded()"), "startRecording should be able to restore audio level subscriptions after cleanup")

        guard let startRecordingRange = source.range(of: "func startRecording() async throws"),
              let stopRecordingRange = source.range(of: "func stopRecording(completion: @escaping (URL?) -> Void)", range: startRecordingRange.upperBound..<source.endIndex) else {
            preconditionFailure("Could not locate startRecording body")
        }
        let startRecordingSource = source[startRecordingRange.lowerBound..<stopRecordingRange.lowerBound]
        precondition(startRecordingSource.contains("configureChildCallbacks()"), "startRecording should configure child callbacks each time it starts")
        precondition(startRecordingSource.contains("subscribeToAudioLevelsIfNeeded()"), "startRecording should restore audio level subscriptions when needed")

        precondition(source.contains("Publishers.CombineLatest(microphoneRecorder.$audioLevel, systemAudioRecorder.$audioLevel)"))
        precondition(source.contains("max(microphoneLevel, systemAudioLevel)"))
        precondition(source.contains("microphoneRecorder.stopRecording"))
        precondition(source.contains("systemAudioRecorder.stopRecording"))
        precondition(source.contains("try mixdownService.mix(microphoneURL: microphoneURL, systemAudioURL: systemAudioURL)"))
        precondition(source.contains("try? FileManager.default.removeItem(at: microphoneURL)"))
        precondition(source.contains("try? FileManager.default.removeItem(at: systemAudioURL)"))
        precondition(source.contains("microphoneRecorder.cancelRecording()"))
        precondition(source.contains("systemAudioRecorder.cancelRecording()"))
        precondition(!source.contains("microphoneRecorder.cleanup()"))
        precondition(!source.contains("systemAudioRecorder.cleanup()"))

        let bannedSymbols = ["SCStream(", "AVCaptureSession(", "SCContentFilter(", "NSLock()"]
        for symbol in bannedSymbols {
            precondition(!source.contains(symbol), "MeetingAudioRecorder must not create a new capture path with \(symbol)")
        }

        print("MeetingAudioRecorderSourceTests passed")
    }
}
