import Foundation

@main
struct LocalAITokenBudgeterTests {
    static func main() async throws {
        try await testSummaryExtractionReservesCompletionAndSafetyMargin()
        try await testPostProcessingCapsCompletionReservation()
        try await testEverySummaryStageUsesFixedCompletionReservation()
        try await testBudgeterRejectsNonPositiveSourceBudget()
        try await testLocalSummaryReservesLargerCompletion()
        print("LocalAITokenBudgeterTests passed")
    }

    private static func testSummaryExtractionReservesCompletionAndSafetyMargin() async throws {
        let counter = FixedTokenCounter(count: 3_000)
        let budget = try await LocalAITokenBudgeter(
            contextWindow: 16_384,
            tokenCounter: counter
        ).budget(
            forRenderedChatPrompt: "rendered prompt",
            role: .summaryExtraction
        )

        try expect(budget == LocalAITokenBudget(
            sourceTokenLimit: 11_848,
            maxCompletionTokens: 1_024
        ), "summary extraction reserves 1,024 completion and 512 safety tokens")
        let prompts = await counter.prompts
        try expect(prompts == ["rendered prompt"], "budgeter counts the rendered prompt")
    }

    private static func testPostProcessingCapsCompletionReservation() async throws {
        let budget = try await LocalAITokenBudgeter(
            contextWindow: 16_384,
            tokenCounter: FixedTokenCounter(count: 600)
        ).budget(
            forRenderedChatPrompt: "rendered prompt",
            role: .postProcessing(inputReservation: 8_000)
        )

        try expect(budget == LocalAITokenBudget(
            sourceTokenLimit: 9_128,
            maxCompletionTokens: 6_144
        ), "post-processing caps a chunk completion reservation at 6,144")
    }

    private static func testEverySummaryStageUsesFixedCompletionReservation() async throws {
        let budgeter = LocalAITokenBudgeter(
            contextWindow: 16_384,
            tokenCounter: FixedTokenCounter(count: 2_000)
        )

        for role in [
            LocalAITokenBudgetRole.summaryExtraction,
            .summaryIntermediateMerge,
            .summaryFinalMerge,
            .summaryCompactMerge
        ] {
            let budget = try await budgeter.budget(
                forRenderedChatPrompt: "rendered prompt",
                role: role
            )
            try expect(budget?.maxCompletionTokens == 1_024, "summary stage reserves 1,024 completion tokens")
            try expect(budget?.sourceTokenLimit == 12_848, "summary stage retains the 512-token safety margin")
        }
    }

    private static func testLocalSummaryReservesLargerCompletion() async throws {
        let budgeter = LocalAITokenBudgeter(
            contextWindow: 16_384,
            tokenCounter: FixedTokenCounter(count: 2_000),
            summaryCompletionTokens: LocalAITokenBudgeter.localSummaryCompletionTokens,
            summaryMergeCompletionTokens: 6_144
        )
        let extraction = try await budgeter.budget(
            forRenderedChatPrompt: "rendered prompt",
            role: .summaryExtraction
        )
        try expect(extraction == LocalAITokenBudget(
            sourceTokenLimit: 9_776,
            maxCompletionTokens: 4_096
        ), "a local extraction reserves 4,096 completion tokens (#609)")

        for role in [LocalAITokenBudgetRole.summaryIntermediateMerge, .summaryFinalMerge] {
            let merge = try await budgeter.budget(
                forRenderedChatPrompt: "rendered prompt",
                role: role
            )
            try expect(merge == LocalAITokenBudget(
                sourceTokenLimit: 7_728,
                maxCompletionTokens: 6_144
            ), "a local merge reserves 6,144 completion tokens (#610)")
        }

        let compact = try await budgeter.budget(
            forRenderedChatPrompt: "rendered prompt",
            role: .summaryCompactMerge
        )
        try expect(
            compact?.maxCompletionTokens == 4_096,
            "a compact merge reserves only the extraction room"
        )
    }

    private static func testBudgeterRejectsNonPositiveSourceBudget() async throws {
        let budget = try await LocalAITokenBudgeter(
            contextWindow: 16_384,
            tokenCounter: FixedTokenCounter(count: 15_000)
        ).budget(
            forRenderedChatPrompt: "oversized rendered prompt",
            role: .summaryExtraction
        )

        try expect(budget == nil, "budgeter rejects chunks without positive source space")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(message) }
    }
}

private actor FixedTokenCounter: LocalAITokenCounting {
    let count: Int
    private(set) var prompts: [String] = []

    init(count: Int) {
        self.count = count
    }

    func tokenCount(forRenderedChatPrompt prompt: String) async throws -> Int {
        prompts.append(prompt)
        return count
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
