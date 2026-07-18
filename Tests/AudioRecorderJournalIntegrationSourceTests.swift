import Foundation

@main
struct AudioRecorderJournalIntegrationSourceTests {
    static func main() throws {
        let source = try String(
            contentsOfFile: "Sources/AudioRecorder.swift",
            encoding: .utf8
        )

        precondition(source.contains("var normalizedPCM16Sink: (any NormalizedPCM16Sink)?"))
        precondition(source.contains("private func writeCanonicalRecordingBuffer("))
        precondition(source.contains("try activeAudioFile.write(from: buffer)"))
        precondition(source.contains("let copiedPCM16LE = try RecordingPCMBufferCopy.data(from: buffer)"))
        precondition(source.contains("normalizedPCM16Sink?.enqueue(copiedPCM16LE)"))
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
}
