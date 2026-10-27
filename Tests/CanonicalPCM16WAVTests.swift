import Foundation

@main
struct CanonicalPCM16WAVTests {
    static func main() {
        do {
            try canonicalHeaderRoundTrips()
            try parsesCanonicalHeaderFromNonzeroIndexDataSlice()
            try rejectsNonCanonicalFormatFields()
            try rejectsInvalidChunkLayout()
            try rejectsEmptyAndMisalignedAudio()
            try validatesPhysicalFileSize()
            try convertsFrameCountsWithoutOverflow()
            try canonicalCopySkipsExtraChunks()
            try canonicalCopyAcceptsExtensiblePCM()
            try canonicalCopyRejectsOtherFormats()
            try acceptanceStaysFixed()
            print("CanonicalPCM16WAVTests passed")
        } catch {
            fputs("CanonicalPCM16WAVTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func chunk(_ id: String, _ payload: Data) -> Data {
        var data = Data(id.utf8)
        var size = UInt32(payload.count).littleEndian
        data.append(Data(bytes: &size, count: 4))
        data.append(payload)
        if payload.count % 2 == 1 { data.append(0) }
        return data
    }

    private static func fmtPayload(
        tag: UInt16 = 1,
        channels: UInt16 = 1,
        rate: UInt32 = 16_000,
        bits: UInt16 = 16,
        extensible: Bool = false
    ) -> Data {
        var data = Data()
        func u16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        u16(extensible ? 0xFFFE : tag)
        u16(channels)
        u32(rate)
        u32(rate * UInt32(channels) * UInt32(bits / 8))
        u16(channels * (bits / 8))
        u16(bits)
        if extensible {
            u16(22)
            u16(bits)
            u32(4)
            // KSDATAFORMAT_SUBTYPE_PCM
            data.append(contentsOf: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
                                     0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        }
        return data
    }

    private static func riff(_ chunks: [Data]) -> Data {
        let body = chunks.reduce(Data("WAVE".utf8), +)
        var data = Data("RIFF".utf8)
        var size = UInt32(body.count).littleEndian
        data.append(Data(bytes: &size, count: 4))
        data.append(body)
        return data
    }

    private static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
    }

    private static func canonicalCopySkipsExtraChunks() throws {
        let samples = Data([1, 0, 2, 0, 3, 0, 4, 0])
        let source = temporaryURL()
        let destination = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        try riff([
            chunk("JUNK", Data(count: 28)),
            chunk("fmt ", fmtPayload()),
            chunk("LIST", Data("INFOISFT".utf8) + Data([1])),
            chunk("data", samples),
            chunk("LIST", Data(count: 6))
        ]).write(to: source)

        let layout = try CanonicalPCM16WAV.writeCanonicalCopy(of: source, to: destination)
        try expectEqual(layout.frameCount, 4, "frames copied")
        try expectEqual(try CanonicalPCM16WAV.validateFile(at: destination), layout, "copy is canonical")
        let copied = try Data(contentsOf: destination)
        try expectEqual(copied.suffix(8), samples, "samples preserved")
    }

    private static func canonicalCopyAcceptsExtensiblePCM() throws {
        let source = temporaryURL()
        let destination = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        try riff([
            chunk("fmt ", fmtPayload(extensible: true)),
            chunk("data", Data([9, 0, 8, 0]))
        ]).write(to: source)
        let layout = try CanonicalPCM16WAV.writeCanonicalCopy(of: source, to: destination)
        try expectEqual(layout.frameCount, 2, "extensible PCM accepted")
    }

    private static func canonicalCopyRejectsOtherFormats() throws {
        for fmt in [fmtPayload(channels: 2), fmtPayload(rate: 44_100), fmtPayload(tag: 3, bits: 32)] {
            let source = temporaryURL()
            let destination = temporaryURL()
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: destination)
            }
            try riff([chunk("fmt ", fmt), chunk("data", Data([1, 0, 2, 0, 3, 0, 4, 0]))])
                .write(to: source)
            do {
                _ = try CanonicalPCM16WAV.writeCanonicalCopy(of: source, to: destination)
                throw TestFailure("non-16 kHz mono PCM16 accepted")
            } catch CanonicalPCM16WAVError.invalidHeader {
            }
            try expectEqual(
                FileManager.default.fileExists(atPath: destination.path),
                false,
                "no partial output"
            )
        }
    }

