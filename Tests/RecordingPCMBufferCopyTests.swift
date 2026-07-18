import AVFoundation
import Foundation

@main
struct RecordingPCMBufferCopyTests {
    static func main() {
        do {
            try copiesCanonicalPCM16Bytes()
            try rejectsUnsupportedFormats()
            print("RecordingPCMBufferCopyTests passed")
        } catch {
            fputs("RecordingPCMBufferCopyTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func copiesCanonicalPCM16Bytes() throws {
        let format = try requireFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4) else {
            throw TestFailure("canonical buffer allocation failed")
        }
        buffer.frameLength = 4

        let samples: [Int16] = [0x1234, -2, 0x7FFF, Int16.min]
        let audioBuffer = buffer.mutableAudioBufferList.pointee.mBuffers
        guard let data = audioBuffer.mData else {
            throw TestFailure("canonical buffer has no writable storage")
        }
        samples.withUnsafeBytes { source in
            data.copyMemory(from: source.baseAddress!, byteCount: source.count)
        }

        let copied = try RecordingPCMBufferCopy.data(from: buffer)
        let expected = samples.withUnsafeBytes { Data($0) }
        try expectEqual(copied, expected, "canonical PCM bytes")

        data.assumingMemoryBound(to: Int16.self)[0] = 0
        try expectEqual(copied, expected, "returned data must own its bytes")
    }

    private static func rejectsUnsupportedFormats() throws {
        let cases: [(AVAudioCommonFormat, Double, AVAudioChannelCount, Bool)] = [
            (.pcmFormatFloat32, 16_000, 1, true),
            (.pcmFormatInt16, 24_000, 1, true),
            (.pcmFormatInt16, 16_000, 2, true),
            (.pcmFormatInt16, 16_000, 1, false),
        ]

        for (commonFormat, sampleRate, channels, interleaved) in cases {
            let format = try requireFormat(
                commonFormat: commonFormat,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: interleaved
            )
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else {
                throw TestFailure("unsupported buffer allocation failed")
            }
            buffer.frameLength = 1

            do {
                _ = try RecordingPCMBufferCopy.data(from: buffer)
                throw TestFailure("unsupported format should be rejected: \(format.settings)")
            } catch RecordingPCMBufferCopyError.unsupportedFormat {
                // expected
            }
        }
    }

    private static func requireFormat(
        commonFormat: AVAudioCommonFormat,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        interleaved: Bool
    ) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: interleaved
        ) else {
            throw TestFailure("format allocation failed")
        }
        return format
    }

    private static func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ label: String
    ) throws {
        guard actual == expected else {
            throw TestFailure("\(label): expected \(expected), got \(actual)")
        }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
