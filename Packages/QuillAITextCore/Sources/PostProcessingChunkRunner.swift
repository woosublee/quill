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

    /// `progress` reports chunks done out of the chunk count: 0 of N once
    /// the transcript is split, then after each chunk (#697). A re-asked
    /// chunk counts once.
    public func run(
        transcript: String,
        contextSummary: String,
        customVocabulary: [String],
        customSystemPrompt: String,
        outputLanguage: String,
        expectedSourceLanguage: String?,
        requester: any PostProcessingChunkRequesting,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async throws -> PostProcessingChunkResult {
        let inputs = PromptInputs(
            contextSummary: contextSummary,
            customVocabulary: customVocabulary,
            customSystemPrompt: customSystemPrompt,
            outputLanguage: outputLanguage,
            cleanupMode: TranscriptCleanupMode.resolve(for: transcript),
            expectedSourceLanguage: expectedSourceLanguage,
            automaticOutputLanguage: AIOutputLanguageValidator.isAutomaticOutputLanguage(
                outputLanguage
            )
        )
        let staticPrompt = try PostProcessingPromptPair(
            system: PostProcessingPrompt.systemPrompt(
                customSystemPrompt: customSystemPrompt,
                outputLanguage: outputLanguage,
                cleanupMode: inputs.cleanupMode,
                dictationLanguageCode: expectedSourceLanguage
            ),
            user: PostProcessingPrompt.userMessage(
                transcript: "",
                contextSummary: contextSummary,
                vocabulary: customVocabulary
            )
        )
        let budget = try await LocalAITokenBudgeter(
            contextWindow: contextWindow,
            tokenCounter: PostProcessingByteTokenCounter(bytesPerToken: bytesPerToken)
        ).budget(
            forRenderedChatPrompt: Self.rendered(staticPrompt),
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
        ).chunks(for: transcript).map {
            // Byte-cut chunks are joined by a blank line, as before #162.
            PlannedChunk(text: $0.text, separatorBefore: "\n\n")
        }
        guard !byteChunks.isEmpty else {
            throw PostProcessingError.invalidInput("Transcript must not be empty")
        }

        var chunks = byteChunks
        if let tokenCounter,
           let counted = try await countedChunks(
               byteChunks,
               tokenCounter: tokenCounter,
               inputs: inputs
           ) {
            chunks = counted
        }

        progress?(0, chunks.count)
        var combinedTranscript = ""
        var hasKeptChunk = false
        // The separator since the last kept chunk; a dropped chunk's blank
        // line is kept over a sentence space.
        var pendingSeparator = ""
        var prompts: [PostProcessingPromptPair] = []
        // At most one extra request per run: a long, non-filler chunk that
        // comes back empty or EMPTY is re-asked once with the same model.
        // Other errors are never retried here.
        var emptyReplyReaskAvailable = true
        for (index, chunk) in chunks.enumerated() {
            if index > 0 {
                pendingSeparator = Self.strongerSeparator(
                    pendingSeparator,
                    chunk.separatorBefore
                )
            }
            let result: (transcript: String, prompt: PostProcessingPromptPair)
            do {
                result = try await processChunk(
                    chunk.text,
                    inputs: inputs,
                    budget: budget,
                    requester: requester
                )
            } catch PostProcessingError.emptyOutput
                where emptyReplyReaskAvailable
                && PostProcessingOutputValidator.shouldReaskAfterEmptyReply(source: chunk.text) {
                emptyReplyReaskAvailable = false
                result = try await processChunk(
                    chunk.text,
                    inputs: inputs,
                    budget: budget,
                    requester: requester,
                    includesEmptyReplyReminder: true
                )
            }
            if !result.transcript.isEmpty {
                if hasKeptChunk {
                    combinedTranscript += pendingSeparator
                }
                combinedTranscript += result.transcript
                hasKeptChunk = true
                pendingSeparator = ""
            }
            prompts.append(result.prompt)
            progress?(index + 1, chunks.count)
        }

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

    /// One chunk to clean and the text that separated it from the one before.
    private struct PlannedChunk {
        let text: String
        let separatorBefore: String
    }

    /// What every chunk's prompt is built from. `promptPair` is the one place
    /// a chunk's prompt is assembled, for both the counted check and the
    /// request, so the two can't drift apart.
    private struct PromptInputs {
        let contextSummary: String
        let customVocabulary: [String]
        let customSystemPrompt: String
        let outputLanguage: String
        let cleanupMode: TranscriptCleanupMode
        let expectedSourceLanguage: String?
        let automaticOutputLanguage: Bool

        /// The language a chunk's output is checked against.
        func expectedLanguage(for chunk: String) -> String? {
            automaticOutputLanguage
                ? AIOutputLanguageValidator.inferredSourceLanguage(for: chunk)
                : expectedSourceLanguage
        }

        func promptPair(
            for chunk: String,
            includesEmptyReplyReminder: Bool
        ) throws -> PostProcessingPromptPair {
            // A chunk too short to recognize falls back to the whole
            // transcript's language.
            let baseSystemPrompt = PostProcessingPrompt.systemPrompt(
                customSystemPrompt: customSystemPrompt,
                outputLanguage: outputLanguage,
                cleanupMode: cleanupMode,
                dictationLanguageCode: expectedLanguage(for: chunk) ?? expectedSourceLanguage
            )
            let systemPrompt = includesEmptyReplyReminder
                ? baseSystemPrompt + "\n\n" + PostProcessingPrompt.emptyReplyReminder
                : baseSystemPrompt
            let userMessage = try PostProcessingPrompt.userMessage(
                transcript: chunk,
                contextSummary: contextSummary,
                vocabulary: customVocabulary
            )
            return PostProcessingPromptPair(system: systemPrompt, user: userMessage)
        }
    }

    private static func rendered(_ prompt: PostProcessingPromptPair) -> String {
        "[System]\n\(prompt.system)\n\n[User]\n\(prompt.user)"
    }

    /// The separator with more line breaks, or `next` on a tie.
    private static func strongerSeparator(_ current: String, _ next: String) -> String {
        current.filter(\.isNewline).count > next.filter(\.isNewline).count ? current : next
    }

    /// Counts the fixed prompt once, then each byte-cut chunk's prompt, with
    /// the model's tokenizer, and splits a chunk that doesn't fit again: at
    /// half its bytes with the same paragraph, sentence, word, and character
    /// boundaries, until every piece fits. The prompt counted is the longest
    /// one a chunk can send: its own language's system prompt with the
    /// empty-reply reminder.
    ///
    /// A fixed prompt or a piece that can't fit fails as an over-budget
    /// prompt, as the byte check does. When the counter throws, it returns
    /// nil and the run uses the byte-cut chunks, as with no counter.
    private func countedChunks(
        _ byteChunks: [PlannedChunk],
        tokenCounter: any LocalAITokenCounting,
        inputs: PromptInputs
    ) async throws -> [PlannedChunk]? {
        let budgeter = LocalAITokenBudgeter(
            contextWindow: contextWindow,
            tokenCounter: tokenCounter
        )
        let staticPrompt = try inputs.promptPair(for: "", includesEmptyReplyReminder: true)
        guard let staticFits = try await countedFit(staticPrompt, budgeter: budgeter) else {
            return nil
        }
        guard staticFits else {
            throw PostProcessingError.contextBudgetExceeded
        }

        var fitted: [PlannedChunk] = []
        var pending = Array(byteChunks.reversed())
        while let chunk = pending.popLast() {
            let prompt = try inputs.promptPair(for: chunk.text, includesEmptyReplyReminder: true)
            guard let fits = try await countedFit(prompt, budgeter: budgeter) else {
                return nil
            }
            if fits {
                fitted.append(chunk)
                continue
            }
            let pieces = PostProcessingTranscriptSplitter(
                maximumSourceBytes: max(1, chunk.text.utf8.count / 2)
            ).chunks(for: chunk.text).map(\.text)
            guard pieces.count > 1 else {
                throw PostProcessingError.contextBudgetExceeded
            }
            let separators = Self.separators(between: pieces, in: chunk.text)
            let planned = pieces.enumerated().map { index, piece in
                PlannedChunk(
                    text: piece,
                    separatorBefore: index == 0 ? chunk.separatorBefore : separators[index - 1]
                )
            }
            pending.append(contentsOf: planned.reversed())
        }
        return fitted
    }

    /// Whether the prompt fits by the model's count, or nil when the counter
    /// fails. Cancellation still ends the run.
    private func countedFit(
        _ prompt: PostProcessingPromptPair,
        budgeter: LocalAITokenBudgeter
    ) async throws -> Bool? {
        do {
            return try await budgeter.budget(
                forRenderedChatPrompt: Self.rendered(prompt),
                role: .postProcessing(inputReservation: inputReservation)
            ) != nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    /// The source text between consecutive pieces: the whitespace after each
    /// piece's last character, or "" where a word was cut. The splitter keeps
    /// every non-whitespace character in order, so each piece is found by
    /// walking the source.
    private static func separators(between pieces: [String], in source: String) -> [String] {
        var index = source.startIndex
        var separators: [String] = []
        for piece in pieces.dropLast() {
            for character in piece where !character.isWhitespace {
                while index < source.endIndex && source[index] != character {
                    index = source.index(after: index)
                }
                if index < source.endIndex {
                    index = source.index(after: index)
                }
            }
            var separator = ""
            while index < source.endIndex && source[index].isWhitespace {
                separator.append(source[index])
                index = source.index(after: index)
            }
            separators.append(separator)
        }
        return separators
    }

    private func processChunk(
        _ transcript: String,
        inputs: PromptInputs,
        budget: LocalAITokenBudget,
        requester: any PostProcessingChunkRequesting,
        includesEmptyReplyReminder: Bool = false
    ) async throws -> (transcript: String, prompt: PostProcessingPromptPair) {
        let prompt = try inputs.promptPair(
            for: transcript,
            includesEmptyReplyReminder: includesEmptyReplyReminder
        )
        let content = try await requester.requestCleanup(
            system: prompt.system,
            user: prompt.user,
            budget: budget
        )

        let sanitizedTranscript = PostProcessingReplySanitizer.postProcessedTranscript(content)
        let parsedVocabulary = CustomVocabularyParser.parseEntries(inputs.customVocabulary)
        let acceptedTranscript: String
        switch PostProcessingOutputValidator().validate(
            source: transcript,
            output: sanitizedTranscript,
            outputLanguage: inputs.outputLanguage,
            expectedSourceLanguage: inputs.expectedLanguage(for: transcript),
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
                outputLanguage: inputs.outputLanguage
            ) {
            throw PostProcessingError.outputRejected(.instructionExecution)
        }
        return (acceptedTranscript, prompt)
    }
}
