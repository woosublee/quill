import Foundation

public enum PostProcessingError: Error, Equatable, Sendable {
    case requestFailed(statusCode: Int, providerCode: String?)
    case rateLimited(model: String, retryAfter: TimeInterval)
    case invalidResponse(String)
    case invalidInput(String)
    case contextBudgetExceeded
    case emptyOutput
    case requestTimedOut(TimeInterval, modelID: String? = nil)
    case suspectedInstructionExecution
    case outputRejected(AIValidationFailure)
}

public enum PostProcessingReplySanitizer {
    /// Trims the reply, removes one pair of surrounding quotes, and turns the
    /// prompt's EMPTY sentinel into an empty string.
    public static func postProcessedTranscript(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count > 1 {
            result.removeFirst()
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if result == "EMPTY" {
            return ""
        }

        return result
    }
}

/// The system and user message sent for one chunk.
public struct PostProcessingPromptPair: Equatable, Sendable {
    public let system: String
    public let user: String

    public init(system: String, user: String) {
        self.system = system
        self.user = user
    }
}

/// The checked transcript and the prompt of each chunk's accepted request.
public struct PostProcessingChunkResult: Equatable, Sendable {
    public let transcript: String
    public let prompts: [PostProcessingPromptPair]

    public init(transcript: String, prompts: [PostProcessingPromptPair]) {
        self.transcript = transcript
        self.prompts = prompts
    }
}

/// Sends one chunk's cleanup prompt to a model. Each app keeps its own
/// requests, response format, and reasoning-tag stripping, and chooses the
/// response room from `budget` (a local model) or its model settings.
public protocol PostProcessingChunkRequesting: Sendable {
    /// The reply text with any reasoning tags removed.
    func requestCleanup(
        system: String,
        user: String,
        budget: LocalAITokenBudget
    ) async throws -> String
}

private struct PostProcessingByteTokenCounter: LocalAITokenCounting {
    let bytesPerToken: Int

    func tokenCount(forRenderedChatPrompt prompt: String) async throws -> Int {
        (prompt.utf8.count + bytesPerToken - 1) / bytesPerToken
    }
}

/// Splits a transcript into chunks that fit, cleans each one, re-asks a long
/// chunk once when it comes back empty, and checks every chunk and the joined
/// result. The model calls go through `PostProcessingChunkRequesting`.
public struct PostProcessingChunkRunner: Sendable {
    private let contextWindow: Int
    private let bytesPerToken: Int
    private let inputReservation: Int
    private let instructionExecutionGuardEnabled: Bool
    private let tokenCounter: (any LocalAITokenCounting)?

    /// The defaults are the Mac's: a 16,384-token window counted one token a
    /// byte, and an 8,000-token input reservation (6,144 response tokens).
    ///
    /// `tokenCounter` is the model's own tokenizer, for a model whose real
    /// count can be denser than `bytesPerToken` (#162). Chunks are still cut
    /// by bytes first; then each chunk's rendered prompt is counted, and a
    /// chunk that doesn't fit the window minus the response room is split
    /// again and rechecked. Without one, chunks are cut by bytes only.
    public init(
        contextWindow: Int = 16_384,
        bytesPerToken: Int = 1,
        inputReservation: Int = 8_000,
        instructionExecutionGuardEnabled: Bool = true,
        tokenCounter: (any LocalAITokenCounting)? = nil
    ) {
        self.contextWindow = contextWindow
        self.bytesPerToken = max(bytesPerToken, 1)
        self.inputReservation = inputReservation
        self.instructionExecutionGuardEnabled = instructionExecutionGuardEnabled
        self.tokenCounter = tokenCounter
    }

