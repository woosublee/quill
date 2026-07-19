import Foundation

@main
struct CanonicalPCM16WAVTests {
    static func main() {
        do {
            try canonicalHeaderRoundTrips()
            try rejectsNonCanonicalFormatFields()
            try rejectsInvalidChunkLayout()
            try rejectsEmptyAndMisalignedAudio()
            try validatesPhysicalFileSize()
            try convertsFrameCountsWithoutOverflow()
            print("CanonicalPCM16WAVTests passed")
        } catch {
            fputs("CanonicalPCM16WAVTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func canonicalHeaderRoundTrips() throws {
        let header = CanonicalPCM16WAV.header(dataByteCount: 8)
        try expectEqual(header.count, 44, "header byte count")
        let layout = try CanonicalPCM16WAV.parseHeader(header)
        try expectEqual(
            layout,
            CanonicalPCM16WAVLayout(
                dataOffset: 44,
                dataByteCount: 8,
                frameCount: 4
            ),
            "canonical layout"
        )
    }

    private static func rejectsNonCanonicalFormatFields() throws {
        let canonical = CanonicalPCM16WAV.header(dataByteCount: 8)
        try expectError(.invalidHeader, "channel count") {
            try CanonicalPCM16WAV.parseHeader(replacingUInt16(in: canonical, at: 22, with: 2))
        }
        try expectError(.invalidHeader, "sample rate") {
            try CanonicalPCM16WAV.parseHeader(replacingUInt32(in: canonical, at: 24, with: 44_100))
        }
        try expectError(.invalidHeader, "byte rate") {
            try CanonicalPCM16WAV.parseHeader(replacingUInt32(in: canonical, at: 28, with: 1))
        }
        try expectError(.invalidHeader, "block alignment") {
            try CanonicalPCM16WAV.parseHeader(replacingUInt16(in: canonical, at: 32, with: 4))
        }
        try expectError(.invalidHeader, "bit depth") {
            try CanonicalPCM16WAV.parseHeader(replacingUInt16(in: canonical, at: 34, with: 24))
        }
    }

    private static func rejectsInvalidChunkLayout() throws {
        let canonical = CanonicalPCM16WAV.header(dataByteCount: 8)
        var wrongRIFF = canonical
        wrongRIFF.replaceSubrange(0..<4, with: Data("RIFX".utf8))
        try expectError(.invalidHeader, "RIFF marker") {
            try CanonicalPCM16WAV.parseHeader(wrongRIFF)
        }

        var wrongData = canonical
        wrongData.replaceSubrange(36..<40, with: Data("JUNK".utf8))
        try expectError(.invalidHeader, "data marker") {
            try CanonicalPCM16WAV.parseHeader(wrongData)
        }

        try expectError(.invalidHeader, "RIFF size") {
            try CanonicalPCM16WAV.parseHeader(replacingUInt32(in: canonical, at: 4, with: 37))
        }
    }

    private static func rejectsEmptyAndMisalignedAudio() throws {
        try expectError(.emptyAudio, "empty audio") {
            try CanonicalPCM16WAV.parseHeader(CanonicalPCM16WAV.header(dataByteCount: 0))
        }
        try expectError(.misalignedData, "odd PCM byte count") {
            try CanonicalPCM16WAV.parseHeader(CanonicalPCM16WAV.header(dataByteCount: 3))
        }
    }

    private static func validatesPhysicalFileSize() throws {
        let validURL = try writeWAV(declaredDataByteCount: 8, payloadByteCount: 8)
        defer { try? FileManager.default.removeItem(at: validURL) }
        try expectEqual(
            try CanonicalPCM16WAV.validateFile(at: validURL).frameCount,
            4,
            "validated frame count"
        )

        let truncatedURL = try writeWAV(declaredDataByteCount: 8, payloadByteCount: 6)
        defer { try? FileManager.default.removeItem(at: truncatedURL) }
        try expectError(.physicalSizeMismatch, "truncated payload") {
            try CanonicalPCM16WAV.validateFile(at: truncatedURL)
        }

        let trailingURL = try writeWAV(declaredDataByteCount: 8, payloadByteCount: 10)
        defer { try? FileManager.default.removeItem(at: trailingURL) }
        try expectError(.physicalSizeMismatch, "trailing payload") {
            try CanonicalPCM16WAV.validateFile(at: trailingURL)
        }
    }

    private static func convertsFrameCountsWithoutOverflow() throws {
        try expectEqual(
            try CanonicalPCM16WAV.dataByteCount(forFrameCount: 4),
            8,
            "frame byte count"
        )
        let maximumFrameCount = UInt64(UInt32.max - 36) / 2
        try expectEqual(
            try CanonicalPCM16WAV.dataByteCount(forFrameCount: maximumFrameCount),
            UInt32(maximumFrameCount * 2),
            "maximum frame byte count"
        )
        try expectError(.outputTooLarge, "overflowing frame count") {
            try CanonicalPCM16WAV.dataByteCount(forFrameCount: maximumFrameCount + 1)
        }
    }

    private static func writeWAV(
        declaredDataByteCount: UInt32,
        payloadByteCount: Int
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        var data = CanonicalPCM16WAV.header(dataByteCount: declaredDataByteCount)
        data.append(Data(repeating: 0, count: payloadByteCount))
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func replacingUInt16(
        in data: Data,
        at offset: Int,
        with value: UInt16
    ) -> Data {
        var copy = data
        copy[offset] = UInt8(value & 0xff)
        copy[offset + 1] = UInt8((value >> 8) & 0xff)
        return copy
    }

    private static func replacingUInt32(
        in data: Data,
        at offset: Int,
        with value: UInt32
    ) -> Data {
        var copy = data
        for index in 0..<4 {
            copy[offset + index] = UInt8((value >> UInt32(index * 8)) & 0xff)
        }
        return copy
    }

    private static func expectError<T>(
        _ expected: CanonicalPCM16WAVError,
        _ label: String,
        operation: () throws -> T
    ) throws {
        do {
            _ = try operation()
            throw TestFailure("\(label): expected \(expected)")
        } catch let error as CanonicalPCM16WAVError {
            try expectEqual(error, expected, label)
        }
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
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
