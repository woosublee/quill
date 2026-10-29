import Foundation
import QuillAITextCore
import QuillUserIssueCore
import QuillSummaryFormatCore

public struct MeetingSummaryGenerationResult: Equatable, Sendable {
    public let draft: MeetingSummaryDraftContentV2
    public let promptVersion: Int
    public let modelID: String
    public let backendKind: MeetingSummaryBackendKind
    public let evidenceVerification: MeetingSummaryEvidenceVerification
    /// The cloud host that produced the summary, set by the service so a
    /// cloud fallback for a local model is recorded with its host (#580).
    public var providerHost: String?

    public init(
        draft: MeetingSummaryDraftContentV2,
        promptVersion: Int,
        modelID: String,
        backendKind: MeetingSummaryBackendKind,
        evidenceVerification: MeetingSummaryEvidenceVerification = .verified,
        providerHost: String? = nil
    ) {
        self.draft = draft
        self.promptVersion = promptVersion
        self.modelID = modelID
        self.backendKind = backendKind
        self.evidenceVerification = evidenceVerification
        self.providerHost = providerHost
    }
}

public enum MeetingSummaryError: Error, Equatable {
    case invalidInput
    case requestFailed(
        statusCode: Int,
        providerCode: String?,
        modelID: String? = nil
    )
    case rateLimited(
        model: String,
        retryAfter: TimeInterval,
        providerCode: String? = nil
    )
    case invalidResponse(
        MeetingSummaryFailureSubtype,
        modelID: String? = nil
    )
    case outputRejected(
        MeetingSummaryOutputValidationError,
        modelID: String? = nil
    )
    case emptyOutput(modelID: String? = nil)
    case requestTimedOut(TimeInterval, modelID: String? = nil)
    case allModelsCoolingDown
    case sourceChanged

    public func effectiveModelID(fallback: String) -> String {
        switch self {
        case .rateLimited(let model, _, _):
            model
        case .requestFailed(_, _, let modelID),
             .invalidResponse(_, let modelID),
             .outputRejected(_, let modelID),
             .emptyOutput(let modelID),
             .requestTimedOut(_, let modelID):
            modelID ?? fallback
        case .invalidInput, .allModelsCoolingDown, .sourceChanged:
            fallback
        }
    }

    public func attributing(modelID: String) -> Self {
        switch self {
        case .requestFailed(let statusCode, let providerCode, nil):
            .requestFailed(
                statusCode: statusCode,
                providerCode: providerCode,
                modelID: modelID
            )
        case .invalidResponse(let subtype, nil):
            .invalidResponse(subtype, modelID: modelID)
        case .outputRejected(let rejection, nil):
            .outputRejected(rejection, modelID: modelID)
        case .emptyOutput(nil):
            .emptyOutput(modelID: modelID)
        case .requestTimedOut(let timeout, nil):
            .requestTimedOut(timeout, modelID: modelID)
        default:
            self
        }
    }

    /// `severity` nil uses the code's default; the iPhone app passes its own.
    public func userIssue(
        providerHost: String?,
        modelID: String,
        localBackend: String?,
        severity: QuillUserIssueSeverity? = nil
    ) -> QuillUserIssueRecord {
        let code: QuillUserIssueCode
        let status: Int?
        let providerCode: String?
        let effectiveModelID: String
        switch self {
        case .requestTimedOut(_, let endpointModelID):
            code = .meetingSummaryUnavailable
            status = nil
            providerCode = nil
            effectiveModelID = endpointModelID ?? modelID
        case .rateLimited(let endpointModelID, _, let responseCode):
            code = .meetingSummaryUnavailable
            status = 429
            providerCode = ProviderDiagnosticCode.normalized(responseCode)
            effectiveModelID = endpointModelID
        case .allModelsCoolingDown:
            code = .meetingSummaryUnavailable
            status = 429
            providerCode = nil
            effectiveModelID = modelID
        case .requestFailed(let statusCode, let responseCode, let endpointModelID):
            status = statusCode > 0 ? statusCode : nil
            providerCode = ProviderDiagnosticCode.normalized(responseCode)
            effectiveModelID = endpointModelID ?? modelID
            if statusCode == 401 || statusCode == 403 {
                code = .authenticationFailed
            } else {
                code = .meetingSummaryUnavailable
            }
        case .invalidResponse(_, let endpointModelID),
             .outputRejected(_, let endpointModelID),
             .emptyOutput(let endpointModelID):
            code = .meetingSummaryInvalidResponse
            status = nil
            providerCode = nil
            effectiveModelID = endpointModelID ?? modelID
        case .invalidInput, .sourceChanged:
            code = .meetingSummaryUnavailable
            status = nil
            providerCode = nil
            effectiveModelID = modelID
        }
        return QuillUserIssueRecord(
            code: code,
            severity: severity,
            context: QuillUserIssueContext(
                httpStatus: status,
                providerHost: providerHost,
                providerCode: providerCode,
                modelID: effectiveModelID,
                localBackend: localBackend,
                meetingSummaryFailureSubtype: failureSubtype
            )
        )
    }

