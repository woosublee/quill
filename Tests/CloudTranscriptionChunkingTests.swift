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
            try plannerCoversExactCeilingInOneChunk()
            try plannerCreatesContiguousChunksAndOneFrameRemainder()
            try plannerRejectsCeilingWithoutOneFrameCapacity()
            try plannerChoosesNearestQuietRunMidpoint()
            try plannerFallsBackToNominalBoundaryWithoutSilence()
            try plannerDoesNotSearchAfterNominalBoundary()
            try plannerIsDeterministic()
            try materializerCopiesExactFrameRanges()
            try materializerUsesBoundedBufferForLargeChunk()
            try materializerCleanupRemovesAttemptDirectory()
            try materializerRejectsShortSourceReadAndCleansPartialOutput()
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

    private static func plannerCoversExactCeilingInOneChunk() throws {
        let samples = Array(repeating: Int16(2_000), count: 5_000)
        let fixture = try makePlannerFixture(samples: samples)
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let multipart = plannerMultipartLayout
        let ceiling = try encodedCeiling(frameCount: UInt64(samples.count), multipart: multipart)
        let plan = try CloudTranscriptionChunkPlanner().plan(
            fileURL: fixture.url,
            source: fixture.identity,
            wavLayout: fixture.layout,
            multipart: multipart,
            encodedUploadCeilingBytes: ceiling
        )

        try expectEqual(plan.chunks.count, 1, "exact ceiling chunk count")
        try expectEqual(plan.chunks[0].startFrame, 0, "exact ceiling start")
        try expectEqual(plan.chunks[0].endFrame, UInt64(samples.count), "exact ceiling end")
        try expectEqual(plan.chunks[0].estimatedEncodedByteCount, ceiling, "exact ceiling size")
        try plan.validate()
    }

    private static func plannerCreatesContiguousChunksAndOneFrameRemainder() throws {
        let maximumChunkFrames: UInt64 = 5_000
        let samples = Array(repeating: Int16(2_000), count: Int(maximumChunkFrames + 1))
        let fixture = try makePlannerFixture(samples: samples)
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let multipart = plannerMultipartLayout
        let ceiling = try encodedCeiling(frameCount: maximumChunkFrames, multipart: multipart)
        let plan = try CloudTranscriptionChunkPlanner().plan(
            fileURL: fixture.url,
            source: fixture.identity,
            wavLayout: fixture.layout,
            multipart: multipart,
            encodedUploadCeilingBytes: ceiling
        )

        try expectEqual(plan.chunks.count, 2, "one-frame remainder chunk count")
        try expectEqual(plan.chunks[0].startFrame, 0, "first start")
        try expectEqual(plan.chunks[0].endFrame, maximumChunkFrames, "first end")
        try expectEqual(plan.chunks[1].startFrame, maximumChunkFrames, "remainder start")
        try expectEqual(plan.chunks[1].endFrame, maximumChunkFrames + 1, "remainder end")
        try plan.validate()
        guard plan.chunks.allSatisfy({ $0.estimatedEncodedByteCount <= ceiling }) else {
            throw TestFailure("every chunk must fit the encoded ceiling")
        }
    }

    private static func plannerRejectsCeilingWithoutOneFrameCapacity() throws {
        let fixture = try makePlannerFixture(samples: [1])
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let multipart = plannerMultipartLayout
        let zeroFrameCeiling = try multipart.encodedByteCount(
            audioDataByteCount: CanonicalPCM16WAV.headerByteCount,
            fileName: CloudTranscriptionChunkPlanner.uploadFileName,
            contentType: "audio/wav"
        )
        do {
            _ = try CloudTranscriptionChunkPlanner().plan(
                fileURL: fixture.url,
                source: fixture.identity,
                wavLayout: fixture.layout,
                multipart: multipart,
                encodedUploadCeilingBytes: zeroFrameCeiling
            )
            throw TestFailure("ceiling without one frame must fail")
        } catch CloudTranscriptionChunkingError.encodedUploadCeilingTooSmall {
            // expected
        }
    }

    private static func plannerChoosesNearestQuietRunMidpoint() throws {
        let nominalEnd = 8_000
        var samples = Array(repeating: Int16(2_000), count: nominalEnd + 1_000)
        let quietStart = 4_480
        let quietEnd = quietStart + 3_200
        for index in quietStart..<quietEnd {
            samples[index] = 0
        }
        let fixture = try makePlannerFixture(samples: samples)
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let multipart = plannerMultipartLayout
        let ceiling = try encodedCeiling(frameCount: UInt64(nominalEnd), multipart: multipart)
        let plan = try CloudTranscriptionChunkPlanner().plan(
            fileURL: fixture.url,
            source: fixture.identity,
            wavLayout: fixture.layout,
            multipart: multipart,
            encodedUploadCeilingBytes: ceiling
        )

        try expectEqual(plan.chunks[0].endFrame, UInt64((quietStart + quietEnd) / 2), "quiet midpoint")
    }

    private static func plannerFallsBackToNominalBoundaryWithoutSilence() throws {
        let nominalEnd = 2_000
        let fixture = try makePlannerFixture(
            samples: Array(repeating: Int16(2_000), count: nominalEnd + 100)
        )
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let multipart = plannerMultipartLayout
        let ceiling = try encodedCeiling(frameCount: UInt64(nominalEnd), multipart: multipart)
        let plan = try CloudTranscriptionChunkPlanner().plan(
            fileURL: fixture.url,
            source: fixture.identity,
            wavLayout: fixture.layout,
            multipart: multipart,
            encodedUploadCeilingBytes: ceiling
        )

        try expectEqual(plan.chunks[0].endFrame, UInt64(nominalEnd), "short no-silence fallback")
    }

    private static func plannerDoesNotSearchAfterNominalBoundary() throws {
        let nominalEnd = 5_000
        var samples = Array(repeating: Int16(2_000), count: nominalEnd + 4_000)
        for index in nominalEnd..<(nominalEnd + 3_200) {
            samples[index] = 0
        }
        let fixture = try makePlannerFixture(samples: samples)
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let multipart = plannerMultipartLayout
        let ceiling = try encodedCeiling(frameCount: UInt64(nominalEnd), multipart: multipart)
        let plan = try CloudTranscriptionChunkPlanner().plan(
            fileURL: fixture.url,
            source: fixture.identity,
            wavLayout: fixture.layout,
            multipart: multipart,
            encodedUploadCeilingBytes: ceiling
        )

        try expectEqual(plan.chunks[0].endFrame, UInt64(nominalEnd), "post-nominal silence ignored")
    }

    private static func plannerIsDeterministic() throws {
        let fixture = try makePlannerFixture(
            samples: Array(repeating: Int16(2_000), count: 12_345)
        )
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let multipart = plannerMultipartLayout
        let ceiling = try encodedCeiling(frameCount: 4_000, multipart: multipart)
        let planner = CloudTranscriptionChunkPlanner()
        let first = try planner.plan(
            fileURL: fixture.url,
            source: fixture.identity,
            wavLayout: fixture.layout,
            multipart: multipart,
            encodedUploadCeilingBytes: ceiling
        )
        let second = try planner.plan(
            fileURL: fixture.url,
            source: fixture.identity,
            wavLayout: fixture.layout,
            multipart: multipart,
            encodedUploadCeilingBytes: ceiling
        )
        try expectEqual(first, second, "deterministic plan")
    }

    private static func materializerCopiesExactFrameRanges() throws {
        let samples = (0..<20).map { Int16($0 - 10) }
        let fixture = try makePlannerFixture(samples: samples)
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: fixture.url)
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        let materializer = CloudTranscriptionChunkMaterializer(
            temporaryRoot: temporaryRoot,
            copyBufferByteCount: 5
        )
        let ranges: [(UInt64, UInt64)] = [(0, 5), (5, 13), (13, 20)]
        var combined: [Int16] = []
        for (index, range) in ranges.enumerated() {
            let frameCount = range.1 - range.0
            let chunk = CloudTranscriptionChunk(
                index: index,
                startFrame: range.0,
                endFrame: range.1,
                estimatedEncodedByteCount: try encodedCeiling(
                    frameCount: frameCount,
                    multipart: plannerMultipartLayout
                )
            )
            let output = try materializer.materialize(
                sourceURL: fixture.url,
                sourceLayout: fixture.layout,
                chunk: chunk,
                multipart: plannerMultipartLayout
            )
            let layout = try CanonicalPCM16WAV.validateFile(at: output.fileURL)
            try expectEqual(layout.frameCount, frameCount, "materialized frame count")
            combined += try readCanonicalSamples(from: output.fileURL)
            output.cleanup()
        }
        try expectEqual(combined, samples, "materialized ranges exact coverage")
    }

    private static func materializerUsesBoundedBufferForLargeChunk() throws {
        let samples = Array(repeating: Int16(123), count: 50_000)
        let fixture = try makePlannerFixture(samples: samples)
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: fixture.url)
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        let materializer = CloudTranscriptionChunkMaterializer(
            temporaryRoot: temporaryRoot,
            copyBufferByteCount: 17
        )
        let chunk = CloudTranscriptionChunk(
            index: 0,
            startFrame: 0,
            endFrame: UInt64(samples.count),
            estimatedEncodedByteCount: try encodedCeiling(
                frameCount: UInt64(samples.count),
                multipart: plannerMultipartLayout
            )
        )
        let output = try materializer.materialize(
            sourceURL: fixture.url,
            sourceLayout: fixture.layout,
            chunk: chunk,
            multipart: plannerMultipartLayout
        )
        defer { output.cleanup() }
        try expectEqual(
            try CanonicalPCM16WAV.validateFile(at: output.fileURL).frameCount,
            UInt64(samples.count),
            "large bounded materialization"
        )
    }

    private static func materializerCleanupRemovesAttemptDirectory() throws {
        let fixture = try makePlannerFixture(samples: [1, 2, 3])
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: fixture.url)
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        let output = try CloudTranscriptionChunkMaterializer(
            temporaryRoot: temporaryRoot,
            copyBufferByteCount: 2
        ).materialize(
            sourceURL: fixture.url,
            sourceLayout: fixture.layout,
            chunk: CloudTranscriptionChunk(
                index: 0,
                startFrame: 0,
                endFrame: 3,
                estimatedEncodedByteCount: try encodedCeiling(
                    frameCount: 3,
                    multipart: plannerMultipartLayout
                )
            ),
            multipart: plannerMultipartLayout
        )
        let attemptDirectory = output.fileURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: attemptDirectory.path) else {
            throw TestFailure("attempt directory must exist before cleanup")
        }
        output.cleanup()
        guard !FileManager.default.fileExists(atPath: attemptDirectory.path) else {
            throw TestFailure("cleanup must remove the attempt directory")
        }
    }

    private static func materializerRejectsShortSourceReadAndCleansPartialOutput() throws {
        let fixture = try makePlannerFixture(samples: [1, 2, 3, 4])
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: fixture.url)
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        let handle = try FileHandle(forWritingTo: fixture.url)
        try handle.truncate(atOffset: CanonicalPCM16WAV.headerByteCount + 4)
        try handle.close()
        do {
            _ = try CloudTranscriptionChunkMaterializer(
                temporaryRoot: temporaryRoot,
                copyBufferByteCount: 3
            ).materialize(
                sourceURL: fixture.url,
                sourceLayout: fixture.layout,
                chunk: CloudTranscriptionChunk(
                    index: 0,
                    startFrame: 0,
                    endFrame: 4,
                    estimatedEncodedByteCount: try encodedCeiling(
                        frameCount: 4,
                        multipart: plannerMultipartLayout
                    )
                ),
                multipart: plannerMultipartLayout
            )
            throw TestFailure("short source read must fail")
        } catch CloudTranscriptionChunkingError.shortSourceRead {
            // expected
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        try expectEqual(contents.count, 0, "partial attempt cleanup")
    }

    private static func readCanonicalSamples(from url: URL) throws -> [Int16] {
        let layout = try CanonicalPCM16WAV.validateFile(at: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: layout.dataOffset)
        let data = try handle.read(upToCount: Int(layout.dataByteCount)) ?? Data()
        guard data.count == Int(layout.dataByteCount) else {
            throw TestFailure("missing materialized PCM data")
        }
        var samples: [Int16] = []
        var offset = 0
        while offset < data.count {
            let bits = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            samples.append(Int16(bitPattern: bits))
            offset += 2
        }
        return samples
    }

    private static var plannerMultipartLayout: CloudTranscriptionMultipartLayout {
        CloudTranscriptionMultipartLayout(
            model: "whisper-large-v3",
            responseFormat: "verbose_json",
            language: "en",
            boundaryByteCount: 36
        )
    }

    private static func encodedCeiling(
        frameCount: UInt64,
        multipart: CloudTranscriptionMultipartLayout
    ) throws -> UInt64 {
        try multipart.encodedByteCount(
            audioDataByteCount: CanonicalPCM16WAV.headerByteCount
                + frameCount * UInt64(CanonicalPCM16WAV.bytesPerFrame),
            fileName: CloudTranscriptionChunkPlanner.uploadFileName,
            contentType: "audio/wav"
        )
    }

    private static func makePlannerFixture(
        samples: [Int16]
    ) throws -> (
        url: URL,
        layout: CanonicalPCM16WAVLayout,
        identity: CloudTranscriptionSourceIdentity
    ) {
        var payload = Data()
        payload.reserveCapacity(samples.count * 2)
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            payload.append(UInt8(bits & 0xff))
            payload.append(UInt8((bits >> 8) & 0xff))
        }
        let url = try writeCanonicalWAV(payload: payload)
        let layout = try CanonicalPCM16WAV.validateFile(at: url)
        let identity = try CloudTranscriptionSourceIdentityBuilder.make(
            fileURL: url,
            layout: layout,
            readBufferByteCount: 257
        )
        return (url, layout, identity)
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
