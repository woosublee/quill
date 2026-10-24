import Foundation

struct LocalAITokenBudget: Equatable, Sendable {
    let sourceTokenLimit: Int
    let maxCompletionTokens: Int
}

protocol LocalAITokenCounting: Sendable {
    func tokenCount(forRenderedChatPrompt prompt: String) async throws -> Int
}

enum LocalAITokenBudgetRole: Sendable {
    case postProcessing(inputReservation: Int)
    case summaryExtraction
    case summaryIntermediateMerge
    case summaryFinalMerge
    /// A merge with only the extraction room, for when the full merge
    /// room leaves no batch to merge (#610).
    case summaryCompactMerge

    fileprivate func maxCompletionTokens(
        summaryCompletionTokens: Int,
        summaryMergeCompletionTokens: Int
    ) -> Int {
        switch self {
        case let .postProcessing(inputReservation):
            return min(max(inputReservation, 0) + 512, 6_144)
        case .summaryExtraction, .summaryCompactMerge:
            return summaryCompletionTokens
        case .summaryIntermediateMerge, .summaryFinalMerge:
            return summaryMergeCompletionTokens
        }
    }
}

struct LocalAITokenBudgeter: Sendable {
    static let safetyMarginTokens = 512
    /// Summary response room on a local model. Every point carries a
    /// verbatim source quote, so a full chunk's JSON outgrows 1,024 tokens
    /// (#609).
    static let localSummaryCompletionTokens = 4_096

    let contextWindow: Int
    let tokenCounter: any LocalAITokenCounting
    var summaryCompletionTokens = 1_024
    /// A merge batch that left only the extraction room could be cut off
    /// before it finished (#610).
    var summaryMergeCompletionTokens = 1_024

    func budget(
        forRenderedChatPrompt prompt: String,
        role: LocalAITokenBudgetRole
    ) async throws -> LocalAITokenBudget? {
        let renderedPromptTokens = try await tokenCounter.tokenCount(
            forRenderedChatPrompt: prompt
        )
        let maxCompletionTokens = role.maxCompletionTokens(
            summaryCompletionTokens: summaryCompletionTokens,
            summaryMergeCompletionTokens: summaryMergeCompletionTokens
        )
        let sourceTokenLimit = contextWindow
            - renderedPromptTokens
            - maxCompletionTokens
            - Self.safetyMarginTokens
        guard sourceTokenLimit > 0 else { return nil }

        return LocalAITokenBudget(
            sourceTokenLimit: sourceTokenLimit,
            maxCompletionTokens: maxCompletionTokens
        )
    }
}