    private var failureSubtype: MeetingSummaryFailureSubtype? {
        switch self {
        case .invalidResponse(let subtype, _):
            return subtype
        case .outputRejected(let rejection, _):
            return rejection.failureSubtype
        case .emptyOutput:
            return .emptyOutput
        case .invalidInput, .requestFailed, .rateLimited,
             .requestTimedOut, .allModelsCoolingDown, .sourceChanged:
            return nil
        }
    }
}

public enum MeetingSummaryStrictDecoder {
    /// `unwrapsNestedSourceQuotes` accepts the one shape the iPhone's small
    /// local model writes for the overview's `sourceQuotes`: a single inner
    /// array, `[["quote", "quote"]]`, which is unwrapped (`[[]]` is no
    /// quotes, like `[]`). Mixed (`[["quote"], "quote"]`) or several inner
    /// arrays are rejected, as the Mac rejects any nesting (#643). Null and
    /// blank quotes are dropped either way. The Mac's local model is held to
    /// the schema, so the Mac leaves this off.
    public static func decode(
        _ text: String,
        unwrapsNestedSourceQuotes: Bool = false
    ) throws -> MeetingSummaryDraftContentV2 {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw MeetingSummaryError.invalidResponse(.jsonSchema)
        }
        try requireKeys(
            root,
            expected: [
                "overview",
                "keyPoints",
                "decisions",
                "actionItems",
                "openQuestions"
            ]
        )

