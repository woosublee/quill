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
            try activeRMSAvoidsIntermediateArrays()
            try concatenatesSegmentsInOrder()
            try concatenateWithSingleSegmentReturnsSameSamples()
            try concatenateOutputIs16kHzMonoInt16InTempDir()
            try concatenateThrowsOnEmptyInput()
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

    private static func concatenatesSegmentsInOrder() throws {
        let first = try writeTinyWAV(samples: [1, 2, 3])
        let second = try writeTinyWAV(samples: [4, 5])
        let third = try writeTinyWAV(samples: [6])
        defer { try? FileManager.default.removeItem(at: first) }
        defer { try? FileManager.default.removeItem(at: second) }
        defer { try? FileManager.default.removeItem(at: third) }

        let outputURL = try AudioMixdownService().concatenate([first, second, third])
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let samples = try readSamples(from: outputURL)
        try expectEqual(samples, [1, 2, 3, 4, 5, 6], "segments should be joined end to end in order")
    }

    private static func concatenateWithSingleSegmentReturnsSameSamples() throws {
        let only = try writeTinyWAV(samples: [7, 8, 9])
        defer { try? FileManager.default.removeItem(at: only) }

        let outputURL = try AudioMixdownService().concatenate([only])
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let samples = try readSamples(from: outputURL)
        try expectEqual(samples, [7, 8, 9], "single segment should be copied unchanged")
    }

    private static func concatenateOutputIs16kHzMonoInt16InTempDir() throws {
        let first = try writeTinyWAV(samples: [100, 200])
        let second = try writeTinyWAV(samples: [300, 400, 500])
        defer { try? FileManager.default.removeItem(at: first) }
        defer { try? FileManager.default.removeItem(at: second) }

        let outputURL = try AudioMixdownService().concatenate([first, second])
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
        try expectEqual(file.length, 5, "output frame count should be the sum of segment frame counts")
    }

    private static func concatenateThrowsOnEmptyInput() throws {
        do {
            _ = try AudioMixdownService().concatenate([])
            throw TestFailure("concatenate([]) should throw")
        } catch AudioMixdownServiceError.noSegmentsToConcatenate {
            // expected
        }
    }

    private static func activeRMSAvoidsIntermediateArrays() throws {
        let source = try String(contentsOf: audioMixdownServiceSourceURL, encoding: .utf8)
        guard !source.contains("samples.map { Float($0) }.filter") else {
            throw TestFailure("activeRMS should avoid building an intermediate activeSamples array")
        }
        guard source.contains("for sample in samples") else {
            throw TestFailure("activeRMS should scan samples directly")
        }
    }

    private static var audioMixdownServiceSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AudioMixdownService.swift")
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
        return (0..<Int(buffer.frameLength)).map {
            let scaled = Int((channelData[$0] * 32768).rounded())
            let clamped = min(Int(Int16.max), max(Int(Int16.min), scaled))
            return Int16(clamped)
        }
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
