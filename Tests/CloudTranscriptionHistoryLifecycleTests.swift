import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct CloudTranscriptionHistoryLifecycleTests {
    static func main() async {
        do {
            try await durableRecordExistsBeforeFirstProviderRequest()
            try await durableProviderIdentityUsesSnapshotURLNormalization()
            try await chunkCheckpointNeverPublishesPartialHistoryText()
            try await assembledRecordSurvivesUntilHistoryCommitSucceeds()
            try await sameCloudRetryReusesCompletedPrefix()
            try await differentCloudRetryStartsFromFirstChunk()
            try await localRetryIgnoresCloudCheckpointAndPreservesItOnFailure()
            try startupReconciliationResumesOnlyExactCompatibleJobs()
            try await repeatedRelaunchResumesFromFirstIncompleteChunk()
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
            progress.values().first,
            .planned(completed: 0, total: 3),
            "progress begins after durable preparation"
        )
    }

    private static func durableProviderIdentityUsesSnapshotURLNormalization() async throws {
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
            progress: ProgressRecorder(),
            baseURL: "HTTPS://Provider.Example:443/v1/"
        )
        let snapshot = try CloudTranscriptionExecutionSnapshot(
            baseURL: "https://provider.example/v1",
            apiKey: "test-key",
            model: "whisper-large-v3",
            language: "en",
            encodedUploadCeilingBytes: fixture.ceiling
        )

        _ = try await service.transcribe(fileURL: fixture.audioURL)

        let record = try fixture.store.load(historyID: historyID)
        try expectEqual(
            record?.identity.providerID,
            snapshot.providerID,
            "durable provider identity uses snapshot URL normalization"
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

    private static func sameCloudRetryReusesCompletedPrefix() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let historyID = UUID()
        let session = fixture.store.beginSession(historyID: historyID)
        let firstRecorder = LifecycleUploadRecorder(
            store: fixture.store,
            historyID: historyID,
            results: ["zero", "one", "two"],
            failAfterUploadCount: 1
        )
        let firstService = try makeService(
            fixture: fixture,
            historyID: historyID,
            session: session,
            recorder: firstRecorder,
            progress: ProgressRecorder()
        )
        do {
            _ = try await firstService.transcribe(fileURL: fixture.audioURL)
            throw TestFailure("first attempt must stop after one checkpoint")
        } catch let issue as QuillUserIssueError {
            try expectEqual(
                issue.record.code,
                .providerUnavailable,
                "interrupted provider issue"
            )
        }
        try expectEqual(
            try fixture.store.load(historyID: historyID)?.completedChunks
                .map(\.normalizedRawText),
            ["zero"],
            "first retry prefix"
        )

        let retryRecorder = LifecycleUploadRecorder(
            store: fixture.store,
            historyID: historyID,
            results: ["one", "two"]
        )
        let retryService = try makeService(
            fixture: fixture,
            historyID: historyID,
            session: session,
            recorder: retryRecorder,
            progress: ProgressRecorder()
        )

        let transcript = try await retryService.transcribe(
            fileURL: fixture.audioURL
        )

        try expectEqual(transcript, "zero one two", "same cloud retry transcript")
        try expectEqual(
            try await retryRecorder.chunkMarkers(),
            [2, 3],
            "same cloud retry starts from first incomplete chunk"
        )
    }

    private static func differentCloudRetryStartsFromFirstChunk() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let historyID = UUID()
        let oldSession = fixture.store.beginSession(historyID: historyID)
        let oldRecorder = LifecycleUploadRecorder(
            store: fixture.store,
            historyID: historyID,
            results: ["zero", "one", "two"],
            failAfterUploadCount: 1
        )
        let oldService = try makeService(
            fixture: fixture,
            historyID: historyID,
            session: oldSession,
            recorder: oldRecorder,
            progress: ProgressRecorder()
        )
        do {
            _ = try await oldService.transcribe(fileURL: fixture.audioURL)
            throw TestFailure("old cloud attempt must stop")
        } catch let issue as QuillUserIssueError {
            try expectEqual(
                issue.record.code,
                .providerUnavailable,
                "interrupted provider issue"
            )
        }

        let newSession = fixture.store.beginSession(historyID: historyID)
        try fixture.store.replaceForIncompatibleRetry(
            historyID: historyID,
            oldSession: oldSession,
            newSession: newSession
        )
        let newRecorder = LifecycleUploadRecorder(
            store: fixture.store,
            historyID: historyID,
            results: ["new-zero", "new-one", "new-two"]
        )
        let newService = try makeService(
            fixture: fixture,
            historyID: historyID,
            session: newSession,
            recorder: newRecorder,
            progress: ProgressRecorder(),
            baseURL: "https://other-provider.example/v1"
        )

        let transcript = try await newService.transcribe(
            fileURL: fixture.audioURL
        )

        try expectEqual(
            transcript,
            "new-zero new-one new-two",
            "different cloud ignores old prefix"
        )
        try expectEqual(
            try await newRecorder.chunkMarkers(),
            [1, 2, 3],
            "different cloud restarts from chunk zero"
        )
        do {
            try await fixture.store.checkpointStore(session: oldSession).save(
                CloudTranscriptionCheckpoint(
                    identity: try fixture.store.load(historyID: historyID)!.identity,
                    completedRawTranscripts: ["late"]
                )
            )
            throw TestFailure("old cloud callback must stay stale")
        } catch CloudTranscriptionJobStoreError.staleSession {
            // expected
        }
    }

    private static func localRetryIgnoresCloudCheckpointAndPreservesItOnFailure() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let historyID = UUID()
        let session = fixture.store.beginSession(historyID: historyID)
        let recorder = LifecycleUploadRecorder(
            store: fixture.store,
            historyID: historyID,
            results: ["zero", "one", "two"],
            failAfterUploadCount: 1
        )
        let service = try makeService(
            fixture: fixture,
            historyID: historyID,
            session: session,
            recorder: recorder,
            progress: ProgressRecorder()
        )
        do {
            _ = try await service.transcribe(fileURL: fixture.audioURL)
            throw TestFailure("cloud preparation must stop")
        } catch let issue as QuillUserIssueError {
            try expectEqual(
                issue.record.code,
                .providerUnavailable,
                "interrupted provider issue"
            )
        }
        let beforeLocal = try fixture.store.load(historyID: historyID)

        let localRunner = CloudTranscriptionLocalRetryRunner(
            store: fixture.store,
            historyID: historyID,
            session: session
        )
        var receivedURL: URL?
        do {
            try localRunner.run(
                sourceURL: fixture.audioURL,
                transcribe: { url in
                    receivedURL = url
                    throw TestProviderError.localFailed
                },
                saveHistory: { _ in }
            )
            throw TestFailure("local retry failure must propagate")
        } catch TestProviderError.localFailed {
            // expected
        }
        try expectEqual(receivedURL, fixture.audioURL, "local retry uses permanent WAV")
        try expectEqual(
            try fixture.store.load(historyID: historyID),
            beforeLocal,
            "local failure preserves cloud checkpoint"
        )

        var savedLocalTranscript = ""
        try localRunner.run(
            sourceURL: fixture.audioURL,
            transcribe: { _ in "local complete transcript" },
            saveHistory: { savedLocalTranscript = $0 }
        )

        try expectEqual(
            savedLocalTranscript,
            "local complete transcript",
            "local transcript does not mix cloud prefix"
        )
        try expectEqual(
            try fixture.store.load(historyID: historyID),
            nil,
            "local success deletes cloud sidecar"
        )
    }

    private static func startupReconciliationResumesOnlyExactCompatibleJobs() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let compatibleID = UUID()
        let terminalID = UUID()
        let providerMismatchID = UUID()
        let languageMismatchID = UUID()
        let records = try [
            makeStoredRecord(
                historyID: compatibleID,
                fileURL: fixture.audioURL,
                phase: .interrupted
            ),
            makeStoredRecord(
                historyID: terminalID,
                fileURL: fixture.audioURL,
                phase: .failed
            ),
            makeStoredRecord(
                historyID: providerMismatchID,
                fileURL: fixture.audioURL,
                phase: .transcribing,
                providerID: String(repeating: "c", count: 64)
            ),
            makeStoredRecord(
                historyID: languageMismatchID,
                fileURL: fixture.audioURL,
                phase: .transcribing,
                language: "ko"
            )
        ]
        for record in records {
            let session = fixture.store.beginSession(historyID: record.historyID)
            try fixture.store.create(record, session: session)
        }
        let history = records.map {
            makePlaceholder(
                historyID: $0.historyID,
                audioFileName: fixture.audioURL.lastPathComponent
            )
        }
        let runtime = try CloudTranscriptionExecutionSnapshot(
            baseURL: "https://provider.example/v1",
            apiKey: "runtime-key",
            model: "whisper-large-v3",
            language: "en",
            encodedUploadCeilingBytes: fixture.ceiling
        )
        let reconciler = CloudTranscriptionStartupReconciler(
            store: fixture.store,
            audioRoot: fixture.audioURL.deletingLastPathComponent()
        )

        let result = reconciler.reconcile(
            history: history,
            runtime: runtime
        )

        try expectEqual(
            result.resumable.map(\.historyID),
            [compatibleID],
            "only exact interrupted job auto-resumes"
        )
        try expectEqual(
            Set(result.waitingForRetry.map(\.historyID)),
            Set([terminalID, providerMismatchID, languageMismatchID]),
            "terminal and incompatible jobs wait for explicit retry"
        )
        let withoutKey = try CloudTranscriptionExecutionSnapshot(
            baseURL: "https://provider.example/v1",
            apiKey: "   ",
            model: "whisper-large-v3",
            language: "en",
            encodedUploadCeilingBytes: fixture.ceiling
        )
        let noKeyResult = reconciler.reconcile(
            history: history,
            runtime: withoutKey
        )
        try expect(noKeyResult.resumable.isEmpty, "missing API key disables auto-resume")
        try expectEqual(
            Set(noKeyResult.waitingForRetry.map(\.historyID)),
            Set(records.map(\.historyID)),
            "missing API key preserves every sidecar for retry"
        )
    }

    private static func repeatedRelaunchResumesFromFirstIncompleteChunk() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let historyID = UUID()

        let processAStore = fixture.makeStore()
        let sessionA = processAStore.beginSession(historyID: historyID)
        let recorderA = LifecycleUploadRecorder(
            store: processAStore,
            historyID: historyID,
            results: ["zero", "one", "two"],
            failAfterUploadCount: 1
        )
        let serviceA = try makeService(
            fixture: fixture.withStore(processAStore),
            historyID: historyID,
            session: sessionA,
            recorder: recorderA,
            progress: ProgressRecorder()
        )
        do {
            _ = try await serviceA.transcribe(fileURL: fixture.audioURL)
            throw TestFailure("process A must be interrupted")
        } catch let issue as QuillUserIssueError {
            try expectEqual(
                issue.record.code,
                .providerUnavailable,
                "interrupted provider issue"
            )
        }

        let processBStore = fixture.makeStore()
        let sessionB = processBStore.beginSession(historyID: historyID)
        let recorderB = LifecycleUploadRecorder(
            store: processBStore,
            historyID: historyID,
            results: ["one", "two"],
            failAfterUploadCount: 1
        )
        let serviceB = try makeService(
            fixture: fixture.withStore(processBStore),
            historyID: historyID,
            session: sessionB,
            recorder: recorderB,
            progress: ProgressRecorder()
        )
        do {
            _ = try await serviceB.transcribe(fileURL: fixture.audioURL)
            throw TestFailure("process B must be interrupted")
        } catch let issue as QuillUserIssueError {
            try expectEqual(
                issue.record.code,
                .providerUnavailable,
                "interrupted provider issue"
            )
        }
        try expectEqual(
            try await recorderB.chunkMarkers(),
            [2],
            "process B resumes at second chunk"
        )

        let processCStore = fixture.makeStore()
        let sessionC = processCStore.beginSession(historyID: historyID)
        let recorderC = LifecycleUploadRecorder(
            store: processCStore,
            historyID: historyID,
            results: ["two"]
        )
        let serviceC = try makeService(
            fixture: fixture.withStore(processCStore),
            historyID: historyID,
            session: sessionC,
            recorder: recorderC,
            progress: ProgressRecorder()
        )
        let transcript = try await serviceC.transcribe(fileURL: fixture.audioURL)

        try expectEqual(transcript, "zero one two", "repeated relaunch transcript")
        try expectEqual(
            try await recorderC.chunkMarkers(),
            [3],
            "process C resumes at final chunk"
        )
        try expectEqual(
            try processCStore.load(historyID: historyID)?.completedChunks.count,
            3,
            "one sidecar retains one contiguous prefix"
        )
        try expect(
            FileManager.default.fileExists(atPath: fixture.audioURL.path),
            "one permanent WAV survives every relaunch"
        )
    }

    private static func makeStoredRecord(
        historyID: UUID,
        fileURL: URL,
        phase: CloudTranscriptionJobPhase,
        providerID: String? = nil,
        language: String? = "en"
    ) throws -> CloudTranscriptionJobRecord {
        let layout = try CanonicalPCM16WAV.validateFile(at: fileURL)
        let source = try CloudTranscriptionSourceIdentityBuilder.make(
            fileURL: fileURL,
            layout: layout,
            readBufferByteCount: 3
        )
        let multipart = CloudTranscriptionMultipartLayout(
            model: "whisper-large-v3",
            responseFormat: "verbose_json",
            language: language,
            boundaryByteCount: 36
        )
        let ceiling = try multipart.encodedByteCount(
            audioDataByteCount: CanonicalPCM16WAV.headerByteCount + 4,
            fileName: CloudTranscriptionChunkPlanner.uploadFileName,
            contentType: "audio/wav"
        )
        let plan = try CloudTranscriptionChunkPlanner().plan(
            fileURL: fileURL,
            source: source,
            wavLayout: layout,
            multipart: multipart,
            encodedUploadCeilingBytes: ceiling
        )
        let runtime = try CloudTranscriptionExecutionSnapshot(
            baseURL: "https://provider.example/v1",
            apiKey: "runtime-key",
            model: "whisper-large-v3",
            language: language,
            encodedUploadCeilingBytes: ceiling
        )
        return CloudTranscriptionJobRecord(
            schemaVersion: CloudTranscriptionJobRecord.currentSchemaVersion,
            historyID: historyID,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            phase: phase,
            identity: CloudTranscriptionJobIdentity(
                providerID: providerID ?? runtime.providerID,
                model: runtime.model,
                language: runtime.language,
                responseFormat: runtime.responseFormat,
                source: source,
                planID: plan.planID
            ),
            plan: plan,
            completedChunks: [],
            firstIncompleteChunkIndex: 0,
            lastFailure: phase == .failed
                ? CloudTranscriptionStoredFailure(
                    category: .authentication,
                    httpStatus: 401,
                    retryAfterSeconds: nil
                )
                : nil,
            completionPolicy: CloudTranscriptionCompletionPolicy(
                postProcessingEnabled: true,
                outputLanguage: "en",
                pressEnterCommandEnabled: false
            )
        )
    }

    private static func makeService(
        fixture: LifecycleFixture,
        historyID: UUID,
        session: CloudTranscriptionJobSession,
        recorder: LifecycleUploadRecorder,
        progress: ProgressRecorder,
        baseURL: String = "https://provider.example/v1"
    ) throws -> TranscriptionService {
        let completionPolicy = CloudTranscriptionCompletionPolicy(
            postProcessingEnabled: true,
            outputLanguage: "en",
            pressEnterCommandEnabled: false
        )
        let checkpointStore = fixture.store.checkpointStore(
            session: session,
            completionPolicy: completionPolicy
        )
        return try TranscriptionService(
            apiKey: "test-key",
            baseURL: baseURL,
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
                    progress.append(value)
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

    func makeStore() -> CloudTranscriptionJobStore {
        CloudTranscriptionJobStore(
            jobsDirectory: root.appendingPathComponent("jobs", isDirectory: true),
            temporaryRoot: temporaryRoot,
            now: { Date(timeIntervalSince1970: 2_000) }
        )
    }

    func withStore(_ store: CloudTranscriptionJobStore) -> LifecycleFixture {
        LifecycleFixture(
            root: root,
            audioURL: audioURL,
            temporaryRoot: temporaryRoot,
            ceiling: ceiling,
            store: store
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor LifecycleUploadRecorder {
    private let store: CloudTranscriptionJobStore
    private let historyID: UUID
    private var results: [String]
    private var recordedBodies: [Data] = []
    private var count = 0
    private var preparedBeforeFirstUpload = false
    private let failAfterUploadCount: Int?
    private let afterUpload: @Sendable (Int) async throws -> Void

    init(
        store: CloudTranscriptionJobStore,
        historyID: UUID,
        results: [String],
        failAfterUploadCount: Int? = nil,
        afterUpload: @escaping @Sendable (Int) async throws -> Void = { _ in }
    ) {
        self.store = store
        self.historyID = historyID
        self.results = results
        self.failAfterUploadCount = failAfterUploadCount
        self.afterUpload = afterUpload
    }

    func upload(
        request: URLRequest,
        body: Data
    ) async throws -> (Data, URLResponse) {
        if let failAfterUploadCount,
           count >= failAfterUploadCount {
            throw TestProviderError.interrupted
        }
        if count == 0,
           let record = try store.load(historyID: historyID),
           record.phase == .transcribing,
           record.completedChunks.isEmpty {
            preparedBeforeFirstUpload = true
        }
        guard !results.isEmpty else { throw TestFailure("unexpected upload") }
        let value = results.removeFirst()
        recordedBodies.append(body)
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

    func chunkMarkers() throws -> [Int] {
        let directory = try FileManager.default.contentsOfDirectory(
            at: store.temporaryRoot,
            includingPropertiesForKeys: nil
        )
        guard directory.isEmpty else {
            throw TestFailure("temporary upload chunks must already be cleaned")
        }
        return try recordedBodies.map { body in
            guard let riffRange = body.range(of: Data("RIFF".utf8)) else {
                throw TestFailure("chunk body missing RIFF")
            }
            let sampleOffset = riffRange.lowerBound
                + Int(CanonicalPCM16WAV.headerByteCount)
            let bits = UInt16(body[sampleOffset])
                | (UInt16(body[sampleOffset + 1]) << 8)
            return Int(Int16(bitPattern: bits))
        }
    }

    func sawPreparedRecordBeforeFirstUpload() -> Bool {
        preparedBeforeFirstUpload
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CloudTranscriptionProgress] = []

    func append(_ value: CloudTranscriptionProgress) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(value)
    }

    func values() -> [CloudTranscriptionProgress] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
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

private enum TestProviderError: Error {
    case interrupted
    case localFailed
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
