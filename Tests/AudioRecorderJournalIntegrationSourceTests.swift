import Foundation

@main
struct AudioRecorderJournalIntegrationSourceTests {
    static func main() throws {
        let source = try String(
            contentsOfFile: "Sources/AudioRecorder.swift",
            encoding: .utf8
        )

        precondition(source.contains("private let normalizedPCM16SinkLock"))
        precondition(source.contains("var normalizedPCM16Sink: (any NormalizedPCM16Sink)?"))
        precondition(source.contains("private func writeCanonicalRecordingBuffer("))
        precondition(source.contains("try activeAudioFile.write(from: buffer)"))
        precondition(source.contains("let sink = normalizedPCM16SinkLock.withLock"))
        precondition(source.contains("let copiedPCM16LE = try RecordingPCMBufferCopy.data(from: buffer)"))
        precondition(source.contains("let firstFrameMonotonicNanoseconds = RecordingMonotonicClock.nowNanoseconds()"))
        precondition(source.contains("firstFrameMonotonicNanoseconds: UInt64"))
        precondition(source.contains("firstFrameMonotonicNanoseconds: firstFrameMonotonicNanoseconds"))
        precondition(source.contains("sink.enqueue(\n            copiedPCM16LE,\n            firstFrameMonotonicNanoseconds: firstFrameMonotonicNanoseconds\n        )"))

        let canonicalWriteBody = try functionBody(
            named: "writeCanonicalRecordingBuffer",
            in: source
        )
        precondition(!canonicalWriteBody.contains("checkpoint"))
        precondition(!canonicalWriteBody.contains("fsync"))
        precondition(!canonicalWriteBody.contains("manifest"))
        precondition(source.contains("func cancelRecording(completion: (() -> Void)?)"))
        precondition(source.contains("completion?()"))

        let canonicalWrites = source.components(
            separatedBy: "try writeCanonicalRecordingBuffer("
        ).count - 1
        precondition(
            canonicalWrites == 2,
            "source-equal and conversion branches must share the canonical write helper"
        )

        precondition(source.contains("var onPCM16Samples: ((Data) -> Void)?"))
        precondition(source.contains("private let pcm16TargetFormat: AVAudioFormat"))
        precondition(source.contains("sampleRate: 24_000"))
        precondition(source.contains("emitPCM16IfNeeded(from: sampleBuffer)"))

        print("AudioRecorderJournalIntegrationSourceTests passed")
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
