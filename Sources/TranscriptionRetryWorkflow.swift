import Foundation

enum TranscriptionRetryOrigin: Equatable, Sendable {
    case manual
    case startupResume
}

enum TranscriptionRetryDeliveryPolicy: Equatable, Sendable {
    case interactive
    case historyOnly
}

struct TranscriptionRetrySourceIdentity: Equatable, Sendable {
    let noteID: UUID
    let noteTimestamp: Date
    let audioFileName: String
}

enum TranscriptionRetryProcessingDisposition: Equatable, Sendable {
    case succeeded
    case fallback
}

struct TranscriptionRetryProcessingResult: Sendable {
    let rawTranscript: String
    let finalTranscript: String
    let prompt: String?
    let postProcessingStatus: String
    let aiProcessingOutcome: AIProcessingOutcome
    let spokenLanguage: SpokenLanguageResolution
    let disposition: TranscriptionRetryProcessingDisposition
}

struct TranscriptionRetryProcessingBehavior {
    var process:
        @MainActor (TranscriptionResult) async
            -> TranscriptionRetryProcessingResult
}

struct TranscriptionRetryHistoryMetadata: Sendable {
    let customVocabulary: String
    let customSystemPrompt: String
    let usedLocalTranscription: Bool
    let usedPostProcessing: Bool
    let transcriptionLanguageCode: String
    let localTranscriptionModelID: String
    let successDebugStatus: String
}

struct TranscriptionRetryFailureContext: Sendable {
    let fallbackCode: QuillUserIssueCode
    let providerHost: String?
    let modelID: String
    let localBackend: String?
}

struct TranscriptionRetryWorkflowRequest {
    let origin: TranscriptionRetryOrigin
    let deliveryPolicy: TranscriptionRetryDeliveryPolicy
    let initialItem: PipelineHistoryItem
    let sourceIdentity: TranscriptionRetrySourceIdentity
    let audioURL: URL
    let execution: TranscriptionExecutionSnapshot
    let cloudDependencies: CloudTranscriptionDependencies
    let processing: TranscriptionRetryProcessingBehavior
    let historyMetadata: TranscriptionRetryHistoryMetadata
    let failureContext: TranscriptionRetryFailureContext
}

struct TranscriptionRetryStartupInput {
    let reconciliation: CloudTranscriptionReconciliation
    let runtime: CloudTranscriptionExecutionSnapshot
    let history: [PipelineHistoryItem]
    let audioDirectory: URL
    let cloudDependenciesFactory:
        @Sendable () -> CloudTranscriptionDependencies
    let makeProcessingBehavior:
        @MainActor (
            PipelineHistoryItem,
            TranscriptionCompletionSnapshot
        ) -> TranscriptionRetryProcessingBehavior
    /// The current Local AI transcription setup, when one is selected. Local AI
    /// jobs resume only when it matches the stored job.
    var localAIExecution: LocalTranscriptionExecutionSnapshot? = nil
    var localAIResumeIdentity: LocalAITranscriptionResumeIdentity? = nil
}

struct TranscriptionRetryHistoryAccess {
    var durability:
        @MainActor @Sendable () -> PipelineHistoryDurability
    var item:
        @MainActor @Sendable (UUID) throws -> PipelineHistoryItem?
    var persist:
        @MainActor @Sendable (PipelineHistoryItem, Bool) throws -> Void
}

struct TranscriptionRetryAssetAccess: Sendable {
    var saveTranscript:
        @Sendable (String, String) throws -> String
    var deleteTranscript:
        @Sendable (String) throws -> Void
}

struct TranscriptionRetryCloudAccess {
    let jobStore: CloudTranscriptionJobStore
    var cancelExistingExecution:
        @MainActor @Sendable (UUID) -> Void
}

struct TranscriptionRetryWorkflowRuntime {
    let history: TranscriptionRetryHistoryAccess
    let assets: TranscriptionRetryAssetAccess
    let cloud: TranscriptionRetryCloudAccess
}

