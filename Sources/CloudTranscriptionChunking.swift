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

enum TranscriptionChunkSizingKind: String, Codable, Equatable, Sendable {
    case rawWAV
}

/// How a chunk's size is measured against its ceiling. Cloud uploads count the
/// multipart envelope; local requests count only the WAV file bytes.
enum TranscriptionChunkSizing: Equatable, Sendable {
    case multipart(CloudTranscriptionMultipartLayout)
    case rawWAV

    var kind: TranscriptionChunkSizingKind? {
        switch self {
        case .multipart: return nil
        case .rawWAV: return .rawWAV
        }
    }

    func encodedByteCount(frameCount: UInt64) throws -> UInt64 {
        let (payload, overflow) = frameCount.multipliedReportingOverflow(
            by: UInt64(CanonicalPCM16WAV.bytesPerFrame)
        )
        guard !overflow else {
            throw CloudTranscriptionChunkingError.encodedByteCountOverflow
        }
        let wavByteCount = CanonicalPCM16WAV.headerByteCount + payload
        switch self {
        case .multipart(let layout):
            return try layout.encodedByteCount(
                audioDataByteCount: wavByteCount,
                fileName: CloudTranscriptionChunkPlanner.uploadFileName,
                contentType: "audio/wav"
            )
        case .rawWAV:
            return wavByteCount
        }
    }
}

enum LocalTranscriptionChunkLimits {
    /// 60 s at 16 kHz mono. Gemma 4 silently drops audio past about 2 minutes.
    static let maximumFrameCount: UInt64 = 960_000
    /// 20 s search back from the nominal end for a quiet cut point.
    static let silenceSearchFrameCount: UInt64 = 320_000
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

struct CloudTranscriptionChunk: Codable, Equatable, Sendable {
    let index: Int
    let startFrame: UInt64
    let endFrame: UInt64
    let estimatedEncodedByteCount: UInt64
}

struct CloudTranscriptionChunkPlan: Codable, Equatable, Sendable {
    static let currentAlgorithmVersion = 1

    let algorithmVersion: Int
    let encodedUploadCeilingBytes: UInt64
    let sourceFrameCount: UInt64
    let chunks: [CloudTranscriptionChunk]
    let planID: String
    /// nil = cloud multipart sizing (the original format).
    var sizing: TranscriptionChunkSizingKind? = nil
    /// nil = the original 3 s cloud silence search.
    var silenceSearchFrameCount: UInt64? = nil

    func validate() throws {
        guard algorithmVersion == Self.currentAlgorithmVersion,
              encodedUploadCeilingBytes > 0,
              sourceFrameCount > 0,
              !chunks.isEmpty,
              chunks.first?.startFrame == 0,
              chunks.last?.endFrame == sourceFrameCount else {
            throw CloudTranscriptionChunkingError.invalidChunkPlan
        }

        var expectedStartFrame: UInt64 = 0
        for (expectedIndex, chunk) in chunks.enumerated() {
            guard chunk.index == expectedIndex,
                  chunk.startFrame == expectedStartFrame,
                  chunk.endFrame > chunk.startFrame,
                  chunk.endFrame <= sourceFrameCount,
                  chunk.estimatedEncodedByteCount <= encodedUploadCeilingBytes else {
                throw CloudTranscriptionChunkingError.invalidChunkPlan
            }
            expectedStartFrame = chunk.endFrame
        }
    }
}

struct CloudTranscriptionChunkPlanner {
    static let uploadFileName = "chunk.wav"

    private static let silenceWindowFrameCount: UInt64 = 320
    private static let minimumQuietWindowCount = 10
    private static let defaultSilenceSearchFrameCount: UInt64 = 48_000
    private static let quietRMSThreshold: Int64 = 128

    func plan(
        fileURL: URL,
        source: CloudTranscriptionSourceIdentity,
        wavLayout: CanonicalPCM16WAVLayout,
        multipart: CloudTranscriptionMultipartLayout,
        encodedUploadCeilingBytes: UInt64
    ) throws -> CloudTranscriptionChunkPlan {
        try plan(
            fileURL: fileURL,
            source: source,
            wavLayout: wavLayout,
            sizing: .multipart(multipart),
            ceilingBytes: encodedUploadCeilingBytes,
            silenceSearchFrameCount: nil
        )
    }

