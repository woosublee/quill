import AVFoundation
import Foundation

@main
struct AudioMixdownServiceTests {
    static func main() {
        do {
            try averagesOverlappingSamplesAndPreservesLongerTail()
            try boostsQuietSystemAudioBeforeMixing()
            try preservesSystemAudioWhenMicrophoneIsSilent()
            try doesNotClipLoudSystemAudio()
            try outputFormatIs16kHzMonoInt16AndFrameCountIsMaxInputFrameCount()
            print("AudioMixdownServiceTests passed")
        } catch {
            fputs("AudioMixdownServiceTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func averagesOverlappingSamplesAndPreservesLongerTail() throws {
        let microphoneURL = try writeTinyWAV(samples: [1000, 1000, 1000, 1000])
        let systemAudioURL = try writeTinyWAV(samples: [3000, 3000])
        defer { try? FileManager.default.removeItem(at: microphoneURL) }
        defer { try? FileManager.default.removeItem(at: systemAudioURL) }

        let outputURL = try AudioMixdownService().mix(microphoneURL: microphoneURL, systemAudioURL: systemAudioURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let samples = try readSamples(from: outputURL)
        try expectEqual(samples, [2000, 2000, 1000, 1000], "mixed samples should average overlap and preserve tail")
    }

    private static func boostsQuietSystemAudioBeforeMixing() throws {
        let microphoneURL = try writeTinyWAV(samples: [1000, 1000])
        let systemAudioURL = try writeTinyWAV(samples: [100, 100])
        defer { try? FileManager.default.removeItem(at: microphoneURL) }
        defer { try? FileManager.default.removeItem(at: systemAudioURL) }

        let outputURL = try AudioMixdownService().mix(microphoneURL: microphoneURL, systemAudioURL: systemAudioURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let samples = try readSamples(from: outputURL)
        try expectEqual(samples, [600, 600], "quiet system audio should be boosted conservatively before averaging with microphone")
    }

    private static func preservesSystemAudioWhenMicrophoneIsSilent() throws {
        let microphoneURL = try writeTinyWAV(samples: [0, 0])
        let systemAudioURL = try writeTinyWAV(samples: [100, 100])
        defer { try? FileManager.default.removeItem(at: microphoneURL) }
        defer { try? FileManager.default.removeItem(at: systemAudioURL) }

        let outputURL = try AudioMixdownService().mix(microphoneURL: microphoneURL, systemAudioURL: systemAudioURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let samples = try readSamples(from: outputURL)
        try expectEqual(samples, [100, 100], "system audio should not be halved by silent microphone samples")
    }

    private static func doesNotClipLoudSystemAudio() throws {
        let microphoneURL = try writeTinyWAV(samples: [0, 0])
        let systemAudioURL = try writeTinyWAV(samples: [20_000, -20_000])
        defer { try? FileManager.default.removeItem(at: microphoneURL) }
        defer { try? FileManager.default.removeItem(at: systemAudioURL) }

        let outputURL = try AudioMixdownService().mix(microphoneURL: microphoneURL, systemAudioURL: systemAudioURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let samples = try readSamples(from: outputURL)
        guard !samples.contains(Int16.max), !samples.contains(Int16.min) else {
            throw TestFailure("system audio gain should not hard-clip loud samples, got \(samples)")
        }
    }

    private static func outputFormatIs16kHzMonoInt16AndFrameCountIsMaxInputFrameCount() throws {
        let microphoneURL = try writeTinyWAV(samples: [100, 200])
        let systemAudioURL = try writeTinyWAV(samples: [400, 600, 800, 1000, 1200])
        defer { try? FileManager.default.removeItem(at: microphoneURL) }
        defer { try? FileManager.default.removeItem(at: systemAudioURL) }

        let outputURL = try AudioMixdownService().mix(microphoneURL: microphoneURL, systemAudioURL: systemAudioURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        guard outputURL.pathExtension == "wav" else {
            throw TestFailure("expected .wav output, got \(outputURL.lastPathComponent)")
        }
        guard outputURL.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL else {
            throw TestFailure("expected output in temporaryDirectory, got \(outputURL.path)")
        }

        let file = try AVAudioFile(forReading: outputURL)
        let format = file.fileFormat
        try expectEqual(format.sampleRate, 16_000, "sample rate")
        try expectEqual(format.channelCount, 1, "channel count")
        guard format.commonFormat == .pcmFormatInt16 else {
            throw TestFailure("expected pcmFormatInt16, got \(format.commonFormat)")
        }
        guard format.isInterleaved else {
            throw TestFailure("expected interleaved output")
        }
        try expectEqual(file.length, 5, "output frame count should be max input frame count")

        let samples = try readSamples(from: outputURL)
        try expectEqual(samples, [250, 400, 800, 1000, 1200], "mixed samples should silence-pad shorter input")
    }

    private static func writeTinyWAV(samples: [Int16]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        var data = Data()
        let sampleDataByteCount = UInt32(samples.count * MemoryLayout<Int16>.size)

        data.appendASCII("RIFF")
        data.appendUInt32LE(36 + sampleDataByteCount)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendUInt32LE(16)
        data.appendUInt16LE(1)
        data.appendUInt16LE(1)
        data.appendUInt32LE(16_000)
        data.appendUInt32LE(16_000 * 2)
        data.appendUInt16LE(2)
        data.appendUInt16LE(16)
        data.appendASCII("data")
        data.appendUInt32LE(sampleDataByteCount)
        for sample in samples {
            data.appendUInt16LE(UInt16(bitPattern: sample))
        }

        try data.write(to: url, options: .atomic)
        return url
    }

    private static func readSamples(from url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)!
        try file.read(into: buffer, frameCount: frameCount)

        guard let channelData = buffer.floatChannelData?[0] else {
            throw TestFailure("missing readable audio buffer data")
        }
        return (0..<Int(buffer.frameLength)).map { Int16((channelData[$0] * 32768).rounded()) }
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
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

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0x00ff))
        append(UInt8((value & 0xff00) >> 8))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0x000000ff))
        append(UInt8((value & 0x0000ff00) >> 8))
        append(UInt8((value & 0x00ff0000) >> 16))
        append(UInt8((value & 0xff000000) >> 24))
    }
}
