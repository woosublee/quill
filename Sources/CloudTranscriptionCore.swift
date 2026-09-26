import Foundation

struct CloudTranscriptionInvalidResponseFailure: Error, Equatable, Sendable {}

/// A local speech model stopped at its output limit before the chunk ended.
struct TranscriptionChunkTruncatedFailure: Error, Equatable, Sendable {}

/// The local runtime could not serve a chunk (start failed or the process
/// exited). Retried like an unavailable provider. `reason` is a fixed code,
/// never user content.
struct TranscriptionChunkRuntimeFailure: Error, Equatable, Sendable {
    let reason: String
}

struct CloudTranscriptionHTTPFailure: Error, Equatable, Sendable {
    let statusCode: Int
    let retryAfterSeconds: TimeInterval?
    let providerCode: String?
    let providerType: String?
    let sanitizedMessage: String?

    init(
        statusCode: Int,
        retryAfterSeconds: TimeInterval? = nil,
        providerCode: String? = nil,
        providerType: String? = nil,
        sanitizedMessage: String? = nil
    ) {
        self.statusCode = statusCode
        self.retryAfterSeconds = retryAfterSeconds
        self.providerCode = providerCode
        self.providerType = providerType
        self.sanitizedMessage = sanitizedMessage
    }
}

enum CloudTranscriptionFailureCategory: String, Codable, Equatable, Sendable {
    case transientNetwork
    case rateLimited
    case providerUnavailable
    case authentication
    case quotaExhausted
    case invalidRequest
    case payloadTooLarge
    case invalidResponse
    case localIO
    case cancelled
    case retryExhausted
}

struct CloudTranscriptionRetryDecision: Equatable, Sendable {
    let shouldRetry: Bool
    let delaySeconds: TimeInterval?
    let category: CloudTranscriptionFailureCategory
}

struct CloudTranscriptionConfiguration: Equatable, Sendable {
    let model: String
    let language: String?
    let responseFormat: String
    let encodedUploadCeilingBytes: UInt64
    let minimumAttemptTimeoutSeconds: TimeInterval
    let maximumAttemptTimeoutSeconds: TimeInterval
}

struct CloudTranscriptionJobIdentity: Codable, Equatable, Sendable {
    let providerID: String
    let model: String
    let language: String?
    let responseFormat: String
    let source: CloudTranscriptionSourceIdentity
    let planID: String
}

enum TranscriptionJobBackend: Equatable, Sendable {
    case cloud
    case localAI(modelID: String)
}

extension CloudTranscriptionJobIdentity {
    /// Local AI jobs share the job store. Their provider ID carries this prefix
    /// plus the model package digest, so the record schema does not change and
    /// an older app treats them as an unknown provider waiting for retry.
    static let localAIProviderIDPrefix = "local-ai:"

    static func localAIProviderID(packageDigest: String) -> String {
        localAIProviderIDPrefix + packageDigest
    }

    var backend: TranscriptionJobBackend {
        providerID.hasPrefix(Self.localAIProviderIDPrefix)
            ? .localAI(modelID: model)
            : .cloud
    }
}

struct LocalAITranscriptionResumeIdentity: Equatable, Sendable {
    let providerID: String
    let model: String
    let language: String?
    let responseFormat: String
    let ceilingBytes: UInt64
    let silenceSearchFrameCount: UInt64
}

struct CloudTranscriptionCheckpoint: Codable, Equatable, Sendable {
    let identity: CloudTranscriptionJobIdentity
    let completedRawTranscripts: [String]
    let engineLanguageCode: String?

    init(
        identity: CloudTranscriptionJobIdentity,
        completedRawTranscripts: [String],
        engineLanguageCode: String? = nil
    ) {
        self.identity = identity
        self.completedRawTranscripts = completedRawTranscripts
        self.engineLanguageCode = engineLanguageCode
    }
}

enum CloudTranscriptionProgress: Equatable, Sendable {
    case planned(completed: Int, total: Int)
    case uploading(index: Int, total: Int, attempt: Int)
    case completed(total: Int)
}

