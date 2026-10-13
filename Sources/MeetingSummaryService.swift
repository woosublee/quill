import Foundation

struct MeetingSummaryGenerationResult: Equatable, Sendable {
    let draft: MeetingSummaryDraftContentV2
    let promptVersion: Int
    let modelID: String
    let backendKind: MeetingSummaryBackendKind
    let evidenceVerification: MeetingSummaryEvidenceVerification

    init(
        draft: MeetingSummaryDraftContentV2,
        promptVersion: Int,
        modelID: String,
        backendKind: MeetingSummaryBackendKind,
        evidenceVerification: MeetingSummaryEvidenceVerification = .verified
    ) {
        self.draft = draft
        self.promptVersion = promptVersion
        self.modelID = modelID
        self.backendKind = backendKind
        self.evidenceVerification = evidenceVerification
    }
}

enum MeetingSummaryError: Error, Equatable {
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

    func effectiveModelID(fallback: String) -> String {
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

    func attributing(modelID: String) -> Self {
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

    func userIssue(
        providerHost: String?,
        modelID: String,
        localBackend: String?
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

enum MeetingSummaryStrictDecoder {
    static func decode(_ text: String) throws -> MeetingSummaryDraftContentV2 {
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
            overview: try overview(root["overview"]),
            keyPoints: try points(root["keyPoints"], field: "keyPoints"),
            decisions: try points(root["decisions"], field: "decisions"),
            actionItems: try actions(root["actionItems"]),
            openQuestions: try points(root["openQuestions"], field: "openQuestions")
        )
    }

    private static func overview(_ value: Any?) throws -> MeetingSummaryEvidenceText {
        guard let dictionary = value as? [String: Any] else {
            throw MeetingSummaryError.invalidResponse(.jsonSchema)
        }
        try requireKeys(dictionary, expected: ["text", "sourceQuotes"])
        guard let sourceQuotes = dictionary["sourceQuotes"] as? [Any] else {
            throw MeetingSummaryError.invalidResponse(.jsonSchema)
        }
        let quotes = try sourceQuotes.compactMap {
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

protocol MeetingSummaryGenerating: Sendable {
    func generate(
        source: MeetingSummarySource
    ) async throws -> MeetingSummaryGenerationResult
}

private struct MeetingSummaryByteTokenCounter: LocalAITokenCounting {
    func tokenCount(forRenderedChatPrompt prompt: String) async throws -> Int {
        prompt.utf8.count
    }
}

final class MeetingSummaryService: MeetingSummaryGenerating, @unchecked Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

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

    private static let requestTimeout: TimeInterval = 120
    private static let contextWindow = 16_384
    private static let completionCeiling = 1_024
    private static let defaultTransport: Transport = { request in
        try await LLMAPITransport.data(for: request)
    }

    private let backendExecutor: AIProcessingBackendExecutor
    private let cloudFallbackModelID: String?
    private let chunker: MeetingSummaryTextChunker
    private let tokenBudgeter: LocalAITokenBudgeter
    private let transport: Transport

    init(
        backendExecutor: AIProcessingBackendExecutor,
        cloudFallbackModelID: String?,
        chunker: MeetingSummaryTextChunker = MeetingSummaryTextChunker(),
        tokenBudgeter: LocalAITokenBudgeter? = nil,
        transport: @escaping Transport = MeetingSummaryService.defaultTransport
    ) {
        self.backendExecutor = backendExecutor
        self.cloudFallbackModelID = cloudFallbackModelID
        self.chunker = chunker
        self.tokenBudgeter = tokenBudgeter ?? LocalAITokenBudgeter(
            contextWindow: Self.contextWindow,
            tokenCounter: MeetingSummaryByteTokenCounter()
        )
        self.transport = transport
    }

    func generate(
        source: MeetingSummarySource
    ) async throws -> MeetingSummaryGenerationResult {
        // The matched calendar event, Google Calendar's included, goes only
        // to a local model; a cloud summary works from the transcript (#529).
        let source = backendExecutor.choice.isLocal ? source : source.withoutCalendar
        let normalizedTranscript = source.normalizedTranscript
        let languageCode = source.languageContext.appliedLanguageCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty, !languageCode.isEmpty else {
            throw MeetingSummaryError.invalidInput
        }
        let promptLanguage = TranscriptionLanguage.summaryPromptLanguage(
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
        let sourceByteLimit = min(
            chunker.maximumSourceBytes,
            max(1, extractionBudget.sourceTokenLimit / 2)
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
                role: .summaryExtraction
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
        while records.count > 1 {
            let allDrafts = records.map(\.draft)
            let finalPrompt = try MeetingSummaryPromptFactory.merge(
                validatedPartials: allDrafts,
                outputLanguage: promptLanguage
            )
            if try await fits(
                finalPrompt,
                role: .summaryFinalMerge
            ) {
                let final = try await generateDraft(
                    prompt: finalPrompt,
                    role: .summaryFinalMerge
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

            let batches = try await largestMergeBatches(
                from: records,
                promptLanguage: promptLanguage
            )
            guard batches.contains(where: { $0.count > 1 }) else {
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
                    role: .summaryIntermediateMerge
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
        promptLanguage: String?
    ) async throws -> [[MergeRecord]] {
        var batches: [[MergeRecord]] = []
        var current: [MergeRecord] = []

        for record in records {
            let candidate = current + [record]
            let prompt = try MeetingSummaryPromptFactory.merge(
                validatedPartials: candidate.map(\.draft),
                outputLanguage: promptLanguage
            )
            if try await fits(prompt, role: .summaryIntermediateMerge) {
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
                role: .summaryIntermediateMerge
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
        role: LocalAITokenBudgetRole
    ) async throws -> DraftResult {
        guard try await fits(prompt, role: role) else {
            throw MeetingSummaryError.invalidResponse(.contextBudget)
        }
        if backendExecutor.choice.isLocal {
            return try await requestDraft(
                prompt: prompt,
                executor: backendExecutor
            )
        }
        return try await requestCloudDraft(prompt: prompt)
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

    private func requestCloudDraft(
        prompt: MeetingSummaryPrompt
    ) async throws -> DraftResult {
        let primary = backendExecutor.choice.modelID
        let fallback = normalizedFallback(primary: primary)
        guard let effective = await LLMCooldownManager.shared.effectivePrimary(
            baseURL: backendExecutor.cloudBaseURL,
            primary: primary,
            fallback: fallback
        ) else {
            throw MeetingSummaryError.allModelsCoolingDown
        }

        var models = [effective]
        if effective == primary, let fallback {
            models.append(fallback)
        }

        var lastError: Error?
        for (index, modelID) in models.enumerated() {
            do {
                return try await requestDraft(
                    prompt: prompt,
                    executor: backendExecutor.replacingChoice(
                        .cloud(modelID: modelID)
                    )
                )
            } catch let error as MeetingSummaryError {
                lastError = error
                if case .rateLimited(_, let retryAfter, _) = error {
                    await LLMCooldownManager.shared.setCooldown(
                        LLMCooldownIdentity(
                            baseURL: backendExecutor.cloudBaseURL,
                            model: modelID
                        ),
                        retryAfterSeconds: retryAfter
                    )
                }
                let canRetry = index + 1 < models.count
                    && isFallbackEligible(error)
                if canRetry { continue }
                throw error
            } catch {
                lastError = error
                throw error
            }
        }
        throw lastError ?? MeetingSummaryError.allModelsCoolingDown
    }

    private func requestDraft(
        prompt: MeetingSummaryPrompt,
        executor: AIProcessingBackendExecutor
    ) async throws -> DraftResult {
        try await executor.withEndpoint { [self] endpoint in
            let request = try makeRequest(prompt: prompt, endpoint: endpoint)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await transport(request)
            } catch let error as URLError where error.code == .timedOut {
                throw MeetingSummaryError.requestTimedOut(
                    Self.requestTimeout,
                    modelID: endpoint.selectedModelID
                )
            } catch {
                throw MeetingSummaryError.requestFailed(
                    statusCode: 0,
                    providerCode: nil,
                    modelID: endpoint.selectedModelID
                )
            }

            guard let http = response as? HTTPURLResponse else {
                throw MeetingSummaryError.invalidResponse(
                    .responseEnvelope,
                    modelID: endpoint.selectedModelID
                )
            }
            guard (200..<300).contains(http.statusCode) else {
                let providerCode = providerErrorCode(data)
                if http.statusCode == 429 {
                    let cooldown = LLMCooldownManager.rateLimitCooldown(from: http)
                    throw MeetingSummaryError.rateLimited(
                        model: endpoint.selectedModelID,
                        retryAfter: cooldown.seconds,
                        providerCode: providerCode
                    )
                }
                throw MeetingSummaryError.requestFailed(
                    statusCode: http.statusCode,
                    providerCode: providerCode,
                    modelID: endpoint.selectedModelID
                )
            }

            let content: String
            do {
                content = try responseContent(data)
            } catch let error as MeetingSummaryError {
                throw error.attributing(modelID: endpoint.selectedModelID)
            }
            let config = ModelConfiguration.config(for: endpoint.selectedModelID)
            let cleaned = config.shouldStripThinkTags
                ? ModelConfiguration.stripThinkTags(content)
                : content
            let trimmed = cleaned.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty else {
                throw MeetingSummaryError.emptyOutput(
                    modelID: endpoint.selectedModelID
                )
            }
            let draft: MeetingSummaryDraftContentV2
            do {
                draft = try MeetingSummaryStrictDecoder.decode(trimmed)
            } catch let error as MeetingSummaryError {
                throw error.attributing(modelID: endpoint.selectedModelID)
            }
            return DraftResult(
                draft: draft,
                modelID: endpoint.selectedModelID,
                backendKind: endpoint.kind == .local ? .local : .cloud,
                evidenceVerification: .verified
            )
        }
    }

    private func makeRequest(
        prompt: MeetingSummaryPrompt,
        endpoint: AIProcessingEndpoint
    ) throws -> URLRequest {
        let url = endpoint.baseURL
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = endpoint.authorizationToken {
            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization"
            )
        }

        let config = ModelConfiguration.config(for: endpoint.selectedModelID)
        var payload: [String: Any] = [
            "model": endpoint.requestModelID,
            "temperature": 0.0,
            "max_completion_tokens": Self.completionCeiling,
            "messages": [
                ["role": "system", "content": prompt.system],
                ["role": "user", "content": prompt.user]
            ]
        ]
        if endpoint.kind == .local {
            payload["max_tokens"] = Self.completionCeiling
        }
        if let effort = config.reasoningEffort {
            payload["reasoning_effort"] = effort
        }
        if let include = config.includeReasoning {
            payload["include_reasoning"] = include
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private func normalizedFallback(primary: String) -> String? {
        guard let cloudFallbackModelID else { return nil }
        let trimmed = cloudFallbackModelID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty, trimmed != primary else { return nil }
        return trimmed
    }

    private func isFallbackEligible(_ error: MeetingSummaryError) -> Bool {
        switch error {
        case .rateLimited, .invalidResponse, .outputRejected, .emptyOutput:
            return true
        case .invalidInput, .requestFailed, .requestTimedOut,
             .allModelsCoolingDown, .sourceChanged:
            return false
        }
    }

    private func responseContent(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw MeetingSummaryError.invalidResponse(.responseEnvelope)
        }
        return content
    }

    private func providerErrorCode(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let error = root["error"] as? [String: Any] else {
            return nil
        }
        return ProviderDiagnosticCode.normalized(error["code"] as? String)
    }
}
