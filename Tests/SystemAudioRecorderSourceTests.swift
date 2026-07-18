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
        precondition(source.contains("func cancelRecording(completion: (() -> Void)?)"))
        precondition(source.contains("cancelRecording(completion: nil)"))
        precondition(source.contains("finishRecording(discard: true) { _ in"))
        precondition(source.contains("completion?()"))
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
        precondition(source.contains("private let normalizedPCM16SinkLock ="))
        precondition(source.contains("OSAllocatedUnfairLock<(any NormalizedPCM16Sink)?>(initialState: nil)"))
        precondition(source.contains("var normalizedPCM16Sink: (any NormalizedPCM16Sink)?"))
        precondition(source.contains("private func writeCanonicalRecordingBuffer("))
        precondition(source.contains("try RecordingPCMBufferCopy.data("))
        precondition(source.contains("let firstFrameMonotonicNanoseconds = RecordingMonotonicClock.nowNanoseconds()"))
        precondition(source.contains("firstFrameMonotonicNanoseconds: UInt64"))
        precondition(source.contains("firstFrameMonotonicNanoseconds: firstFrameMonotonicNanoseconds"))
        precondition(source.contains("sink.enqueue(\n            copiedPCM16LE,\n            firstFrameMonotonicNanoseconds: firstFrameMonotonicNanoseconds\n        )"))
        precondition(source.contains("private struct CallbackState"))
        precondition(source.contains("private func resetSampleBufferState(outputURL: URL?, recordingStartTime: CFAbsoluteTime = 0) -> URL?"))
        precondition(source.contains("let staleOutputURL = self.resetSampleBufferState(outputURL: outputURL, recordingStartTime: t0)"))
        precondition(source.contains("let finishedRecording = self.finishAudioFileLocked(discard: discard)"))
        let appendBody = try functionBody(named: "appendSampleBufferToFile", in: source)
        precondition(
            countOccurrences(
                of: "try writeCanonicalRecordingBuffer(",
                in: appendBody
            ) == 2
        )
        let canonicalWriteBody = try functionBody(
            named: "writeCanonicalRecordingBuffer",
            in: source
        )
        precondition(canonicalWriteBody.contains("try activeAudioFile.write(from: buffer)"))
        precondition(canonicalWriteBody.contains("recordedFrameCount +="))
        precondition(canonicalWriteBody.contains("normalizedPCM16SinkLock.withLock"))
        precondition(!canonicalWriteBody.contains("checkpoint"))
        precondition(!canonicalWriteBody.contains("fsync"))
        precondition(!canonicalWriteBody.contains("manifest"))
        let realtimeBody = try functionBody(named: "emitPCM16IfNeeded", in: source)
        precondition(realtimeBody.contains("pcm16TargetFormat"))
        precondition(realtimeBody.contains("handler(data)"))

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

    private static func functionBody(named name: String, in text: String) throws -> String {
        let signatures = ["private func \(name)", "func \(name)"]
        guard let signatureRange = signatures.compactMap({ text.range(of: $0) }).first,
              let openBrace = text[signatureRange.upperBound...].firstIndex(of: "{") else {
            throw TestFailure("missing function \(name)")
        }

        var depth = 0
        var index = openBrace
        while index < text.endIndex {
            switch text[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(text[text.index(after: openBrace)..<index])
                }
            default:
                break
            }
            index = text.index(after: index)
        }
        throw TestFailure("unterminated function \(name)")
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
