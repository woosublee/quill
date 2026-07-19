import AVFoundation
import Foundation

struct AudioMixdownSource: Equatable {
    let url: URL
    let frameOffset: UInt64
}

struct AudioMixdownSegment: Equatable {
    let microphone: AudioMixdownSource?
    let systemAudio: AudioMixdownSource?
}

struct AudioMixdownAssembly: Equatable {
    let dataByteCount: UInt64
    let frameCount: UInt64
}

public struct AudioMixdownService {
    /// Per-source headroom applied before summing the two streams. Summing two
    /// full-scale signals would overflow, so each is attenuated to leave room.
    /// Mixing the streams continuously (rather than gating sample-by-sample on
    /// activity) avoids the per-sample amplitude jumps that produced audible
    /// crackle when the microphone was recorded alongside system audio.
    private static let mixHeadroom: Float = 0.8
    private static let streamingFrameCount = 4_096

    public init() {}

    public func mix(microphoneURL: URL, systemAudioURL: URL) throws -> URL {
        try mix(
            microphoneURL: microphoneURL,
            microphoneFrameOffset: 0,
            systemAudioURL: systemAudioURL,
            systemAudioFrameOffset: 0
        )
    }

    public func mix(
        microphoneURL: URL,
        microphoneFrameOffset: UInt64,
        systemAudioURL: URL,
        systemAudioFrameOffset: UInt64
    ) throws -> URL {
        let outputURL = temporaryWAVURL()
        _ = try assemble(
            [AudioMixdownSegment(
                microphone: AudioMixdownSource(
                    url: microphoneURL,
                    frameOffset: microphoneFrameOffset
                ),
                systemAudio: AudioMixdownSource(
                    url: systemAudioURL,
                    frameOffset: systemAudioFrameOffset
                )
            )],
            outputURL: outputURL
        )
        return outputURL
    }

    public func materialize(
        sourceURL: URL,
        frameOffset: UInt64
    ) throws -> URL {
        let outputURL = temporaryWAVURL()
        _ = try assemble(
            [AudioMixdownSegment(
                microphone: AudioMixdownSource(
                    url: sourceURL,
                    frameOffset: frameOffset
                ),
                systemAudio: nil
            )],
            outputURL: outputURL
        )
        return outputURL
    }