    func planLocal(
        fileURL: URL,
        source: CloudTranscriptionSourceIdentity,
        wavLayout: CanonicalPCM16WAVLayout,
        maximumFrameCount: UInt64 = LocalTranscriptionChunkLimits.maximumFrameCount,
        silenceSearchFrameCount: UInt64 = LocalTranscriptionChunkLimits.silenceSearchFrameCount
    ) throws -> CloudTranscriptionChunkPlan {
        try plan(
            fileURL: fileURL,
            source: source,
            wavLayout: wavLayout,
            sizing: .rawWAV,
            ceilingBytes: try TranscriptionChunkSizing.rawWAV.encodedByteCount(
                frameCount: maximumFrameCount
            ),
            silenceSearchFrameCount: silenceSearchFrameCount
        )
    }

    func plan(
        fileURL: URL,
        source: CloudTranscriptionSourceIdentity,
        wavLayout: CanonicalPCM16WAVLayout,
        sizing: TranscriptionChunkSizing,
        ceilingBytes: UInt64,
        silenceSearchFrameCount: UInt64?
    ) throws -> CloudTranscriptionChunkPlan {
        let encodedUploadCeilingBytes = ceilingBytes
        let searchFrameCount = silenceSearchFrameCount
            ?? Self.defaultSilenceSearchFrameCount
        let validatedLayout = try CanonicalPCM16WAV.validateFile(at: fileURL)
        guard validatedLayout == wavLayout,
              source.audioFileName == fileURL.lastPathComponent,
              source.physicalByteCount == wavLayout.dataOffset + wavLayout.dataByteCount,
              source.dataByteCount == wavLayout.dataByteCount,
              source.frameCount == wavLayout.frameCount,
              source.frameCount > 0 else {
            throw CloudTranscriptionChunkingError.invalidSourceIdentity
        }

        let zeroPayloadEncodedByteCount = try sizing.encodedByteCount(frameCount: 0)
        let bytesPerFrame = UInt64(CanonicalPCM16WAV.bytesPerFrame)
        guard encodedUploadCeilingBytes >= zeroPayloadEncodedByteCount,
              encodedUploadCeilingBytes - zeroPayloadEncodedByteCount >= bytesPerFrame else {
            throw CloudTranscriptionChunkingError.encodedUploadCeilingTooSmall
        }
        let maximumFrameCount = (
            encodedUploadCeilingBytes - zeroPayloadEncodedByteCount
        ) / bytesPerFrame
        guard maximumFrameCount > 0 else {
            throw CloudTranscriptionChunkingError.encodedUploadCeilingTooSmall
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var chunks: [CloudTranscriptionChunk] = []
        var startFrame: UInt64 = 0
        while startFrame < source.frameCount {
            try Task.checkCancellation()
            let remainingFrameCount = source.frameCount - startFrame
            let nominalEndFrame = startFrame + min(maximumFrameCount, remainingFrameCount)
            let endFrame: UInt64
            if nominalEndFrame == source.frameCount {
                endFrame = nominalEndFrame
            } else {
                endFrame = try silenceBoundary(
                    handle: handle,
                    wavLayout: wavLayout,
                    startFrame: startFrame,
                    nominalEndFrame: nominalEndFrame,
                    searchFrameCount: searchFrameCount
                ) ?? nominalEndFrame
            }
            guard endFrame > startFrame else {
                throw CloudTranscriptionChunkingError.invalidChunkPlan
            }

            let frameCount = endFrame - startFrame
            let estimatedEncodedByteCount = try sizing.encodedByteCount(
                frameCount: frameCount
            )
            guard estimatedEncodedByteCount <= encodedUploadCeilingBytes else {
                throw CloudTranscriptionChunkingError.invalidChunkPlan
            }
            chunks.append(CloudTranscriptionChunk(
                index: chunks.count,
                startFrame: startFrame,
                endFrame: endFrame,
                estimatedEncodedByteCount: estimatedEncodedByteCount
            ))
            startFrame = endFrame
        }

        let plan = CloudTranscriptionChunkPlan(
            algorithmVersion: CloudTranscriptionChunkPlan.currentAlgorithmVersion,
            encodedUploadCeilingBytes: encodedUploadCeilingBytes,
            sourceFrameCount: source.frameCount,
            chunks: chunks,
            planID: makePlanID(
                encodedUploadCeilingBytes: encodedUploadCeilingBytes,
                sourceFrameCount: source.frameCount,
                chunks: chunks,
                sizing: sizing.kind,
                silenceSearchFrameCount: silenceSearchFrameCount
            ),
            sizing: sizing.kind,
            silenceSearchFrameCount: silenceSearchFrameCount
        )
        try plan.validate()
        return plan
    }

    private func silenceBoundary(
        handle: FileHandle,
        wavLayout: CanonicalPCM16WAVLayout,
        startFrame: UInt64,
        nominalEndFrame: UInt64,
        searchFrameCount: UInt64
    ) throws -> UInt64? {
        let searchStartFrame = max(
            startFrame,
            nominalEndFrame > searchFrameCount
                ? nominalEndFrame - searchFrameCount
                : 0
        )
        let searchableFrameCount = nominalEndFrame - searchStartFrame
        let completeWindowCount = searchableFrameCount / Self.silenceWindowFrameCount
        guard completeWindowCount >= UInt64(Self.minimumQuietWindowCount) else {
            return nil
        }

        try handle.seek(
            toOffset: wavLayout.dataOffset
                + searchStartFrame * UInt64(CanonicalPCM16WAV.bytesPerFrame)
        )
        let windowByteCount = Int(
            Self.silenceWindowFrameCount * UInt64(CanonicalPCM16WAV.bytesPerFrame)
        )
        var quietRunStartFrame: UInt64?
        var quietRunWindowCount = 0
        var nearestBoundary: UInt64?

        for windowIndex in 0..<completeWindowCount {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: windowByteCount),
                  data.count == windowByteCount else {
                throw CloudTranscriptionChunkingError.shortSourceRead
            }
            let windowStartFrame = searchStartFrame
                + windowIndex * Self.silenceWindowFrameCount
            if isQuietWindow(data) {
                if quietRunStartFrame == nil {
                    quietRunStartFrame = windowStartFrame
                }
                quietRunWindowCount += 1
            } else {
                recordQuietRunBoundary(
                    startFrame: quietRunStartFrame,
                    windowCount: quietRunWindowCount,
                    chunkStartFrame: startFrame,
                    nearestBoundary: &nearestBoundary
                )
                quietRunStartFrame = nil
                quietRunWindowCount = 0
            }
        }
        recordQuietRunBoundary(
            startFrame: quietRunStartFrame,
            windowCount: quietRunWindowCount,
            chunkStartFrame: startFrame,
            nearestBoundary: &nearestBoundary
        )
        return nearestBoundary
    }

