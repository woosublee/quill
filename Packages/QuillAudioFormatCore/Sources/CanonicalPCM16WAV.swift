import Foundation

public struct CanonicalAudioFormat: Codable, Equatable, Hashable, Sendable {
    public static let pcm16Mono16k = CanonicalAudioFormat(
        sampleRate: 16_000,
        channelCount: 1,
        bitsPerSample: 16,
        bytesPerFrame: 2,
        isInterleaved: true,
        isSigned: true,
        isLittleEndian: true
    )

    public let sampleRate: UInt32
    public let channelCount: UInt16
    public let bitsPerSample: UInt16
    public let bytesPerFrame: UInt16
    public let isInterleaved: Bool
    public let isSigned: Bool
    public let isLittleEndian: Bool

    public init(
        sampleRate: UInt32,
        channelCount: UInt16,
        bitsPerSample: UInt16,
        bytesPerFrame: UInt16,
        isInterleaved: Bool,
        isSigned: Bool,
        isLittleEndian: Bool
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitsPerSample = bitsPerSample
        self.bytesPerFrame = bytesPerFrame
        self.isInterleaved = isInterleaved
        self.isSigned = isSigned
        self.isLittleEndian = isLittleEndian
    }

    public func dataByteCount(forFrameCount frameCount: UInt64) throws -> UInt64 {
        let bytesPerFrame = try validatedBytesPerFrame()
        let (byteCount, overflow) = frameCount.multipliedReportingOverflow(by: bytesPerFrame)
        guard !overflow else {
            throw CanonicalPCM16WAVError.sizeOverflow
        }
        return byteCount
    }

    public func frameCount(forDataByteCount byteCount: UInt64) throws -> UInt64 {
        let bytesPerFrame = try validatedBytesPerFrame()
        guard byteCount.isMultiple(of: bytesPerFrame) else {
            throw CanonicalPCM16WAVError.misalignedPayload
        }
        return byteCount / bytesPerFrame
    }

    public func duration(forFrameCount frameCount: UInt64) -> TimeInterval {
        guard sampleRate > 0 else {
            return 0
        }
        return TimeInterval(frameCount) / TimeInterval(sampleRate)
    }

    private func validatedBytesPerFrame() throws -> UInt64 {
        guard bytesPerFrame > 0 else {
            throw CanonicalPCM16WAVError.invalidFormat
        }
        return UInt64(bytesPerFrame)
    }
}

public struct CanonicalPCM16WAVLayout: Codable, Equatable, Sendable {
    public let dataOffset: UInt64
    public let dataByteCount: UInt64
    public let frameCount: UInt64
    public let duration: TimeInterval

    public init(
        dataOffset: UInt64,
        dataByteCount: UInt64,
        frameCount: UInt64,
        duration: TimeInterval
    ) {
        self.dataOffset = dataOffset
        self.dataByteCount = dataByteCount
        self.frameCount = frameCount
        self.duration = duration
    }
}

/// How much of a recording cut off mid-write can still be read: the bytes
/// after the header, less a trailing half frame.
public struct RecoverablePCM16Payload: Equatable, Sendable {
    public let physicalDataByteCount: UInt64
    public let recoverableDataByteCount: UInt64
    public let frameCount: UInt64
    public let removedTrailingByte: Bool

    public init(
        physicalDataByteCount: UInt64,
        recoverableDataByteCount: UInt64,
        frameCount: UInt64,
        removedTrailingByte: Bool
    ) {
        self.physicalDataByteCount = physicalDataByteCount
        self.recoverableDataByteCount = recoverableDataByteCount
        self.frameCount = frameCount
        self.removedTrailingByte = removedTrailingByte
    }
}

public enum CanonicalPCM16WAVError: Error, Equatable, Sendable {
    case fileTooShort
    case invalidRIFF
    case invalidWAVE
    case invalidFormat
    case invalidDataChunk
    case emptyPayload
    case truncatedPayload
    case trailingPayload
    case misalignedPayload
    case sizeOverflow
}