protocol CloudTranscriptionCheckpointStore: Sendable {
    func loadCompatible(
        identity: CloudTranscriptionJobIdentity
    ) async throws -> CloudTranscriptionCheckpoint?
    func save(_ checkpoint: CloudTranscriptionCheckpoint) async throws
    func recordFailure(
        category: CloudTranscriptionFailureCategory
    ) async throws
}

protocol CloudTranscriptionCheckpointPreparing: Sendable {
    func prepare(
        identity: CloudTranscriptionJobIdentity,
        plan: CloudTranscriptionChunkPlan
    ) async throws
}

actor InMemoryCloudTranscriptionCheckpointStore: CloudTranscriptionCheckpointStore {
    private var checkpoint: CloudTranscriptionCheckpoint?
    private(set) var failureCategory: CloudTranscriptionFailureCategory?

    func loadCompatible(
        identity: CloudTranscriptionJobIdentity
    ) async throws -> CloudTranscriptionCheckpoint? {
        guard checkpoint?.identity == identity else { return nil }
        return checkpoint
    }

    func save(_ checkpoint: CloudTranscriptionCheckpoint) async throws {
        self.checkpoint = checkpoint
    }

    func recordFailure(
        category: CloudTranscriptionFailureCategory
    ) async throws {
        failureCategory = category
    }
}

struct CloudTranscriptionRetryPolicy: Sendable {
    let maximumAttempts: Int
    let jitter: @Sendable (Int) -> TimeInterval

    func decision(
        for error: Error,
        completedAttemptCount: Int
    ) -> CloudTranscriptionRetryDecision {
        let category = category(for: error)
        let retryable = isRetryable(error: error, category: category)
        guard retryable else {
            return CloudTranscriptionRetryDecision(
                shouldRetry: false,
                delaySeconds: nil,
                category: category
            )
        }
        guard completedAttemptCount < maximumAttempts else {
            return CloudTranscriptionRetryDecision(
                shouldRetry: false,
                delaySeconds: nil,
                category: .retryExhausted
            )
        }

        if let failure = error as? CloudTranscriptionHTTPFailure,
           let retryAfterSeconds = failure.retryAfterSeconds {
            guard retryAfterSeconds >= 0, retryAfterSeconds <= 60 else {
                return CloudTranscriptionRetryDecision(
                    shouldRetry: false,
                    delaySeconds: nil,
                    category: category
                )
            }
            return CloudTranscriptionRetryDecision(
                shouldRetry: true,
                delaySeconds: retryAfterSeconds,
                category: category
            )
        }

        let retryIndex = max(0, completedAttemptCount - 1)
        let baseDelay: TimeInterval = retryIndex == 0 ? 1 : 3
        return CloudTranscriptionRetryDecision(
            shouldRetry: true,
            delaySeconds: baseDelay + max(0, jitter(retryIndex)),
            category: category
        )
    }

    func attemptTimeout(
        encodedByteCount: UInt64,
        minimum: TimeInterval,
        maximum: TimeInterval
    ) -> TimeInterval {
        let calculated = 20 + TimeInterval(encodedByteCount) / 131_072
        return max(minimum, min(calculated, maximum))
    }

