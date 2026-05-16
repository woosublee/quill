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
        precondition(!source.contains("if !readyFired && rms > 0"))
        precondition(source.contains("if !readyFired {\n            readyFired = true"))
        precondition(!source.contains("if discard, let outputURL"))
        precondition(source.contains("fileURLToDelete = finalizedURL"))
        precondition(source.contains("if let fileURLToDelete = finishedRecording.fileURLToDelete"))
        precondition(source.contains("var shouldDiscardRecording = false"))
        precondition(source.contains("shouldDiscardRecording = true"))
        precondition(source.contains("finishRecording(discard: shouldDiscardRecording, completion: completion)"))
        precondition(source.contains("private let callbacksLock = OSAllocatedUnfairLock(initialState: CallbackState())"))
        precondition(source.contains("private struct CallbackState"))
        precondition(source.contains("private func resetSampleBufferState(outputURL: URL?, recordingStartTime: CFAbsoluteTime = 0) -> URL?"))
        precondition(source.contains("let staleOutputURL = self.resetSampleBufferState(outputURL: outputURL, recordingStartTime: t0)"))
        precondition(source.contains("let finishedRecording = self.finishAudioFileLocked(discard: discard)"))

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

    private static func countOccurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}
