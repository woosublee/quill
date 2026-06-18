import AVFoundation
import Foundation

public struct AudioMixdownService {
    /// Per-source headroom applied before summing the two streams. Summing two
    /// full-scale signals would overflow, so each is attenuated to leave room.
    /// Mixing the streams continuously (rather than gating sample-by-sample on
    /// activity) avoids the per-sample amplitude jumps that produced audible
    /// crackle when the microphone was recorded alongside system audio.
    private static let mixHeadroom: Float = 0.8

    public init() {}

    public func mix(microphoneURL: URL, systemAudioURL: URL) throws -> URL {
        let microphoneSamples = try readSamples(from: microphoneURL)
        let systemAudioSamples = try readSamples(from: systemAudioURL)
        let outputFrameCount = max(microphoneSamples.count, systemAudioSamples.count)
        let systemGain = systemAudioGain(microphoneSamples: microphoneSamples, systemAudioSamples: systemAudioSamples)

        var mixedSamples: [Int16] = []
        mixedSamples.reserveCapacity(outputFrameCount)

        for index in 0..<outputFrameCount {
            // A source that has run out (the shorter recording) contributes
            // silence, so the same continuous mix runs across the whole file
            // without an amplitude step at the boundary.
            let microphoneSample = index < microphoneSamples.count ? microphoneSamples[index] : 0
            let systemAudioSample = index < systemAudioSamples.count ? systemAudioSamples[index] : 0
            mixedSamples.append(mix(microphoneSample: microphoneSample, systemAudioSample: systemAudioSample, systemGain: systemGain))
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try writeWAV(samples: mixedSamples, to: outputURL)
        return outputURL
    }

    /// Concatenates 16 kHz mono 16-bit PCM WAV segments end to end into a single
    /// WAV file, preserving order. Used to stitch recording segments captured
    /// across a mid-recording input switch into one continuous file.
    public func concatenate(_ segmentURLs: [URL]) throws -> URL {
        guard !segmentURLs.isEmpty else {
            throw AudioMixdownServiceError.noSegmentsToConcatenate
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        // Stream each segment's raw PCM bytes straight to disk after a placeholder
        // header, then patch the sizes. This avoids decoding/re-encoding every
        // sample and holding the whole recording in memory.
        try wavHeader(dataByteCount: 0).write(to: outputURL, options: .atomic)
        var totalDataBytes = 0
        do {
            let handle = try FileHandle(forWritingTo: outputURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            for url in segmentURLs {
                let pcm = try pcmDataChunk(from: url)
                try handle.write(contentsOf: pcm)
                totalDataBytes += pcm.count
            }
            // Patch the RIFF chunk size (offset 4) and data chunk size (offset 40).
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: uint32LEData(UInt32(36 + totalDataBytes)))
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: uint32LEData(UInt32(totalDataBytes)))
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        return outputURL
    }

    private func systemAudioGain(microphoneSamples: [Int16], systemAudioSamples: [Int16]) -> Float {
        let systemRMS = activeRMS(systemAudioSamples)
        guard systemRMS > 0 else { return 1 }

        let microphoneRMS = activeRMS(microphoneSamples)
        guard microphoneRMS > 0 else { return 1 }

        let targetSystemRMS = microphoneRMS * 0.8
        let requestedGain = min(2, max(1, targetSystemRMS / systemRMS))
        return peakSafeGain(for: systemAudioSamples, requestedGain: requestedGain)
    }

    private func peakSafeGain(for samples: [Int16], requestedGain: Float) -> Float {
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        guard peak > 0 else { return requestedGain }

        let headroomGain = (Float(Int16.max) * 0.95) / Float(peak)
        return min(requestedGain, max(1, headroomGain))
    }

    private func activeRMS(_ samples: [Int16]) -> Float {
        var sum = Float(0)
        var count = 0
        for sample in samples {
            let floatSample = Float(sample)
            if abs(floatSample) > 32 {
                sum += floatSample * floatSample
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        return sqrt(sum / Float(count))
    }

    private func mix(microphoneSample: Int16, systemAudioSample: Int16, systemGain: Float) -> Int16 {
        let microphone = Float(microphoneSample) * Self.mixHeadroom
        let systemAudio = Float(systemAudioSample) * systemGain * Self.mixHeadroom
        return clampedInt16(Int((microphone + systemAudio).rounded()))
    }

    private func clampedInt16(_ sample: Int) -> Int16 {
        Int16(max(Int(Int16.min), min(Int(Int16.max), sample)))
    }

    /// Parses a 16 kHz mono 16-bit PCM WAV and returns just its `data` chunk
    /// bytes (0-based copy), validating the format. Used both to decode samples
    /// and to concatenate raw PCM without a per-sample round trip.
    private func pcmDataChunk(from url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard data.count >= 44 else {
            throw AudioMixdownServiceError.invalidWAVFile
        }
        guard String(bytes: data[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: data[8..<12], encoding: .ascii) == "WAVE" else {
            throw AudioMixdownServiceError.invalidWAVFile
        }

        var offset = 12
        var audioFormat: UInt16?
        var channelCount: UInt16?
        var sampleRate: UInt32?
        var bitsPerSample: UInt16?
        var sampleData: Data?

        while offset + 8 <= data.count {
            let chunkID = String(bytes: data[offset..<(offset + 4)], encoding: .ascii)
            let chunkSize = Int(readUInt32LE(data, at: offset + 4))
            let chunkStart = offset + 8
            let chunkEnd = chunkStart + chunkSize
            guard chunkEnd <= data.count else {
                throw AudioMixdownServiceError.invalidWAVFile
            }

            if chunkID == "fmt " {
                guard chunkSize >= 16 else {
                    throw AudioMixdownServiceError.invalidWAVFile
                }
                audioFormat = readUInt16LE(data, at: chunkStart)
                channelCount = readUInt16LE(data, at: chunkStart + 2)
                sampleRate = readUInt32LE(data, at: chunkStart + 4)
                bitsPerSample = readUInt16LE(data, at: chunkStart + 14)
            } else if chunkID == "data" {
                sampleData = data[chunkStart..<chunkEnd]
            }

            offset = chunkEnd + (chunkSize % 2)
        }

        guard audioFormat == 1,
              channelCount == 1,
              sampleRate == 16_000,
              bitsPerSample == 16,
              let sampleData else {
            throw AudioMixdownServiceError.unsupportedWAVFormat
        }
        return Data(sampleData)
    }

    private func readSamples(from url: URL) throws -> [Int16] {
        let sampleData = try pcmDataChunk(from: url)
        var samples: [Int16] = []
        samples.reserveCapacity(sampleData.count / 2)
        var sampleOffset = sampleData.startIndex
        while sampleOffset + 1 < sampleData.endIndex {
            let low = UInt16(sampleData[sampleOffset])
            let high = UInt16(sampleData[sampleData.index(after: sampleOffset)]) << 8
            samples.append(Int16(bitPattern: high | low))
            sampleOffset = sampleData.index(sampleOffset, offsetBy: 2)
        }
        return samples
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

    private func uint32LEData(_ value: UInt32) -> Data {
        var data = Data()
        data.appendUInt32LE(value)
        return data
    }

    private func writeWAV(samples: [Int16], to url: URL) throws {
        var data = wavHeader(dataByteCount: UInt32(samples.count * MemoryLayout<Int16>.size))
        for sample in samples {
            data.appendUInt16LE(UInt16(bitPattern: sample))
        }
        try data.write(to: url, options: .atomic)
    }

    private func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

enum AudioMixdownServiceError: Error {
    case invalidWAVFile
    case unsupportedWAVFormat
    case noSegmentsToConcatenate
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
