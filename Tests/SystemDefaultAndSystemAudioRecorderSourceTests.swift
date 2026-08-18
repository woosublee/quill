import Foundation

@main
struct SystemDefaultAndSystemAudioRecorderSourceTests {
    static func main() throws {
        let source = try String(contentsOfFile: "Sources/SystemDefaultAndSystemAudioRecorder.swift", encoding: .utf8)

        precondition(source.contains("final class SystemDefaultAndSystemAudioRecorder: ObservableObject"))
        precondition(source.contains("@Published var audioLevel: Float"))
        precondition(source.contains("var onRecordingReady: (() -> Void)?"))
        precondition(source.contains("var onRecordingFailure: ((Error) -> Void)?"))
        precondition(source.contains("init(microphoneRecorder: AudioRecorder, systemAudioRecorder: SystemAudioRecorder, mixdownService: AudioMixdownService = AudioMixdownService())"))
        precondition(source.contains("struct CombinedRecordingStartResult: Equatable"))
        precondition(source.contains("let microphoneStarted: Bool"))
        precondition(source.contains("let systemAudioStarted: Bool"))
        precondition(source.contains("let microphoneUsedSystemDefaultFallback: Bool"))

        // A partial combined start (exactly one source) must be identifiable
        // as a single typed value so callers don't re-derive it from the two
        // booleans, and so the notice can name which source is missing.
        precondition(source.contains("enum DegradedCombinedCaptureSource: Equatable"))
        precondition(source.contains("case microphone"))
        precondition(source.contains("case systemAudio"))
        precondition(source.contains("var missingSource: DegradedCombinedCaptureSource?"))
        guard let missingSourceRange = source.range(of: "var missingSource: DegradedCombinedCaptureSource?") else {
            preconditionFailure("Could not locate missingSource computed property")
        }
        let missingSourceBody = source[missingSourceRange.lowerBound..<source.index(missingSourceRange.lowerBound, offsetBy: 260)]
        precondition(missingSourceBody.contains("!microphoneStarted"), "missingSource identifies a failed microphone")
        precondition(missingSourceBody.contains("!systemAudioStarted"), "missingSource identifies a failed System Audio source")

        // Manual QA hook: let a developer force one side of the combined
        // start to fail deterministically, without touching real hardware
        // permissions, to exercise the degraded-capture notice on demand.
        // Each flag is consumed (reset) by the attempt it triggers, so it
        // only affects the next recording, never a later one.
        precondition(source.contains("var debugForcesMicrophoneStartFailure = false"))
        precondition(source.contains("var debugForcesSystemAudioStartFailure = false"))
        precondition(source.contains("case debugSimulatedStartFailure"))
        precondition(source.contains("struct CombinedStoppedRecordingSources: Equatable"))
        precondition(source.contains("func startRecording(microphoneDeviceUID: String) async throws -> CombinedRecordingStartResult"))
        precondition(source.contains("func stopRecordingSources("))
        precondition(source.contains("completion: @escaping (CombinedStoppedRecordingSources) -> Void"))
        precondition(source.contains("func stopRecording(completion: @escaping (URL?) -> Void)"))
        precondition(source.contains("func cancelRecording()"))
        precondition(source.contains("func cancelRecording(completion: (() -> Void)?)"))
        precondition(source.contains("func cleanup()"))

        precondition(source.contains("let microphoneRecorder: AudioRecorder"))
        precondition(source.contains("let systemAudioRecorder: SystemAudioRecorder"))
        precondition(source.contains("let mixdownService: AudioMixdownService"))
        precondition(source.contains("let result = try microphoneRecorder.startRecording("))
        precondition(source.contains("deviceUID: microphoneDeviceUID"))
        precondition(source.contains("result.usedSystemDefaultFallback"))
        precondition(!source.contains("deviceUID: AudioInputDevice.defaultMicrophoneID"))
        precondition(source.contains("try await systemAudioRecorder.startRecording()"))
        precondition(source.contains("guard microphoneStarted || systemStarted else"))
        precondition(source.contains("return CombinedRecordingStartResult("))
        precondition(source.contains("fireRecordingReadyOnce()"))
        precondition(source.contains("handleSourceFailure"), "SystemDefaultAndSystemAudioRecorder should aggregate child recorder failures before reporting overall failure")
        precondition(!source.contains("self?.onRecordingFailure?(error)"), "Child recorder failures should not be forwarded directly as overall failures")
        precondition(source.contains("subscribeToAudioLevelsIfNeeded()"), "startRecording should be able to restore audio level subscriptions after cleanup")

        guard let startRecordingRange = source.range(of: "func startRecording(microphoneDeviceUID: String) async throws"),
              let stopRecordingRange = source.range(of: "func stopRecording(completion: @escaping (URL?) -> Void)", range: startRecordingRange.upperBound..<source.endIndex) else {
            preconditionFailure("Could not locate startRecording body")
        }
        let startRecordingSource = source[startRecordingRange.lowerBound..<stopRecordingRange.lowerBound]
        precondition(startRecordingSource.contains("configureChildCallbacks()"), "startRecording should configure child callbacks each time it starts")
        precondition(startRecordingSource.contains("subscribeToAudioLevelsIfNeeded()"), "startRecording should restore audio level subscriptions when needed")
        precondition(startRecordingSource.contains("if debugForcesMicrophoneStartFailure {"), "startRecording checks the microphone debug-failure hook")
        precondition(startRecordingSource.contains("if debugForcesSystemAudioStartFailure {"), "startRecording checks the System Audio debug-failure hook")
        precondition(startRecordingSource.contains("debugForcesMicrophoneStartFailure = false"), "the microphone debug hook resets itself after one use")
        precondition(startRecordingSource.contains("debugForcesSystemAudioStartFailure = false"), "the System Audio debug hook resets itself after one use")

        precondition(source.contains("Publishers.CombineLatest(microphoneRecorder.$audioLevel, systemAudioRecorder.$audioLevel)"))
        precondition(source.contains("max(microphoneLevel, systemAudioLevel)"))
        precondition(source.contains("microphoneRecorder.stopRecording"))
        precondition(source.contains("systemAudioRecorder.stopRecording"))
        precondition(source.contains("stopRecordingSources { sources in"))
        precondition(source.contains("group.notify(queue: .main)"), "source drain completion should return on the main queue")
        precondition(source.contains("completion(CombinedStoppedRecordingSources("))
        precondition(source.contains("DispatchQueue.global(qos: .userInitiated).async"), "mixdown should not run on the main queue")
        precondition(source.contains("let finalURL = self.finalRecordingURL("))
        precondition(source.contains("DispatchQueue.main.async {\n                completion(finalURL)\n            }"), "stop completion should return to the main queue")
        precondition(source.contains("try mixdownService.mix(microphoneURL: microphoneURL, systemAudioURL: systemAudioURL)"))
        precondition(source.contains("try? FileManager.default.removeItem(at: microphoneURL)"))
        precondition(source.contains("try? FileManager.default.removeItem(at: systemAudioURL)"))
        precondition(source.contains("microphoneRecorder.cancelRecording(completion:"))
        precondition(source.contains("systemAudioRecorder.cancelRecording(completion:"))
        precondition(source.contains("cancelRecording(completion: nil)"))
        precondition(source.contains("microphoneRecorder.onPCM16Samples = nil"))
        precondition(source.contains("systemAudioRecorder.onPCM16Samples = nil"))
        precondition(!source.contains("microphoneRecorder.cleanup()"))
        precondition(!source.contains("systemAudioRecorder.cleanup()"))

        let bannedSymbols = ["SCStream(", "AVCaptureSession(", "SCContentFilter(", "NSLock()"]
        for symbol in bannedSymbols {
            precondition(!source.contains(symbol), "SystemDefaultAndSystemAudioRecorder must not create a new capture path with \(symbol)")
        }

        print("SystemDefaultAndSystemAudioRecorderSourceTests passed")
    }
}