struct TranscriptionRetryWorkflowState: Equatable, Sendable {
    var retryingNoteIDs: Set<UUID>
    var progressByNoteID: [UUID: CloudTranscriptionDisplayProgress]

    static let initial = TranscriptionRetryWorkflowState(
        retryingNoteIDs: [],
        progressByNoteID: [:]
    )
}

struct TranscriptionRetryPersistedEffects: Equatable, Sendable {
    let advancesWarningGeneration: Bool
    let invalidatesMeetingSummary: Bool
}

struct TranscriptionRetryCompletion: Equatable, Sendable {
    let interactiveTranscript: String?
    let transcriptAssetPersisted: Bool
    let cleanupFailureDescription: String?
}

struct TranscriptionRetryFailure: Equatable, Sendable {
    let issue: QuillUserIssueRecord
    let historyPersisted: Bool
}

enum TranscriptionRetryWorkflowOutcome: Equatable, Sendable {
    case succeeded(TranscriptionRetryCompletion)
    case fallback(TranscriptionRetryCompletion)
    case failed(TranscriptionRetryFailure)
    case cancelled
    case stale
    case persistenceFailed(QuillUserIssueRecord)
}

enum TranscriptionRetryWorkflowEvent {
    case stateChanged(TranscriptionRetryWorkflowState)
    case itemPersisted(
        PipelineHistoryItem,
        TranscriptionRetryPersistedEffects
    )
    case completed(UUID, TranscriptionRetryWorkflowOutcome)
}

struct TranscriptionRetryWorkflowDependencies {
    var transcribe:
        @Sendable (
            TranscriptionExecutionSnapshot,
            URL,
            CloudTranscriptionDependencies,
            CloudTranscriptionExecutionContext?
        ) async throws -> TranscriptionResult
    var makeAttemptToken: @Sendable () -> UUID

    static let live = TranscriptionRetryWorkflowDependencies(
        transcribe: { execution, audioURL, cloudDependencies, cloudContext in
            let service = try execution.makeTranscriptionService(
                cloudDependencies: cloudDependencies,
                cloudExecutionContext: cloudContext
            )
            return try await service.transcribe(fileURL: audioURL)
        },
        makeAttemptToken: { UUID() }
    )
}

private struct TranscriptionRetryActiveAttempt {
    let token: UUID
    let revision: UInt64
    var task: Task<Void, Never>?
    let jobStore: CloudTranscriptionJobStore
    let session: CloudTranscriptionJobSession
}

final class TranscriptionRetryWorkflow: @unchecked Sendable {
    private let dependencies: TranscriptionRetryWorkflowDependencies
    @MainActor private var activeAttempts: [UUID: TranscriptionRetryActiveAttempt] = [:]
    @MainActor private var attemptRevisionByNoteID: [UUID: UInt64] = [:]
    @MainActor private(set) var state = TranscriptionRetryWorkflowState.initial
    nonisolated(unsafe) var onEvent:
        (@MainActor (TranscriptionRetryWorkflowEvent) -> Void)?

    init(dependencies: TranscriptionRetryWorkflowDependencies = .live) {
        self.dependencies = dependencies
    }

    @MainActor
    @discardableResult
    func startManual(
        request: TranscriptionRetryWorkflowRequest,
        runtime: TranscriptionRetryWorkflowRuntime
    ) -> Bool {
        guard request.origin == .manual,
              request.deliveryPolicy == .interactive else {
            return false
        }
        return start(
            request: request,
            runtime: runtime,
            seededProgress: nil
        )
    }