    private func isQuietWindow(_ data: Data) -> Bool {
        var squareSum: Int64 = 0
        var offset = 0
        while offset < data.count {
            let bits = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            let sample = Int64(Int16(bitPattern: bits))
            squareSum += sample * sample
            offset += Int(CanonicalPCM16WAV.bytesPerFrame)
        }
        let sampleCount = Int64(data.count / Int(CanonicalPCM16WAV.bytesPerFrame))
        let thresholdSquare = Self.quietRMSThreshold * Self.quietRMSThreshold
        return squareSum <= thresholdSquare * sampleCount
    }

    private func recordQuietRunBoundary(
        startFrame: UInt64?,
        windowCount: Int,
        chunkStartFrame: UInt64,
        nearestBoundary: inout UInt64?
    ) {
        guard let startFrame,
              windowCount >= Self.minimumQuietWindowCount else {
            return
        }
        let runFrameCount = UInt64(windowCount) * Self.silenceWindowFrameCount
        let midpoint = startFrame + runFrameCount / 2
        guard midpoint > chunkStartFrame else { return }
        nearestBoundary = midpoint
    }

    private func makePlanID(
        encodedUploadCeilingBytes: UInt64,
        sourceFrameCount: UInt64,
        chunks: [CloudTranscriptionChunk],
        sizing: TranscriptionChunkSizingKind?,
        silenceSearchFrameCount: UInt64?
    ) -> String {
        var canonical = "v=\(CloudTranscriptionChunkPlan.currentAlgorithmVersion)"
        canonical += ";ceiling=\(encodedUploadCeilingBytes)"
        canonical += ";frames=\(sourceFrameCount)"
        for chunk in chunks {
            canonical += ";\(chunk.index):\(chunk.startFrame)-\(chunk.endFrame):\(chunk.estimatedEncodedByteCount)"
        }
        if let sizing {
            canonical += ";sizing=\(sizing.rawValue)"
        }
        if let silenceSearchFrameCount {
            canonical += ";search=\(silenceSearchFrameCount)"
        }
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct CloudTranscriptionMaterializedChunk: Sendable {
    let fileURL: URL
    let encodedByteCount: UInt64
    let cleanup: @Sendable () -> Void
}

struct CloudTranscriptionChunkMaterializer: Sendable {
    let temporaryRoot: URL
    let copyBufferByteCount: Int
    let closeOutput: @Sendable (FileHandle) throws -> Void

    init(
        temporaryRoot: URL,
        copyBufferByteCount: Int,
        closeOutput: @escaping @Sendable (FileHandle) throws -> Void = { handle in
            try handle.close()
        }
    ) {
        self.temporaryRoot = temporaryRoot
        self.copyBufferByteCount = copyBufferByteCount
        self.closeOutput = closeOutput
    }

    func materialize(
        sourceURL: URL,
        sourceLayout: CanonicalPCM16WAVLayout,
        chunk: CloudTranscriptionChunk,
        multipart: CloudTranscriptionMultipartLayout
    ) throws -> CloudTranscriptionMaterializedChunk {
        try materialize(
            sourceURL: sourceURL,
            sourceLayout: sourceLayout,
            chunk: chunk,
            sizing: .multipart(multipart)
        )
    }

    func materialize(
        sourceURL: URL,
        sourceLayout: CanonicalPCM16WAVLayout,
        chunk: CloudTranscriptionChunk,
        sizing: TranscriptionChunkSizing
    ) throws -> CloudTranscriptionMaterializedChunk {
        guard copyBufferByteCount > 0 else {
            throw CloudTranscriptionChunkingError.invalidReadBufferByteCount
        }
        guard chunk.startFrame < chunk.endFrame,
              chunk.endFrame <= sourceLayout.frameCount else {
            throw CloudTranscriptionChunkingError.invalidChunkPlan
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        let attemptDirectory = temporaryRoot.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: attemptDirectory,
            withIntermediateDirectories: false
        )
        var shouldCleanup = true
        defer {
            if shouldCleanup {
                try? fileManager.removeItem(at: attemptDirectory)
            }
        }

        let fileURL = attemptDirectory.appendingPathComponent(
            CloudTranscriptionChunkPlanner.uploadFileName
        )
        let frameCount = chunk.endFrame - chunk.startFrame
        let dataByteCount = try CanonicalPCM16WAV.dataByteCount(
            forFrameCount: frameCount
        )
        try CanonicalPCM16WAV.header(dataByteCount: dataByteCount).write(
            to: fileURL,
            options: .atomic
        )
        let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? sourceHandle.close() }
        let outputHandle = try FileHandle(forWritingTo: fileURL)
        var outputHandleOpen = true
        defer {
            if outputHandleOpen {
                try? outputHandle.close()
            }
        }
        try sourceHandle.seek(
            toOffset: sourceLayout.dataOffset
                + chunk.startFrame * UInt64(CanonicalPCM16WAV.bytesPerFrame)
        )
        try outputHandle.seekToEnd()

        var remainingByteCount = UInt64(dataByteCount)
        while remainingByteCount > 0 {
            try Task.checkCancellation()
            let requestedByteCount = Int(min(
                UInt64(copyBufferByteCount),
                remainingByteCount
            ))
            guard let data = try sourceHandle.read(upToCount: requestedByteCount),
                  data.count == requestedByteCount else {
                throw CloudTranscriptionChunkingError.shortSourceRead
            }
            try outputHandle.write(contentsOf: data)
            remainingByteCount -= UInt64(data.count)
        }
        try outputHandle.synchronize()
        try closeOutput(outputHandle)
        outputHandleOpen = false
        let outputLayout = try CanonicalPCM16WAV.validateFile(at: fileURL)
        guard outputLayout.dataByteCount == UInt64(dataByteCount),
              outputLayout.frameCount == frameCount else {
            throw CloudTranscriptionChunkingError.materializedChunkMismatch
        }
        let encodedByteCount = try sizing.encodedByteCount(
            frameCount: outputLayout.frameCount
        )
        guard encodedByteCount == chunk.estimatedEncodedByteCount else {
            throw CloudTranscriptionChunkingError.materializedChunkMismatch
        }

        shouldCleanup = false
        return CloudTranscriptionMaterializedChunk(
            fileURL: fileURL,
            encodedByteCount: encodedByteCount,
            cleanup: {
                try? FileManager.default.removeItem(at: attemptDirectory)
            }
        )
    }
}

enum CloudTranscriptionChunkingError: Error, Equatable {
    case invalidBoundaryByteCount
    case invalidReadBufferByteCount
    case encodedByteCountOverflow
    case sourceByteCountOverflow
    case invalidSourceIdentity
    case encodedUploadCeilingTooSmall
    case invalidChunkPlan
    case shortSourceRead
    case materializedChunkMismatch
}