    private func category(for error: Error) -> CloudTranscriptionFailureCategory {
        if error is CancellationError {
            return .cancelled
        }
        if error is TranscriptionChunkRuntimeFailure {
            return .providerUnavailable
        }
        if error is TranscriptionChunkTruncatedFailure {
            return .invalidResponse
        }
        if error is CloudTranscriptionInvalidResponseFailure {
            return .invalidResponse
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .timedOut,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .cannotConnectToHost,
                 .cannotFindHost,
                 .dnsLookupFailed:
                return .transientNetwork
            default:
                return .invalidRequest
            }
        }
        if let failure = error as? CloudTranscriptionHTTPFailure {
            if failure.statusCode == 200 {
                return .invalidResponse
            }
            let safeCode = failure.providerCode?.lowercased()
            let safeType = failure.providerType?.lowercased()
            if safeCode == "insufficient_quota" || safeType == "insufficient_quota" {
                return .quotaExhausted
            }
            switch failure.statusCode {
            case 408:
                return .transientNetwork
            case 429:
                return .rateLimited
            case 500..<600:
                return .providerUnavailable
            case 401, 403:
                return .authentication
            case 413:
                return .payloadTooLarge
            case 400, 404, 415, 422:
                return .invalidRequest
            default:
                return .invalidResponse
            }
        }
        return .localIO
    }

    private func isRetryable(
        error: Error,
        category: CloudTranscriptionFailureCategory
    ) -> Bool {
        switch category {
        case .transientNetwork, .providerUnavailable:
            return true
        case .rateLimited:
            guard let failure = error as? CloudTranscriptionHTTPFailure else {
                return false
            }
            let safeCode = failure.providerCode?.lowercased()
            let safeType = failure.providerType?.lowercased()
            return safeCode != "insufficient_quota"
                && safeType != "insufficient_quota"
        default:
            return false
        }
    }
}

struct CloudTranscriptionCore: Sendable {
    static let maximumTruncationSplitDepth = 2

    let configuration: CloudTranscriptionConfiguration
    let materializer: CloudTranscriptionChunkMaterializer
    let retryPolicy: CloudTranscriptionRetryPolicy
    let sleep: @Sendable (TimeInterval) async throws -> Void

    func transcribe(
        sourceURL: URL,
        sourceLayout: CanonicalPCM16WAVLayout,
        sourceIdentity: CloudTranscriptionSourceIdentity,
        plan: CloudTranscriptionChunkPlan,
        identity: CloudTranscriptionJobIdentity,
        multipart: CloudTranscriptionMultipartLayout,
        checkpointStore: any CloudTranscriptionCheckpointStore,
        request: @escaping @Sendable (URL, TimeInterval) async throws -> String,
        engineLanguageCode: @escaping @Sendable () async -> String? = { nil },
        restoreEngineLanguageCode: @escaping @Sendable (String?) async -> Void = { _ in },
        progress: @escaping @Sendable (CloudTranscriptionProgress) -> Void
    ) async throws -> String {
        try await transcribe(
            sourceURL: sourceURL,
            sourceLayout: sourceLayout,
            sourceIdentity: sourceIdentity,
            plan: plan,
            identity: identity,
            sizing: .multipart(multipart),
            checkpointStore: checkpointStore,
            request: request,
            engineLanguageCode: engineLanguageCode,
            restoreEngineLanguageCode: restoreEngineLanguageCode,
            progress: progress
        )
    }