/// The one audio file shape both apps record, store, and send: 16 kHz mono
/// 16-bit PCM with the plain 44-byte header.
public enum CanonicalPCM16WAV {
    public static let sampleRate = CanonicalAudioFormat.pcm16Mono16k.sampleRate
    public static let channelCount = CanonicalAudioFormat.pcm16Mono16k.channelCount
    public static let bitsPerSample = CanonicalAudioFormat.pcm16Mono16k.bitsPerSample
    public static let bytesPerFrame = CanonicalAudioFormat.pcm16Mono16k.bytesPerFrame
    public static let headerByteCount: UInt64 = 44

    public static func header(dataByteCount: UInt32) throws -> Data {
        let (riffByteCount, overflow) = dataByteCount.addingReportingOverflow(36)
        guard !overflow else {
            throw CanonicalPCM16WAVError.sizeOverflow
        }

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

    /// The `data` size a canonical header declares, or nil when the header
    /// isn't canonical.
    public static func declaredDataByteCount(in data: Data) -> UInt32? {
        try? validatedDataByteCount(in: data)
    }

    /// The layout a canonical header declares, without the file behind it.
    public static func parseHeader(
        _ data: Data,
        requireNonEmpty: Bool = true
    ) throws -> CanonicalPCM16WAVLayout {
        let dataByteCount = try validatedDataByteCount(in: data)
        guard !requireNonEmpty || dataByteCount > 0 else {
            throw CanonicalPCM16WAVError.emptyPayload
        }
        let format = CanonicalAudioFormat.pcm16Mono16k
        let frameCount = try format.frameCount(forDataByteCount: UInt64(dataByteCount))
        return CanonicalPCM16WAVLayout(
            dataOffset: headerByteCount,
            dataByteCount: UInt64(dataByteCount),
            frameCount: frameCount,
            duration: format.duration(forFrameCount: frameCount)
        )
    }

    /// A canonical file whose length matches its header exactly.
    public static func validateFile(
        at url: URL,
        requireNonEmpty: Bool = true
    ) throws -> CanonicalPCM16WAVLayout {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let header = try handle.read(upToCount: Int(headerByteCount)) ?? Data()
        let layout = try parseHeader(header, requireNonEmpty: requireNonEmpty)
        let physicalFileByteCount = try handle.seekToEnd()
        let expectedFileByteCount = layout.dataOffset + layout.dataByteCount
        if physicalFileByteCount < expectedFileByteCount {
            throw CanonicalPCM16WAVError.truncatedPayload
        }
        if physicalFileByteCount > expectedFileByteCount {
            throw CanonicalPCM16WAVError.trailingPayload
        }
        return layout
    }

    /// Copies 16 kHz mono 16-bit PCM audio from a WAV file whose header is
    /// not the plain 44-byte form (for example extra JUNK or LIST chunks, or
    /// WAVE_FORMAT_EXTENSIBLE) into a canonical WAV. Other formats are
    /// rejected, and no partial output is left behind.
    public static func writeCanonicalCopy(
        of sourceURL: URL,
        to destinationURL: URL,
        copyBufferByteCount: Int = 1_048_576
    ) throws -> CanonicalPCM16WAVLayout {
        let source = try FileHandle(forReadingFrom: sourceURL)
        defer { try? source.close() }
        let sourceByteCount = try source.seekToEnd()
        try source.seek(toOffset: 0)
        guard let riff = try source.read(upToCount: 12), riff.count == 12 else {
            throw CanonicalPCM16WAVError.fileTooShort
        }
        guard riff.hasASCII("RIFF", at: 0) else {
            throw CanonicalPCM16WAVError.invalidRIFF
        }
        guard riff.hasASCII("WAVE", at: 8) else {
            throw CanonicalPCM16WAVError.invalidWAVE
        }

        var offset: UInt64 = 12
        var hasSupportedFormat = false
        var audioRange: (start: UInt64, byteCount: UInt64)?
        while offset + 8 <= sourceByteCount, audioRange == nil {
            try source.seek(toOffset: offset)
            guard let header = try source.read(upToCount: 8), header.count == 8 else {
                break
            }
            let size = UInt64(header.readUInt32LE(at: 4))
            let payloadStart = offset + 8
            if header.hasASCII("fmt ", at: 0) {
                guard size >= 16, size <= 64,
                      let format = try source.read(upToCount: Int(size)),
                      format.count == Int(size) else {
                    throw CanonicalPCM16WAVError.invalidFormat
                }
                hasSupportedFormat = isSupportedFormat(format)
            } else if header.hasASCII("data", at: 0) {
                guard hasSupportedFormat else {
                    throw CanonicalPCM16WAVError.invalidFormat
                }
                audioRange = (payloadStart, min(size, sourceByteCount - payloadStart))
            }
            offset = payloadStart + size + (size % 2)
        }
        guard let audioRange else {
            throw CanonicalPCM16WAVError.invalidDataChunk
        }
        let frameCount = audioRange.byteCount / UInt64(bytesPerFrame)
        guard frameCount > 0 else {
            throw CanonicalPCM16WAVError.emptyPayload
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
                throw CanonicalPCM16WAVError.truncatedPayload
            }
            try output.write(contentsOf: chunk)
            remaining -= UInt64(count)
        }
        try output.synchronize()
        let layout = try validateFile(at: destinationURL)
        succeeded = true
        return layout
    }

