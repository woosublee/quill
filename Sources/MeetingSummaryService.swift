import Foundation
import QuillAITextCore
import QuillUserIssueCore
import QuillSummaryFormatCore
import QuillSummaryGenerationCore
import QuillProviderCore

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

/// Counts with the local model's own tokenizer. A byte count overstates a
/// Korean prompt about fourfold, which leaves too little room to merge
/// partial summaries (#609). Falls back to the byte count when the server
/// is running but can't count; a server that won't start fails as it would
/// for the request itself.
private struct MeetingSummaryLocalTokenCounter: LocalAITokenCounting {
    private static let requestTimeout: TimeInterval = 10

    let executor: AIProcessingBackendExecutor
    let transport: MeetingSummaryService.Transport

    func tokenCount(forRenderedChatPrompt prompt: String) async throws -> Int {
        try await executor.withEndpoint { [transport] endpoint in
            do {
                // llama-server serves /tokenize beside /v1, not under it.
                let url = endpoint.baseURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("tokenize")
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = Self.requestTimeout
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(
                    withJSONObject: ["content": prompt]
                )
                let (data, response) = try await transport(request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let tokens = (object as? [String: Any])?["tokens"] as? [Any] else {
                    return prompt.utf8.count
                }
                return tokens.count
            } catch {
                if AIProcessingFallbackPolicy.isCancellation(error) { throw error }
                return prompt.utf8.count
            }
        }
    }
}

final class MeetingSummaryService: MeetingSummaryGenerating, @unchecked Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let requestTimeout: TimeInterval = 120
    /// A local model writes about 50 tokens a second on a fast Mac and
    /// about 20 on a base M1, so its longest response needs more time than
    /// a cloud request.
    private static let localRequestTimeout: TimeInterval = 420
    /// Measured responses need at most about 4,200 tokens. A model stuck
    /// repeating itself stops here as a cut-off response, not after
    /// filling the whole context (#609). A local merge reserves all of it
    /// (#610).
    private static let localCompletionCap = 6_144
    private static let contextWindow = 16_384
    private static let cloudCompletionCeiling = 1_024
    private static let defaultTransport: Transport = { request in
        try await LLMAPITransport.shared.data(for: request)
    }

    private let backendExecutor: AIProcessingBackendExecutor
    /// The model to retry with when the main model fails (#580). A cloud
    /// fallback for a cloud model retries each failed request; any other
    /// pairing reruns the whole summary once on the fallback's backend.
    private let fallbackExecutor: AIProcessingBackendExecutor?
    private let chunker: MeetingSummaryTextChunker
    private let tokenBudgeter: LocalAITokenBudgeter
    /// Passed on to a fallback service, which otherwise picks the counter
    /// for its own backend.
    private let injectedTokenBudgeter: LocalAITokenBudgeter?
    private let transport: Transport

    init(
        backendExecutor: AIProcessingBackendExecutor,
        fallbackExecutor: AIProcessingBackendExecutor?,
        chunker: MeetingSummaryTextChunker = MeetingSummaryTextChunker(),
        tokenBudgeter: LocalAITokenBudgeter? = nil,
        transport: @escaping Transport = MeetingSummaryService.defaultTransport
    ) {
        self.backendExecutor = backendExecutor
        self.fallbackExecutor = fallbackExecutor
        self.chunker = chunker
        self.injectedTokenBudgeter = tokenBudgeter
        let tokenCounter: any LocalAITokenCounting = backendExecutor.choice.isLocal
            ? MeetingSummaryLocalTokenCounter(executor: backendExecutor, transport: transport)
            : MeetingSummaryByteTokenCounter()
        self.tokenBudgeter = tokenBudgeter ?? LocalAITokenBudgeter(
            contextWindow: Self.contextWindow,
            tokenCounter: tokenCounter,
            summaryCompletionTokens: backendExecutor.choice.isLocal
                ? LocalAITokenBudgeter.localSummaryCompletionTokens
                : Self.cloudCompletionCeiling,
            summaryMergeCompletionTokens: backendExecutor.choice.isLocal
                ? Self.localCompletionCap
                : Self.cloudCompletionCeiling
        )
        self.transport = transport
    }

