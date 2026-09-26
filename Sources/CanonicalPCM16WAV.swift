import Foundation

struct CanonicalPCM16WAVLayout: Equatable, Sendable {
    let dataOffset: UInt64
    let dataByteCount: UInt64
    let frameCount: UInt64
}

enum CanonicalPCM16WAVError: Error, Equatable {
    case invalidHeader
    case emptyAudio
    case misalignedData
    case physicalSizeMismatch
    case outputTooLarge
}

enum CanonicalPCM16WAV {
    static let sampleRate: UInt32 = 16_000
    static let channelCount: UInt16 = 1
    static let bitsPerSample: UInt16 = 16
    static let bytesPerFrame: UInt16 = 2
    static let headerByteCount: UInt64 = 44

    static func header(dataByteCount: UInt32) -> Data {
        let (riffByteCount, overflow) = dataByteCount.addingReportingOverflow(36)
        precondition(!overflow, "Canonical WAV payload exceeds RIFF limits.")

        var data = Data()
        data.reserveCapacity(Int(headerByteCount))
        data.appendASCII("RIFF")
        data.appendUInt32LE(riffByteCount)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendUInt32LE(16)
        data.appendUInt16LE(1)
        data.appendUInt16LE(channelCount)
        data.appendUInt32LE(sampleRate)
        data.appendUInt32LE(sampleRate * UInt32(bytesPerFrame))
        data.appendUInt16LE(bytesPerFrame)
        data.appendUInt16LE(bitsPerSample)
        data.appendASCII("data")
        data.appendUInt32LE(dataByteCount)
        return data
    }

    static func declaredDataByteCount(in data: Data) -> UInt32? {
        guard data.count >= Int(headerByteCount) else { return nil }
        let start = data.startIndex
        guard String(bytes: data[start..<(start + 4)], encoding: .ascii) == "RIFF",
              String(bytes: data[(start + 8)..<(start + 12)], encoding: .ascii) == "WAVE",
              String(bytes: data[(start + 12)..<(start + 16)], encoding: .ascii) == "fmt ",
              data.readUInt32LE(at: 16) == 16,
              data.readUInt16LE(at: 20) == 1,
              data.readUInt16LE(at: 22) == channelCount,
              data.readUInt32LE(at: 24) == sampleRate,
              data.readUInt32LE(at: 28) == sampleRate * UInt32(bytesPerFrame),
              data.readUInt16LE(at: 32) == bytesPerFrame,
              data.readUInt16LE(at: 34) == bitsPerSample,
              String(bytes: data[(start + 36)..<(start + 40)], encoding: .ascii) == "data" else {
            return nil
        }

        let dataByteCount = data.readUInt32LE(at: 40)
        guard dataByteCount <= UInt32.max - 36,
              data.readUInt32LE(at: 4) == 36 + dataByteCount else {
            return nil
        }
        return dataByteCount
    }

    static func parseHeader(_ data: Data) throws -> CanonicalPCM16WAVLayout {
        guard let dataByteCount = declaredDataByteCount(in: data) else {
            throw CanonicalPCM16WAVError.invalidHeader
        }
        guard dataByteCount > 0 else {
            throw CanonicalPCM16WAVError.emptyAudio
        }
        guard dataByteCount % UInt32(bytesPerFrame) == 0 else {
            throw CanonicalPCM16WAVError.misalignedData
        }

        return CanonicalPCM16WAVLayout(
            dataOffset: headerByteCount,
            dataByteCount: UInt64(dataByteCount),
            frameCount: UInt64(dataByteCount) / UInt64(bytesPerFrame)
        )
    }

