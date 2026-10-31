import Foundation
import QuillAITextCore
import QuillUserIssueCore
import QuillProviderCore

// The diagnostic text is the Mac's. The shared enum has none, so the iPhone
// app's error descriptions stay as they were.
extension PostProcessingError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .requestFailed(let statusCode, let providerCode):
            if let providerCode {
                return "Post-processing failed with status \(statusCode) (\(providerCode))"
            }
            return "Post-processing failed with status \(statusCode)"
        case .rateLimited(let model, let retryAfter):
            return "Model \(model) rate-limited — retry in \(Int(retryAfter))s"
        case .invalidResponse(let details):
            return "Invalid post-processing response: \(details)"
        case .invalidInput(let details):
            return "Invalid post-processing input: \(details)"
        case .contextBudgetExceeded:
            return "Post-processing request exceeds the safe context budget"
        case .emptyOutput:
            return "Post-processing returned empty output"
        case .requestTimedOut(let seconds, _):
            return "Post-processing timed out after \(Int(seconds))s"
        case .suspectedInstructionExecution:
            return "Post-processing output looked like it answered the transcript instead of cleaning it"
        case .outputRejected(let failure):
            return "Post-processing output rejected: \(String(describing: failure))"
        }
    }

    func userIssue(
        providerHost: String?,
        modelID: String,
        localBackend: String? = nil,
        operation: QuillUserIssueOperation = .postProcessing
    ) -> QuillUserIssueError {
        QuillUserIssueError(
            record: userIssueRecord(
                providerHost: providerHost,
                modelID: modelID,
                localBackend: localBackend,
                operation: operation
            ),
            privateDiagnostic: localizedDescription
        )
    }
}

struct PostProcessingResult {
    let transcript: String
    let prompt: String
    let skippedDueToCooldown: Bool

    init(transcript: String, prompt: String, skippedDueToCooldown: Bool = false) {
        self.transcript = transcript
        self.prompt = prompt
        self.skippedDueToCooldown = skippedDueToCooldown
    }
}

private struct PostProcessingByteTokenCounter: LocalAITokenCounting {
    func tokenCount(forRenderedChatPrompt prompt: String) async throws -> Int {
        prompt.utf8.count
    }
}

