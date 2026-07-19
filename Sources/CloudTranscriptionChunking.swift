import CryptoKit
import Foundation

struct CloudTranscriptionMultipartLayout: Equatable, Sendable {
    let model: String
    let responseFormat: String
    let language: String?
    let boundaryByteCount: Int

    init(
        model: String,
        responseFormat: String,
        language: String?,
        boundaryByteCount: Int = 36
    ) {
        self.model = model
        self.responseFormat = responseFormat
        self.language = language
        self.boundaryByteCount = boundaryByteCount
    }

    func encodedByteCount(
        audioDataByteCount: UInt64,
        fileName: String,
        contentType: String
    ) throws -> UInt64 {
        guard boundaryByteCount > 0 else {
            throw CloudTranscriptionChunkingError.invalidBoundaryByteCount
        }
        let boundary = String(repeating: "b", count: boundaryByteCount)
        var byteCount: UInt64 = 0

        func append(_ value: String) throws {
            let (next, overflow) = byteCount.addingReportingOverflow(
                UInt64(value.utf8.count)
            )
            guard !overflow else {
                throw CloudTranscriptionChunkingError.encodedByteCountOverflow
            }
            byteCount = next
        }

        try append("--\(boundary)\r\n")
        try append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        try append("\(model)\r\n")
        try append("--\(boundary)\r\n")
        try append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        try append("\(responseFormat)\r\n")
        if let language, !language.isEmpty {
            try append("--\(boundary)\r\n")
            try append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            try append("\(language)\r\n")
        }
        try append("--\(boundary)\r\n")
        try append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        try append("Content-Type: \(contentType)\r\n\r\n")
        let (withAudio, audioOverflow) = byteCount.addingReportingOverflow(
            audioDataByteCount
        )
        guard !audioOverflow else {
            throw CloudTranscriptionChunkingError.encodedByteCountOverflow
        }
        byteCount = withAudio
        try append("\r\n")
        try append("--\(boundary)--\r\n")
        return byteCount
    }
}

struct CloudTranscriptionSourceIdentity: Codable, Equatable, Sendable {
    let audioFileName: String
    let physicalByteCount: UInt64
    let sha256: String
    let dataByteCount: UInt64
    let frameCount: UInt64
}

enum CloudTranscriptionSourceIdentityBuilder {
    static func make(
        fileURL: URL,
        layout: CanonicalPCM16WAVLayout,
        readBufferByteCount: Int = 1_048_576
    ) throws -> CloudTranscriptionSourceIdentity {
        guard readBufferByteCount > 0 else {
            throw CloudTranscriptionChunkingError.invalidReadBufferByteCount
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        var physicalByteCount: UInt64 = 0
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: readBufferByteCount),
                  !data.isEmpty else {
                break
            }
            let (nextByteCount, overflow) = physicalByteCount.addingReportingOverflow(
                UInt64(data.count)
            )
            guard !overflow else {
                throw CloudTranscriptionChunkingError.sourceByteCountOverflow
            }
            physicalByteCount = nextByteCount
            hasher.update(data: data)
        }

        guard physicalByteCount == layout.dataOffset + layout.dataByteCount else {
            throw CanonicalPCM16WAVError.physicalSizeMismatch
        }
        let digest = hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        return CloudTranscriptionSourceIdentity(
            audioFileName: fileURL.lastPathComponent,
            physicalByteCount: physicalByteCount,
            sha256: digest,
            dataByteCount: layout.dataByteCount,
            frameCount: layout.frameCount
        )
    }
}

enum CloudTranscriptionChunkingError: Error, Equatable {
    case invalidBoundaryByteCount
    case invalidReadBufferByteCount
    case encodedByteCountOverflow
    case sourceByteCountOverflow
}