        return MeetingSummaryDraftContentV2(
            overview: try overview(
                root["overview"],
                unwrapsNestedSourceQuotes: unwrapsNestedSourceQuotes
            ),
            keyPoints: try points(root["keyPoints"], field: "keyPoints"),
            decisions: try points(root["decisions"], field: "decisions"),
            actionItems: try actions(root["actionItems"]),
            openQuestions: try points(root["openQuestions"], field: "openQuestions")
        )
    }

    private static func overview(
        _ value: Any?,
        unwrapsNestedSourceQuotes: Bool
    ) throws -> MeetingSummaryEvidenceText {
        guard let dictionary = value as? [String: Any] else {
            throw MeetingSummaryError.invalidResponse(.jsonSchema)
        }
        try requireKeys(dictionary, expected: ["text", "sourceQuotes"])
        guard let sourceQuotes = dictionary["sourceQuotes"] as? [Any] else {
            throw MeetingSummaryError.invalidResponse(.jsonSchema)
        }
        let flattened: [Any]
        if unwrapsNestedSourceQuotes,
           sourceQuotes.count == 1,
           let inner = sourceQuotes.first as? [Any] {
            flattened = inner
        } else {
            flattened = sourceQuotes
        }
        let quotes = try flattened.compactMap {
            try optionalEvidenceString($0)
        }
        return MeetingSummaryEvidenceText(
            text: try requiredString(dictionary["text"], field: "overview text"),
            sourceQuotes: quotes
        )
    }

    private static func points(
        _ value: Any?,
        field: String
    ) throws -> [MeetingSummaryPoint] {
        guard let values = value as? [Any] else {
            throw MeetingSummaryError.invalidResponse(.jsonSchema)
        }
        return try values.map { value in
            guard let dictionary = value as? [String: Any] else {
                throw MeetingSummaryError.invalidResponse(.jsonSchema)
            }
            try requireKeys(dictionary, expected: ["text", "sourceQuote"])
            return MeetingSummaryPoint(
                id: UUID(),
                text: try requiredString(dictionary["text"], field: "text"),
                sourceQuote: try optionalEvidenceString(
                    dictionary["sourceQuote"]
                )
            )
        }
    }

    private static func actions(
        _ value: Any?
    ) throws -> [MeetingSummaryActionItem] {
        guard let values = value as? [Any] else {
            throw MeetingSummaryError.invalidResponse(.jsonSchema)
        }
        return try values.map { value in
            guard let dictionary = value as? [String: Any] else {
                throw MeetingSummaryError.invalidResponse(.jsonSchema)
            }
            try requireKeys(
                dictionary,
                expected: ["task", "owner", "dueDate", "sourceQuote"]
            )
            return MeetingSummaryActionItem(
                id: UUID(),
                task: try requiredString(dictionary["task"], field: "task"),
                owner: try optionalString(dictionary["owner"], field: "owner"),
                dueDate: try optionalString(
                    dictionary["dueDate"],
                    field: "dueDate"
                ),
                sourceQuote: try optionalEvidenceString(
                    dictionary["sourceQuote"]
                ),
                isCompleted: false
            )
        }
    }

    private static func requireKeys(
        _ dictionary: [String: Any],
        expected: Set<String>
    ) throws {
        guard Set(dictionary.keys) == expected else {
            throw MeetingSummaryError.invalidResponse(.jsonSchema)
        }
    }

    private static func requiredString(
        _ value: Any?,
        field: String
    ) throws -> String {
        guard let value = value as? String else {
            throw MeetingSummaryError.invalidResponse(.jsonSchema)
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MeetingSummaryError.invalidResponse(.jsonSchema)
        }
        return trimmed
    }

    private static func optionalEvidenceString(
        _ value: Any?
    ) throws -> String? {
        if value == nil || value is NSNull { return nil }
        guard let value = value as? String else {
            throw MeetingSummaryError.invalidResponse(.jsonSchema)
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func optionalString(
        _ value: Any?,
        field: String
    ) throws -> String? {
        if value == nil || value is NSNull { return nil }
        guard let value = value as? String else {
            throw MeetingSummaryError.invalidResponse(.jsonSchema)
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One model request for a summary draft, with the budget the generator
/// checked for its prompt.
public struct MeetingSummaryDraftRequest: Sendable {
    public let prompt: MeetingSummaryPrompt
    public let role: LocalAITokenBudgetRole
    public let budget: LocalAITokenBudget
    public let outputLanguageCode: String

    public init(
        prompt: MeetingSummaryPrompt,
        role: LocalAITokenBudgetRole,
        budget: LocalAITokenBudget,
        outputLanguageCode: String
    ) {
        self.prompt = prompt
        self.role = role
        self.budget = budget
        self.outputLanguageCode = outputLanguageCode
    }
}

/// A decoded draft and the model that wrote it, which may be a fallback.
public struct MeetingSummaryDraftReply: Sendable {
    public let draft: MeetingSummaryDraftContentV2
    public let modelID: String
    public let backendKind: MeetingSummaryBackendKind

    public init(
        draft: MeetingSummaryDraftContentV2,
        modelID: String,
        backendKind: MeetingSummaryBackendKind
    ) {
        self.draft = draft
        self.modelID = modelID
        self.backendKind = backendKind
    }
}

/// Sends one draft request to a model and decodes its reply with
/// `MeetingSummaryStrictDecoder`. Each app keeps its own requests, retries,
/// fallbacks, and what comes before decoding: the request's response format,
/// stripping reasoning tags or code fences, and telling a cut-off reply from
/// a malformed one.
public protocol MeetingSummaryDraftRequesting: Sendable {
    /// Local or cloud. Only a local model gets the calendar event (#529).
    var backendKind: MeetingSummaryBackendKind { get }
    func requestDraft(
        _ request: MeetingSummaryDraftRequest
    ) async throws -> MeetingSummaryDraftReply
}

/// Splits the transcript into chunks that fit, summarizes each, merges the
/// partial summaries, and repairs and checks every draft against the
/// transcript. The model calls go through `MeetingSummaryDraftRequesting`.
public struct MeetingSummaryGenerator: Sendable {
    private struct DraftResult {
        let draft: MeetingSummaryDraftContentV2
        let modelID: String
        let backendKind: MeetingSummaryBackendKind
        let evidenceVerification: MeetingSummaryEvidenceVerification
    }

    private struct MergeRecord {
        let draft: MeetingSummaryDraftContentV2
        let modelID: String
        let backendKind: MeetingSummaryBackendKind
        let evidenceVerification: MeetingSummaryEvidenceVerification
    }

    private let requester: any MeetingSummaryDraftRequesting
    private let tokenBudgeter: LocalAITokenBudgeter
    private let chunker: MeetingSummaryTextChunker

    public init(
        requester: any MeetingSummaryDraftRequesting,
        tokenBudgeter: LocalAITokenBudgeter,
        chunker: MeetingSummaryTextChunker = MeetingSummaryTextChunker()
    ) {
        self.requester = requester
        self.tokenBudgeter = tokenBudgeter
        self.chunker = chunker
    }

    public func generate(
        source: MeetingSummarySource
    ) async throws -> MeetingSummaryGenerationResult {
        // The matched calendar event, Google Calendar's included, goes only
        // to a local model; a cloud summary works from the transcript (#529).
        let source = requester.backendKind == .local ? source : source.withoutCalendar
        let normalizedTranscript = source.normalizedTranscript
        let languageCode = source.languageContext.appliedLanguageCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty, !languageCode.isEmpty else {
            throw MeetingSummaryError.invalidInput
        }
        let promptLanguage = MeetingSummaryPromptLanguage.name(
            for: languageCode
        )

        let extractionBudgetPrompt = try MeetingSummaryPromptFactory.singlePass(
            source: MeetingSummarySource(
                transcript: "",
                calendar: source.calendar,
                languageContext: source.languageContext
            ),
            outputLanguage: promptLanguage
        )
        let extractionBudget = try await sourceBudget(
            for: extractionBudgetPrompt,
            role: .summaryExtraction
        )
        // The budget is in tokens and the chunker cuts bytes; convert with
        // this transcript's own ratio, which is 1 for the byte counter. It
        // multiplies before dividing, so a ratio such as 1.9 bytes a token
        // isn't floored to 1 (#643); a ratio below 1 counts as 1.
        let transcriptTokens = try await tokenBudgeter.tokenCounter.tokenCount(
            forRenderedChatPrompt: normalizedTranscript
        )
        let sourceBytes = extractionBudget.sourceTokenLimit
            * max(normalizedTranscript.utf8.count, transcriptTokens)
            / max(1, transcriptTokens)
        // Half of that, as cleanup does: JSON escaping can double an ASCII
        // character, and a chunk can be denser than the transcript's average.
        let sourceByteLimit = min(
            chunker.maximumSourceBytes,
            max(1, sourceBytes / 2)
        )
        let chunks = MeetingSummaryTextChunker(
            maximumSourceBytes: sourceByteLimit
        ).chunks(for: normalizedTranscript)
        guard !chunks.isEmpty else {
            throw MeetingSummaryError.invalidInput
        }

        let sourceData = SummarySourceData(
            transcript: normalizedTranscript,
            calendar: source.calendar
        )
        var records: [MergeRecord] = []
        for chunk in chunks {
            let prompt = try MeetingSummaryPromptFactory.chunkExtraction(
                chunk: chunk,
                calendar: source.calendar,
                outputLanguage: promptLanguage
            )
            let partial = try await generateDraft(
                prompt: prompt,
                role: .summaryExtraction,
                outputLanguageCode: languageCode
            )
            let repaired = try repairAndValidate(
                partial,
                outputLanguageCode: languageCode,
                source: sourceData
            )
            records.append(
                MergeRecord(
                    draft: repaired.draft,
                    modelID: repaired.modelID,
                    backendKind: repaired.backendKind,
                    evidenceVerification: repaired.evidenceVerification
                )
            )
        }

        let final: DraftResult
        if records.count == 1, let only = records.first {
            final = DraftResult(
                draft: only.draft,
                modelID: only.modelID,
                backendKind: only.backendKind,
                evidenceVerification: only.evidenceVerification
            )
        } else {
            final = try await merge(
                records: records,
                promptLanguage: promptLanguage,
                outputLanguageCode: languageCode,
                source: sourceData
            )
        }

        return MeetingSummaryGenerationResult(
            draft: final.draft,
            promptVersion: MeetingSummaryPromptFactory.version,
            modelID: final.modelID,
            backendKind: final.backendKind,
            evidenceVerification: final.evidenceVerification
        )
    }

    private func merge(
        records initialRecords: [MergeRecord],
        promptLanguage: String?,
        outputLanguageCode: String,
        source: SummarySourceData
    ) async throws -> DraftResult {
        var records = initialRecords
        // A merge leaves the full response room, unless that leaves no
        // batch to merge; then it tries with the extraction room (#610).
        // When the extraction room isn't smaller (the iPhone, and Mac cloud
        // summaries, use one room for both), that pass checks the same
        // budgets again and ends the same way, so it is skipped (#643).
        let compactLeavesMoreRoom = tokenBudgeter.compactMergeLeavesMoreRoom
        var compact = false
        while records.count > 1 {
            let finalRole: LocalAITokenBudgetRole = compact
                ? .summaryCompactMerge
                : .summaryFinalMerge
            let batchRole: LocalAITokenBudgetRole = compact
                ? .summaryCompactMerge
                : .summaryIntermediateMerge
            let allDrafts = records.map(\.draft)
            let finalPrompt = try MeetingSummaryPromptFactory.merge(
                validatedPartials: allDrafts,
                outputLanguage: promptLanguage
            )
            if try await fits(
                finalPrompt,
                role: finalRole
            ) {
                let final = try await generateDraft(
                    prompt: finalPrompt,
                    role: finalRole,
                    outputLanguageCode: outputLanguageCode
                )
                let repaired = try repairAndValidate(
                    final,
                    outputLanguageCode: outputLanguageCode,
                    source: source
                )
                return DraftResult(
                    draft: repaired.draft,
                    modelID: repaired.modelID,
                    backendKind: repaired.backendKind,
                    evidenceVerification: combinedVerification(
                        repaired.evidenceVerification,
                        records.map(\.evidenceVerification)
                    )
                )
            }

            let batches: [[MergeRecord]]
            do {
                batches = try await largestMergeBatches(
                    from: records,
                    promptLanguage: promptLanguage,
                    role: batchRole
                )
            } catch MeetingSummaryError.invalidResponse(.mergeBudget, _) where !compact && compactLeavesMoreRoom {
                compact = true
                continue
            }
            guard batches.contains(where: { $0.count > 1 }) else {
                if !compact && compactLeavesMoreRoom {
                    compact = true
                    continue
                }
                throw MeetingSummaryError.invalidResponse(.mergeBudget)
            }

            var merged: [MergeRecord] = []
            for batch in batches {
                guard batch.count > 1 else {
                    merged.append(batch[0])
                    continue
                }
                let inputs = batch.map(\.draft)
                let prompt = try MeetingSummaryPromptFactory.merge(
                    validatedPartials: inputs,
                    outputLanguage: promptLanguage
                )
                let result = try await generateDraft(
                    prompt: prompt,
                    role: batchRole,
                    outputLanguageCode: outputLanguageCode
                )
                let repaired = try repairAndValidate(
                    result,
                    outputLanguageCode: outputLanguageCode,
                    source: source
                )
                merged.append(
                    MergeRecord(
                        draft: repaired.draft,
                        modelID: repaired.modelID,
                        backendKind: repaired.backendKind,
                        evidenceVerification: combinedVerification(
                            repaired.evidenceVerification,
                            batch.map(\.evidenceVerification)
                        )
                    )
                )
            }
            records = merged
            compact = false
        }

        guard let record = records.first else {
            throw MeetingSummaryError.invalidResponse(.mergeBudget)
        }
        return DraftResult(
            draft: record.draft,
            modelID: record.modelID,
            backendKind: record.backendKind,
            evidenceVerification: record.evidenceVerification
        )
    }

    private func largestMergeBatches(
        from records: [MergeRecord],
        promptLanguage: String?,
        role: LocalAITokenBudgetRole
    ) async throws -> [[MergeRecord]] {
        var batches: [[MergeRecord]] = []
        var current: [MergeRecord] = []

        for record in records {
            let candidate = current + [record]
            let prompt = try MeetingSummaryPromptFactory.merge(
                validatedPartials: candidate.map(\.draft),
                outputLanguage: promptLanguage
            )
            if try await fits(prompt, role: role) {
                current = candidate
                continue
            }

            if current.isEmpty {
                throw MeetingSummaryError.invalidResponse(.mergeBudget)
            }
            batches.append(current)
            current = [record]
            let singlePrompt = try MeetingSummaryPromptFactory.merge(
                validatedPartials: [record.draft],
                outputLanguage: promptLanguage
            )
            guard try await fits(
                singlePrompt,
                role: role
            ) else {
                throw MeetingSummaryError.invalidResponse(.mergeBudget)
            }
        }
        if !current.isEmpty {
            batches.append(current)
        }
        return batches
    }

    private func generateDraft(
        prompt: MeetingSummaryPrompt,
        role: LocalAITokenBudgetRole,
        outputLanguageCode: String
    ) async throws -> DraftResult {
        guard let budget = try await tokenBudgeter.budget(
            forRenderedChatPrompt: renderedPrompt(prompt),
            role: role
        ) else {
            throw MeetingSummaryError.invalidResponse(.contextBudget)
        }
        let reply = try await requester.requestDraft(
            MeetingSummaryDraftRequest(
                prompt: prompt,
                role: role,
                budget: budget,
                outputLanguageCode: outputLanguageCode
            )
        )
        return DraftResult(
            draft: reply.draft,
            modelID: reply.modelID,
            backendKind: reply.backendKind,
            evidenceVerification: .verified
        )
    }

    private func sourceBudget(
        for prompt: MeetingSummaryPrompt,
        role: LocalAITokenBudgetRole
    ) async throws -> LocalAITokenBudget {
        guard let budget = try await tokenBudgeter.budget(
            forRenderedChatPrompt: renderedPrompt(prompt),
            role: role
        ) else {
            throw MeetingSummaryError.invalidResponse(.contextBudget)
        }
        return budget
    }

    private func fits(
        _ prompt: MeetingSummaryPrompt,
        role: LocalAITokenBudgetRole
    ) async throws -> Bool {
        try await tokenBudgeter.budget(
            forRenderedChatPrompt: renderedPrompt(prompt),
            role: role
        ) != nil
    }

    private func renderedPrompt(_ prompt: MeetingSummaryPrompt) -> String {
        "[System]\n\(prompt.system)\n\n[User]\n\(prompt.user)"
    }

    private func repairAndValidate(
        _ result: DraftResult,
        outputLanguageCode: String,
        source: SummarySourceData
    ) throws -> DraftResult {
        let repaired = MeetingSummaryEvidenceRepairer().repair(
            result.draft,
            sourceTexts: MeetingSummaryOutputValidator.sourceTexts(for: source)
        )
        do {
            try MeetingSummaryOutputValidator().validateLanguage(
                repaired.draft,
                outputLanguage: outputLanguageCode
            )
        } catch let error as MeetingSummaryOutputValidationError {
            throw MeetingSummaryError.outputRejected(error, modelID: result.modelID)
        }
        return DraftResult(
            draft: repaired.draft,
            modelID: result.modelID,
            backendKind: result.backendKind,
            evidenceVerification: combinedVerification(
                result.evidenceVerification,
                [repaired.verification]
            )
        )
    }

    private func combinedVerification(
        _ first: MeetingSummaryEvidenceVerification,
        _ rest: [MeetingSummaryEvidenceVerification]
    ) -> MeetingSummaryEvidenceVerification {
        ([first] + rest).contains(.unverified) ? .unverified : .verified
    }
}