    public static func dataByteCount(
        forFrameCount frameCount: UInt64
    ) throws -> UInt32 {
        let maximumDataByteCount = UInt64(UInt32.max - 36)
        guard frameCount <= maximumDataByteCount / UInt64(bytesPerFrame) else {
            throw CanonicalPCM16WAVError.sizeOverflow
        }
        return UInt32(frameCount * UInt64(bytesPerFrame))
    }

    public static func recoverablePayload(
        physicalFileByteCount: UInt64
    ) throws -> RecoverablePCM16Payload {
        guard physicalFileByteCount >= headerByteCount else {
            throw CanonicalPCM16WAVError.fileTooShort
        }

        let physicalDataByteCount = physicalFileByteCount - headerByteCount
        let format = CanonicalAudioFormat.pcm16Mono16k
        let recoverableDataByteCount = physicalDataByteCount
            - (physicalDataByteCount % UInt64(format.bytesPerFrame))
        let frameCount = try format.frameCount(forDataByteCount: recoverableDataByteCount)

        return RecoverablePCM16Payload(
            physicalDataByteCount: physicalDataByteCount,
            recoverableDataByteCount: recoverableDataByteCount,
            frameCount: frameCount,
            removedTrailingByte: physicalDataByteCount != recoverableDataByteCount
        )
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

    private static func validatedDataByteCount(in header: Data) throws -> UInt32 {
        guard header.count >= Int(headerByteCount) else {
            throw CanonicalPCM16WAVError.fileTooShort
        }
        guard header.hasASCII("RIFF", at: 0) else {
            throw CanonicalPCM16WAVError.invalidRIFF
        }
        guard header.hasASCII("WAVE", at: 8) else {
            throw CanonicalPCM16WAVError.invalidWAVE
        }
        guard header.hasASCII("fmt ", at: 12),
              header.readUInt32LE(at: 16) == 16,
              header.readUInt16LE(at: 20) == 1,
              header.readUInt16LE(at: 22) == channelCount,
              header.readUInt32LE(at: 24) == sampleRate,
              header.readUInt32LE(at: 28) == sampleRate * UInt32(bytesPerFrame),
              header.readUInt16LE(at: 32) == bytesPerFrame,
              header.readUInt16LE(at: 34) == bitsPerSample else {
            throw CanonicalPCM16WAVError.invalidFormat
        }
        guard header.hasASCII("data", at: 36) else {
            throw CanonicalPCM16WAVError.invalidDataChunk
        }

        let dataByteCount = header.readUInt32LE(at: 40)
        let (expectedRIFFByteCount, overflow) = dataByteCount.addingReportingOverflow(36)
        guard !overflow,
              header.readUInt32LE(at: 4) == expectedRIFFByteCount else {
            throw CanonicalPCM16WAVError.invalidRIFF
        }
        return dataByteCount
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0x00FF))
        append(UInt8((value & 0xFF00) >> 8))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0x000000FF))
        append(UInt8((value & 0x0000FF00) >> 8))
        append(UInt8((value & 0x00FF0000) >> 16))
        append(UInt8((value & 0xFF000000) >> 24))
    }

    func hasASCII(_ value: String, at offset: Int) -> Bool {
        let bytes = Array(value.utf8)
        guard offset >= 0, count >= offset + bytes.count else {
            return false
        }
        let start = startIndex + offset
        return self[start..<(start + bytes.count)].elementsEqual(bytes)
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
