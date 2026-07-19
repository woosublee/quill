import Foundation

@main
struct CloudTranscriptionHistoryLifecycleTests {
    static func main() async {
        do {
            try await durableRecordExistsBeforeFirstProviderRequest()
            try await chunkCheckpointNeverPublishesPartialHistoryText()
            try await assembledRecordSurvivesUntilHistoryCommitSucceeds()
            print("CloudTranscriptionHistoryLifecycleTests passed")
        } catch {
            fputs("CloudTranscriptionHistoryLifecycleTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func durableRecordExistsBeforeFirstProviderRequest() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let historyID = UUID()
        let session = fixture.store.beginSession(historyID: historyID)
        let recorder = LifecycleUploadRecorder(
            store: fixture.store,
            historyID: historyID,
            results: ["zero", "one", "two"]
        )
        let progress = ProgressRecorder()
        let service = try makeService(
            fixture: fixture,
            historyID: historyID,
            session: session,
            recorder: recorder,
            progress: progress
        )

        let transcript = try await service.transcribe(fileURL: fixture.audioURL)

        try expectEqual(transcript, "zero one two", "assembled transcript")
        try expectEqual(await recorder.uploadCount(), 3, "provider upload count")
        let preparedBeforeFirstUpload = await recorder
            .sawPreparedRecordBeforeFirstUpload()
        try expect(preparedBeforeFirstUpload, "sidecar exists before first request")
        let record = try fixture.store.load(historyID: historyID)
        try expectEqual(record?.phase, .assembled, "assembled sidecar phase")
        try expectEqual(record?.completedChunks.map(\.normalizedRawText), ["zero", "one", "two"], "durable raw chunk prefix")
        try expectEqual(record?.firstIncompleteChunkIndex, 3, "assembled first incomplete index")
        try expectEqual(
            await progress.values().first,
            .planned(completed: 0, total: 3),
            "progress begins after durable preparation"
        )
    }

    private static func chunkCheckpointNeverPublishesPartialHistoryText() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let historyID = UUID()
        let session = fixture.store.beginSession(historyID: historyID)
        let history = HistoryRecorder(
            item: makePlaceholder(historyID: historyID, audioFileName: fixture.audioURL.lastPathComponent)
        )
        let recorder = LifecycleUploadRecorder(
            store: fixture.store,
            historyID: historyID,
            results: ["zero", "one", "two"],
            afterUpload: { _ in
                let current = await history.item()
                guard current.rawTranscript.isEmpty,
                      current.postProcessedTranscript.isEmpty,
                      current.postProcessingStatus
                        == PipelineHistoryItem.cloudTranscribingStatus else {
                    throw TestFailure("partial chunk text reached history")
                }
            }
        )
        let service = try makeService(
            fixture: fixture,
            historyID: historyID,
            session: session,
            recorder: recorder,
            progress: ProgressRecorder()
        )

        _ = try await service.transcribe(fileURL: fixture.audioURL)

        let item = await history.item()
        try expect(item.rawTranscript.isEmpty, "history raw text remains empty before final completion")
        try expect(item.postProcessedTranscript.isEmpty, "history processed text remains empty before final completion")
    }

    private static func assembledRecordSurvivesUntilHistoryCommitSucceeds() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let historyID = UUID()
        let session = fixture.store.beginSession(historyID: historyID)
        let recorder = LifecycleUploadRecorder(
            store: fixture.store,
            historyID: historyID,
            results: ["zero", "one", "two"]
        )
        let service = try makeService(
            fixture: fixture,
            historyID: historyID,
            session: session,
            recorder: recorder,
            progress: ProgressRecorder()
        )
        let transcript = try await service.transcribe(fileURL: fixture.audioURL)
        let committer = CloudTranscriptionHistoryCommitter(
            store: fixture.store,
            session: session
        )

        do {
            try committer.commit(historyID: historyID) {
                throw TestHistoryError.saveFailed
            }
            throw TestFailure("history failure must propagate")
        } catch TestHistoryError.saveFailed {
            // expected
        }
        try expectEqual(
            try fixture.store.load(historyID: historyID)?.phase,
            .assembled,
            "history failure preserves assembled sidecar"
        )
        try expect(
            FileManager.default.fileExists(atPath: fixture.audioURL.path),
            "history failure preserves permanent WAV"
        )

        var savedTranscript = ""
        try committer.commit(historyID: historyID) {
            savedTranscript = transcript
        }

        try expectEqual(savedTranscript, "zero one two", "history receives full transcript once")
        try expectEqual(
            try fixture.store.load(historyID: historyID),
            nil,
            "sidecar deletes only after history commit"
        )
        try expect(
            FileManager.default.fileExists(atPath: fixture.audioURL.path),
            "successful history commit keeps permanent WAV"
        )
    }