    @MainActor
    @discardableResult
    private func start(
        request: TranscriptionRetryWorkflowRequest,
        runtime: TranscriptionRetryWorkflowRuntime,
        seededProgress: CloudTranscriptionDisplayProgress?
    ) -> Bool {
        let noteID = request.sourceIdentity.noteID
        guard runtime.history.durability() == .durable else {
            onEvent?(
                .completed(
                    noteID,
                    .persistenceFailed(
                        QuillUserIssueRecord(
                            code: .historyPersistenceUnavailable
                        )
                    )
                )
            )
            return false
        }

        cancelCurrentAttempt(noteID: noteID)
        runtime.cloud.cancelExistingExecution(noteID)

        let token = dependencies.makeAttemptToken()
        let revision = nextRevision(noteID: noteID)
        let existingRecord = try? runtime.cloud.jobStore.load(
            historyID: noteID
        )
        let session = runtime.cloud.jobStore.beginSession(historyID: noteID)
        prepareSidecarForAttempt(
            existingRecord: existingRecord,
            request: request,
            store: runtime.cloud.jobStore,
            session: session
        )
        let cloudContext = makeCloudContext(
            request: request,
            store: runtime.cloud.jobStore,
            session: session,
            token: token,
            revision: revision
        )
        activeAttempts[noteID] = TranscriptionRetryActiveAttempt(
            token: token,
            revision: revision,
            task: nil,
            jobStore: runtime.cloud.jobStore,
            session: session
        )
        state.retryingNoteIDs.insert(noteID)
        if let seededProgress {
            state.progressByNoteID[noteID] = seededProgress
        } else {
            state.progressByNoteID.removeValue(forKey: noteID)
        }
        emitState()

        let dependencies = dependencies
        let task = Task { [weak self] in
            do {
                let transcription = try await dependencies.transcribe(
                    request.execution,
                    request.audioURL,
                    request.cloudDependencies,
                    cloudContext
                )
                try Task.checkCancellation()
                let processing = await request.processing.process(transcription)
                self?.finishProcessedAttempt(
                    request: request,
                    runtime: runtime,
                    token: token,
                    revision: revision,
                    processing: processing
                )
            } catch is CancellationError {
                self?.finishAttempt(
                    noteID: noteID,
                    token: token,
                    revision: revision,
                    outcome: .cancelled
                )
            } catch {
                self?.finishFailedAttempt(
                    error,
                    request: request,
                    runtime: runtime,
                    token: token,
                    revision: revision
                )
            }
        }
        guard isCurrentAttempt(
            noteID: noteID,
            token: token,
            revision: revision
        ) else {
            task.cancel()
            return false
        }
        activeAttempts[noteID]?.task = task
        return true
    }

