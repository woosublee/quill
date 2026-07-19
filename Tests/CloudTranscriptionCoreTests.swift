import Foundation

@main
struct CloudTranscriptionCoreTests {
    static func main() async {
        do {
            try classifiesRetryableURLErrors()
            try classifiesHTTPFailures()
            try respectsShortRetryAfter()
            try treatsQuotaAndAuthenticationAsTerminal()
            try stopsAfterRetryBudgetIsExhausted()
            try calculatesSizeAwareAttemptTimeout()
            try await coordinatorRunsSequentiallyAfterDurableCheckpoint()
            try await coordinatorRetriesOnlyTheCurrentChunk()
            try await coordinatorResumesCompatibleCheckpointPrefix()
            try await checkpointFailureSuppressesTheNextRequest()
            try await terminalFailureSuppressesLaterChunks()
            try await materializationFailureRecordsLocalIOAndSuppressesRequest()
            try await cancellationCleansMaterializedChunk()
            print("CloudTranscriptionCoreTests passed")
        } catch {
            fputs("CloudTranscriptionCoreTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func classifiesRetryableURLErrors() throws {
        let policy = makePolicy()
        let retryable: [URLError.Code] = [
            .timedOut,
            .networkConnectionLost,
            .notConnectedToInternet,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed
        ]
        for code in retryable {
            let decision = policy.decision(
                for: URLError(code),
                completedAttemptCount: 1
            )
            try expectEqual(decision.shouldRetry, true, "retry URL error \(code)")
            try expectEqual(decision.category, .transientNetwork, "URL category \(code)")
            try expectEqual(decision.delaySeconds, 1.25, "URL delay \(code)")
        }

        let certificate = policy.decision(
            for: URLError(.serverCertificateUntrusted),
            completedAttemptCount: 1
        )
        try expectEqual(certificate.shouldRetry, false, "certificate terminal")
        try expectEqual(certificate.category, .invalidRequest, "certificate category")

        let cancelled = policy.decision(
            for: CancellationError(),
            completedAttemptCount: 1
        )
        try expectEqual(cancelled.shouldRetry, false, "cancellation terminal")
        try expectEqual(cancelled.category, .cancelled, "cancellation category")

        let cancelledURLRequest = policy.decision(
            for: URLError(.cancelled),
            completedAttemptCount: 1
        )
        try expectEqual(cancelledURLRequest.shouldRetry, false, "cancelled URL request terminal")
        try expectEqual(cancelledURLRequest.category, .cancelled, "cancelled URL request category")
    }

    private static func classifiesHTTPFailures() throws {
        let policy = makePolicy()
        for status in [408, 500, 503] {
            let decision = policy.decision(
                for: CloudTranscriptionHTTPFailure(statusCode: status),
                completedAttemptCount: 1
            )
            try expectEqual(decision.shouldRetry, true, "HTTP \(status) retry")
            let expected: CloudTranscriptionFailureCategory = status == 408
                ? .transientNetwork
                : .providerUnavailable
            try expectEqual(decision.category, expected, "HTTP \(status) category")
        }

        let temporaryRateLimit = policy.decision(
            for: CloudTranscriptionHTTPFailure(
                statusCode: 429,
                providerCode: "rate_limit_exceeded"
            ),
            completedAttemptCount: 1
        )
        try expectEqual(temporaryRateLimit.shouldRetry, true, "temporary 429 retry")
        try expectEqual(temporaryRateLimit.category, .rateLimited, "temporary 429 category")

        let terminalCases: [(Int, CloudTranscriptionFailureCategory)] = [
            (400, .invalidRequest),
            (401, .authentication),
            (403, .authentication),
            (404, .invalidRequest),
            (413, .payloadTooLarge),
            (415, .invalidRequest),
            (422, .invalidRequest)
        ]
        for (status, category) in terminalCases {
            let decision = policy.decision(
                for: CloudTranscriptionHTTPFailure(statusCode: status),
                completedAttemptCount: 1
            )
            try expectEqual(decision.shouldRetry, false, "HTTP \(status) terminal")
            try expectEqual(decision.category, category, "HTTP \(status) category")
        }
    }

    private static func respectsShortRetryAfter() throws {
        let decision = makePolicy().decision(
            for: CloudTranscriptionHTTPFailure(
                statusCode: 429,
                retryAfterSeconds: 12,
                providerCode: "rate_limit_exceeded"
            ),
            completedAttemptCount: 2
        )
        try expectEqual(decision.shouldRetry, true, "Retry-After retry")
        try expectEqual(decision.delaySeconds, 12, "Retry-After delay")

        let tooLong = makePolicy().decision(
            for: CloudTranscriptionHTTPFailure(
                statusCode: 429,
                retryAfterSeconds: 61,
                providerCode: "rate_limit_exceeded"
            ),
            completedAttemptCount: 1
        )
        try expectEqual(tooLong.shouldRetry, false, "long Retry-After terminal")
        try expectEqual(tooLong.category, .rateLimited, "long Retry-After category")
    }

    private static func treatsQuotaAndAuthenticationAsTerminal() throws {
        let policy = makePolicy()
        let quota = policy.decision(
            for: CloudTranscriptionHTTPFailure(
                statusCode: 429,
                providerCode: "insufficient_quota",
                providerType: "insufficient_quota"
            ),
            completedAttemptCount: 1
        )
        try expectEqual(quota.shouldRetry, false, "quota terminal")
        try expectEqual(quota.category, .quotaExhausted, "quota category")
    }

    private static func stopsAfterRetryBudgetIsExhausted() throws {
        let decision = makePolicy().decision(
            for: URLError(.timedOut),
            completedAttemptCount: 3
        )
        try expectEqual(decision.shouldRetry, false, "retry budget terminal")
        try expectEqual(decision.category, .retryExhausted, "retry budget category")
        try expectEqual(decision.delaySeconds, nil, "retry budget delay")
    }

    private static func calculatesSizeAwareAttemptTimeout() throws {
        let policy = makePolicy()
        try expectEqual(
            policy.attemptTimeout(
                encodedByteCount: 0,
                minimum: 20,
                maximum: 300
            ),
            20,
            "base timeout"
        )
        try expectEqual(
            policy.attemptTimeout(
                encodedByteCount: 131_072,
                minimum: 30,
                maximum: 300
            ),
            30,
            "configured minimum"
        )
        try expectEqual(
            policy.attemptTimeout(
                encodedByteCount: 131_072 * 400,
                minimum: 20,
                maximum: 300
            ),
            300,
            "timeout cap"
        )
    }

    private static func coordinatorRunsSequentiallyAfterDurableCheckpoint() async throws {
        let fixture = try makeCoordinatorFixture()
        defer { fixture.cleanup() }
        let events = EventRecorder()
        let store = TestCheckpointStore(events: events)
        let core = makeCore(temporaryRoot: fixture.temporaryRoot)
        let result = try await core.transcribe(
            sourceURL: fixture.sourceURL,
            sourceLayout: fixture.sourceLayout,
            sourceIdentity: fixture.sourceIdentity,
            plan: fixture.plan,
            identity: fixture.identity,
            multipart: fixture.multipart,
            checkpointStore: store,
            request: { url, _ in
                let index = try chunkIndex(from: url)
                await events.append("request:\(index)")
                return ["zero", "one", "two"][index]
            },
            progress: { _ in }
        )
        try expectEqual(result, "zero one two", "ordered transcript")
        try expectEqual(
            await events.values(),
            ["request:0", "save:1", "request:1", "save:2", "request:2", "save:3"],
            "request/checkpoint ordering"
        )
    }

    private static func coordinatorRetriesOnlyTheCurrentChunk() async throws {
        let fixture = try makeCoordinatorFixture()
        defer { fixture.cleanup() }
        let requests = IntegerRecorder()
        let delays = DoubleRecorder()
        let attempts = AttemptRecorder()
        let store = TestCheckpointStore()
        let core = makeCore(
            temporaryRoot: fixture.temporaryRoot,
            sleep: { delay in await delays.append(delay) }
        )
        let result = try await core.transcribe(
            sourceURL: fixture.sourceURL,
            sourceLayout: fixture.sourceLayout,
            sourceIdentity: fixture.sourceIdentity,
            plan: fixture.plan,
            identity: fixture.identity,
            multipart: fixture.multipart,
            checkpointStore: store,
            request: { url, _ in
                let index = try chunkIndex(from: url)
                await requests.append(index)
                let attempt = await attempts.next(for: index)
                if index == 1, attempt == 1 {
                    throw URLError(.networkConnectionLost)
                }
                return ["zero", "one", "two"][index]
            },
            progress: { _ in }
        )
        try expectEqual(result, "zero one two", "retry ordered transcript")
        try expectEqual(await requests.values(), [0, 1, 1, 2], "retry request indices")
        try expectEqual(await delays.values(), [1.0], "retry delays")
    }

    private static func coordinatorResumesCompatibleCheckpointPrefix() async throws {
        let fixture = try makeCoordinatorFixture()
        defer { fixture.cleanup() }
        let requests = IntegerRecorder()
        let store = TestCheckpointStore(
            checkpoint: CloudTranscriptionCheckpoint(
                identity: fixture.identity,
                completedRawTranscripts: [" zero "]
            )
        )
        let result = try await makeCore(
            temporaryRoot: fixture.temporaryRoot
        ).transcribe(
            sourceURL: fixture.sourceURL,
            sourceLayout: fixture.sourceLayout,
            sourceIdentity: fixture.sourceIdentity,
            plan: fixture.plan,
            identity: fixture.identity,
            multipart: fixture.multipart,
            checkpointStore: store,
            request: { url, _ in
                let index = try chunkIndex(from: url)
                await requests.append(index)
                return index == 1 ? " one  " : "two"
            },
            progress: { _ in }
        )
        try expectEqual(result, "zero one two", "resumed transcript")
        try expectEqual(await requests.values(), [1, 2], "resumed request indices")
    }

    private static func checkpointFailureSuppressesTheNextRequest() async throws {
        let fixture = try makeCoordinatorFixture()
        defer { fixture.cleanup() }
        let requests = IntegerRecorder()
        let store = TestCheckpointStore(failingSaveNumber: 1)
        do {
            _ = try await makeCore(
                temporaryRoot: fixture.temporaryRoot
            ).transcribe(
                sourceURL: fixture.sourceURL,
                sourceLayout: fixture.sourceLayout,
                sourceIdentity: fixture.sourceIdentity,
                plan: fixture.plan,
                identity: fixture.identity,
                multipart: fixture.multipart,
                checkpointStore: store,
                request: { url, _ in
                    let index = try chunkIndex(from: url)
                    await requests.append(index)
                    return "chunk"
                },
                progress: { _ in }
            )
            throw TestFailure("checkpoint failure must stop the job")
        } catch TestStoreError.saveFailed {
            // expected
        }
        try expectEqual(await requests.values(), [0], "checkpoint failure request count")
    }

    private static func terminalFailureSuppressesLaterChunks() async throws {
        let fixture = try makeCoordinatorFixture()
        defer { fixture.cleanup() }
        let requests = IntegerRecorder()
        let store = TestCheckpointStore()
        do {
            _ = try await makeCore(
                temporaryRoot: fixture.temporaryRoot
            ).transcribe(
                sourceURL: fixture.sourceURL,
                sourceLayout: fixture.sourceLayout,
                sourceIdentity: fixture.sourceIdentity,
                plan: fixture.plan,
                identity: fixture.identity,
                multipart: fixture.multipart,
                checkpointStore: store,
                request: { url, _ in
                    await requests.append(try chunkIndex(from: url))
                    throw CloudTranscriptionHTTPFailure(statusCode: 401)
                },
                progress: { _ in }
            )
            throw TestFailure("terminal HTTP failure must stop the job")
        } catch let error as CloudTranscriptionHTTPFailure {
            try expectEqual(error.statusCode, 401, "terminal status")
        }
        try expectEqual(await requests.values(), [0], "terminal failure request count")
        try expectEqual(await store.failures(), [.authentication], "terminal failure category")
    }

    private static func materializationFailureRecordsLocalIOAndSuppressesRequest() async throws {
        let fixture = try makeCoordinatorFixture()
        defer { fixture.cleanup() }
        let requests = IntegerRecorder()
        let store = TestCheckpointStore()
        let failingMaterializer = CloudTranscriptionChunkMaterializer(
            temporaryRoot: fixture.temporaryRoot,
            copyBufferByteCount: 3,
            closeOutput: { _ in throw TestMaterializationError.closeFailed }
        )
        do {
            _ = try await makeCore(
                materializer: failingMaterializer
            ).transcribe(
                sourceURL: fixture.sourceURL,
                sourceLayout: fixture.sourceLayout,
                sourceIdentity: fixture.sourceIdentity,
                plan: fixture.plan,
                identity: fixture.identity,
                multipart: fixture.multipart,
                checkpointStore: store,
                request: { url, _ in
                    await requests.append(try chunkIndex(from: url))
                    return "unexpected"
                },
                progress: { _ in }
            )
            throw TestFailure("materialization failure must stop the job")
        } catch TestMaterializationError.closeFailed {
            // expected
        }
        try expectEqual(await requests.values(), [], "materialization failure request count")
        try expectEqual(await store.failures(), [.localIO], "materialization failure category")
    }

    private static func cancellationCleansMaterializedChunk() async throws {
        let fixture = try makeCoordinatorFixture()
        defer { fixture.cleanup() }
        let store = TestCheckpointStore()
        do {
            _ = try await makeCore(
                temporaryRoot: fixture.temporaryRoot
            ).transcribe(
                sourceURL: fixture.sourceURL,
                sourceLayout: fixture.sourceLayout,
                sourceIdentity: fixture.sourceIdentity,
                plan: fixture.plan,
                identity: fixture.identity,
                multipart: fixture.multipart,
                checkpointStore: store,
                request: { _, _ in throw CancellationError() },
                progress: { _ in }
            )
            throw TestFailure("cancellation must propagate")
        } catch is CancellationError {
            // expected
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: fixture.temporaryRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        try expectEqual(contents.count, 0, "cancellation temp cleanup")
        try expectEqual(await store.failures(), [.cancelled], "cancellation category")
    }

    private static func makeCore(
        temporaryRoot: URL,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in }
    ) -> CloudTranscriptionCore {
        makeCore(
            materializer: CloudTranscriptionChunkMaterializer(
                temporaryRoot: temporaryRoot,
                copyBufferByteCount: 3
            ),
            sleep: sleep
        )
    }

    private static func makeCore(
        materializer: CloudTranscriptionChunkMaterializer,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in }
    ) -> CloudTranscriptionCore {
        CloudTranscriptionCore(
            configuration: CloudTranscriptionConfiguration(
                model: "whisper-large-v3",
                language: "en",
                responseFormat: "verbose_json",
                encodedUploadCeilingBytes: 1_000_000,
                minimumAttemptTimeoutSeconds: 20,
                maximumAttemptTimeoutSeconds: 300
            ),
            materializer: materializer,
            retryPolicy: CloudTranscriptionRetryPolicy(
                maximumAttempts: 3,
                jitter: { _ in 0 }
            ),
            sleep: sleep
        )
    }

    private static func makeCoordinatorFixture() throws -> CoordinatorFixture {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        var sourceData = CanonicalPCM16WAV.header(dataByteCount: 12)
        for sample in [Int16(1), 1, 2, 2, 3, 3] {
            let bits = UInt16(bitPattern: sample)
            sourceData.append(UInt8(bits & 0xff))
            sourceData.append(UInt8((bits >> 8) & 0xff))
        }
        try sourceData.write(to: sourceURL, options: .atomic)
        let sourceLayout = try CanonicalPCM16WAV.validateFile(at: sourceURL)
        let sourceIdentity = try CloudTranscriptionSourceIdentityBuilder.make(
            fileURL: sourceURL,
            layout: sourceLayout,
            readBufferByteCount: 3
        )
        let multipart = CloudTranscriptionMultipartLayout(
            model: "whisper-large-v3",
            responseFormat: "verbose_json",
            language: "en",
            boundaryByteCount: 36
        )
        let chunks = try (0..<3).map { index in
            CloudTranscriptionChunk(
                index: index,
                startFrame: UInt64(index * 2),
                endFrame: UInt64(index * 2 + 2),
                estimatedEncodedByteCount: try multipart.encodedByteCount(
                    audioDataByteCount: CanonicalPCM16WAV.headerByteCount + 4,
                    fileName: CloudTranscriptionChunkPlanner.uploadFileName,
                    contentType: "audio/wav"
                )
            )
        }
        let plan = CloudTranscriptionChunkPlan(
            algorithmVersion: CloudTranscriptionChunkPlan.currentAlgorithmVersion,
            encodedUploadCeilingBytes: 1_000_000,
            sourceFrameCount: 6,
            chunks: chunks,
            planID: "plan"
        )
        let identity = CloudTranscriptionJobIdentity(
            providerID: "provider",
            model: "whisper-large-v3",
            language: "en",
            responseFormat: "verbose_json",
            source: sourceIdentity,
            planID: plan.planID
        )
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return CoordinatorFixture(
            sourceURL: sourceURL,
            sourceLayout: sourceLayout,
            sourceIdentity: sourceIdentity,
            multipart: multipart,
            plan: plan,
            identity: identity,
            temporaryRoot: temporaryRoot
        )
    }

    private static func chunkIndex(from url: URL) throws -> Int {
        let layout = try CanonicalPCM16WAV.validateFile(at: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: layout.dataOffset)
        let bytes = try handle.read(upToCount: 2) ?? Data()
        guard bytes.count == 2 else { throw TestFailure("missing chunk marker") }
        let marker = Int(Int16(bitPattern: UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)))
        return marker - 1
    }