    private static func makeService(
        fixture: LifecycleFixture,
        historyID: UUID,
        session: CloudTranscriptionJobSession,
        recorder: LifecycleUploadRecorder,
        progress: ProgressRecorder
    ) throws -> TranscriptionService {
        let completionPolicy = CloudTranscriptionCompletionPolicy(
            postProcessingEnabled: true,
            preserveExactWording: false,
            outputLanguage: "en",
            pressEnterCommandEnabled: false
        )
        let checkpointStore = fixture.store.checkpointStore(
            session: session,
            completionPolicy: completionPolicy
        )
        return try TranscriptionService(
            apiKey: "test-key",
            baseURL: "https://provider.example/v1",
            useLocalTranscription: false,
            transcriptionLanguage: .auto,
            transcriptionModel: "whisper-large-v3",
            language: "en",
            cloudDependencies: CloudTranscriptionDependencies(
                encodedUploadCeilingBytes: fixture.ceiling,
                upload: { request, body in
                    try await recorder.upload(request: request, body: body)
                },
                checkpointStore: InMemoryCloudTranscriptionCheckpointStore(),
                progress: { _ in },
                temporaryRoot: fixture.temporaryRoot,
                sleep: { _ in }
            ),
            cloudExecutionContext: CloudTranscriptionExecutionContext(
                historyID: historyID,
                session: session,
                checkpointStore: checkpointStore,
                progress: { value in
                    Task { await progress.append(value) }
                }
            )
        )
    }

    private static func makeFixture() throws -> LifecycleFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let audioRoot = root.appendingPathComponent("audio", isDirectory: true)
        let jobsRoot = root.appendingPathComponent("jobs", isDirectory: true)
        let temporaryRoot = root.appendingPathComponent("temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        let audioURL = audioRoot.appendingPathComponent("recording.wav")
        try writeCanonicalWAV(samples: [1, 1, 2, 2, 3, 3], to: audioURL)
        let multipart = CloudTranscriptionMultipartLayout(
            model: "whisper-large-v3",
            responseFormat: "verbose_json",
            language: "en",
            boundaryByteCount: 36
        )
        let ceiling = try multipart.encodedByteCount(
            audioDataByteCount: CanonicalPCM16WAV.headerByteCount + 4,
            fileName: CloudTranscriptionChunkPlanner.uploadFileName,
            contentType: "audio/wav"
        )
        return LifecycleFixture(
            root: root,
            audioURL: audioURL,
            temporaryRoot: temporaryRoot,
            ceiling: ceiling,
            store: CloudTranscriptionJobStore(
                jobsDirectory: jobsRoot,
                temporaryRoot: temporaryRoot,
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )
    }

    private static func writeCanonicalWAV(
        samples: [Int16],
        to url: URL
    ) throws {
        var data = CanonicalPCM16WAV.header(
            dataByteCount: UInt32(samples.count * 2)
        )
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            data.append(UInt8(bits & 0xff))
            data.append(UInt8((bits >> 8) & 0xff))
        }
        try data.write(to: url, options: .atomic)
    }

    private static func makePlaceholder(
        historyID: UUID,
        audioFileName: String
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: historyID,
            timestamp: Date(timeIntervalSince1970: 1_000),
            rawTranscript: "",
            postProcessedTranscript: "",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "",
            postProcessingStatus: PipelineHistoryItem.cloudTranscribingStatus,
            debugStatus: "",
            customVocabulary: "",
            audioFileName: audioFileName,
            usedLocalTranscription: false
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else { throw TestFailure(label) }
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

private struct LifecycleFixture {
    let root: URL
    let audioURL: URL
    let temporaryRoot: URL
    let ceiling: UInt64
    let store: CloudTranscriptionJobStore

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor LifecycleUploadRecorder {
    private let store: CloudTranscriptionJobStore
    private let historyID: UUID
    private var results: [String]
    private var count = 0
    private var preparedBeforeFirstUpload = false
    private let afterUpload: @Sendable (Int) async throws -> Void

    init(
        store: CloudTranscriptionJobStore,
        historyID: UUID,
        results: [String],
        afterUpload: @escaping @Sendable (Int) async throws -> Void = { _ in }
    ) {
        self.store = store
        self.historyID = historyID
        self.results = results
        self.afterUpload = afterUpload
    }

    func upload(
        request: URLRequest,
        body: Data
    ) async throws -> (Data, URLResponse) {
        if count == 0,
           let record = try store.load(historyID: historyID),
           record.phase == .transcribing,
           record.completedChunks.isEmpty {
            preparedBeforeFirstUpload = true
        }
        guard !results.isEmpty else { throw TestFailure("unexpected upload") }
        let value = results.removeFirst()
        count += 1
        try await afterUpload(count)
        let data = Data(#"{"text":"\#(value)","segments":[]}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }

    func uploadCount() -> Int { count }
    func sawPreparedRecordBeforeFirstUpload() -> Bool {
        preparedBeforeFirstUpload
    }
}

private actor ProgressRecorder {
    private var recorded: [CloudTranscriptionProgress] = []

    func append(_ value: CloudTranscriptionProgress) {
        recorded.append(value)
    }

    func values() -> [CloudTranscriptionProgress] { recorded }
}

private actor HistoryRecorder {
    private var current: PipelineHistoryItem

    init(item: PipelineHistoryItem) {
        current = item
    }

    func item() -> PipelineHistoryItem { current }
}

private enum TestHistoryError: Error {
    case saveFailed
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
