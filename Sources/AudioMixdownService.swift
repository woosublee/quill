import AVFoundation
import Foundation

public struct AudioMixdownService {
    public init() {}

    public func mix(microphoneURL: URL, systemAudioURL: URL) throws -> URL {
        let microphoneSamples = try readSamples(from: microphoneURL)
        let systemAudioSamples = try readSamples(from: systemAudioURL)
        let outputFrameCount = max(microphoneSamples.count, systemAudioSamples.count)

        var mixedSamples: [Int16] = []
        mixedSamples.reserveCapacity(outputFrameCount)

        for index in 0..<outputFrameCount {
            let hasMicrophoneSample = index < microphoneSamples.count
            let hasSystemAudioSample = index < systemAudioSamples.count

            switch (hasMicrophoneSample, hasSystemAudioSample) {
            case (true, true):
                let average = (Int(microphoneSamples[index]) + Int(systemAudioSamples[index])) / 2
                mixedSamples.append(Int16(average))
            case (true, false):
                mixedSamples.append(microphoneSamples[index])
            case (false, true):
                mixedSamples.append(systemAudioSamples[index])
            case (false, false):
                mixedSamples.append(0)
            }
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try writeWAV(samples: mixedSamples, to: outputURL)
        return outputURL
    }

    private func readSamples(from url: URL) throws -> [Int16] {
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

    private func writeWAV(samples: [Int16], to url: URL) throws {
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
