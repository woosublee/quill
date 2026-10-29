import Foundation
import QuillAITextCore

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct PostProcessingChunkingTests {
    static func main() async throws {
        try testParagraphsArePreferredAndRemainOrdered()
        try testSentencesSplitWhenParagraphExceedsBudget()
        try testLongTokenFallsBackToSafeByteBoundaries()
        try testMultibyteCharactersRespectSafeBoundaries()
        try testLargeUnbrokenTokenPreservesOrderAndBudget()
        try await testRunnerSizesChunksFromItsWindowAndByteRatio()
        try await testTokenCounterResplitsChunksThatDoNotFit()
        try await testTokenCounterKeepsChunksThatFit()
        try await testUnsplittableChunkOverTheCountedBudgetFails()
        try testFallbackPolicyByErrorAndHosts()
        print("PostProcessingChunkingTests passed")
    }

    private static func testParagraphsArePreferredAndRemainOrdered() throws {
        let splitter = PostProcessingTranscriptSplitter(maximumSourceBytes: 32)
        let source = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."

        let chunks = splitter.chunks(for: source)

        try expect(
            chunks.map(\.text) == ["First paragraph.", "Second paragraph.", "Third paragraph."],
            "paragraph chunks preserve source order"
        )
    }

    private static func testSentencesSplitWhenParagraphExceedsBudget() throws {
        let splitter = PostProcessingTranscriptSplitter(maximumSourceBytes: 20)
        let source = "First sentence. Second sentence."

        let chunks = splitter.chunks(for: source)

        try expect(
            chunks.map(\.text) == ["First sentence.", "Second sentence."],
            "sentence chunks avoid splitting within a sentence"
        )
    }

    private static func testLongTokenFallsBackToSafeByteBoundaries() throws {
        let splitter = PostProcessingTranscriptSplitter(maximumSourceBytes: 8)
        let source = "abcdefghijklmno"

        let chunks = splitter.chunks(for: source)

        try expect(
            chunks.map(\.text) == ["abcdefgh", "ijklmno"],
            "oversized token splits at safe byte boundaries"
        )
        try expect(chunks.allSatisfy { $0.text.utf8.count <= 8 }, "every chunk respects the byte budget")
    }

    private static func testMultibyteCharactersRespectSafeBoundaries() throws {
        let splitter = PostProcessingTranscriptSplitter(maximumSourceBytes: 7)
        let source = "가나다🙂라마"

        let chunks = splitter.chunks(for: source)

        try expect(
            chunks.map(\.text).joined() == source,
            "multibyte chunks preserve every Character in order"
        )
        try expect(
            chunks.allSatisfy { chunk in
                chunk.text.count == 1 || chunk.text.utf8.count <= 7
            },
            "multibyte chunks stay within budget unless one Character exceeds it"
        )
    }

    private static func testLargeUnbrokenTokenPreservesOrderAndBudget() throws {
        let splitter = PostProcessingTranscriptSplitter(maximumSourceBytes: 1_024)
        let source = String(repeating: "abcdefghij", count: 10_000)

        let chunks = splitter.chunks(for: source)

        try expect(chunks.map(\.text).joined() == source, "large token preserves source order")
        try expect(chunks.count > 1, "large token is split")
        try expect(
            chunks.allSatisfy { $0.text.utf8.count <= 1_024 },
            "every ASCII chunk respects the byte budget"
        )
    }

    /// The Mac defaults leave 6,144 response tokens. The iPhone passes its
    /// own window, bytes per token, and input reservation, and a chunk then
    /// holds that many more bytes.
    private static func testRunnerSizesChunksFromItsWindowAndByteRatio() async throws {
        let transcript = (0..<200)
            .map { "Sentence \($0) keeps the synthetic release plan on track." }
            .joined(separator: " ")

        let mac = EchoCleanupRequester()
        let macResult = try await PostProcessingChunkRunner().run(
            transcript: transcript, contextSummary: "", customVocabulary: [], customSystemPrompt: "",
            outputLanguage: "", expectedSourceLanguage: "en", requester: mac
        )
        let phone = EchoCleanupRequester()
        _ = try await PostProcessingChunkRunner(
            contextWindow: 8_192, bytesPerToken: 2, inputReservation: 1_536
        ).run(
            transcript: transcript, contextSummary: "", customVocabulary: [], customSystemPrompt: "",
            outputLanguage: "", expectedSourceLanguage: "en", requester: phone
        )

        try expect(mac.budgets.count > 1, "the long paragraph is split")
        try expect(
            macResult.transcript.replacingOccurrences(of: "\n\n", with: " ") == transcript,
            "cleaned chunks are joined by blank lines in order"
        )
        try expect(macResult.prompts.count == mac.budgets.count, "one prompt per accepted chunk")
        try expect(Set(mac.budgets.map(\.maxCompletionTokens)) == [6_144], "Mac response room")
        try expect(Set(phone.budgets.map(\.maxCompletionTokens)) == [2_048], "reservation plus 512")
        try expect(phone.budgets.count < mac.budgets.count, "two bytes a token makes larger chunks")
    }

    /// A dense model (one token a byte, as for emoji or CJK text) on a
    /// two-bytes-a-token estimate, as the iPhone uses: the counted check splits the
    /// byte-cut chunks again until every prompt fits the window (#162).
    private static func testTokenCounterResplitsChunksThatDoNotFit() async throws {
        let transcript = (0..<120)
            .map { "Sentence \($0) keeps the synthetic release plan on track." }
            .joined(separator: " ")
        let window = 16_384
        let reservation = 8_000
        let promptLimit = window - 6_144 - LocalAITokenBudgeter.safetyMarginTokens

        let byteOnly = EchoCleanupRequester()
        _ = try await PostProcessingChunkRunner(
            contextWindow: window, bytesPerToken: 2, inputReservation: reservation
        ).run(
            transcript: transcript, contextSummary: "", customVocabulary: [], customSystemPrompt: "",
            outputLanguage: "", expectedSourceLanguage: "en", requester: byteOnly
        )
        let counted = EchoCleanupRequester()
        let counter = DenseTokenCounter()
        let result = try await PostProcessingChunkRunner(
            contextWindow: window, bytesPerToken: 2, inputReservation: reservation,
            tokenCounter: counter
        ).run(
            transcript: transcript, contextSummary: "", customVocabulary: [], customSystemPrompt: "",
            outputLanguage: "", expectedSourceLanguage: "en", requester: counted
        )

        try expect(
            byteOnly.prompts.contains { $0.utf8.count >= promptLimit },
            "the byte estimate alone overfills a dense model's window"
        )
        try expect(counted.prompts.count > byteOnly.prompts.count, "the counted check splits again")
        try expect(
            counted.prompts.allSatisfy { $0.utf8.count < promptLimit },
            "no chunk's counted prompt exceeds the window minus the response room"
        )
        try expect(
            result.transcript.replacingOccurrences(of: "\n\n", with: " ") == transcript,
            "re-split chunks keep every sentence in order"
        )
        try expect(
            counted.transcripts.allSatisfy { $0.hasSuffix(".") },
            "re-splitting keeps sentence boundaries"
        )
    }

    /// Chunks whose counted prompts fit are sent as the bytes cut them, the
    /// same as with no counter.
    private static func testTokenCounterKeepsChunksThatFit() async throws {
        let transcript = (0..<200)
            .map { "Sentence \($0) keeps the synthetic release plan on track." }
            .joined(separator: " ")
        let byteOnly = EchoCleanupRequester()
        _ = try await PostProcessingChunkRunner().run(
            transcript: transcript, contextSummary: "", customVocabulary: [], customSystemPrompt: "",
            outputLanguage: "", expectedSourceLanguage: "en", requester: byteOnly
        )
        let counted = EchoCleanupRequester()
        let counter = DenseTokenCounter()
        _ = try await PostProcessingChunkRunner(tokenCounter: counter).run(
            transcript: transcript, contextSummary: "", customVocabulary: [], customSystemPrompt: "",
            outputLanguage: "", expectedSourceLanguage: "en", requester: counted
        )

        try expect(byteOnly.transcripts.count > 1, "the long paragraph is split by bytes")
        try expect(counted.transcripts == byteOnly.transcripts, "fitting chunks aren't split again")
        try expect(counted.prompts == byteOnly.prompts, "the same prompts are sent")
        try expect(counter.calls == byteOnly.transcripts.count, "each chunk's prompt is counted once")
    }

    /// A single character whose counted prompt can't fit fails as an
    /// over-budget prompt, and no request is sent.
    private static func testUnsplittableChunkOverTheCountedBudgetFails() async throws {
        let requester = EchoCleanupRequester()
        do {
            _ = try await PostProcessingChunkRunner(
                tokenCounter: DenseTokenCounter(costlyCharacter: "🙂", cost: 100_000)
            ).run(
                transcript: "🙂", contextSummary: "", customVocabulary: [], customSystemPrompt: "",
                outputLanguage: "", expectedSourceLanguage: "en", requester: requester
            )
            throw PostProcessingChunkingTestFailure("an unsplittable oversized chunk must fail")
        } catch PostProcessingError.contextBudgetExceeded {
            try expect(requester.prompts.isEmpty, "no request is sent")
        }
    }

    /// Which cleanup errors try the fallback model, for each pair of hosts
    /// (cloud to cloud, local to cloud, cloud to local, local to local) and
    /// with an empty cloud reply retried or not. The table is the Mac's rule
    /// from #580.
    private static func testFallbackPolicyByErrorAndHosts() throws {
        // Per host pair: [without, with] retrying an empty cloud reply.
        let cases: [(PostProcessingError, [[Bool]])] = [
            (.rateLimited(model: "m", retryAfter: 1), [[true, true], [false, false], [true, true], [false, false]]),
            (.requestFailed(statusCode: 429, providerCode: nil), [[true, true], [false, false], [true, true], [false, false]]),
            (.requestFailed(statusCode: 500, providerCode: nil), [[true, true], [true, true], [true, true], [true, true]]),
            (.requestFailed(statusCode: 503, providerCode: nil), [[true, true], [true, true], [true, true], [true, true]]),
            (.requestFailed(statusCode: 400, providerCode: nil), [[false, false], [false, false], [false, false], [false, false]]),
            (.requestFailed(statusCode: 401, providerCode: nil), [[false, false], [false, false], [false, false], [false, false]]),
            (.requestTimedOut(30), [[false, false], [true, true], [true, true], [true, true]]),
            (.emptyOutput, [[false, true], [true, true], [false, true], [true, true]]),
            (.invalidResponse("synthetic"), [[false, false], [true, true], [false, false], [true, true]]),
            (.invalidInput("synthetic"), [[false, false], [false, false], [false, false], [false, false]]),
            (.contextBudgetExceeded, [[false, false], [false, false], [false, false], [false, false]]),
            (.suspectedInstructionExecution, [[false, false], [false, false], [false, false], [false, false]]),
            (.outputRejected(.languageMismatch), [[false, false], [false, false], [false, false], [false, false]]),
        ]
        let hosts: [(fromLocal: Bool, toLocal: Bool)] = [(false, false), (true, false), (false, true), (true, true)]
        for (error, expected) in cases {
            for (index, host) in hosts.enumerated() {
                for (retryIndex, retries) in [false, true].enumerated() {
                    try expect(
                        PostProcessingFallbackPolicy.shouldFallBack(
                            after: error,
                            fromLocal: host.fromLocal,
                            toLocal: host.toLocal,
                            retriesEmptyCloudOutput: retries
                        ) == expected[index][retryIndex],
                        "\(error) from local \(host.fromLocal) to local \(host.toLocal) retrying empty \(retries)"
                    )
                }
            }
        }
        let networkFallbacks = hosts.map {
            PostProcessingFallbackPolicy.shouldFallBackAfterNetworkFailure(fromLocal: $0.fromLocal, toLocal: $0.toLocal)
        }
        try expect(networkFallbacks == [false, true, true, true], "a network failure retries only on another host")
        try expect(!PostProcessingFallbackPolicy.isServerError(statusCode: 499), "499 isn't a server error")
        try expect(PostProcessingFallbackPolicy.isServerError(statusCode: 599), "599 is a server error")
        try expect(!PostProcessingFallbackPolicy.isServerError(statusCode: 600), "600 isn't a server error")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw PostProcessingChunkingTestFailure(message) }
    }
}