    @MainActor
    func resumeAtStartup(
        input: TranscriptionRetryStartupInput,
        runtime: TranscriptionRetryWorkflowRuntime
    ) {
        let reconciliation = CloudTranscriptionStartupReconciler(
            store: runtime.cloud.jobStore,
            audioRoot: input.audioDirectory
        ).reconcile(
            input.reconciliation,
            runtime: input.runtime,
            localAI: input.localAIResumeIdentity
        )
        let historyByID = Dictionary(
            input.history.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for record in reconciliation.resumable {
            guard let item = historyByID[record.historyID],
                  let audioFileName = item.audioFileName,
                  audioFileName == record.identity.source.audioFileName,
                  Self.isSafeAudioBasename(audioFileName) else {
                continue
            }
            let completion = TranscriptionCompletionSnapshot(
                postProcessingEnabled:
                    record.completionPolicy.postProcessingEnabled,
                outputLanguage: record.completionPolicy.outputLanguage,
                pressEnterCommandEnabled:
                    record.completionPolicy.pressEnterCommandEnabled
            )
            let execution: TranscriptionExecutionSnapshot
            let failureContext: TranscriptionRetryFailureContext
            let usedLocalTranscription: Bool
            let localTranscriptionModelID: String
            switch record.identity.backend {
            case .cloud:
                execution = .cloud(input.runtime, completion)
                failureContext = TranscriptionRetryFailureContext(
                    fallbackCode: .providerConfigurationInvalid,
                    providerHost: input.runtime.baseURL.host,
                    modelID: input.runtime.model,
                    localBackend: nil
                )
                usedLocalTranscription = false
                localTranscriptionModelID = item.localTranscriptionModelID
            case .localAI(let modelID):
                guard let local = input.localAIExecution,
                      local.localAIExecution != nil else {
                    continue
                }
                execution = .local(local, completion)
                failureContext = TranscriptionRetryFailureContext(
                    fallbackCode: .localTranscriptionFailed,
                    providerHost: nil,
                    modelID: modelID,
                    localBackend: LocalAITranscriptionExecutionSnapshot.backendLabel
                )
                usedLocalTranscription = true
                localTranscriptionModelID = modelID
            }
            let processing = input.makeProcessingBehavior(
                item,
                completion
            )
            let request = TranscriptionRetryWorkflowRequest(
                origin: .startupResume,
                deliveryPolicy: .historyOnly,
                initialItem: item,
                sourceIdentity: TranscriptionRetrySourceIdentity(
                    noteID: item.id,
                    noteTimestamp: item.timestamp,
                    audioFileName: audioFileName
                ),
                audioURL: input.audioDirectory.appendingPathComponent(
                    audioFileName,
                    isDirectory: false
                ),
                execution: execution,
                cloudDependencies: input.cloudDependenciesFactory(),
                processing: processing,
                historyMetadata: TranscriptionRetryHistoryMetadata(
                    customVocabulary: item.customVocabulary,
                    customSystemPrompt: item.customSystemPrompt,
                    usedLocalTranscription: usedLocalTranscription,
                    usedPostProcessing: completion.postProcessingEnabled,
                    transcriptionLanguageCode:
                        item.transcriptionLanguageCode,
                    localTranscriptionModelID: localTranscriptionModelID,
                    successDebugStatus: "Resumed after relaunch"
                ),
                failureContext: failureContext
            )
            _ = start(
                request: request,
                runtime: runtime,
                seededProgress: CloudTranscriptionDisplayProgress(
                    completedChunkCount: record.completedChunks.count,
                    totalChunkCount: record.plan.chunks.count,
                    activeAttempt: nil
                )
            )
        }
    }

    private static func isSafeAudioBasename(_ value: String) -> Bool {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.hasPrefix("/"),
              !value.contains("/"),
              !value.contains("\\") else {
            return false
        }
        return URL(fileURLWithPath: value).lastPathComponent == value
    }

    static func classifyFailure(
        _ error: Error,
        context: TranscriptionRetryFailureContext
    ) -> QuillUserIssueError {
        if let issue = error as? QuillUserIssueError {
            return issue
        }
        if let code = urlErrorCode(in: error) {
            return QuillUserIssueError.cloudTransport(
                URLError(code),
                providerHost: context.providerHost,
                modelID: context.modelID
            )
        }
        let nsError = error as NSError
        return QuillUserIssueError(
            record: QuillUserIssueRecord(
                code: context.fallbackCode,
                context: QuillUserIssueContext(
                    providerHost: context.localBackend == nil
                        ? context.providerHost
                        : nil,
                    modelID: context.modelID,
                    localBackend: context.localBackend
                )
            ),
            privateDiagnostic: "\(nsError.domain) \(nsError.code)"
        )
    }

    private static func urlErrorCode(in error: Error) -> URLError.Code? {
        var current: Error? = error
        var depth = 0
        while let candidate = current, depth < 8 {
            if let urlError = candidate as? URLError {
                return urlError.code
            }
            let nsError = candidate as NSError
            if nsError.domain == NSURLErrorDomain {
                return URLError.Code(rawValue: nsError.code)
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? Error
            depth += 1
        }
        return nil
    }

    @MainActor
    private func prepareSidecarForAttempt(
        existingRecord: CloudTranscriptionJobRecord?,
        request: TranscriptionRetryWorkflowRequest,
        store: CloudTranscriptionJobStore,
        session: CloudTranscriptionJobSession
    ) {
        guard let existingRecord else { return }
        let isCompatible: Bool
        switch request.execution {
        case .cloud(let cloud, let completion):
            isCompatible = Self.isCompatibleRetry(
                existingRecord,
                cloud: cloud,
                completion: completion
            )
        case .local(let local, let completion):
            guard let localAI = local.localAIExecution else { return }
            isCompatible = Self.isCompatibleLocalAIRetry(
                existingRecord,
                localAI: localAI,
                language: local.language.whisperArgument,
                completion: completion
            )
        }
        guard !isCompatible else { return }
        let staleSession = CloudTranscriptionJobSession(
            historyID: request.sourceIdentity.noteID,
            token: UUID()
        )
        try? store.replaceForIncompatibleRetry(
            historyID: request.sourceIdentity.noteID,
            oldSession: staleSession,
            newSession: session
        )
    }

    private static func isCompatibleRetry(
        _ record: CloudTranscriptionJobRecord,
        cloud: CloudTranscriptionExecutionSnapshot,
        completion: TranscriptionCompletionSnapshot
    ) -> Bool {
        record.identity.providerID == cloud.providerID
            && record.identity.model == cloud.model
            && record.identity.language == cloud.language
            && record.identity.responseFormat == cloud.responseFormat
            && record.plan.encodedUploadCeilingBytes
                == cloud.encodedUploadCeilingBytes
            && record.completionPolicy == completion.cloudJobPolicy
    }

    private static func isCompatibleLocalAIRetry(
        _ record: CloudTranscriptionJobRecord,
        localAI: LocalAITranscriptionExecutionSnapshot,
        language: String?,
        completion: TranscriptionCompletionSnapshot
    ) -> Bool {
        record.identity.providerID == localAI.providerID
            && record.identity.model == localAI.modelID
            && record.identity.language == language
            && record.identity.responseFormat == localAI.requestFormat.rawValue
            && record.plan.sizing == .rawWAV
            && record.completionPolicy == completion.cloudJobPolicy
    }

    @MainActor
    private func makeCloudContext(
        request: TranscriptionRetryWorkflowRequest,
        store: CloudTranscriptionJobStore,
        session: CloudTranscriptionJobSession,
        token: UUID,
        revision: UInt64
    ) -> CloudTranscriptionExecutionContext? {
        let completion: TranscriptionCompletionSnapshot
        switch request.execution {
        case .cloud(_, let value):
            completion = value
        case .local(let local, let value) where local.localAIExecution != nil:
            completion = value
        case .local:
            return nil
        }
        let noteID = request.sourceIdentity.noteID
        return CloudTranscriptionExecutionContext(
            historyID: noteID,
            session: session,
            checkpointStore: store.checkpointStore(
                session: session,
                completionPolicy: completion.cloudJobPolicy
            ),
            progress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.recordProgress(
                        progress,
                        noteID: noteID,
                        token: token,
                        revision: revision
                    )
                }
            }
        )
    }