    static func validateFile(at url: URL) throws -> CanonicalPCM16WAVLayout {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: Int(headerByteCount)) ?? Data()
        let layout = try parseHeader(header)
        let physicalByteCount = try handle.seekToEnd()
        guard physicalByteCount == layout.dataOffset + layout.dataByteCount else {
            throw CanonicalPCM16WAVError.physicalSizeMismatch
        }
        return layout
    }

    /// Copies 16 kHz mono 16-bit PCM audio from a WAV file whose header is
    /// not the plain 44-byte form (for example extra JUNK or LIST chunks, or
    /// WAVE_FORMAT_EXTENSIBLE) into a canonical WAV. Other formats are rejected
    /// with `invalidHeader`, and no partial output is left behind.
    static func writeCanonicalCopy(
        of sourceURL: URL,
        to destinationURL: URL,
        copyBufferByteCount: Int = 1_048_576
    ) throws -> CanonicalPCM16WAVLayout {
        let source = try FileHandle(forReadingFrom: sourceURL)
        defer { try? source.close() }
        let sourceByteCount = try source.seekToEnd()
        try source.seek(toOffset: 0)
        guard let riff = try source.read(upToCount: 12), riff.count == 12,
              String(bytes: riff.prefix(4), encoding: .ascii) == "RIFF",
              String(bytes: riff.suffix(4), encoding: .ascii) == "WAVE" else {
            throw CanonicalPCM16WAVError.invalidHeader
        }

        var offset: UInt64 = 12
        var hasSupportedFormat = false
        var audioRange: (start: UInt64, byteCount: UInt64)?
        while offset + 8 <= sourceByteCount, audioRange == nil {
            try source.seek(toOffset: offset)
            guard let header = try source.read(upToCount: 8), header.count == 8 else {
                break
            }
            let id = String(bytes: header.prefix(4), encoding: .ascii)
            let size = UInt64(header.readUInt32LE(at: 4))
            let payloadStart = offset + 8
            switch id {
            case "fmt ":
                guard size >= 16, size <= 64,
                      let format = try source.read(upToCount: Int(size)),
                      format.count == Int(size) else {
                    throw CanonicalPCM16WAVError.invalidHeader
                }
                hasSupportedFormat = isSupportedFormat(format)
            case "data":
                guard hasSupportedFormat else {
                    throw CanonicalPCM16WAVError.invalidHeader
                }
                audioRange = (payloadStart, min(size, sourceByteCount - payloadStart))
            default:
                break
            }
            offset = payloadStart + size + (size % 2)
        }
        guard let audioRange else {
            throw CanonicalPCM16WAVError.invalidHeader
        }
        let frameCount = audioRange.byteCount / UInt64(bytesPerFrame)
        guard frameCount > 0 else {
            throw CanonicalPCM16WAVError.emptyAudio
        }
        let payloadByteCount = try dataByteCount(forFrameCount: frameCount)

        var succeeded = false
        defer {
            if !succeeded {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }
        try header(dataByteCount: payloadByteCount).write(to: destinationURL)
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }
        try output.seekToEnd()
        try source.seek(toOffset: audioRange.start)
        var remaining = UInt64(payloadByteCount)
        while remaining > 0 {
            try Task.checkCancellation()
            let count = Int(min(UInt64(copyBufferByteCount), remaining))
            guard let chunk = try source.read(upToCount: count), chunk.count == count else {
                throw CanonicalPCM16WAVError.physicalSizeMismatch
            }
            try output.write(contentsOf: chunk)
            remaining -= UInt64(count)
        }
        try output.synchronize()
        let layout = try validateFile(at: destinationURL)
        succeeded = true
        return layout
    }

    private static func isSupportedFormat(_ format: Data) -> Bool {
        let tag = format.readUInt16LE(at: 0)
        let isPCM: Bool
        if tag == 1 {
            isPCM = true
        } else if tag == 0xFFFE, format.count >= 26 {
            // WAVE_FORMAT_EXTENSIBLE: the sub-format GUID starts with the PCM tag.
            isPCM = format.readUInt16LE(at: 24) == 1
        } else {
            isPCM = false
        }
        return isPCM
            && format.readUInt16LE(at: 2) == channelCount
            && format.readUInt32LE(at: 4) == sampleRate
            && format.readUInt16LE(at: 12) == bytesPerFrame
            && format.readUInt16LE(at: 14) == bitsPerSample
    }

    static func dataByteCount(forFrameCount frameCount: UInt64) throws -> UInt32 {
        let maximumDataByteCount = UInt64(UInt32.max - 36)
        guard frameCount <= maximumDataByteCount / UInt64(bytesPerFrame) else {
            throw CanonicalPCM16WAVError.outputTooLarge
        }
        return UInt32(frameCount * UInt64(bytesPerFrame))
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

    func readUInt16LE(at offset: Int) -> UInt16 {
        let base = startIndex + offset
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base])
            | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16)
            | (UInt32(self[base + 3]) << 24)
    }
}