    func generate(
        source: MeetingSummarySource
    ) async throws -> MeetingSummaryGenerationResult {
        do {
            return try await generateWithPrimary(source: source)
        } catch {
            guard let fallback = wholeSummaryFallbackExecutor(),
                  Self.isFallbackEligible(
                      error,
                      primaryIsLocal: backendExecutor.choice.isLocal,
                      fallbackIsLocal: fallback.choice.isLocal
                  ) else {
                throw error
            }
            // The fallback service applies its own calendar rule: a cloud
            // fallback never gets the calendar event (#529).
            do {
                return try await MeetingSummaryService(
                    backendExecutor: fallback,
                    fallbackExecutor: nil,
                    chunker: chunker,
                    tokenBudgeter: injectedTokenBudgeter,
                    transport: transport
                ).generateWithPrimary(source: source)
            } catch let fallbackError {
                // When both fail, report the model the person chose.
                if AIProcessingFallbackPolicy.isCancellation(fallbackError) {
                    throw fallbackError
                }
                throw error
            }
        }
    }

    private func generateWithPrimary(
        source: MeetingSummarySource
    ) async throws -> MeetingSummaryGenerationResult {
        var result = try await MeetingSummaryGenerator(
            requester: self,
            tokenBudgeter: tokenBudgeter,
            chunker: chunker
        ).generate(source: source)
        if result.backendKind == .cloud {
            result.providerHost = URL(string: backendExecutor.cloudBaseURL)?.host
        }
        return result
    }

