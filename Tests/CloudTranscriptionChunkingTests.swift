import CryptoKit
import Foundation

@main
struct CloudTranscriptionChunkingTests {
    static func main() {
        do {
            try multipartSizeMatchesEncodedBodyWithLanguage()
            try multipartSizeMatchesEncodedBodyWithoutLanguage()
            try multipartSizeUsesExactFileMetadata()
            try sourceIdentityHashesCanonicalWAVIncrementally()
            try sourceIdentitySupportsBuffersSmallerThanTheFile()
            try sourceIdentityRejectsInvalidReadBufferSize()
            print("CloudTranscriptionChunkingTests passed")
        } catch {
            fputs("CloudTranscriptionChunkingTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func multipartSizeMatchesEncodedBodyWithLanguage() throws {
        let layout = CloudTranscriptionMultipartLayout(
            model: "whisper-large-v3",
            responseFormat: "verbose_json",
            language: "ko",
            boundaryByteCount: 36
        )
        let boundary = String(repeating: "b", count: 36)
        let body = makeMultipartBody(
            audioData: Data(repeating: 7, count: 1_337),
            fileName: "meeting.wav",
            contentType: "audio/wav",
            model: layout.model,
            responseFormat: layout.responseFormat,
            language: layout.language,
            boundary: boundary
        )
        try expectEqual(
            try layout.encodedByteCount(
                audioDataByteCount: 1_337,
                fileName: "meeting.wav",
                contentType: "audio/wav"
            ),
            UInt64(body.count),
            "multipart size with language"
        )
    }

    private static func multipartSizeMatchesEncodedBodyWithoutLanguage() throws {
        let layout = CloudTranscriptionMultipartLayout(
            model: "whisper-1",
            responseFormat: "json",
            language: nil,
            boundaryByteCount: 36
        )
        let boundary = String(repeating: "x", count: 36)
        let body = makeMultipartBody(
            audioData: Data(repeating: 1, count: 64),
            fileName: "voice.mp3",
            contentType: "audio/mpeg",
            model: layout.model,
            responseFormat: layout.responseFormat,
            language: layout.language,
            boundary: boundary
        )
        try expectEqual(
            try layout.encodedByteCount(
                audioDataByteCount: 64,
                fileName: "voice.mp3",
                contentType: "audio/mpeg"
            ),
            UInt64(body.count),
            "multipart size without language"
        )
    }

    private static func multipartSizeUsesExactFileMetadata() throws {
        let layout = CloudTranscriptionMultipartLayout(
            model: "m",
            responseFormat: "text",
            language: "en-US",
            boundaryByteCount: 12
        )
        let wavCount = try layout.encodedByteCount(
            audioDataByteCount: 100,
            fileName: "a.wav",
            contentType: "audio/wav"
        )
        let mp3Count = try layout.encodedByteCount(
            audioDataByteCount: 100,
            fileName: "long-name.mp3",
            contentType: "audio/mpeg"
        )
        guard wavCount != mp3Count else {
            throw TestFailure("filename and content type must affect multipart size")
        }
    }

    private static func sourceIdentityHashesCanonicalWAVIncrementally() throws {
        let payload = Data((0..<32).map(UInt8.init))
        let url = try writeCanonicalWAV(payload: payload)
        defer { try? FileManager.default.removeItem(at: url) }
        let layout = try CanonicalPCM16WAV.validateFile(at: url)
        let identity = try CloudTranscriptionSourceIdentityBuilder.make(
            fileURL: url,
            layout: layout,
            readBufferByteCount: 7
        )
        let completeData = try Data(contentsOf: url)
        let expectedHash = SHA256.hash(data: completeData)
            .map { String(format: "%02x", $0) }
            .joined()

        try expectEqual(identity.audioFileName, url.lastPathComponent, "audio filename")
        try expectEqual(identity.physicalByteCount, UInt64(completeData.count), "physical size")
        try expectEqual(identity.sha256, expectedHash, "streaming SHA-256")
        try expectEqual(identity.dataByteCount, UInt64(payload.count), "data byte count")
        try expectEqual(identity.frameCount, UInt64(payload.count / 2), "frame count")
    }

    private static func sourceIdentitySupportsBuffersSmallerThanTheFile() throws {
        let payload = Data(repeating: 0x5a, count: 2 * 128 * 1_024)
        let url = try writeCanonicalWAV(payload: payload)
        defer { try? FileManager.default.removeItem(at: url) }
        let layout = try CanonicalPCM16WAV.validateFile(at: url)
        let smallBuffer = try CloudTranscriptionSourceIdentityBuilder.make(
            fileURL: url,
            layout: layout,
            readBufferByteCount: 31
        )
        let largeBuffer = try CloudTranscriptionSourceIdentityBuilder.make(
            fileURL: url,
            layout: layout,
            readBufferByteCount: 65_536
        )
        try expectEqual(smallBuffer, largeBuffer, "identity independent of read buffer")
    }

    private static func sourceIdentityRejectsInvalidReadBufferSize() throws {
        let url = try writeCanonicalWAV(payload: Data(repeating: 0, count: 2))
        defer { try? FileManager.default.removeItem(at: url) }
        let layout = try CanonicalPCM16WAV.validateFile(at: url)
        do {
            _ = try CloudTranscriptionSourceIdentityBuilder.make(
                fileURL: url,
                layout: layout,
                readBufferByteCount: 0
            )
            throw TestFailure("zero read buffer must fail")
        } catch CloudTranscriptionChunkingError.invalidReadBufferByteCount {
            // expected
        }
    }

    private static func makeMultipartBody(
        audioData: Data,
        fileName: String,
        contentType: String,
        model: String,
        responseFormat: String,
        language: String?,
        boundary: String
    ) -> Data {
        var body = Data()
        func append(_ value: String) { body.append(Data(value.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("\(responseFormat)\r\n")
        if let language, !language.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            append("\(language)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(audioData)
        append("\r\n")
        append("--\(boundary)--\r\n")
        return body
    }

    private static func writeCanonicalWAV(payload: Data) throws -> URL {
        guard payload.count <= Int(UInt32.max), payload.count % 2 == 0 else {
            throw TestFailure("invalid fixture payload")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        var data = CanonicalPCM16WAV.header(dataByteCount: UInt32(payload.count))
        data.append(payload)
        try data.write(to: url, options: .atomic)
        return url
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
