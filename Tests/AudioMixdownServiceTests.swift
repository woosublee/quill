import AVFoundation
import Foundation

@main
struct AudioMixdownServiceTests {
    static func main() {
        do {
            try sumsOverlappingSamplesWithHeadroomAndPreservesLongerTail()
            try boostsQuietSystemAudioBeforeMixing()
            try preservesSystemAudioWhenMicrophoneIsSilent()
            try doesNotClipLoudSystemAudio()
            try outputFormatIs16kHzMonoInt16AndFrameCountIsMaxInputFrameCount()
            try streamsAcrossFixedChunkBoundaries()
            try mixesLongSyntheticWAVWithConstantMemoryContract()
            try rejectsEmptyFile()
            try rejectsTruncatedPayload()
            try rejectsOddBytePCM16Payload()
            try mixPathAvoidsDurationSizedMaterialization()
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

    private static func sumsOverlappingSamplesWithHeadroomAndPreservesLongerTail() throws {
        let microphoneURL = try writeTinyWAV(samples: [1000, 1000, 1000, 1000])
        let systemAudioURL = try writeTinyWAV(samples: [3000, 3000])
        defer { try? FileManager.default.removeItem(at: microphoneURL) }
        defer { try? FileManager.default.removeItem(at: systemAudioURL) }

        let outputURL = try AudioMixdownService().mix(microphoneURL: microphoneURL, systemAudioURL: systemAudioURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        // systemGain stays at 1 (system already louder than the microphone), and
        // each source is attenuated by the 0.8 headroom: overlap is
        // 1000*0.8 + 3000*0.8 = 3200; the microphone-only tail is 1000*0.8 = 800.
        let samples = try readSamples(from: outputURL)
        try expectEqual(samples, [3200, 3200, 800, 800], "mixed samples should sum overlap with headroom and preserve tail")
    }

    private static func boostsQuietSystemAudioBeforeMixing() throws {
        let microphoneURL = try writeTinyWAV(samples: [1000, 1000])
        let systemAudioURL = try writeTinyWAV(samples: [100, 100])
        defer { try? FileManager.default.removeItem(at: microphoneURL) }
        defer { try? FileManager.default.removeItem(at: systemAudioURL) }

        let outputURL = try AudioMixdownService().mix(microphoneURL: microphoneURL, systemAudioURL: systemAudioURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        // systemGain is capped at 2 (100 -> 200), then both sources take the 0.8
        // headroom: 1000*0.8 + 100*2*0.8 = 800 + 160 = 960.
        let samples = try readSamples(from: outputURL)
        try expectEqual(samples, [960, 960], "quiet system audio should be boosted conservatively before summing with microphone")
    }

    private static func preservesSystemAudioWhenMicrophoneIsSilent() throws {
        let microphoneURL = try writeTinyWAV(samples: [0, 0])
        let systemAudioURL = try writeTinyWAV(samples: [100, 100])
        defer { try? FileManager.default.removeItem(at: microphoneURL) }
        defer { try? FileManager.default.removeItem(at: systemAudioURL) }

        let outputURL = try AudioMixdownService().mix(microphoneURL: microphoneURL, systemAudioURL: systemAudioURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        // A silent microphone contributes nothing; system audio passes through at
        // the 0.8 headroom (100*0.8 = 80) with no activity-gated halving.
        let samples = try readSamples(from: outputURL)
        try expectEqual(samples, [80, 80], "system audio should not be halved by silent microphone samples")
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

        // systemGain stays at 1; every sample takes the 0.8 headroom. Overlap:
        // 100*0.8 + 400*0.8 = 400 and 200*0.8 + 600*0.8 = 640. The system-only
        // tail is 800*0.8, 1000*0.8, 1200*0.8.
        let samples = try readSamples(from: outputURL)
        try expectEqual(samples, [400, 640, 640, 800, 960], "mixed samples should silence-pad shorter input")
    }

    private static func streamsAcrossFixedChunkBoundaries() throws {
        let chunkFrameCount = 4_096
        let microphoneURL = try writeTinyWAV(
            samples: Array(repeating: 1_000, count: chunkFrameCount + 1)
        )
        let systemAudioURL = try writeTinyWAV(
            samples: Array(repeating: 3_000, count: chunkFrameCount + 3)
        )
        defer { try? FileManager.default.removeItem(at: microphoneURL) }
        defer { try? FileManager.default.removeItem(at: systemAudioURL) }

        let outputURL = try AudioMixdownService().mix(
            microphoneURL: microphoneURL,
            systemAudioURL: systemAudioURL
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let samples = try readSamples(from: outputURL)
        try expectEqual(samples.count, chunkFrameCount + 3, "chunk-boundary output frame count")
        try expectEqual(samples[chunkFrameCount - 1], 3_200, "last sample before chunk boundary")
        try expectEqual(samples[chunkFrameCount], 3_200, "first sample after chunk boundary")
        try expectEqual(samples[chunkFrameCount + 1], 2_400, "first system-only tail sample")
        try expectEqual(samples[chunkFrameCount + 2], 2_400, "last system-only tail sample")
    }

    private static func mixesLongSyntheticWAVWithConstantMemoryContract() throws {
        let microphoneFrameCount = 1_000_003
        let systemAudioFrameCount = 1_000_017
        let microphoneURL = try writeRepeatedSampleWAV(
            sample: 1_000,
            frameCount: microphoneFrameCount
        )
        let systemAudioURL = try writeRepeatedSampleWAV(
            sample: 100,
            frameCount: systemAudioFrameCount
        )
        defer { try? FileManager.default.removeItem(at: microphoneURL) }
        defer { try? FileManager.default.removeItem(at: systemAudioURL) }

        let outputURL = try AudioMixdownService().mix(
            microphoneURL: microphoneURL,
            systemAudioURL: systemAudioURL
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let physicalByteCount = try requireFileSize(attributes[.size])
        try expectEqual(
            physicalByteCount,
            UInt64(44 + systemAudioFrameCount * MemoryLayout<Int16>.size),
            "long output physical byte count"
        )
        try expectEqual(
            try readCanonicalSample(from: outputURL, atFrame: 0),
            960,
            "long output first mixed sample"
        )
        try expectEqual(
            try readCanonicalSample(from: outputURL, atFrame: 4_096),
            960,
            "long output sample after first chunk boundary"
        )
        try expectEqual(
            try readCanonicalSample(from: outputURL, atFrame: microphoneFrameCount),
            160,
            "long output system-only tail sample"
        )
        try expectEqual(
            try readCanonicalSample(from: outputURL, atFrame: systemAudioFrameCount - 1),
            160,
            "long output final sample"
        )
    }

    private static func rejectsEmptyFile() throws {
        let emptyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let validURL = try writeTinyWAV(samples: [1])
        try Data().write(to: emptyURL)
        defer { try? FileManager.default.removeItem(at: emptyURL) }
        defer { try? FileManager.default.removeItem(at: validURL) }

        try expectInvalidWAV {
            _ = try AudioMixdownService().mix(
                microphoneURL: emptyURL,
                systemAudioURL: validURL
            )
        }
    }

    private static func rejectsTruncatedPayload() throws {
        let truncatedURL = try writeCanonicalWAVPayload(
            declaredDataByteCount: 4,
            payload: Data([0x01, 0x00])
        )
        let validURL = try writeTinyWAV(samples: [1])
        defer { try? FileManager.default.removeItem(at: truncatedURL) }
        defer { try? FileManager.default.removeItem(at: validURL) }

        try expectInvalidWAV {
            _ = try AudioMixdownService().mix(
                microphoneURL: truncatedURL,
                systemAudioURL: validURL
            )
        }
    }

    private static func rejectsOddBytePCM16Payload() throws {
        let oddPayloadURL = try writeCanonicalWAVPayload(
            declaredDataByteCount: 1,
            payload: Data([0x01])
        )
        let validURL = try writeTinyWAV(samples: [1])
        defer { try? FileManager.default.removeItem(at: oddPayloadURL) }
        defer { try? FileManager.default.removeItem(at: validURL) }

        try expectInvalidWAV {
            _ = try AudioMixdownService().mix(
                microphoneURL: oddPayloadURL,
                systemAudioURL: validURL
            )
        }
    }

    private static func mixPathAvoidsDurationSizedMaterialization() throws {
        let source = try String(contentsOf: audioMixdownServiceSourceURL, encoding: .utf8)
        let mixBody = try functionBody(
            startingWith: "public func mix(microphoneURL: URL, systemAudioURL: URL)",
            in: source
        )
        guard !mixBody.contains("readSamples(") else {
            throw TestFailure("mix should not decode an entire source into [Int16]")
        }
        guard !mixBody.contains("mixedSamples") else {
            throw TestFailure("mix should not build a duration-sized mixedSamples array")
        }
        guard !mixBody.contains("reserveCapacity(outputFrameCount)") else {
            throw TestFailure("mix should not reserve output memory proportional to recording duration")
        }
        guard !source.contains("private func readSamples(from url: URL) throws -> [Int16]") else {
            throw TestFailure("production mixdown should not retain a full-source [Int16] decoder")
        }
        guard countOccurrences(of: "Data(contentsOf:", in: source) == 1 else {
            throw TestFailure("only the unchanged concatenate path may use Data(contentsOf:)")
        }
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

    private static func functionBody(
        startingWith signature: String,
        in source: String
    ) throws -> String {
        guard let signatureRange = source.range(of: signature),
              let openingBrace = source[signatureRange.upperBound...].firstIndex(of: "{") else {
            throw TestFailure("missing function signature: \(signature)")
        }

        var depth = 0
        var index = openingBrace
        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[source.index(after: openingBrace)..<index])
                }
            default:
                break
            }
            index = source.index(after: index)
        }
        throw TestFailure("missing closing brace for: \(signature)")
    }

    private static func countOccurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private static func expectInvalidWAV(_ operation: () throws -> Void) throws {
        do {
            try operation()
            throw TestFailure("expected invalid WAV error")
        } catch AudioMixdownServiceError.invalidWAVFile {
            // expected
        }
    }

    private static func requireFileSize(_ value: Any?) throws -> UInt64 {
        guard let number = value as? NSNumber else {
            throw TestFailure("missing output file size")
        }
        return number.uint64Value
    }

    private static func readCanonicalSample(
        from url: URL,
        atFrame frame: Int
    ) throws -> Int16 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(44 + frame * MemoryLayout<Int16>.size))
        let bytes = try handle.read(upToCount: 2) ?? Data()
        guard bytes.count == 2 else {
            throw TestFailure("missing sample at frame \(frame)")
        }
        return Int16(bitPattern: UInt16(bytes[0]) | (UInt16(bytes[1]) << 8))
    }

    private static func writeRepeatedSampleWAV(
        sample: Int16,
        frameCount: Int
    ) throws -> URL {
        let dataByteCount = frameCount * MemoryLayout<Int16>.size
        guard dataByteCount <= Int(UInt32.max) else {
            throw TestFailure("test WAV is too large")
        }

        let url = try writeCanonicalWAVPayload(
            declaredDataByteCount: UInt32(dataByteCount),
            payload: Data()
        )
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()

        let chunkFrameCount = 4_096
        var chunk = Data()
        chunk.reserveCapacity(chunkFrameCount * MemoryLayout<Int16>.size)
        for _ in 0..<chunkFrameCount {
            chunk.appendUInt16LE(UInt16(bitPattern: sample))
        }

        var remainingFrames = frameCount
        while remainingFrames > 0 {
            let framesToWrite = min(chunkFrameCount, remainingFrames)
            try handle.write(
                contentsOf: chunk.prefix(framesToWrite * MemoryLayout<Int16>.size)
            )
            remainingFrames -= framesToWrite
        }
        return url
    }

    private static func writeCanonicalWAVPayload(
        declaredDataByteCount: UInt32,
        payload: Data
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        var data = Data()
        data.appendASCII("RIFF")
        data.appendUInt32LE(36 + declaredDataByteCount)
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
        data.appendUInt32LE(declaredDataByteCount)
        data.append(payload)
        try data.write(to: url, options: .atomic)
        return url
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