    private func requestCloudDraft(
        prompt: MeetingSummaryPrompt
    ) async throws -> MeetingSummaryDraftReply {
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
        var primaryError: Error?
        for (index, modelID) in models.enumerated() {
            do {
                return try await requestDraft(
                    prompt: prompt,
                    executor: backendExecutor.replacingChoice(
                        .cloud(modelID: modelID)
                    ),
                    localResponseFormat: nil
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
                    && Self.isFallbackEligible(
                        error,
                        primaryIsLocal: false,
                        fallbackIsLocal: false
                    )
                if canRetry {
                    primaryError = error
                    continue
                }
                // When the fallback fails too, report the primary's error.
                throw primaryError ?? error
            } catch {
                if let primaryError, !AIProcessingFallbackPolicy.isCancellation(error) {
                    throw primaryError
                }
                lastError = error
                throw error
            }
        }
        throw lastError ?? MeetingSummaryError.allModelsCoolingDown
    }

    private func requestDraft(
        prompt: MeetingSummaryPrompt,
        executor: AIProcessingBackendExecutor,
        localCompletionTokens: Int? = nil,
        localResponseFormat: String?
    ) async throws -> MeetingSummaryDraftReply {
        try await executor.withEndpoint { [self] endpoint in
            let request = try makeRequest(
                prompt: prompt,
                endpoint: endpoint,
                localCompletionTokens: localCompletionTokens,
                localResponseFormat: localResponseFormat
            )
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await transport(request)
            } catch let error as URLError where error.code == .timedOut {
                throw MeetingSummaryError.requestTimedOut(
                    Self.requestTimeout(for: endpoint),
                    modelID: endpoint.selectedModelID
                )
            } catch {
                // A cancelled request stays a cancellation so it is never
                // retried with the fallback.
                if AIProcessingFallbackPolicy.isCancellation(error) {
                    throw error
                }
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
            return MeetingSummaryDraftReply(
                draft: draft,
                modelID: endpoint.selectedModelID,
                backendKind: endpoint.kind == .local ? .local : .cloud
            )
        }
    }

    /// The shape `MeetingSummaryStrictDecoder` accepts, as JSON text so
    /// its key order is fixed: llama-server makes the model write keys in
    /// schema order, which follows the order the prompt shows.
    private static let responseFormatTemplate = #"""
    {"type":"json_schema","json_schema":{"name":"meeting_summary","schema":{"type":"object","additionalProperties":false,"required":["overview","keyPoints","decisions","actionItems","openQuestions"],"properties":{"overview":{"type":"object","additionalProperties":false,"required":["text","sourceQuotes"],"properties":{"text":PROSE,"sourceQuotes":{"type":"array","items":{"type":"string"}}}},"keyPoints":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["text","sourceQuote"],"properties":{"text":PROSE,"sourceQuote":{"type":["string","null"]}}}},"decisions":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["text","sourceQuote"],"properties":{"text":PROSE,"sourceQuote":{"type":["string","null"]}}}},"actionItems":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["task","owner","dueDate","sourceQuote"],"properties":{"task":PROSE,"owner":{"type":["string","null"]},"dueDate":{"type":["string","null"]},"sourceQuote":{"type":["string","null"]}}}},"openQuestions":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["text","sourceQuote"],"properties":{"text":PROSE,"sourceQuote":{"type":["string","null"]}}}}}}}}
    """#

    private static let proseSchema = #"{"type":"string","minLength":1}"#

    /// Generated prose with no CJK ideographs, for an output language that
    /// doesn't write them. A small local model can otherwise drift into
    /// Chinese mid-summary (#613). A pattern matches the string's raw JSON
    /// text, so `"` and `\` only come as part of an escape; a bare one
    /// would let the model run past the string's end.
    private static let proseWithoutHanSchema = #"{"type":"string","pattern":"^([^\"\\\\\\x00-\\x1f\u3400-\u9fff\uf900-\ufaff]|\\\\[\"\\\\/bfnrt])+$"}"#

    private static let responseFormat = responseFormatTemplate
        .replacingOccurrences(of: "PROSE", with: proseSchema)
    private static let responseFormatWithoutHan = responseFormatTemplate
        .replacingOccurrences(of: "PROSE", with: proseWithoutHanSchema)

    /// Source quotes are not constrained, so Hanja spoken in the meeting is
    /// still quoted as is.
    private static func responseFormatJSON(outputLanguageCode: String) -> String {
        guard let code = SpokenLanguageResolver.supportedCode(outputLanguageCode) else {
            return responseFormat
        }
        let primaryCode = code.split(separator: "-").first ?? ""
        return primaryCode == "zh" || primaryCode == "ja"
            ? responseFormat
            : responseFormatWithoutHan
    }

    private static func requestTimeout(for endpoint: AIProcessingEndpoint) -> TimeInterval {
        endpoint.kind == .local ? localRequestTimeout : requestTimeout
    }

    private func makeRequest(
        prompt: MeetingSummaryPrompt,
        endpoint: AIProcessingEndpoint,
        localCompletionTokens: Int?,
        localResponseFormat: String?
    ) throws -> URLRequest {
        let config = ModelConfiguration.config(for: endpoint.selectedModelID)
        let isLocal = endpoint.kind == .local
        return try ChatCompletionRequest(
            model: endpoint.requestModelID,
            system: prompt.system,
            user: prompt.user,
            completionCeiling: isLocal
                ? localCompletionTokens ?? tokenBudgeter.summaryCompletionTokens
                : Self.cloudCompletionCeiling,
            reasoningEffort: config.reasoningEffort,
            includeReasoning: config.includeReasoning,
            sendsLegacyCompletionCeiling: isLocal,
            // A small local model drops null keys or leaves quotes inside a
            // string unescaped; llama-server can only sample JSON that fits
            // the shape the decoder requires (#611).
            responseFormatJSON: isLocal ? localResponseFormat ?? Self.responseFormat : nil
        ).urlRequest(
            baseURL: endpoint.baseURL,
            authorizationToken: endpoint.authorizationToken,
            timeout: Self.requestTimeout(for: endpoint)
        )
    }

    /// The configured fallback, unless there is none, it can't run, or it
    /// is the main model itself.
    private func usableFallbackExecutor() -> AIProcessingBackendExecutor? {
        guard let fallbackExecutor, fallbackExecutor.isConfigured else { return nil }
        if case .cloud(let modelID) = fallbackExecutor.choice {
            let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let fallback = fallbackExecutor.replacingChoice(.cloud(modelID: trimmed))
            return fallback.choice == backendExecutor.choice ? nil : fallback
        }
        return fallbackExecutor.choice == backendExecutor.choice ? nil : fallbackExecutor
    }

    /// A cloud fallback for a cloud model, retried per request.
    private func normalizedFallback(primary: String) -> String? {
        guard !backendExecutor.choice.isLocal,
              case .cloud(let modelID)? = usableFallbackExecutor()?.choice,
              modelID != primary else {
            return nil
        }
        return modelID
    }

    /// A fallback that reruns the whole summary: any fallback for a local
    /// model, or a local fallback for a cloud model.
    private func wholeSummaryFallbackExecutor() -> AIProcessingBackendExecutor? {
        guard let fallback = usableFallbackExecutor() else { return nil }
        guard backendExecutor.choice.isLocal || fallback.choice.isLocal else {
            return nil
        }
        return fallback
    }

    /// A cloud model that is offline or timed out is retried only on a local
    /// fallback; a cloud fallback shares the same provider.
    static func isFallbackEligible(
        _ error: Error,
        primaryIsLocal: Bool,
        fallbackIsLocal: Bool
    ) -> Bool {
        if AIProcessingFallbackPolicy.isCancellation(error) { return false }
        if primaryIsLocal, AIProcessingFallbackPolicy.isLocalRuntimeFailure(error) {
            return true
        }
        let reachesAnotherHost = primaryIsLocal || fallbackIsLocal
        guard let error = error as? MeetingSummaryError else { return false }
        switch error {
        case .rateLimited, .allModelsCoolingDown:
            return !primaryIsLocal
        case .invalidResponse(let subtype, _):
            // A prompt that doesn't fit the budget won't fit the fallback.
            return subtype != .contextBudget && subtype != .mergeBudget
        case .outputRejected, .emptyOutput:
            return true
        case .requestTimedOut:
            return reachesAnotherHost
        case .requestFailed(let statusCode, _, _):
            // Status 0 is a transport failure such as a lost connection.
            return (statusCode == 0 && reachesAnotherHost)
                || AIProcessingFallbackPolicy.isServerError(statusCode: statusCode)
        case .invalidInput, .sourceChanged:
            return false
        }
    }

    private func responseContent(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first else {
            throw MeetingSummaryError.invalidResponse(.responseEnvelope)
        }
        // A response that hit the token limit ends mid-JSON, or has no
        // content when reasoning used it all; say so rather than report a
        // bad format.
        if first["finish_reason"] as? String == "length" {
            throw MeetingSummaryError.invalidResponse(.outputTruncated)
        }
        guard let message = first["message"] as? [String: Any],
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

extension MeetingSummaryService: MeetingSummaryDraftRequesting {
    var backendKind: MeetingSummaryBackendKind {
        backendExecutor.choice.isLocal ? .local : .cloud
    }

    func requestDraft(
        _ request: MeetingSummaryDraftRequest
    ) async throws -> MeetingSummaryDraftReply {
        if backendExecutor.choice.isLocal {
            // A local response may use the context the prompt leaves, up to
            // the cap.
            return try await requestDraft(
                prompt: request.prompt,
                executor: backendExecutor,
                localCompletionTokens: min(
                    request.budget.sourceTokenLimit + request.budget.maxCompletionTokens,
                    Self.localCompletionCap
                ),
                localResponseFormat: Self.responseFormatJSON(
                    outputLanguageCode: request.outputLanguageCode
                )
            )
        }
        return try await requestCloudDraft(prompt: request.prompt)
    }
}
