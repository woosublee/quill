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
        guard data.count >= Int(headerByteCount),
              String(bytes: data[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: data[8..<12], encoding: .ascii) == "WAVE",
              String(bytes: data[12..<16], encoding: .ascii) == "fmt ",
              data.readUInt32LE(at: 16) == 16,
              data.readUInt16LE(at: 20) == 1,
              data.readUInt16LE(at: 22) == channelCount,
              data.readUInt32LE(at: 24) == sampleRate,
              data.readUInt32LE(at: 28) == sampleRate * UInt32(bytesPerFrame),
              data.readUInt16LE(at: 32) == bytesPerFrame,
              data.readUInt16LE(at: 34) == bitsPerSample,
              String(bytes: data[36..<40], encoding: .ascii) == "data" else {
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
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