    func transcribe(
        sourceURL: URL,
        sourceLayout: CanonicalPCM16WAVLayout,
        sourceIdentity: CloudTranscriptionSourceIdentity,
        plan: CloudTranscriptionChunkPlan,
        identity: CloudTranscriptionJobIdentity,
        sizing: TranscriptionChunkSizing,
        checkpointStore: any CloudTranscriptionCheckpointStore,
        request: @escaping @Sendable (URL, TimeInterval) async throws -> String,
        engineLanguageCode: @escaping @Sendable () async -> String? = { nil },
        restoreEngineLanguageCode: @escaping @Sendable (String?) async -> Void = { _ in },
        progress: @escaping @Sendable (CloudTranscriptionProgress) -> Void
    ) async throws -> String {
        try plan.validate()
        guard identity.source == sourceIdentity,
              identity.model == configuration.model,
              identity.language == configuration.language,
              identity.responseFormat == configuration.responseFormat,
              identity.planID == plan.planID,
              plan.encodedUploadCeilingBytes
                == configuration.encodedUploadCeilingBytes else {
            throw CloudTranscriptionChunkingError.invalidChunkPlan
        }

        if let preparingStore = checkpointStore
            as? any CloudTranscriptionCheckpointPreparing {
            try await preparingStore.prepare(identity: identity, plan: plan)
        }
        let loadedCheckpoint = try await checkpointStore.loadCompatible(
            identity: identity
        )
        var completedRawTranscripts = loadedCheckpoint?.completedRawTranscripts ?? []
        await restoreEngineLanguageCode(loadedCheckpoint?.engineLanguageCode)
        guard completedRawTranscripts.count <= plan.chunks.count else {
            throw CloudTranscriptionChunkingError.invalidChunkPlan
        }
        completedRawTranscripts = completedRawTranscripts.map(normalizedText)
        progress(.planned(
            completed: completedRawTranscripts.count,
            total: plan.chunks.count
        ))

        for chunk in plan.chunks.dropFirst(completedRawTranscripts.count) {
            var completedAttemptCount = 0
            while true {
                try Task.checkCancellation()
                completedAttemptCount += 1
                progress(.uploading(
                    index: chunk.index,
                    total: plan.chunks.count,
                    attempt: completedAttemptCount
                ))
                do {
                    let rawTranscript = try await transcribeRange(
                        sourceURL: sourceURL,
                        sourceLayout: sourceLayout,
                        chunk: chunk,
                        sizing: sizing,
                        depth: 0,
                        request: request
                    )
                    completedRawTranscripts.append(normalizedText(rawTranscript))
                    try await checkpointStore.save(
                        CloudTranscriptionCheckpoint(
                            identity: identity,
                            completedRawTranscripts: completedRawTranscripts,
                            engineLanguageCode: await engineLanguageCode()
                        )
                    )
                    break
                } catch {
                    let decision = retryPolicy.decision(
                        for: error,
                        completedAttemptCount: completedAttemptCount
                    )
                    guard decision.shouldRetry else {
                        try await checkpointStore.recordFailure(
                            category: decision.category
                        )
                        throw error
                    }
                    if let delaySeconds = decision.delaySeconds {
                        try await sleep(delaySeconds)
                    }
                }
            }
        }

        progress(.completed(total: plan.chunks.count))
        return normalizedText(
            completedRawTranscripts.filter { !$0.isEmpty }.joined(separator: " ")
        )
    }

    private func transcribeRange(
        sourceURL: URL,
        sourceLayout: CanonicalPCM16WAVLayout,
        chunk: CloudTranscriptionChunk,
        sizing: TranscriptionChunkSizing,
        depth: Int,
        request: @escaping @Sendable (URL, TimeInterval) async throws -> String
    ) async throws -> String {
        do {
            let materialized = try materializer.materialize(
                sourceURL: sourceURL,
                sourceLayout: sourceLayout,
                chunk: chunk,
                sizing: sizing
            )
            defer { materialized.cleanup() }
            let timeout = retryPolicy.attemptTimeout(
                encodedByteCount: materialized.encodedByteCount,
                minimum: configuration.minimumAttemptTimeoutSeconds,
                maximum: configuration.maximumAttemptTimeoutSeconds
            )
            return try await request(materialized.fileURL, timeout)
        } catch is TranscriptionChunkTruncatedFailure
            where depth < Self.maximumTruncationSplitDepth
                && chunk.endFrame - chunk.startFrame >= 2 {
            // Halves are requested in order and joined into this chunk's one
            // result; they are not checkpointed or reported as progress.
            let middle = chunk.startFrame + (chunk.endFrame - chunk.startFrame) / 2
            var parts: [String] = []
            for (start, end) in [(chunk.startFrame, middle), (middle, chunk.endFrame)] {
                let half = CloudTranscriptionChunk(
                    index: chunk.index,
                    startFrame: start,
                    endFrame: end,
                    estimatedEncodedByteCount: try sizing.encodedByteCount(
                        frameCount: end - start
                    )
                )
                parts.append(normalizedText(try await transcribeRange(
                    sourceURL: sourceURL,
                    sourceLayout: sourceLayout,
                    chunk: half,
                    sizing: sizing,
                    depth: depth + 1,
                    request: request
                )))
            }
            return parts.filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    private func normalizedText(_ text: String) -> String {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