    @MainActor
    private func recordProgress(
        _ progress: CloudTranscriptionProgress,
        noteID: UUID,
        token: UUID,
        revision: UInt64
    ) {
        guard isCurrentAttempt(
            noteID: noteID,
            token: token,
            revision: revision
        ) else { return }
        state.progressByNoteID[noteID] = Self.displayProgress(progress)
        emitState()
    }

    private static func displayProgress(
        _ progress: CloudTranscriptionProgress
    ) -> CloudTranscriptionDisplayProgress {
        switch progress {
        case .planned(let completed, let total):
            return CloudTranscriptionDisplayProgress(
                completedChunkCount: completed,
                totalChunkCount: total,
                activeAttempt: nil
            )
        case .uploading(let index, let total, let attempt):
            return CloudTranscriptionDisplayProgress(
                completedChunkCount: index,
                totalChunkCount: total,
                activeAttempt: attempt
            )
        case .completed(let total):
            return CloudTranscriptionDisplayProgress(
                completedChunkCount: total,
                totalChunkCount: total,
                activeAttempt: nil
            )
        }
    }

    @MainActor
    private func finishProcessedAttempt(
        request: TranscriptionRetryWorkflowRequest,
        runtime: TranscriptionRetryWorkflowRuntime,
        token: UUID,
        revision: UInt64,
        processing: TranscriptionRetryProcessingResult
    ) {
        let noteID = request.sourceIdentity.noteID
        guard isCurrentAttempt(
            noteID: noteID,
            token: token,
            revision: revision
        ) else {
            return
        }

        let currentItem: PipelineHistoryItem
        do {
            guard let item = try runtime.history.item(noteID) else {
                finishAttempt(
                noteID: noteID,
                token: token,
                revision: revision,
                outcome: .stale
            )
                return
            }
            currentItem = item
        } catch {
            finishAttempt(
                noteID: noteID,
                token: token,
                revision: revision,
                outcome: .persistenceFailed(
                    QuillUserIssueRecord(code: .historyPersistenceUnavailable)
                )
            )
            return
        }
        guard currentItem.timestamp == request.sourceIdentity.noteTimestamp,
              currentItem.audioFileName == request.sourceIdentity.audioFileName else {
            finishAttempt(
                noteID: noteID,
                token: token,
                revision: revision,
                outcome: .stale
            )
            return
        }

        let transcriptFileName: String?
        let createdTranscriptFileName: String?
        if let existingFileName = currentItem.transcriptFileName {
            transcriptFileName = existingFileName
            createdTranscriptFileName = nil
        } else {
            let created = try? runtime.assets.saveTranscript(
                processing.rawTranscript,
                processing.finalTranscript
            )
            transcriptFileName = created
            createdTranscriptFileName = created
        }

        guard isCurrentAttempt(
            noteID: noteID,
            token: token,
            revision: revision
        ) else {
            if let createdTranscriptFileName {
                try? runtime.assets.deleteTranscript(createdTranscriptFileName)
            }
            return
        }

        let replacement = PipelineHistoryTranscriptionReplacement(
            rawTranscript: processing.rawTranscript,
            postProcessedTranscript: processing.finalTranscript,
            postProcessingPrompt: processing.prompt,
            postProcessingStatus: processing.postProcessingStatus,
            aiProcessingOutcome: processing.aiProcessingOutcome.pipelineHistoryStatus,
            debugStatus: request.historyMetadata.successDebugStatus,
            customVocabulary: request.historyMetadata.customVocabulary,
            customSystemPrompt: request.historyMetadata.customSystemPrompt,
            usedLocalTranscription: request.historyMetadata.usedLocalTranscription,
            usedPostProcessing: request.historyMetadata.usedPostProcessing,
            transcriptionLanguageCode:
                request.historyMetadata.transcriptionLanguageCode,
            spokenLanguage: processing.spokenLanguage,
            localTranscriptionModelID:
                request.historyMetadata.localTranscriptionModelID,
            transcriptFileName: transcriptFileName
        )
        let updatedItem = currentItem.replacingTranscription(
            with: replacement
        )

        do {
            try runtime.history.persist(updatedItem, true)
        } catch {
            if let createdTranscriptFileName {
                try? runtime.assets.deleteTranscript(createdTranscriptFileName)
            }
            finishAttempt(
                noteID: noteID,
                token: token,
                revision: revision,
                outcome: .persistenceFailed(
                    QuillUserIssueRecord(code: .historyPersistenceUnavailable)
                )
            )
            return
        }

        guard isCurrentAttempt(
            noteID: noteID,
            token: token,
            revision: revision
        ) else {
            return
        }
        onEvent?(
            .itemPersisted(
                updatedItem,
                TranscriptionRetryPersistedEffects(
                    advancesWarningGeneration: true,
                    invalidatesMeetingSummary: request.origin == .manual
                )
            )
        )

        let cleanupFailureDescription = deleteCompletedSidecarIfPresent(
            noteID: noteID,
            token: token,
            revision: revision
        )
        let completion = TranscriptionRetryCompletion(
            interactiveTranscript: request.deliveryPolicy == .interactive
                ? processing.finalTranscript
                : nil,
            transcriptAssetPersisted: transcriptFileName != nil,
            cleanupFailureDescription: cleanupFailureDescription
        )
        let outcome: TranscriptionRetryWorkflowOutcome
        switch processing.disposition {
        case .succeeded:
            outcome = .succeeded(completion)
        case .fallback:
            outcome = .fallback(completion)
        }
        finishAttempt(
            noteID: noteID,
            token: token,
            revision: revision,
            outcome: outcome
        )
    }