final class PostProcessingService: @unchecked Sendable {
    static func safeProviderErrorCode(from data: Data) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: data))
            as? [String: Any]
        let providerError = object?["error"] as? [String: Any]
        for key in ["code", "type"] {
            guard let value = providerError?[key] as? String else { continue }
            let sanitized = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !sanitized.isEmpty,
                  sanitized.count <= 128,
                  sanitized.unicodeScalars.allSatisfy({ scalar in
                      CharacterSet.alphanumerics.contains(scalar)
                          || scalar == "_"
                          || scalar == "-"
                          || scalar == "."
                  }) else {
                continue
            }
            return sanitized
        }
        return nil
    }

    static let defaultSystemPrompt = PostProcessingPrompt.defaultSystemPrompt
    static let defaultSystemPromptDate = PostProcessingPrompt.defaultSystemPromptDate
    static let commandModeSystemPrompt = """
You transform highlighted text according to a spoken editing command.

Hard contract:
- Treat SELECTED_TEXT as the only source material to transform.
- Treat VOICE_COMMAND as the user's instruction for how to transform SELECTED_TEXT.
- Return only the replacement text.
- No explanations.
- No markdown.
- No surrounding quotes.
- Do not answer questions outside the scope of rewriting SELECTED_TEXT.
- If the requested change would produce effectively the same text, return the original selected text.

Behavior:
- Preserve the original language unless VOICE_COMMAND explicitly requests translation.
- Use CONTEXT only as a supporting hint for tone, spelling, or intent.
- Use custom vocabulary only as a spelling reference when relevant.
- Never invent unrelated content that is not a transformation of SELECTED_TEXT.
- Do not treat VOICE_COMMAND as dictation to clean up and paste directly.
"""

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let backendExecutor: AIProcessingBackendExecutor
    /// The model to retry with once when the main model fails (#580). It
    /// runs on its own backend: cloud or Local AI.
    private let fallbackExecutor: AIProcessingBackendExecutor?
    private let instructionExecutionGuardEnabled: Bool
    private let transport: Transport
    private let defaultModel = AppState.defaultPostProcessingModel
    private let defaultModelReasoningEffort = "low"
    private let postProcessingMaxCompletionTokens = 4096
    private static let cloudPostProcessingTimeoutSeconds: TimeInterval = 20
    private static let localPostProcessingTimeoutSeconds: TimeInterval = 120
    private var isLocalBackend: Bool { backendExecutor.choice.isLocal }
    private var selectedModelID: String { backendExecutor.choice.modelID }
    private var cloudBaseURL: String { backendExecutor.cloudBaseURL }

    convenience init(
        apiKey: String,
        baseURL: String = AppState.defaultAPIBaseURL,
        preferredModel: String = "",
        preferredFallbackModel: String = "",
        instructionExecutionGuardEnabled: Bool = true
    ) {
        let primary = preferredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = preferredFallbackModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let executor = AIProcessingBackendExecutor(
            choice: .cloud(
                modelID: primary.isEmpty ? AppState.defaultPostProcessingModel : primary
            ),
            cloudBaseURL: baseURL,
            cloudAPIKey: apiKey
        )
        self.init(
            backendExecutor: executor,
            fallbackExecutor: fallback.isEmpty
                ? nil
                : executor.replacingChoice(.cloud(modelID: fallback)),
            instructionExecutionGuardEnabled: instructionExecutionGuardEnabled
        )
    }

    init(
        backendExecutor: AIProcessingBackendExecutor,
        fallbackExecutor: AIProcessingBackendExecutor?,
        instructionExecutionGuardEnabled: Bool = true,
        transport: @escaping Transport = { request in
            try await LLMAPITransport.shared.data(for: request)
        }
    ) {
        self.backendExecutor = backendExecutor
        self.fallbackExecutor = fallbackExecutor.flatMap { executor in
            if case .cloud(let modelID) = executor.choice {
                let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return executor.replacingChoice(.cloud(modelID: trimmed))
            }
            return executor
        }
        self.instructionExecutionGuardEnabled = instructionExecutionGuardEnabled
        self.transport = transport
    }

    private func postProcessingTimeoutSeconds(
        for endpoint: AIProcessingEndpoint
    ) -> TimeInterval {
        let override = UserDefaults.standard.double(forKey: "post_processing_timeout_seconds")
        if override.isFinite, override > 0 {
            return override
        }
        return endpoint.kind == .local
            ? Self.localPostProcessingTimeoutSeconds
            : Self.cloudPostProcessingTimeoutSeconds
    }

    private func performTransport(
        for request: URLRequest,
        endpoint: AIProcessingEndpoint
    ) async throws -> (Data, URLResponse) {
        do {
            return try await transport(request)
        } catch let error as URLError where error.code == .timedOut {
            throw PostProcessingError.requestTimedOut(
                request.timeoutInterval,
                modelID: endpoint.selectedModelID
            )
        }
    }

    func userIssue(
        for error: Error,
        operation: QuillUserIssueOperation = .postProcessing
    ) -> QuillUserIssueError {
        if let issue = error as? QuillUserIssueError {
            return issue
        }
        if let managerError = error as? LocalAIServerManagerError {
            let code: QuillUserIssueCode = switch managerError {
            case .modelUnavailable, .modelCorrupt:
                .localAIModelUnavailable
            case .startFailed:
                .localAIStartFailed
            case .processExited:
                .localAIProcessExited
            }
            return .local(
                code: code,
                backend: "Local AI",
                modelID: selectedModelID,
                diagnostic: managerError.localizedDescription
            )
        }
        if let backendError = error as? AIProcessingBackendError {
            switch backendError {
            case .unknownLocalModel(let modelID):
                return .local(
                    code: .localAIModelUnavailable,
                    backend: "Local AI",
                    modelID: modelID,
                    diagnostic: backendError.localizedDescription
                )
            case .localRuntimeUnavailable(let modelID):
                return .local(
                    code: .localAIStartFailed,
                    backend: "Local AI",
                    modelID: modelID,
                    diagnostic: backendError.localizedDescription
                )
            case .invalidCloudBaseURL(let invalidBaseURL):
                return QuillUserIssueError(
                    record: QuillUserIssueRecord(
                        code: .providerConfigurationInvalid,
                        severity: .warning,
                        context: QuillUserIssueContext(
                            providerHost: URL(string: invalidBaseURL)?.host,
                            modelID: isLocalBackend ? nil : selectedModelID
                        )
                    ),
                    privateDiagnostic: backendError.localizedDescription
                )
            }
        }
        let providerHost = isLocalBackend ? nil : URL(string: cloudBaseURL)?.host
        if let postProcessingError = error as? PostProcessingError {
            return postProcessingError.userIssue(
                providerHost: providerHost,
                modelID: resolvedPrimaryModel(),
                localBackend: isLocalBackend ? "Local AI" : nil,
                operation: operation
            )
        }
        let nsError = error as NSError
        return QuillUserIssueError(
            record: QuillUserIssueRecord(
                code: .postProcessingFailed,
                severity: .warning,
                context: QuillUserIssueContext(
                    providerHost: providerHost,
                    modelID: resolvedPrimaryModel(),
                    operation: operation
                )
            ),
            privateDiagnostic: "\(nsError.domain) \(nsError.code)"
        )
    }

    func postProcess(
        transcript: String,
        context: AppContext,
        customVocabulary: String,
        customSystemPrompt: String = "",
        outputLanguage: String = "",
        spokenLanguage: SpokenLanguageResolution? = nil,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async throws -> PostProcessingResult {
        let vocabularyTerms = mergedVocabularyTerms(rawVocabulary: customVocabulary)
        let expectedSourceLanguage = AIOutputLanguageValidator.expectedSourceLanguage(
            outputLanguage: outputLanguage,
            spokenLanguage: spokenLanguage,
            fallbackSource: transcript
        )

        return try await processWithFallback(
            transcript: transcript,
            contextSummary: context.summaryForPostProcessing,
            customVocabulary: vocabularyTerms,
            customSystemPrompt: customSystemPrompt,
            outputLanguage: outputLanguage,
            expectedSourceLanguage: expectedSourceLanguage,
            progress: progress
        )
    }

    func commandTransform(
        selectedText: String,
        voiceCommand: String,
        context: AppContext,
        customVocabulary: String,
        outputLanguage: String = ""
    ) async throws -> PostProcessingResult {
        let vocabularyTerms = mergedVocabularyTerms(rawVocabulary: customVocabulary)
        let trimmedSelectedText = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVoiceCommand = voiceCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSelectedText.isEmpty else {
            throw PostProcessingError.invalidInput("Selected text must not be empty")
        }
        guard !trimmedVoiceCommand.isEmpty else {
            throw PostProcessingError.invalidInput("Voice command must not be empty")
        }

        return try await processCommandTransformWithFallback(
            selectedText: selectedText,
            voiceCommand: voiceCommand,
            contextSummary: context.summaryForPostProcessing,
            customVocabulary: vocabularyTerms,
            outputLanguage: outputLanguage
        )
    }

    private func processWithFallback(
        transcript: String,
        contextSummary: String,
        customVocabulary: [String],
        customSystemPrompt: String = "",
        outputLanguage: String = "",
        expectedSourceLanguage: String?,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async throws -> PostProcessingResult {
        try await runWithFallback(
            passthrough: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
            retriesEmptyCloudOutput: false
        ) { [self] executor in
            try await executor.withEndpoint { [self] endpoint in
                try await processTranscriptChunks(
                    transcript: transcript,
                    contextSummary: contextSummary,
                    endpoint: endpoint,
                    customVocabulary: customVocabulary,
                    customSystemPrompt: customSystemPrompt,
                    outputLanguage: outputLanguage,
                    expectedSourceLanguage: expectedSourceLanguage,
                    progress: progress
                )
            }
        }
    }

    private func processCommandTransformWithFallback(
        selectedText: String,
        voiceCommand: String,
        contextSummary: String,
        customVocabulary: [String],
        outputLanguage: String = ""
    ) async throws -> PostProcessingResult {
        try await runWithFallback(
            passthrough: selectedText,
            retriesEmptyCloudOutput: true
        ) { [self] executor in
            try await executor.withEndpoint { [self] endpoint in
                try await processCommandTransform(
                    selectedText: selectedText,
                    voiceCommand: voiceCommand,
                    contextSummary: contextSummary,
                    endpoint: endpoint,
                    customVocabulary: customVocabulary,
                    outputLanguage: outputLanguage
                )
            }
        }
    }

    private typealias FallbackAttempt =
        @Sendable (AIProcessingBackendExecutor) async throws -> PostProcessingResult

    /// Runs the main model and, when it fails in a way a retry can help,
    /// the fallback once on its own backend (#580). Transcript cleanup and
    /// Edit Mode share this path.
    private func runWithFallback(
        passthrough: String,
        retriesEmptyCloudOutput: Bool,
        attempt: @escaping FallbackAttempt
    ) async throws -> PostProcessingResult {
        let skipped = PostProcessingResult(
            transcript: passthrough,
            prompt: "",
            skippedDueToCooldown: true
        )
        let fallback = usableFallbackExecutor()

        if isLocalBackend {
            do {
                return try await attempt(backendExecutor)
            } catch {
                guard let fallback,
                      shouldFallBack(
                          after: error,
                          fromLocal: true,
                          toLocal: fallback.choice.isLocal,
                          retriesEmptyCloudOutput: retriesEmptyCloudOutput
                      ) else {
                    throw error
                }
                // A cloud fallback that is cooling down isn't sent; the local
                // failure is what the person sees.
                if case .cloud(let modelID) = fallback.choice,
                   await LLMCooldownManager.shared.effectivePrimary(
                       baseURL: cloudBaseURL,
                       primary: modelID,
                       fallback: nil
                   ) == nil {
                    throw error
                }
                return try await runFallback(
                    fallback,
                    afterPrimaryError: error,
                    skipped: skipped,
                    attempt: attempt
                )
            }
        }

        let primaryModel = resolvedPrimaryModel()
        let cloudRetryModel: String?
        if case .cloud(let modelID)? = fallback?.choice {
            cloudRetryModel = modelID
        } else {
            cloudRetryModel = nil
        }
        guard let availableModel = await LLMCooldownManager.shared.effectivePrimary(
            baseURL: cloudBaseURL,
            primary: primaryModel,
            fallback: cloudRetryModel
        ) else {
            // Every cloud model is cooling down; a local fallback still runs.
            if let fallback, fallback.choice.isLocal {
                return try await runFallback(
                    fallback,
                    afterPrimaryError: nil,
                    skipped: skipped,
                    attempt: attempt
                )
            }
            return skipped
        }
        if availableModel != primaryModel, let fallback {
            // The main model is cooling down, so the cloud fallback runs
            // in its place, once.
            return try await runFallback(
                fallback,
                afterPrimaryError: nil,
                skipped: skipped,
                attempt: attempt
            )
        }

        do {
            return try await attempt(
                backendExecutor.replacingChoice(.cloud(modelID: primaryModel))
            )
        } catch {
            guard shouldFallBack(
                after: error,
                fromLocal: false,
                toLocal: fallback?.choice.isLocal == true,
                retriesEmptyCloudOutput: retriesEmptyCloudOutput
            ) else {
                throw error
            }
            guard let fallback else {
                if Self.isRateLimited(error),
                   await allCloudModelsCoolingDown(fallbackModel: nil) {
                    return skipped
                }
                throw error
            }
            if let cloudRetryModel {
                if Self.isRateLimited(error),
                   await allCloudModelsCoolingDown(fallbackModel: cloudRetryModel) {
                    return skipped
                }
                guard await LLMCooldownManager.shared.effectivePrimary(
                    baseURL: cloudBaseURL,
                    primary: cloudRetryModel,
                    fallback: nil
                ) != nil else {
                    throw error
                }
            }
            return try await runFallback(
                fallback,
                afterPrimaryError: error,
                skipped: skipped,
                attempt: attempt
            )
        }
    }

    /// Runs the fallback once. Cancellation is always rethrown.
    ///
    /// When a cloud main model was cooling down or rate-limited (no primary
    /// error, or a rate limit), the text passes through unchanged only if
    /// the fallback was rate-limited too, every cloud model is now cooling
    /// down, or a local fallback couldn't run at all, which is the same as
    /// having none. Any other fallback failure is the fallback's own error,
    /// as before local fallbacks. Otherwise the main model's error is
    /// reported, since that is what the person chose; a local main model
    /// always reports its own failure.
    private func runFallback(
        _ fallback: AIProcessingBackendExecutor,
        afterPrimaryError primaryError: Error?,
        skipped: PostProcessingResult,
        attempt: FallbackAttempt
    ) async throws -> PostProcessingResult {
        do {
            return try await attempt(fallback)
        } catch {
            if AIProcessingFallbackPolicy.isCancellation(error) { throw error }
            let primaryCoolingOrRateLimited = !isLocalBackend
                && (primaryError.map(Self.isRateLimitFailure) ?? true)
            guard primaryCoolingOrRateLimited else { throw primaryError ?? error }
            if Self.isRateLimitFailure(error) { return skipped }
            if case .cloud(let modelID) = fallback.choice,
               await allCloudModelsCoolingDown(fallbackModel: modelID) {
                return skipped
            }
            if fallback.choice.isLocal, Self.isLocalUnavailability(error) {
                return skipped
            }
            throw error
        }
    }

    /// The local fallback never ran: unknown or unsupported model, not
    /// installed, or the server couldn't start.
    private static func isLocalUnavailability(_ error: Error) -> Bool {
        if let backendError = error as? AIProcessingBackendError {
            switch backendError {
            case .unknownLocalModel, .localRuntimeUnavailable: return true
            case .invalidCloudBaseURL: return false
            }
        }
        if let managerError = error as? LocalAIServerManagerError {
            switch managerError {
            case .modelUnavailable, .modelCorrupt, .startFailed: return true
            case .processExited: return false
            }
        }
        return false
    }

    private static func isRateLimitFailure(_ error: Error) -> Bool {
        if isRateLimited(error) { return true }
        if case PostProcessingError.requestFailed(429, _) = error { return true }
        return false
    }

    /// The fallback, unless there is none, it can't run, or it is the main
    /// model itself.
    private func usableFallbackExecutor() -> AIProcessingBackendExecutor? {
        guard let fallbackExecutor, fallbackExecutor.isConfigured else { return nil }
        let primary: AIProcessingBackendChoice = isLocalBackend
            ? backendExecutor.choice
            : .cloud(modelID: resolvedPrimaryModel())
        guard fallbackExecutor.choice != primary else { return nil }
        return fallbackExecutor
    }

    /// A cloud model that is offline or timed out is retried only on a local
    /// fallback: a cloud fallback shares the same provider and would just
    /// make the person wait twice.
    private func shouldFallBack(
        after error: Error,
        fromLocal: Bool,
        toLocal: Bool,
        retriesEmptyCloudOutput: Bool
    ) -> Bool {
        if AIProcessingFallbackPolicy.isCancellation(error) { return false }
        if fromLocal, AIProcessingFallbackPolicy.isLocalRuntimeFailure(error) {
            return true
        }
        if AIProcessingFallbackPolicy.isNetworkFailure(error) {
            return PostProcessingFallbackPolicy.shouldFallBackAfterNetworkFailure(
                fromLocal: fromLocal,
                toLocal: toLocal
            )
        }
        guard let error = error as? PostProcessingError else { return false }
        return PostProcessingFallbackPolicy.shouldFallBack(
            after: error,
            fromLocal: fromLocal,
            toLocal: toLocal,
            retriesEmptyCloudOutput: retriesEmptyCloudOutput
        )
    }

    private static func isRateLimited(_ error: Error) -> Bool {
        if case PostProcessingError.rateLimited = error { return true }
        return false
    }

    /// True when a rate-limited request leaves no cloud model to run now,
    /// so the text is passed through unchanged.
    private func allCloudModelsCoolingDown(fallbackModel: String?) async -> Bool {
        if isLocalBackend {
            guard let fallbackModel else { return false }
            return await LLMCooldownManager.shared.effectivePrimary(
                baseURL: cloudBaseURL,
                primary: fallbackModel,
                fallback: nil
            ) == nil
        }
        return await LLMCooldownManager.shared.effectivePrimary(
            baseURL: cloudBaseURL,
            primary: resolvedPrimaryModel(),
            fallback: fallbackModel
        ) == nil
    }

    private func resolvedPrimaryModel() -> String {
        selectedModelID.isEmpty ? defaultModel : selectedModelID
    }

    private func processTranscriptChunks(
        transcript: String,
        contextSummary: String,
        endpoint: AIProcessingEndpoint,
        customVocabulary: [String],
        customSystemPrompt: String = "",
        outputLanguage: String = "",
        expectedSourceLanguage: String?,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async throws -> PostProcessingResult {
        let result = try await PostProcessingChunkRunner(
            instructionExecutionGuardEnabled: instructionExecutionGuardEnabled
        ).run(
            transcript: transcript,
            contextSummary: contextSummary,
            customVocabulary: customVocabulary,
            customSystemPrompt: customSystemPrompt,
            outputLanguage: outputLanguage,
            expectedSourceLanguage: expectedSourceLanguage,
            requester: EndpointCleanupRequester(service: self, endpoint: endpoint),
            progress: progress
        )
        let model = endpoint.selectedModelID
        return PostProcessingResult(
            transcript: result.transcript,
            prompt: result.prompts.map { prompt in
                """
Model: \(model)

[System]
\(prompt.system)

[User]
\(prompt.user)
"""
            }.joined(separator: "\n\n---\n\n")
        )
    }

    /// Sends one cleanup chunk and returns the reply with reasoning tags
    /// removed. A local model gets the response room the runner checked.
    fileprivate func requestCleanup(
        systemPrompt: String,
        userMessage: String,
        endpoint: AIProcessingEndpoint,
        localCompletionCeiling: Int?
    ) async throws -> String {
        let model = endpoint.selectedModelID

        let config = ModelConfiguration.config(for: model)
        let request = try chatCompletionRequest(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            endpoint: endpoint,
            config: config,
            localCompletionCeiling: localCompletionCeiling
        )

        let (data, response) = try await performTransport(
            for: request,
            endpoint: endpoint
        )
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PostProcessingError.invalidResponse("No HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 429 {
                let cooldown = LLMCooldownManager.rateLimitCooldown(from: httpResponse)
                if endpoint.kind == .cloud {
                    let identity = LLMCooldownIdentity(baseURL: cloudBaseURL, model: model)
                    await LLMCooldownManager.shared.setCooldown(
                        identity,
                        retryAfterSeconds: cooldown.seconds,
                        persist: cooldown.isDaily
                    )
                }
                throw PostProcessingError.rateLimited(model: model, retryAfter: cooldown.seconds)
            }
            throw PostProcessingError.requestFailed(
                statusCode: httpResponse.statusCode,
                providerCode: Self.safeProviderErrorCode(from: data)
            )
        }

        let responseObject: Any
        do {
            responseObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PostProcessingError.invalidResponse("Response JSON could not be decoded")
        }
        guard let json = responseObject as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let rawContent = message["content"] as? String else {
            throw PostProcessingError.invalidResponse("Missing choices[0].message.content")
        }
        
        var content = rawContent
        if config.shouldStripThinkTags {
            content = ModelConfiguration.stripThinkTags(content)
        }

        return content
    }

    private func completionCeiling(
        for config: ModelConfig,
        model: String
    ) -> Int? {
        config.maxCompletionTokens
            ?? (model == defaultModel ? postProcessingMaxCompletionTokens : nil)
    }

    /// A Local AI request always sends a ceiling, under both names; the
    /// default model gets low reasoning effort with its reasoning hidden.
    private func chatCompletionRequest(
        systemPrompt: String,
        userMessage: String,
        endpoint: AIProcessingEndpoint,
        config: ModelConfig,
        localCompletionCeiling: Int?
    ) throws -> URLRequest {
        let isLocal = endpoint.kind == .local
        let model = endpoint.selectedModelID
        let isDefaultModel = model == defaultModel
        let token = endpoint.authorizationToken.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        return try ChatCompletionRequest(
            model: endpoint.requestModelID,
            system: systemPrompt,
            user: userMessage,
            completionCeiling: isLocal
                ? localCompletionCeiling ?? postProcessingMaxCompletionTokens
                : completionCeiling(for: config, model: model),
            reasoningEffort: config.reasoningEffort
                ?? (isDefaultModel ? defaultModelReasoningEffort : nil),
            includeReasoning: config.includeReasoning
                ?? (isDefaultModel ? false : nil),
            sendsLegacyCompletionCeiling: isLocal
        ).urlRequest(
            baseURL: endpoint.baseURL,
            authorizationToken: token,
            timeout: postProcessingTimeoutSeconds(for: endpoint)
        )
    }

    private func processCommandTransform(
        selectedText: String,
        voiceCommand: String,
        contextSummary: String,
        endpoint: AIProcessingEndpoint,
        customVocabulary: [String],
        outputLanguage: String = ""
    ) async throws -> PostProcessingResult {
        let model = endpoint.selectedModelID

        // Edit Mode keeps the plain spelling list only. Correction pairs
        // contribute their correct spelling and never rewrite SELECTED_TEXT.
        let normalizedVocabulary = normalizedVocabularyText(
            CustomVocabularyParser.parseEntries(customVocabulary).terms
        )
        let vocabularyPrompt = if !normalizedVocabulary.isEmpty {
            """
The following vocabulary must be treated as high-priority terms while rewriting.
Use these spellings exactly in the output when relevant:
\(normalizedVocabulary)
"""
        } else {
            ""
        }

        var systemPrompt = Self.commandModeSystemPrompt
        let trimmedOutputLanguage = outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOutputLanguage.isEmpty {
            systemPrompt = systemPrompt.replacingOccurrences(
                of: "- Preserve the original language unless VOICE_COMMAND explicitly requests translation.",
                with: "- Output the result in \(trimmedOutputLanguage)."
            )
        }
        if !vocabularyPrompt.isEmpty {
            systemPrompt += "\n\n" + vocabularyPrompt
        }

        let userMessage = """
Transform SELECTED_TEXT according to VOICE_COMMAND and return only the replacement text.

\(ContextInferenceFailure.promptSection(for: contextSummary))
VOICE_COMMAND: "\(voiceCommand)"

SELECTED_TEXT: "\(selectedText)"
"""

        let config = ModelConfiguration.config(for: model)
        let configuredCompletionCeiling = completionCeiling(
            for: config,
            model: model
        )
        let localCompletionCeiling: Int?
        if endpoint.kind == .local {
            let renderedPrompt = "[System]\n\(systemPrompt)\n\n[User]\n\(userMessage)"
            guard let budget = try await LocalAITokenBudgeter(
                contextWindow: 16_384,
                tokenCounter: PostProcessingByteTokenCounter()
            ).budget(
                forRenderedChatPrompt: renderedPrompt,
                role: .postProcessing(inputReservation: 8_000)
            ) else {
                throw PostProcessingError.invalidInput(
                    "Command transform request exceeds the safe context budget"
                )
            }
            localCompletionCeiling = min(
                configuredCompletionCeiling ?? postProcessingMaxCompletionTokens,
                budget.maxCompletionTokens
            )
        } else {
            localCompletionCeiling = nil
        }

        let promptForDisplay = """
Model: \(model)

[System]
\(systemPrompt)

[User]
\(userMessage)
"""

        let request = try chatCompletionRequest(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            endpoint: endpoint,
            config: config,
            localCompletionCeiling: localCompletionCeiling
        )

        let (data, response) = try await performTransport(
            for: request,
            endpoint: endpoint
        )
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PostProcessingError.invalidResponse("No HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 429 {
                let cooldown = LLMCooldownManager.rateLimitCooldown(from: httpResponse)
                if endpoint.kind == .cloud {
                    let identity = LLMCooldownIdentity(baseURL: cloudBaseURL, model: model)
                    await LLMCooldownManager.shared.setCooldown(
                        identity,
                        retryAfterSeconds: cooldown.seconds,
                        persist: cooldown.isDaily
                    )
                }
                throw PostProcessingError.rateLimited(model: model, retryAfter: cooldown.seconds)
            }
            throw PostProcessingError.requestFailed(
                statusCode: httpResponse.statusCode,
                providerCode: Self.safeProviderErrorCode(from: data)
            )
        }

        let responseObject: Any
        do {
            responseObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PostProcessingError.invalidResponse("Response JSON could not be decoded")
        }
        guard let json = responseObject as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let rawContent = message["content"] as? String else {
            throw PostProcessingError.invalidResponse("Missing choices[0].message.content")
        }
        
        var content = rawContent
        if config.shouldStripThinkTags {
            content = ModelConfiguration.stripThinkTags(content)
        }

        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PostProcessingError.emptyOutput
        }

        let sanitizedTranscript = TranscriptOutputSanitizer.commandModeTranscript(content)
        return PostProcessingResult(
            transcript: sanitizedTranscript,
            prompt: promptForDisplay
        )
    }

    private func mergedVocabularyTerms(rawVocabulary: String) -> [String] {
        CustomVocabularyParser.entries(from: rawVocabulary)
    }

    private func normalizedVocabularyText(_ vocabularyTerms: [String]) -> String {
        let terms = vocabularyTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !terms.isEmpty else { return "" }
        return terms.joined(separator: ", ")
    }
}

private struct EndpointCleanupRequester: PostProcessingChunkRequesting {
    let service: PostProcessingService
    let endpoint: AIProcessingEndpoint

    func requestCleanup(
        system: String,
        user: String,
        budget: LocalAITokenBudget
    ) async throws -> String {
        try await service.requestCleanup(
            systemPrompt: system,
            userMessage: user,
            endpoint: endpoint,
            localCompletionCeiling: endpoint.kind == .local ? budget.maxCompletionTokens : nil
        )
    }
}
