import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct TranscriptionServiceCloudChunkingTests {
    static func main() async {
        do {
            try await missingAPIKeyStopsBeforeCloudUpload()
            try realtimeMissingAPIKeyStopsBeforeWebSocketCreation()
            try await smallWAVUsesExistingSingleRequestPath()
            try await smallMP3UsesExistingSingleRequestPath()
            try await largeCanonicalWAVUsesSequentialBoundedChunks()
            try await retryableHTTPFailureRetriesCurrentChunkOnly()
            try await terminalProviderFailuresUseStableIssueRecords()
            try await networkAndTimeoutFailuresUseStableIssueCodes()
            try await invalidSuccessfulResponseUsesStableIssueRecord()
            print("TranscriptionServiceCloudChunkingTests passed")
        } catch {
            fputs("TranscriptionServiceCloudChunkingTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func missingAPIKeyStopsBeforeCloudUpload() async throws {
        let recorder = UploadRecorder(results: [.success("must not upload")])
        let service = try makeService(
            apiKey: "  ",
            ceiling: 10_000,
            recorder: recorder,
            checkpointStore: CountingCheckpointStore()
        )
        let missingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")

        do {
            _ = try await service.transcribe(fileURL: missingFile)
            throw TestFailure("missing API key must fail")
        } catch let issue as QuillUserIssueError {
            try expectEqual(
                issue.record.code,
                .providerConfigurationInvalid,
                "missing API key issue code"
            )
            try expectEqual(
                issue.record.recoveryAction,
                .openProviderSettings,
                "missing API key recovery action"
            )
        }
        try expectEqual(
            await recorder.uploads().count,
            0,
            "missing API key upload count"
        )
    }

    private static func realtimeMissingAPIKeyStopsBeforeWebSocketCreation() throws {
        let creations = LockedCounter()
        let service = RealtimeTranscriptionService(
            config: RealtimeTranscriptionService.Configuration(
                baseURL: "https://api.example.com/openai/v1",
                apiKey: "\n",
                model: "provider/realtime",
                language: nil
            ),
            makeWebSocketTask: { request in
                creations.increment()
                return URLSession.shared.webSocketTask(with: request)
            }
        )

        do {
            try service.start()
            throw TestFailure("missing realtime API key must fail")
        } catch let issue as QuillUserIssueError {
            try expectEqual(
                issue.record.code,
                .providerConfigurationInvalid,
                "missing realtime API key issue code"
            )
            try expectEqual(
                issue.record.recoveryAction,
                .openProviderSettings,
                "missing realtime API key recovery action"
            )
        }
        try expectEqual(creations.value, 0, "missing realtime WebSocket count")
    }

    private static func smallWAVUsesExistingSingleRequestPath() async throws {
        UserDefaults.standard.removeObject(forKey: "transcription_timeout_seconds")
        let url = try writeCanonicalWAV(samples: [10, 20, 30])
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = UploadRecorder(results: [.success("short wav")])
        let store = CountingCheckpointStore()
        let service = try makeService(
            ceiling: 10_000,
            recorder: recorder,
            checkpointStore: store
        )

        let transcript = try await service.transcribe(fileURL: url)
        try expectEqual(transcript, "short wav", "small WAV transcript")
        let uploads = await recorder.uploads()
        try expectEqual(uploads.count, 1, "small WAV upload count")
        try expectEqual(uploads[0].timeout, 20, "small WAV timeout")
        try expectContains(uploads[0].body, "filename=\"\(url.lastPathComponent)\"", "small WAV filename")
        try expectContains(uploads[0].body, "Content-Type: audio/wav", "small WAV content type")
        try expectContains(uploads[0].body, "name=\"model\"\r\n\r\nwhisper-large-v3", "small WAV model")
        try expectContains(uploads[0].body, "name=\"language\"\r\n\r\nen", "small WAV language")
        try expectEqual(await store.loadCount(), 0, "small WAV checkpoint load")
    }

    private static func smallMP3UsesExistingSingleRequestPath() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try Data(repeating: 0x44, count: 128).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = UploadRecorder(results: [.success("short mp3")])
        let store = CountingCheckpointStore()
        let service = try makeService(
            ceiling: 10_000,
            recorder: recorder,
            checkpointStore: store
        )

        let transcript = try await service.transcribe(fileURL: url)
        try expectEqual(transcript, "short mp3", "small MP3 transcript")
        let uploads = await recorder.uploads()
        try expectEqual(uploads.count, 1, "small MP3 upload count")
        try expectContains(uploads[0].body, "Content-Type: audio/mpeg", "small MP3 content type")
        try expectEqual(await store.loadCount(), 0, "small MP3 checkpoint load")
    }

    private static func largeCanonicalWAVUsesSequentialBoundedChunks() async throws {
        let multipart = testMultipartLayout
        let ceiling = try multipart.encodedByteCount(
            audioDataByteCount: CanonicalPCM16WAV.headerByteCount + 4,
            fileName: CloudTranscriptionChunkPlanner.uploadFileName,
            contentType: "audio/wav"
        )
        let url = try writeCanonicalWAV(samples: [1, 1, 2, 2, 3, 3])
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = UploadRecorder(results: [
            .success("zero"),
            .success("one"),
            .success("two")
        ])
        let store = CountingCheckpointStore()
        let service = try makeService(
            ceiling: ceiling,
            recorder: recorder,
            checkpointStore: store
        )

        let transcript = try await service.transcribe(fileURL: url)
        try expectEqual(transcript, "zero one two", "large ordered transcript")
        let uploads = await recorder.uploads()
        try expectEqual(uploads.count, 3, "large upload count")
        try expectEqual(await recorder.maximumConcurrentUploads(), 1, "sequential upload count")
        guard uploads.allSatisfy({ UInt64($0.body.count) <= ceiling }) else {
            throw TestFailure("every multipart body must fit the encoded ceiling")
        }
        try expectEqual(await store.savedPrefixCounts(), [1, 2, 3], "large checkpoint prefixes")
    }

    private static func retryableHTTPFailureRetriesCurrentChunkOnly() async throws {
        let multipart = testMultipartLayout
        let ceiling = try multipart.encodedByteCount(
            audioDataByteCount: CanonicalPCM16WAV.headerByteCount + 4,
            fileName: CloudTranscriptionChunkPlanner.uploadFileName,
            contentType: "audio/wav"
        )
        let url = try writeCanonicalWAV(samples: [1, 1, 2, 2])
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = UploadRecorder(results: [
            .http(status: 503, body: #"{"error":{"message":"temporary"}}"#),
            .success("zero"),
            .success("one")
        ])
        let service = try makeService(
            ceiling: ceiling,
            recorder: recorder,
            checkpointStore: CountingCheckpointStore()
        )

        let transcript = try await service.transcribe(fileURL: url)
        try expectEqual(transcript, "zero one", "503 retry transcript")
        let markers = try await recorder.chunkMarkers()
        try expectEqual(markers, [1, 1, 2], "503 retries current chunk only")
    }

    private static func terminalProviderFailuresUseStableIssueRecords() async throws {
        for (status, providerCode, expectedCode, forbidden) in [
            (429, "insufficient_quota", QuillUserIssueCode.quotaExceeded, "secret quota detail"),
            (413, nil, QuillUserIssueCode.audioFileTooLarge, "secret payload detail")
        ] {
            let multipart = testMultipartLayout
            let ceiling = try multipart.encodedByteCount(
                audioDataByteCount: CanonicalPCM16WAV.headerByteCount + 4,
                fileName: CloudTranscriptionChunkPlanner.uploadFileName,
                contentType: "audio/wav"
            )
            let url = try writeCanonicalWAV(samples: [1, 1, 2, 2])
            defer { try? FileManager.default.removeItem(at: url) }
            let body = #"{"error":{"message":"\#(forbidden)","code":"\#(providerCode ?? "")","type":"\#(providerCode ?? "")"}}"#
            let recorder = UploadRecorder(results: [.http(status: status, body: body)])
            let service = try makeService(
                ceiling: ceiling,
                recorder: recorder,
                checkpointStore: CountingCheckpointStore()
            )
            do {
                _ = try await service.transcribe(fileURL: url)
                throw TestFailure("HTTP \(status) must fail")
            } catch let issue as QuillUserIssueError {
                try expectEqual(issue.record.code, expectedCode, "stable HTTP \(status) code")
                try expectEqual(issue.record.context.httpStatus, status, "safe HTTP status")
                try expectEqual(issue.record.context.providerHost, "provider.example", "safe provider host")
                try expectEqual(issue.record.context.modelID, "whisper-large-v3", "safe model ID")
                let payload = try issue.record.encodedStatus()
                guard !payload.contains(forbidden),
                      !issue.record.presentation().body.contains(forbidden) else {
                    throw TestFailure("user issue must not expose provider body")
                }
            }
            try expectEqual(await recorder.uploads().count, 1, "terminal HTTP \(status) upload count")
        }
    }

    private static func networkAndTimeoutFailuresUseStableIssueCodes() async throws {
        for (urlCode, expectedCode) in [
            (URLError.notConnectedToInternet, QuillUserIssueCode.networkUnavailable),
            (URLError.timedOut, QuillUserIssueCode.requestTimedOut)
        ] {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mp3")
            try Data(repeating: 0x44, count: 128).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let recorder = UploadRecorder(results: [.urlError(urlCode)])
            let service = try makeService(
                ceiling: 10_000,
                recorder: recorder,
                checkpointStore: CountingCheckpointStore()
            )

            do {
                _ = try await service.transcribe(fileURL: url)
                throw TestFailure("URL error \(urlCode) must fail")
            } catch let issue as QuillUserIssueError {
                try expectEqual(issue.record.code, expectedCode, "stable URL error code")
                try expectEqual(issue.record.context.providerHost, "provider.example", "URL error provider host")
            }
        }
    }

    private static func invalidSuccessfulResponseUsesStableIssueRecord() async throws {
        let multipart = testMultipartLayout
        let ceiling = try multipart.encodedByteCount(
            audioDataByteCount: CanonicalPCM16WAV.headerByteCount + 4,
            fileName: CloudTranscriptionChunkPlanner.uploadFileName,
            contentType: "audio/wav"
        )
        let url = try writeCanonicalWAV(samples: [1, 1, 2, 2])
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = UploadRecorder(results: [.rawSuccess("")])
        let service = try makeService(
            ceiling: ceiling,
            recorder: recorder,
            checkpointStore: CountingCheckpointStore()
        )
        do {
            _ = try await service.transcribe(fileURL: url)
            throw TestFailure("invalid successful response must fail")
        } catch let issue as QuillUserIssueError {
            try expectEqual(issue.record.code, .invalidProviderResponse, "invalid response code")
        }
        try expectEqual(await recorder.uploads().count, 1, "invalid success must not retry")
    }

    private static func makeService(
        apiKey: String = "test-key",
        ceiling: UInt64,
        recorder: UploadRecorder,
        checkpointStore: CountingCheckpointStore
    ) throws -> TranscriptionService {
        try TranscriptionService(
            apiKey: apiKey,
            baseURL: "https://provider.example/v1",
            useLocalTranscription: false,
            transcriptionLanguage: .auto,
            transcriptionModel: "whisper-large-v3",
            language: "en",
            cloudDependencies: CloudTranscriptionDependencies(
                encodedUploadCeilingBytes: ceiling,
                upload: { request, body in
                    try await recorder.upload(request: request, body: body)
                },
                checkpointStore: checkpointStore,
                progress: { _ in },
                temporaryRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true),
                sleep: { _ in }
            )
        )
    }

    private static var testMultipartLayout: CloudTranscriptionMultipartLayout {
        CloudTranscriptionMultipartLayout(
            model: "whisper-large-v3",
            responseFormat: "verbose_json",
            language: "en",
            boundaryByteCount: 36
        )
    }

    private static func writeCanonicalWAV(samples: [Int16]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        var data = CanonicalPCM16WAV.header(
            dataByteCount: UInt32(samples.count * 2)
        )
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            data.append(UInt8(bits & 0xff))
            data.append(UInt8((bits >> 8) & 0xff))
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func expectContains(
        _ data: Data,
        _ expected: String,
        _ label: String
    ) throws {
        try expectContains(String(decoding: data, as: UTF8.self), expected, label)
    }

    private static func expectContains(
        _ value: String,
        _ expected: String,
        _ label: String
    ) throws {
        guard value.contains(expected) else {
            throw TestFailure("\(label): missing \(expected)")
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

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private actor CountingCheckpointStore: CloudTranscriptionCheckpointStore {
    private var checkpoint: CloudTranscriptionCheckpoint?
    private var loads = 0
    private var prefixes: [Int] = []

    func loadCompatible(
        identity: CloudTranscriptionJobIdentity
    ) async throws -> CloudTranscriptionCheckpoint? {
        loads += 1
        guard checkpoint?.identity == identity else { return nil }
        return checkpoint
    }

    func save(_ checkpoint: CloudTranscriptionCheckpoint) async throws {
        self.checkpoint = checkpoint
        prefixes.append(checkpoint.completedRawTranscripts.count)
    }

    func recordFailure(
        category: CloudTranscriptionFailureCategory
    ) async throws {}

    func loadCount() -> Int { loads }
    func savedPrefixCounts() -> [Int] { prefixes }
}

private actor UploadRecorder {
    struct Upload: Sendable {
        let timeout: TimeInterval
        let body: Data
    }

    enum ScriptedResult: Sendable {
        case success(String)
        case rawSuccess(String)
        case http(status: Int, body: String)
        case urlError(URLError.Code)
    }

    private var results: [ScriptedResult]
    private var recorded: [Upload] = []
    private var activeUploads = 0
    private var maximumActiveUploads = 0

    init(results: [ScriptedResult]) {
        self.results = results
    }

    func upload(
        request: URLRequest,
        body: Data
    ) async throws -> (Data, URLResponse) {
        guard !results.isEmpty else {
            throw TestFailure("unexpected upload")
        }
        activeUploads += 1
        maximumActiveUploads = max(maximumActiveUploads, activeUploads)
        recorded.append(Upload(timeout: request.timeoutInterval, body: body))
        defer { activeUploads -= 1 }
        let result = results.removeFirst()
        let status: Int
        let responseData: Data
        switch result {
        case .urlError(let code):
            throw URLError(code)
        case .success(let text):
            status = 200
            responseData = try JSONSerialization.data(withJSONObject: ["text": text])
        case .rawSuccess(let body):
            status = 200
            responseData = Data(body.utf8)
        case .http(let httpStatus, let body):
            status = httpStatus
            responseData = Data(body.utf8)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (responseData, response)
    }

    func uploads() -> [Upload] { recorded }
    func maximumConcurrentUploads() -> Int { maximumActiveUploads }

    func chunkMarkers() throws -> [Int] {
        try recorded.map { upload in
            guard let riffRange = upload.body.range(of: Data("RIFF".utf8)) else {
                throw TestFailure("chunk body missing RIFF")
            }
            let sampleOffset = riffRange.lowerBound + Int(CanonicalPCM16WAV.headerByteCount)
            guard upload.body.count >= sampleOffset + 2 else {
                throw TestFailure("chunk body missing sample")
            }
            let bits = UInt16(upload.body[sampleOffset])
                | (UInt16(upload.body[sampleOffset + 1]) << 8)
            return Int(Int16(bitPattern: bits))
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