    @MainActor
    private func deleteCompletedSidecarIfPresent(
        noteID: UUID,
        token: UUID,
        revision: UInt64
    ) -> String? {
        guard isCurrentAttempt(
            noteID: noteID,
            token: token,
            revision: revision
        ), let attempt = activeAttempts[noteID] else {
            return nil
        }
        do {
            guard try attempt.jobStore.load(historyID: noteID) != nil else {
                return nil
            }
            try attempt.jobStore.deleteCompletedJob(
                historyID: noteID,
                session: attempt.session
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @MainActor
    private func finishFailedAttempt(
        _ error: Error,
        request: TranscriptionRetryWorkflowRequest,
        runtime: TranscriptionRetryWorkflowRuntime,
        token: UUID,
        revision: UInt64
    ) {
        let noteID = request.sourceIdentity.noteID
        guard isCurrentAttempt(
            noteID: noteID,
            token: token,
            revision: revision
        ) else {
            return
        }
        let issue = Self.classifyFailure(
            error,
            context: request.failureContext
        )

        let currentItem: PipelineHistoryItem
        do {
            guard let item = try runtime.history.item(noteID) else {
                finishAttempt(
                noteID: noteID,
                token: token,
                revision: revision,
                outcome: .stale
            )
                return
            }
            currentItem = item
        } catch {
            finishAttempt(
                noteID: noteID,
                token: token,
                revision: revision,
                outcome: .persistenceFailed(
                    QuillUserIssueRecord(code: .historyPersistenceUnavailable)
                )
            )
            return
        }
        guard currentItem.timestamp == request.sourceIdentity.noteTimestamp,
              currentItem.audioFileName == request.sourceIdentity.audioFileName else {
            finishAttempt(
                noteID: noteID,
                token: token,
                revision: revision,
                outcome: .stale
            )
            return
        }

        guard request.origin == .manual else {
            finishAttempt(
                noteID: noteID,
                token: token,
                revision: revision,
                outcome: .failed(
                    TranscriptionRetryFailure(
                        issue: issue.record,
                        historyPersisted: false
                    )
                )
            )
            return
        }

        let replacement = PipelineHistoryTranscriptionReplacement(
            rawTranscript: currentItem.rawTranscript,
            postProcessedTranscript: currentItem.postProcessedTranscript,
            postProcessingPrompt: currentItem.postProcessingPrompt,
            postProcessingStatus: issue.persistedStatus,
            aiProcessingOutcome: currentItem.aiProcessingOutcome,
            debugStatus: "Retry failed",
            customVocabulary: request.historyMetadata.customVocabulary,
            customSystemPrompt: request.historyMetadata.customSystemPrompt,
            usedLocalTranscription: request.historyMetadata.usedLocalTranscription,
            usedPostProcessing: request.historyMetadata.usedPostProcessing,
            transcriptionLanguageCode:
                request.historyMetadata.transcriptionLanguageCode,
            spokenLanguage: currentItem.spokenLanguage,
            localTranscriptionModelID:
                request.historyMetadata.localTranscriptionModelID,
            transcriptFileName: currentItem.transcriptFileName
        )
        let updatedItem = currentItem.replacingTranscription(
            with: replacement
        )
        do {
            try runtime.history.persist(updatedItem, true)
        } catch {
            finishAttempt(
                noteID: noteID,
                token: token,
                revision: revision,
                outcome: .persistenceFailed(
                    QuillUserIssueRecord(code: .historyPersistenceUnavailable)
                )
            )
            return
        }

        guard isCurrentAttempt(
            noteID: noteID,
            token: token,
            revision: revision
        ) else {
            return
        }
        onEvent?(
            .itemPersisted(
                updatedItem,
                TranscriptionRetryPersistedEffects(
                    advancesWarningGeneration: true,
                    invalidatesMeetingSummary: false
                )
            )
        )
        finishAttempt(
            noteID: noteID,
            token: token,
            revision: revision,
            outcome: .failed(
                TranscriptionRetryFailure(
                    issue: issue.record,
                    historyPersisted: true
                )
            )
        )
    }

    @MainActor
    func invalidate(noteID: UUID) {
        cancelActiveAttempt(
            noteID: noteID,
            incrementRevision: true,
            emitCancellation: true
        )
    }

    @MainActor
    func cancel(noteID: UUID) {
        cancelActiveAttempt(
            noteID: noteID,
            incrementRevision: true,
            emitCancellation: true
        )
    }

    @MainActor
    func forget(noteID: UUID) {
        cancelActiveAttempt(
            noteID: noteID,
            incrementRevision: true,
            emitCancellation: true
        )
        attemptRevisionByNoteID.removeValue(forKey: noteID)
    }

    @MainActor
    func forgetAll() {
        for noteID in Array(activeAttempts.keys) {
            cancelActiveAttempt(
                noteID: noteID,
                incrementRevision: true,
                emitCancellation: true
            )
        }
        attemptRevisionByNoteID.removeAll()
        guard state != .initial else { return }
        state = .initial
        emitState()
    }

    @MainActor
    private func cancelCurrentAttempt(noteID: UUID) {
        cancelActiveAttempt(
            noteID: noteID,
            incrementRevision: false,
            emitCancellation: true
        )
    }

    @MainActor
    private func cancelActiveAttempt(
        noteID: UUID,
        incrementRevision: Bool,
        emitCancellation: Bool
    ) {
        if incrementRevision {
            _ = nextRevision(noteID: noteID)
        }
        let attempt = activeAttempts.removeValue(forKey: noteID)
        attempt?.task?.cancel()
        attempt?.jobStore.invalidateSession(historyID: noteID)
        let removedRetry = state.retryingNoteIDs.remove(noteID) != nil
        let removedProgress = state.progressByNoteID.removeValue(
            forKey: noteID
        ) != nil
        if removedRetry || removedProgress {
            emitState()
        }
        if emitCancellation, attempt != nil {
            onEvent?(.completed(noteID, .cancelled))
        }
    }

    @MainActor
    private func nextRevision(noteID: UUID) -> UInt64 {
        let next = (attemptRevisionByNoteID[noteID] ?? 0) &+ 1
        attemptRevisionByNoteID[noteID] = next
        return next
    }

    @MainActor
    private func isCurrentAttempt(
        noteID: UUID,
        token: UUID,
        revision: UInt64
    ) -> Bool {
        guard let attempt = activeAttempts[noteID] else { return false }
        return attempt.token == token
            && attempt.revision == revision
            && attemptRevisionByNoteID[noteID] == revision
    }

    @MainActor
    private func finishAttempt(
        noteID: UUID,
        token: UUID,
        revision: UInt64,
        outcome: TranscriptionRetryWorkflowOutcome
    ) {
        guard isCurrentAttempt(
            noteID: noteID,
            token: token,
            revision: revision
        ), let attempt = activeAttempts[noteID] else {
            return
        }
        activeAttempts.removeValue(forKey: noteID)
        attempt.jobStore.invalidateSession(historyID: noteID)
        state.retryingNoteIDs.remove(noteID)
        state.progressByNoteID.removeValue(forKey: noteID)
        emitState()
        onEvent?(.completed(noteID, outcome))
    }

    @MainActor
    private func emitState() {
        onEvent?(.stateChanged(state))
    }
}
