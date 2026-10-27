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

    /// Which cleanup errors try the fallback model, for each pair of hosts
    /// (cloud to cloud, local to cloud, cloud to local). The table is the
    /// Mac's rule from #580.
    private static func testFallbackPolicyByErrorAndHosts() throws {
        let cases: [(PostProcessingError, [Bool])] = [
            (.rateLimited(model: "m", retryAfter: 1), [true, false, true]),
            (.requestFailed(statusCode: 429, providerCode: nil), [true, false, true]),
            (.requestFailed(statusCode: 500, providerCode: nil), [true, true, true]),
            (.requestFailed(statusCode: 503, providerCode: nil), [true, true, true]),
            (.requestFailed(statusCode: 400, providerCode: nil), [false, false, false]),
            (.requestFailed(statusCode: 401, providerCode: nil), [false, false, false]),
            (.requestTimedOut(30), [false, true, true]),
            (.emptyOutput, [false, true, false]),
            (.invalidResponse("synthetic"), [false, true, false]),
            (.invalidInput("synthetic"), [false, false, false]),
            (.contextBudgetExceeded, [false, false, false]),
            (.suspectedInstructionExecution, [false, false, false]),
        ]
        let hosts: [(fromLocal: Bool, toLocal: Bool)] = [(false, false), (true, false), (false, true)]
        for (error, expected) in cases {
            for (index, host) in hosts.enumerated() {
                try expect(
                    PostProcessingFallbackPolicy.shouldFallBack(
                        after: error,
                        fromLocal: host.fromLocal,
                        toLocal: host.toLocal,
                        retriesEmptyCloudOutput: false
                    ) == expected[index],
                    "\(error) from local \(host.fromLocal) to local \(host.toLocal)"
                )
            }
        }
        try expect(
            PostProcessingFallbackPolicy.shouldFallBack(
                after: .emptyOutput, fromLocal: false, toLocal: false, retriesEmptyCloudOutput: true
            ),
            "an empty cloud reply retries when the caller allows it"
        )
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
    private var recorded: [LocalAITokenBudget] = []

    var budgets: [LocalAITokenBudget] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func requestCleanup(system: String, user: String, budget: LocalAITokenBudget) async throws -> String {
        record(budget)
        // The transcript is in the envelope, the user message's last paragraph.
        let envelope = user.components(separatedBy: "\n\n").last ?? ""
        let object = try JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any]
        return (object?["data"] as? [String: Any])?["transcript"] as? String ?? ""
    }

    private func record(_ budget: LocalAITokenBudget) {
        lock.lock()
        recorded.append(budget)
        lock.unlock()
    }
}
