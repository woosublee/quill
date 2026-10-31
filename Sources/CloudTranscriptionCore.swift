import Foundation
import QuillAudioFormatCore
import QuillProviderCore

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

extension CloudTranscriptionJobIdentity {
    /// Both jobs read a converted copy of the same stored import with the
    /// same request settings, and the copies themselves differ. (A plan
    /// change on the same copy is not this; callers also compare the plan
    /// rules.)
    func differsOnlyInConvertedCopy(from other: CloudTranscriptionJobIdentity) -> Bool {
        guard let convertedFrom = source.convertedFrom,
              convertedFrom == other.source.convertedFrom,
              source.sha256 != other.source.sha256 else {
            return false
        }
        return providerID == other.providerID
            && model == other.model
            && language == other.language
            && responseFormat == other.responseFormat
    }
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
    /// The job will report chunk progress and is still reading and
    /// planning the audio (#697): the status shows its bar at 0% from the
    /// start instead of growing one when the first chunk count arrives.
    case preparing
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