private struct PostProcessingChunkingTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private final class EchoCleanupRequester: PostProcessingChunkRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(budget: LocalAITokenBudget, prompt: String, transcript: String)] = []

    var budgets: [LocalAITokenBudget] { snapshot().map(\.budget) }
    /// Each request's rendered prompt, as the runner counts it.
    var prompts: [String] { snapshot().map(\.prompt) }
    var transcripts: [String] { snapshot().map(\.transcript) }

    func requestCleanup(system: String, user: String, budget: LocalAITokenBudget) async throws -> String {
        // The transcript is in the envelope, the user message's last paragraph.
        let envelope = user.components(separatedBy: "\n\n").last ?? ""
        let object = try JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any]
        let transcript = (object?["data"] as? [String: Any])?["transcript"] as? String ?? ""
        record((budget, "[System]\n\(system)\n\n[User]\n\(user)", transcript))
        return transcript
    }

    private func snapshot() -> [(budget: LocalAITokenBudget, prompt: String, transcript: String)] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ entry: (budget: LocalAITokenBudget, prompt: String, transcript: String)) {
        lock.lock()
        recorded.append(entry)
        lock.unlock()
    }
}

/// One token a byte, as a model counts emoji- or CJK-dense text; a
/// `costlyCharacter` adds `cost` tokens for each time it appears.
private final class DenseTokenCounter: LocalAITokenCounting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let costlyCharacter: Character?
    private let cost: Int

    init(costlyCharacter: Character? = nil, cost: Int = 0) {
        self.costlyCharacter = costlyCharacter
        self.cost = cost
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func tokenCount(forRenderedChatPrompt prompt: String) async throws -> Int {
        recordCall()
        let costly = costlyCharacter.map { character in prompt.filter { $0 == character }.count } ?? 0
        return prompt.utf8.count + costly * cost
    }

    private func recordCall() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
