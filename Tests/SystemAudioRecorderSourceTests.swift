import Foundation

@main
struct SystemAudioRecorderSourceTests {
    static func main() throws {
        let source = try String(contentsOfFile: "Sources/SystemAudioRecorder.swift", encoding: .utf8)

        precondition(source.contains("final class SystemAudioRecorder"))
        precondition(source.contains("SCStreamOutput"))
        precondition(source.contains("SCStreamDelegate"))
        precondition(source.contains("configuration.capturesAudio = true"))
        precondition(source.contains("configuration.excludesCurrentProcessAudio = true"))
        precondition(source.contains("try stream.addStreamOutput(self, type: .audio"))
        precondition(source.contains("func startRecording() async throws"))
        precondition(source.contains("func stopRecording(completion: @escaping (URL?) -> Void)"))
        precondition(source.contains("func cancelRecording()"))
        precondition(source.contains("func cleanup()"))
        precondition(source.contains("var onPCM16Samples: ((Data) -> Void)?"))
        precondition(source.contains("onRecordingFailure?(error)"))

        let bannedSymbols = [
            "SCRecordingOutput",
            "captureMicrophone",
            "SCStreamOutputTypeMicrophone",
            "type: .microphone"
        ]
        for symbol in bannedSymbols {
            precondition(!source.contains(symbol), "SystemAudioRecorder must not use \(symbol) in the first implementation")
        }

        print("SystemAudioRecorderSourceTests passed")
    }
}