    /// Which files are accepted, and what they hold, pinned before this
    /// code is shared with the iPhone app (#634). Error names are left out
    /// on purpose: only acceptance must stay the same.
    private static func acceptanceStaysFixed() throws {
        let canonical = CanonicalPCM16WAV.header(dataByteCount: 8)
        let validated: [(String, Data)] = [
            ("canonical", canonical + Data(count: 8)),
            ("empty", CanonicalPCM16WAV.header(dataByteCount: 0)),
            ("odd byte count", CanonicalPCM16WAV.header(dataByteCount: 3) + Data(count: 3)),
            ("truncated", canonical + Data(count: 6)),
            ("trailing byte", canonical + Data(count: 9)),
            ("short header", canonical.prefix(20)),
            ("RIFX", canonical.replacingBytes(0..<4, with: Data("RIFX".utf8)) + Data(count: 8)),
            ("WAVX", canonical.replacingBytes(8..<12, with: Data("WAVX".utf8)) + Data(count: 8)),
            ("fmt marker", canonical.replacingBytes(12..<16, with: Data("fmtx".utf8)) + Data(count: 8)),
            ("fmt size 18", replacingUInt32(in: canonical, at: 16, with: 18) + Data(count: 8)),
            ("float tag", replacingUInt16(in: canonical, at: 20, with: 3) + Data(count: 8)),
            ("stereo", replacingUInt16(in: canonical, at: 22, with: 2) + Data(count: 8)),
            ("44.1 kHz", replacingUInt32(in: canonical, at: 24, with: 44_100) + Data(count: 8)),
            ("byte rate", replacingUInt32(in: canonical, at: 28, with: 1) + Data(count: 8)),
            ("block align", replacingUInt16(in: canonical, at: 32, with: 4) + Data(count: 8)),
            ("24-bit", replacingUInt16(in: canonical, at: 34, with: 24) + Data(count: 8)),
            ("data marker", canonical.replacingBytes(36..<40, with: Data("JUNK".utf8)) + Data(count: 8)),
            ("RIFF size", replacingUInt32(in: canonical, at: 4, with: 37) + Data(count: 8)),
            ("overflowing size", replacingUInt32(
                in: replacingUInt32(in: canonical, at: 40, with: .max),
                at: 4,
                with: 35
            ) + Data(count: 8))
        ]
        var lines = ["canonical header for 8 data bytes: " + headerHex(canonical)]
        for (label, bytes) in validated {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            try bytes.write(to: url)
            let parsed = outcome { try CanonicalPCM16WAV.parseHeader(Data(bytes.prefix(44))) }
            let validatedFile = outcome { try CanonicalPCM16WAV.validateFile(at: url) }
            lines.append("validate \(label): header \(parsed), file \(validatedFile)")
        }

        let samples = Data([1, 0, 2, 0, 3, 0, 4, 0])
        var extensibleFloat = fmtPayload(extensible: true)
        extensibleFloat[24] = 3
        let copied: [(String, Data)] = [
            ("canonical", riff([chunk("fmt ", fmtPayload()), chunk("data", samples)])),
            ("extra chunks", riff([
                chunk("JUNK", Data(repeating: 9, count: 28)),
                chunk("fmt ", fmtPayload()),
                chunk("LIST", Data(repeating: 9, count: 5)),
                chunk("data", samples)
            ])),
            ("extensible", riff([chunk("fmt ", fmtPayload(extensible: true)), chunk("data", samples)])),
            ("extensible float", riff([chunk("fmt ", extensibleFloat), chunk("data", samples)])),
            ("extensible fmt size 18", riff([
                chunk("fmt ", fmtPayload(extensible: true).prefix(18)),
                chunk("data", samples)
            ])),
            ("stereo", riff([chunk("fmt ", fmtPayload(channels: 2)), chunk("data", samples)])),
            ("44.1 kHz", riff([chunk("fmt ", fmtPayload(rate: 44_100)), chunk("data", samples)])),
            ("float", riff([chunk("fmt ", fmtPayload(tag: 3, bits: 32)), chunk("data", samples)])),
            ("fmt too large", riff([chunk("fmt ", fmtPayload() + Data(count: 50)), chunk("data", samples)])),
            ("fmt too small", riff([chunk("fmt ", fmtPayload().prefix(14)), chunk("data", samples)])),
            ("odd fmt size", riff([chunk("fmt ", fmtPayload() + Data([0])), chunk("data", samples)])),
            ("supported then unsupported fmt", riff([
                chunk("fmt ", fmtPayload()),
                chunk("fmt ", fmtPayload(channels: 2)),
                chunk("data", samples)
            ])),
            ("unsupported then supported fmt", riff([
                chunk("fmt ", fmtPayload(channels: 2)),
                chunk("fmt ", fmtPayload()),
                chunk("data", samples)
            ])),
            ("data before fmt", riff([chunk("data", samples), chunk("fmt ", fmtPayload())])),
            ("no data", riff([chunk("fmt ", fmtPayload())])),
            ("empty data", riff([chunk("fmt ", fmtPayload()), chunk("data", Data())])),
            ("odd data", riff([chunk("fmt ", fmtPayload()), chunk("data", Data([1, 0, 2, 0, 3]))])),
            // The chunk declares 64 bytes but only 8 follow. Today the copy
            // keeps what is there.
            ("data past the end", riff([chunk("fmt ", fmtPayload())])
                + Data("data".utf8) + Data([0x40, 0, 0, 0]) + samples),
            ("not RIFF", riff([chunk("fmt ", fmtPayload()), chunk("data", samples)])
                .replacingBytes(0..<4, with: Data("RIFX".utf8))),
            ("not WAVE", riff([chunk("fmt ", fmtPayload()), chunk("data", samples)])
                .replacingBytes(8..<12, with: Data("AVI ".utf8))),
            ("too short", Data("RIFF".utf8))
        ]
        for (label, bytes) in copied {
            let source = temporaryURL()
            let destination = temporaryURL()
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: destination)
            }
            try bytes.write(to: source)
            let result = outcome {
                try CanonicalPCM16WAV.writeCanonicalCopy(of: source, to: destination)
            }
            let output: String
            if let written = try? Data(contentsOf: destination) {
                let audio = written.dropFirst(44).map { String(format: "%02x", $0) }.joined()
                let headerMatches = written.prefix(44)
                    == CanonicalPCM16WAV.header(dataByteCount: UInt32(written.count - 44))
                output = "audio \(audio)" + (headerMatches ? "" : ", other header")
            } else {
                output = "no output"
            }
            lines.append("copy \(label): \(result), \(output)")
        }
        let pinned = """
            canonical header for 8 data bytes: 52494646 2c000000 57415645 666d7420 10000000 0100 0100 803e0000 007d0000 0200 1000 64617461 08000000
            validate canonical: header frames 4, file frames 4
            validate empty: header rejected, file rejected
            validate odd byte count: header rejected, file rejected
            validate truncated: header frames 4, file rejected
            validate trailing byte: header frames 4, file rejected
            validate short header: header rejected, file rejected
            validate RIFX: header rejected, file rejected
            validate WAVX: header rejected, file rejected
            validate fmt marker: header rejected, file rejected
            validate fmt size 18: header rejected, file rejected
            validate float tag: header rejected, file rejected
            validate stereo: header rejected, file rejected
            validate 44.1 kHz: header rejected, file rejected
            validate byte rate: header rejected, file rejected
            validate block align: header rejected, file rejected
            validate 24-bit: header rejected, file rejected
            validate data marker: header rejected, file rejected
            validate RIFF size: header rejected, file rejected
            validate overflowing size: header rejected, file rejected
            copy canonical: frames 4, audio 0100020003000400
            copy extra chunks: frames 4, audio 0100020003000400
            copy extensible: frames 4, audio 0100020003000400
            copy extensible float: rejected, no output
            copy extensible fmt size 18: rejected, no output
            copy stereo: rejected, no output
            copy 44.1 kHz: rejected, no output
            copy float: rejected, no output
            copy fmt too large: rejected, no output
            copy fmt too small: rejected, no output
            copy odd fmt size: frames 4, audio 0100020003000400
            copy supported then unsupported fmt: rejected, no output
            copy unsupported then supported fmt: frames 4, audio 0100020003000400
            copy data before fmt: rejected, no output
            copy no data: rejected, no output
            copy empty data: rejected, no output
            copy odd data: frames 2, audio 01000200
            copy data past the end: frames 4, audio 0100020003000400
            copy not RIFF: rejected, no output
            copy not WAVE: rejected, no output
            copy too short: rejected, no output
            """
        try expectEqual(lines.joined(separator: "\n"), pinned, "WAV acceptance")
    }

    /// "frames N" when accepted, "rejected" for a WAV format error, and the
    /// error itself for anything else, such as a file that can't be read.
    private static func outcome(_ operation: () throws -> CanonicalPCM16WAVLayout) -> String {
        do {
            return "frames \(try operation().frameCount)"
        } catch is CanonicalPCM16WAVError {
            return "rejected"
        } catch {
            return "error \(error)"
        }
    }

    /// The canonical header, grouped by field.
    private static func headerHex(_ header: Data) -> String {
        let widths = [4, 4, 4, 4, 4, 2, 2, 4, 4, 2, 2, 4, 4]
        var offset = header.startIndex
        return widths.map { width in
            defer { offset += width }
            return header[offset..<(offset + width)].map { String(format: "%02x", $0) }.joined()
        }.joined(separator: " ")
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

    private static func parsesCanonicalHeaderFromNonzeroIndexDataSlice() throws {
        let header = CanonicalPCM16WAV.header(dataByteCount: 8)
        var container = Data(repeating: 0xaa, count: 7)
        container.append(header)
        container.append(Data(repeating: 0xbb, count: 3))
        let slice = container[7..<(7 + header.count)]
        guard slice.startIndex == 7 else {
            throw TestFailure("fixture must preserve a nonzero start index")
        }

        try expectEqual(
            CanonicalPCM16WAV.declaredDataByteCount(in: slice),
            8,
            "sliced declared byte count"
        )
        try expectEqual(
            try CanonicalPCM16WAV.parseHeader(slice).frameCount,
            4,
            "sliced frame count"
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

private extension Data {
    func replacingBytes(_ range: Range<Int>, with bytes: Data) -> Data {
        var copy = self
        copy.replaceSubrange(range, with: bytes)
        return copy
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