    private static func makePolicy() -> CloudTranscriptionRetryPolicy {
        CloudTranscriptionRetryPolicy(
            maximumAttempts: 3,
            jitter: { _ in 0.25 }
        )
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

private struct CoordinatorFixture {
    let sourceURL: URL
    let sourceLayout: CanonicalPCM16WAVLayout
    let sourceIdentity: CloudTranscriptionSourceIdentity
    let multipart: CloudTranscriptionMultipartLayout
    let plan: CloudTranscriptionChunkPlan
    let identity: CloudTranscriptionJobIdentity
    let temporaryRoot: URL

    func cleanup() {
        try? FileManager.default.removeItem(at: sourceURL)
        try? FileManager.default.removeItem(at: temporaryRoot)
    }
}

private actor EventRecorder {
    private var recorded: [String] = []

    func append(_ value: String) {
        recorded.append(value)
    }

    func values() -> [String] {
        recorded
    }
}

private actor IntegerRecorder {
    private var recorded: [Int] = []

    func append(_ value: Int) {
        recorded.append(value)
    }

    func values() -> [Int] {
        recorded
    }
}

private actor DoubleRecorder {
    private var recorded: [Double] = []

    func append(_ value: Double) {
        recorded.append(value)
    }

    func values() -> [Double] {
        recorded
    }
}

private actor AttemptRecorder {
    private var attempts: [Int: Int] = [:]

    func next(for index: Int) -> Int {
        let next = (attempts[index] ?? 0) + 1
        attempts[index] = next
        return next
    }
}

private enum TestStoreError: Error {
    case saveFailed
}

private enum TestMaterializationError: Error {
    case closeFailed
}

private actor TestCheckpointStore: CloudTranscriptionCheckpointStore {
    private var checkpoint: CloudTranscriptionCheckpoint?
    private var savedCount = 0
    private let failingSaveNumber: Int?
    private let events: EventRecorder?
    private var recordedFailures: [CloudTranscriptionFailureCategory] = []

    init(
        checkpoint: CloudTranscriptionCheckpoint? = nil,
        failingSaveNumber: Int? = nil,
        events: EventRecorder? = nil
    ) {
        self.checkpoint = checkpoint
        self.failingSaveNumber = failingSaveNumber
        self.events = events
    }

    func loadCompatible(
        identity: CloudTranscriptionJobIdentity
    ) async throws -> CloudTranscriptionCheckpoint? {
        guard checkpoint?.identity == identity else { return nil }
        return checkpoint
    }

    func save(_ checkpoint: CloudTranscriptionCheckpoint) async throws {
        savedCount += 1
        if savedCount == failingSaveNumber {
            throw TestStoreError.saveFailed
        }
        self.checkpoint = checkpoint
        await events?.append("save:\(checkpoint.completedRawTranscripts.count)")
    }

    func recordFailure(
        category: CloudTranscriptionFailureCategory
    ) async throws {
        recordedFailures.append(category)
    }

    func failures() -> [CloudTranscriptionFailureCategory] {
        recordedFailures
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