    public func run(
        transcript: String,
        contextSummary: String,
        customVocabulary: [String],
        customSystemPrompt: String,
        outputLanguage: String,
        expectedSourceLanguage: String?,
        requester: any PostProcessingChunkRequesting
    ) async throws -> PostProcessingChunkResult {
        let cleanupMode = TranscriptCleanupMode.resolve(for: transcript)
        let staticUserMessage = try PostProcessingPrompt.userMessage(
            transcript: "",
            contextSummary: contextSummary,
            vocabulary: customVocabulary
        )
        let staticSystemPrompt = PostProcessingPrompt.systemPrompt(
            customSystemPrompt: customSystemPrompt,
            outputLanguage: outputLanguage,
            cleanupMode: cleanupMode,
            dictationLanguageCode: expectedSourceLanguage
        )
        let renderedPrompt = "[System]\n\(staticSystemPrompt)\n\n[User]\n\(staticUserMessage)"
        let budget = try await LocalAITokenBudgeter(
            contextWindow: contextWindow,
            tokenCounter: PostProcessingByteTokenCounter(bytesPerToken: bytesPerToken)
        ).budget(
            forRenderedChatPrompt: renderedPrompt,
            role: .postProcessing(inputReservation: inputReservation)
        )
        guard let budget else {
            throw PostProcessingError.contextBudgetExceeded
        }

        // JSON escaping can double an ASCII character (for example, `"` or
        // `\\`). Reserve half of the byte-derived source budget so the encoded
        // envelope remains within the measured context window.
        let maximumSourceBytes = max(1, budget.sourceTokenLimit * bytesPerToken / 2)
        let byteChunks = PostProcessingTranscriptSplitter(
            maximumSourceBytes: maximumSourceBytes
        ).chunks(for: transcript).map(\.text)
        guard !byteChunks.isEmpty else {
            throw PostProcessingError.invalidInput("Transcript must not be empty")
        }

        let automaticOutputLanguage = AIOutputLanguageValidator.isAutomaticOutputLanguage(
            outputLanguage
        )
        let chunks: [String]
        if let tokenCounter {
            chunks = try await countedChunks(
                byteChunks,
                tokenCounter: tokenCounter,
                contextSummary: contextSummary,
                customVocabulary: customVocabulary,
                customSystemPrompt: customSystemPrompt,
                outputLanguage: outputLanguage,
                cleanupMode: cleanupMode,
                expectedSourceLanguage: expectedSourceLanguage,
                automaticOutputLanguage: automaticOutputLanguage
            )
        } else {
            chunks = byteChunks
        }
        var cleanedChunks: [String] = []
        var prompts: [PostProcessingPromptPair] = []
        // At most one extra request per run: a long, non-filler chunk that
        // comes back empty or EMPTY is re-asked once with the same model.
        // Other errors are never retried here.
        var emptyReplyReaskAvailable = true
        for chunk in chunks {
            let chunkExpectedSourceLanguage = automaticOutputLanguage
                ? AIOutputLanguageValidator.inferredSourceLanguage(for: chunk)
                : expectedSourceLanguage
            let result: (transcript: String, prompt: PostProcessingPromptPair)
            do {
                result = try await processChunk(
                    transcript: chunk,
                    contextSummary: contextSummary,
                    customVocabulary: customVocabulary,
                    customSystemPrompt: customSystemPrompt,
                    outputLanguage: outputLanguage,
                    cleanupMode: cleanupMode,
                    expectedSourceLanguage: chunkExpectedSourceLanguage,
                    dictationLanguageCode: chunkExpectedSourceLanguage ?? expectedSourceLanguage,
                    budget: budget,
                    requester: requester
                )
            } catch PostProcessingError.emptyOutput
                where emptyReplyReaskAvailable
                && PostProcessingOutputValidator.shouldReaskAfterEmptyReply(source: chunk) {
                emptyReplyReaskAvailable = false
                result = try await processChunk(
                    transcript: chunk,
                    contextSummary: contextSummary,
                    customVocabulary: customVocabulary,
                    customSystemPrompt: customSystemPrompt,
                    outputLanguage: outputLanguage,
                    cleanupMode: cleanupMode,
                    expectedSourceLanguage: chunkExpectedSourceLanguage,
                    dictationLanguageCode: chunkExpectedSourceLanguage ?? expectedSourceLanguage,
                    budget: budget,
                    requester: requester,
                    includesEmptyReplyReminder: true
                )
            }
            if !result.transcript.isEmpty {
                cleanedChunks.append(result.transcript)
            }
            prompts.append(result.prompt)
        }

        let combinedTranscript = cleanedChunks.joined(separator: "\n\n")
        let parsedVocabulary = CustomVocabularyParser.parseEntries(customVocabulary)
        switch PostProcessingOutputValidator().validate(
            source: transcript,
            output: combinedTranscript,
            outputLanguage: outputLanguage,
            expectedSourceLanguage: expectedSourceLanguage,
            vocabulary: parsedVocabulary.terms,
            correctionHeardForms: parsedVocabulary.outputCheckExemptHeardForms
        ) {
        case .success(let accepted):
            return PostProcessingChunkResult(transcript: accepted, prompts: prompts)
        case .failure(.nonFillerEmpty):
            throw PostProcessingError.emptyOutput
        case .failure(let failure):
            throw PostProcessingError.outputRejected(failure)
        }
    }