    func assemble(
        _ segments: [AudioMixdownSegment],
        outputURL: URL
    ) throws -> AudioMixdownAssembly {
        guard !segments.isEmpty else {
            throw AudioMixdownServiceError.noSegmentsToConcatenate
        }

        var plans: [AudioMixdownRenderPlan] = []
        plans.reserveCapacity(segments.count)
        var totalFrameCount: UInt64 = 0
        for segment in segments {
            let plan: AudioMixdownRenderPlan
            switch (segment.microphone, segment.systemAudio) {
            case (nil, nil):
                throw AudioMixdownServiceError.emptySegment
            case (.some(let source), nil), (nil, .some(let source)):
                let scan = try scanSamples(at: source.url)
                plan = .source(url: source.url, frameCount: scan.frameCount)
            case (.some(let microphone), .some(let systemAudio)):
                let microphoneScan = try scanSamples(at: microphone.url)
                let systemAudioScan = try scanSamples(at: systemAudio.url)
                let earliestOffset = min(
                    microphone.frameOffset,
                    systemAudio.frameOffset
                )
                let microphoneOffset = microphone.frameOffset - earliestOffset
                let systemAudioOffset = systemAudio.frameOffset - earliestOffset
                let microphoneEndFrame = try alignedEndFrame(
                    offset: microphoneOffset,
                    frameCount: microphoneScan.frameCount
                )
                let systemAudioEndFrame = try alignedEndFrame(
                    offset: systemAudioOffset,
                    frameCount: systemAudioScan.frameCount
                )
                plan = .mix(
                    microphoneURL: microphone.url,
                    microphoneFrameOffset: microphoneOffset,
                    systemAudioURL: systemAudio.url,
                    systemAudioFrameOffset: systemAudioOffset,
                    frameCount: max(microphoneEndFrame, systemAudioEndFrame),
                    systemGain: systemAudioGain(
                        microphoneStatistics: microphoneScan.statistics,
                        systemAudioStatistics: systemAudioScan.statistics
                    )
                )
            }
            let (nextFrameCount, overflow) = totalFrameCount.addingReportingOverflow(
                plan.frameCount
            )
            guard !overflow else {
                throw AudioMixdownServiceError.outputTooLarge
            }
            totalFrameCount = nextFrameCount
            plans.append(plan)
        }
        let outputDataByteCount = try validatedOutputDataByteCount(
            frameCount: totalFrameCount
        )

        do {
            try wavHeader(dataByteCount: 0).write(to: outputURL, options: .atomic)
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            defer { try? outputHandle.close() }
            try outputHandle.seekToEnd()
            for plan in plans {
                switch plan {
                case .source(let url, _):
                    try writeStreamingSource(
                        sourceURL: url,
                        outputHandle: outputHandle
                    )
                case .mix(
                    let microphoneURL,
                    let microphoneFrameOffset,
                    let systemAudioURL,
                    let systemAudioFrameOffset,
                    let frameCount,
                    let systemGain
                ):
                    try writeStreamingMix(
                        microphoneURL: microphoneURL,
                        microphoneFrameOffset: microphoneFrameOffset,
                        systemAudioURL: systemAudioURL,
                        systemAudioFrameOffset: systemAudioFrameOffset,
                        outputHandle: outputHandle,
                        outputFrameCount: frameCount,
                        systemGain: systemGain
                    )
                }
            }
            try outputHandle.seek(toOffset: 0)
            try outputHandle.write(
                contentsOf: wavHeader(dataByteCount: outputDataByteCount)
            )
            try validateOutput(
                at: outputURL,
                expectedFrameCount: totalFrameCount
            )
            return AudioMixdownAssembly(
                dataByteCount: UInt64(outputDataByteCount),
                frameCount: totalFrameCount
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    /// Concatenates 16 kHz mono 16-bit PCM WAV segments end to end into a single
    /// WAV file, preserving order.
    public func concatenate(_ segmentURLs: [URL]) throws -> URL {
        let outputURL = temporaryWAVURL()
        _ = try assemble(
            segmentURLs.map {
                AudioMixdownSegment(
                    microphone: AudioMixdownSource(url: $0, frameOffset: 0),
                    systemAudio: nil
                )
            },
            outputURL: outputURL
        )
        return outputURL
    }

    private func scanSamples(at url: URL) throws -> SampleScan {
        var reader = try StreamingPCM16WAVReader(url: url)
        defer { try? reader.close() }

        var statistics = SampleStatistics()
        while true {
            let samples = try reader.readChunk(
                maximumFrameCount: Self.streamingFrameCount
            )
            guard !samples.isEmpty else { break }
            statistics.consume(samples)
        }
        return SampleScan(
            frameCount: reader.frameCount,
            statistics: statistics
        )
    }

    private func writeStreamingMix(
        microphoneURL: URL,
        microphoneFrameOffset: UInt64,
        systemAudioURL: URL,
        systemAudioFrameOffset: UInt64,
        outputHandle: FileHandle,
        outputFrameCount: UInt64,
        systemGain: Float
    ) throws {
        var microphoneReader = try AlignedPCM16WAVReader(
            url: microphoneURL,
            leadingFrameCount: microphoneFrameOffset
        )
        defer { try? microphoneReader.close() }
        var systemAudioReader = try AlignedPCM16WAVReader(
            url: systemAudioURL,
            leadingFrameCount: systemAudioFrameOffset
        )
        defer { try? systemAudioReader.close() }

        var remainingOutputFrames = outputFrameCount
        while remainingOutputFrames > 0 {
            let frameCount = Int(min(
                UInt64(Self.streamingFrameCount),
                remainingOutputFrames
            ))
            let microphoneSamples = try microphoneReader.readChunk(
                maximumFrameCount: frameCount
            )
            let systemAudioSamples = try systemAudioReader.readChunk(
                maximumFrameCount: frameCount
            )
            var outputData = Data()
            outputData.reserveCapacity(frameCount * MemoryLayout<Int16>.size)

            for index in 0..<frameCount {
                let microphoneSample = index < microphoneSamples.count
                    ? microphoneSamples[index]
                    : 0
                let systemAudioSample = index < systemAudioSamples.count
                    ? systemAudioSamples[index]
                    : 0
                let mixedSample = mix(
                    microphoneSample: microphoneSample,
                    systemAudioSample: systemAudioSample,
                    systemGain: systemGain
                )
                outputData.appendUInt16LE(UInt16(bitPattern: mixedSample))
            }
            try outputHandle.write(contentsOf: outputData)
            remainingOutputFrames -= UInt64(frameCount)
        }
    }

    private func writeStreamingSource(
        sourceURL: URL,
        outputHandle: FileHandle
    ) throws {
        var reader = try StreamingPCM16WAVReader(url: sourceURL)
        defer { try? reader.close() }

        while true {
            let samples = try reader.readChunk(
                maximumFrameCount: Self.streamingFrameCount
            )
            guard !samples.isEmpty else { break }
            let outputData = samples.withUnsafeBufferPointer { Data(buffer: $0) }
            try outputHandle.write(contentsOf: outputData)
        }
    }

    private func temporaryWAVURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
    }

    private func validateOutput(
        at outputURL: URL,
        expectedFrameCount: UInt64
    ) throws {
        let validationReader = try StreamingPCM16WAVReader(url: outputURL)
        defer { try? validationReader.close() }
        guard validationReader.frameCount == expectedFrameCount else {
            throw AudioMixdownServiceError.invalidWAVFile
        }
    }

    private func alignedEndFrame(
        offset: UInt64,
        frameCount: UInt64
    ) throws -> UInt64 {
        let (result, overflow) = offset.addingReportingOverflow(frameCount)
        guard !overflow else {
            throw AudioMixdownServiceError.outputTooLarge
        }
        return result
    }

    private func validatedOutputDataByteCount(
        frameCount: UInt64
    ) throws -> UInt32 {
        let maximumDataByteCount = UInt64(UInt32.max - 36)
        let bytesPerFrame = UInt64(MemoryLayout<Int16>.size)
        guard frameCount <= maximumDataByteCount / bytesPerFrame else {
            throw AudioMixdownServiceError.outputTooLarge
        }
        return UInt32(frameCount * bytesPerFrame)
    }

    private func systemAudioGain(
        microphoneStatistics: SampleStatistics,
        systemAudioStatistics: SampleStatistics
    ) -> Float {
        let systemRMS = systemAudioStatistics.activeRMS
        guard systemRMS > 0 else { return 1 }

        let microphoneRMS = microphoneStatistics.activeRMS
        guard microphoneRMS > 0 else { return 1 }

        let targetSystemRMS = microphoneRMS * 0.8
        let requestedGain = min(2, max(1, targetSystemRMS / systemRMS))
        return peakSafeGain(
            peak: systemAudioStatistics.peak,
            requestedGain: requestedGain
        )
    }

    private func peakSafeGain(peak: Int, requestedGain: Float) -> Float {
        guard peak > 0 else { return requestedGain }

        let headroomGain = (Float(Int16.max) * 0.95) / Float(peak)
        return min(requestedGain, max(1, headroomGain))
    }

    private func mix(
        microphoneSample: Int16,
        systemAudioSample: Int16,
        systemGain: Float
    ) -> Int16 {
        let microphone = Float(microphoneSample) * Self.mixHeadroom
        let systemAudio = Float(systemAudioSample) * systemGain * Self.mixHeadroom
        return clampedInt16(Int((microphone + systemAudio).rounded()))
    }

    private func clampedInt16(_ sample: Int) -> Int16 {
        Int16(max(Int(Int16.min), min(Int(Int16.max), sample)))
    }

    /// 44-byte canonical header for 16 kHz mono 16-bit PCM WAV.
    private func wavHeader(dataByteCount: UInt32) -> Data {
        var data = Data()
        data.appendASCII("RIFF")
        data.appendUInt32LE(36 + dataByteCount)
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
        data.appendUInt32LE(dataByteCount)
        return data
    }

}

private enum AudioMixdownRenderPlan {
    case source(
        url: URL,
        frameCount: UInt64
    )
    case mix(
        microphoneURL: URL,
        microphoneFrameOffset: UInt64,
        systemAudioURL: URL,
        systemAudioFrameOffset: UInt64,
        frameCount: UInt64,
        systemGain: Float
    )

    var frameCount: UInt64 {
        switch self {
        case .source(_, let frameCount):
            return frameCount
        case .mix(_, _, _, _, let frameCount, _):
            return frameCount
        }
    }
}

private struct SampleScan {
    let frameCount: UInt64
    let statistics: SampleStatistics
}

private struct SampleStatistics {
    private var activeSquareSum: Double = 0
    private var activeSampleCount = 0
    private(set) var peak = 0

    var activeRMS: Float {
        guard activeSampleCount > 0 else { return 0 }
        return Float(sqrt(activeSquareSum / Double(activeSampleCount)))
    }

    mutating func consume(_ samples: [Int16]) {
        for sample in samples {
            let integerSample = Int(sample)
            peak = max(peak, abs(integerSample))

            let doubleSample = Double(sample)
            if abs(doubleSample) > 32 {
                activeSquareSum += doubleSample * doubleSample
                activeSampleCount += 1
            }
        }
    }
}

private struct AlignedPCM16WAVReader {
    private var reader: StreamingPCM16WAVReader
    private var remainingLeadingFrameCount: UInt64

    init(url: URL, leadingFrameCount: UInt64) throws {
        reader = try StreamingPCM16WAVReader(url: url)
        remainingLeadingFrameCount = leadingFrameCount
    }

    mutating func readChunk(maximumFrameCount: Int) throws -> [Int16] {
        guard maximumFrameCount > 0 else { return [] }
        var samples: [Int16] = []
        samples.reserveCapacity(maximumFrameCount)

        if remainingLeadingFrameCount > 0 {
            let silenceFrameCount = Int(min(
                UInt64(maximumFrameCount),
                remainingLeadingFrameCount
            ))
            samples.append(contentsOf: repeatElement(0, count: silenceFrameCount))
            remainingLeadingFrameCount -= UInt64(silenceFrameCount)
        }

        let sourceFrameCount = maximumFrameCount - samples.count
        if sourceFrameCount > 0 {
            samples.append(contentsOf: try reader.readChunk(
                maximumFrameCount: sourceFrameCount
            ))
        }
        return samples
    }

    func close() throws {
        try reader.close()
    }
}

private struct StreamingPCM16WAVReader {
    let frameCount: UInt64

    private let handle: FileHandle
    private var remainingDataByteCount: UInt64

    init(url: URL) throws {
        let openedHandle = try FileHandle(forReadingFrom: url)
        do {
            let layout = try Self.parseLayout(from: openedHandle)
            try openedHandle.seek(toOffset: layout.dataOffset)
            handle = openedHandle
            frameCount = layout.dataByteCount / UInt64(MemoryLayout<Int16>.size)
            remainingDataByteCount = layout.dataByteCount
        } catch {
            try? openedHandle.close()
            throw error
        }
    }

    mutating func readChunk(maximumFrameCount: Int) throws -> [Int16] {
        guard maximumFrameCount > 0, remainingDataByteCount > 0 else {
            return []
        }
        let requestedByteCount = min(
            UInt64(maximumFrameCount * MemoryLayout<Int16>.size),
            remainingDataByteCount
        )
        let data = try Self.readExactly(
            Int(requestedByteCount),
            from: handle
        )
        remainingDataByteCount -= requestedByteCount

        var samples: [Int16] = []
        samples.reserveCapacity(data.count / MemoryLayout<Int16>.size)
        var offset = 0
        while offset < data.count {
            samples.append(Int16(bitPattern: data.readUInt16LE(at: offset)))
            offset += MemoryLayout<Int16>.size
        }
        return samples
    }

    func close() throws {
        try handle.close()
    }

    private static func parseLayout(from handle: FileHandle) throws -> WAVLayout {
        let physicalByteCount = try handle.seekToEnd()
        guard physicalByteCount >= 12 else {
            throw AudioMixdownServiceError.invalidWAVFile
        }
        try handle.seek(toOffset: 0)
        let riffHeader = try readExactly(12, from: handle)
        guard String(bytes: riffHeader[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: riffHeader[8..<12], encoding: .ascii) == "WAVE" else {
            throw AudioMixdownServiceError.invalidWAVFile
        }

        let riffByteCount = UInt64(riffHeader.readUInt32LE(at: 4)) + 8
        guard riffByteCount >= 12, riffByteCount <= physicalByteCount else {
            throw AudioMixdownServiceError.invalidWAVFile
        }

        var offset: UInt64 = 12
        var audioFormat: UInt16?
        var channelCount: UInt16?
        var sampleRate: UInt32?
        var byteRate: UInt32?
        var blockAlign: UInt16?
        var bitsPerSample: UInt16?
        var dataOffset: UInt64?
        var dataByteCount: UInt64?

        while offset + 8 <= riffByteCount {
            try handle.seek(toOffset: offset)
            let chunkHeader = try readExactly(8, from: handle)
            let chunkID = String(bytes: chunkHeader[0..<4], encoding: .ascii)
            let chunkByteCount = UInt64(chunkHeader.readUInt32LE(at: 4))
            let chunkDataOffset = offset + 8
            let paddedChunkByteCount = chunkByteCount + (chunkByteCount % 2)
            guard chunkDataOffset <= riffByteCount,
                  paddedChunkByteCount <= riffByteCount - chunkDataOffset else {
                throw AudioMixdownServiceError.invalidWAVFile
            }

            if chunkID == "fmt " {
                guard chunkByteCount >= 16 else {
                    throw AudioMixdownServiceError.invalidWAVFile
                }
                try handle.seek(toOffset: chunkDataOffset)
                let formatData = try readExactly(16, from: handle)
                audioFormat = formatData.readUInt16LE(at: 0)
                channelCount = formatData.readUInt16LE(at: 2)
                sampleRate = formatData.readUInt32LE(at: 4)
                byteRate = formatData.readUInt32LE(at: 8)
                blockAlign = formatData.readUInt16LE(at: 12)
                bitsPerSample = formatData.readUInt16LE(at: 14)
            } else if chunkID == "data", dataOffset == nil {
                guard chunkByteCount % UInt64(MemoryLayout<Int16>.size) == 0 else {
                    throw AudioMixdownServiceError.invalidWAVFile
                }
                dataOffset = chunkDataOffset
                dataByteCount = chunkByteCount
            }

            offset = chunkDataOffset + paddedChunkByteCount
        }

        guard audioFormat == 1,
              channelCount == 1,
              sampleRate == 16_000,
              byteRate == 16_000 * 2,
              blockAlign == 2,
              bitsPerSample == 16,
              let dataOffset,
              let dataByteCount else {
            throw AudioMixdownServiceError.unsupportedWAVFormat
        }
        guard dataOffset <= physicalByteCount,
              dataByteCount <= physicalByteCount - dataOffset else {
            throw AudioMixdownServiceError.invalidWAVFile
        }
        return WAVLayout(
            dataOffset: dataOffset,
            dataByteCount: dataByteCount
        )
    }

    private static func readExactly(
        _ byteCount: Int,
        from handle: FileHandle
    ) throws -> Data {
        guard let data = try handle.read(upToCount: byteCount),
              data.count == byteCount else {
            throw AudioMixdownServiceError.invalidWAVFile
        }
        return data
    }

    private struct WAVLayout {
        let dataOffset: UInt64
        let dataByteCount: UInt64
    }
}

enum AudioMixdownServiceError: Error {
    case invalidWAVFile
    case unsupportedWAVFormat
    case noSegmentsToConcatenate
    case emptySegment
    case outputTooLarge
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

    func readUInt16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