    /// Counts each byte-cut chunk's prompt with the model's tokenizer and
    /// splits a chunk that doesn't fit again, at half its bytes with the same
    /// paragraph, sentence, word, and character boundaries, until every piece
    /// fits. A piece that can't be split further fails as an over-budget
    /// prompt. The prompt counted is the longest one the chunk can send: its
    /// own language's system prompt with the empty-reply reminder.
    private func countedChunks(
        _ byteChunks: [String],
        tokenCounter: any LocalAITokenCounting,
        contextSummary: String,
        customVocabulary: [String],
        customSystemPrompt: String,
        outputLanguage: String,
        cleanupMode: TranscriptCleanupMode,
        expectedSourceLanguage: String?,
        automaticOutputLanguage: Bool
    ) async throws -> [String] {
        let budgeter = LocalAITokenBudgeter(
            contextWindow: contextWindow,
            tokenCounter: tokenCounter
        )
        var fitted: [String] = []
        var pending = Array(byteChunks.reversed())
        while let chunk = pending.popLast() {
            let chunkLanguage = automaticOutputLanguage
                ? AIOutputLanguageValidator.inferredSourceLanguage(for: chunk)
                : expectedSourceLanguage
            let systemPrompt = PostProcessingPrompt.systemPrompt(
                customSystemPrompt: customSystemPrompt,
                outputLanguage: outputLanguage,
                cleanupMode: cleanupMode,
                dictationLanguageCode: chunkLanguage ?? expectedSourceLanguage
            ) + "\n\n" + PostProcessingPrompt.emptyReplyReminder
            let userMessage = try PostProcessingPrompt.userMessage(
                transcript: chunk,
                contextSummary: contextSummary,
                vocabulary: customVocabulary
            )
            let fits = try await budgeter.budget(
                forRenderedChatPrompt: "[System]\n\(systemPrompt)\n\n[User]\n\(userMessage)",
                role: .postProcessing(inputReservation: inputReservation)
            ) != nil
            if fits {
                fitted.append(chunk)
                continue
            }
            let pieces = PostProcessingTranscriptSplitter(
                maximumSourceBytes: max(1, chunk.utf8.count / 2)
            ).chunks(for: chunk).map(\.text)
            guard pieces.count > 1 else {
                throw PostProcessingError.contextBudgetExceeded
            }
            pending.append(contentsOf: pieces.reversed())
        }
        return fitted
    }

    private func processChunk(
        transcript: String,
        contextSummary: String,
        customVocabulary: [String],
        customSystemPrompt: String,
        outputLanguage: String,
        cleanupMode: TranscriptCleanupMode,
        expectedSourceLanguage: String?,
        dictationLanguageCode: String?,
        budget: LocalAITokenBudget,
        requester: any PostProcessingChunkRequesting,
        includesEmptyReplyReminder: Bool = false
    ) async throws -> (transcript: String, prompt: PostProcessingPromptPair) {
        // A chunk too short to recognize falls back to the whole transcript's language.
        let baseSystemPrompt = PostProcessingPrompt.systemPrompt(
            customSystemPrompt: customSystemPrompt,
            outputLanguage: outputLanguage,
            cleanupMode: cleanupMode,
            dictationLanguageCode: dictationLanguageCode ?? expectedSourceLanguage
        )
        let systemPrompt = includesEmptyReplyReminder
            ? baseSystemPrompt + "\n\n" + PostProcessingPrompt.emptyReplyReminder
            : baseSystemPrompt
        let userMessage = try PostProcessingPrompt.userMessage(
            transcript: transcript,
            contextSummary: contextSummary,
            vocabulary: customVocabulary
        )
        let content = try await requester.requestCleanup(
            system: systemPrompt,
            user: userMessage,
            budget: budget
        )

        let sanitizedTranscript = PostProcessingReplySanitizer.postProcessedTranscript(content)
        let parsedVocabulary = CustomVocabularyParser.parseEntries(customVocabulary)
        let acceptedTranscript: String
        switch PostProcessingOutputValidator().validate(
            source: transcript,
            output: sanitizedTranscript,
            outputLanguage: outputLanguage,
            expectedSourceLanguage: expectedSourceLanguage,
            vocabulary: parsedVocabulary.terms,
            correctionHeardForms: parsedVocabulary.outputCheckExemptHeardForms
        ) {
        case .success(let accepted):
            acceptedTranscript = accepted
        case .failure(.nonFillerEmpty):
            throw PostProcessingError.emptyOutput
        case .failure(let failure):
            throw PostProcessingError.outputRejected(failure)
        }
        if instructionExecutionGuardEnabled
            && InstructionExecutionDetector.appearsToHaveExecutedInstruction(
                rawTranscript: transcript,
                cleanedTranscript: acceptedTranscript,
                outputLanguage: outputLanguage
            ) {
            throw PostProcessingError.outputRejected(.instructionExecution)
        }
        return (
            acceptedTranscript,
            PostProcessingPromptPair(system: systemPrompt, user: userMessage)
        )
    }
}
