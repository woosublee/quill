import Foundation

public struct LocalAITokenBudget: Equatable, Sendable {
    public let sourceTokenLimit: Int
    public let maxCompletionTokens: Int

    public init(sourceTokenLimit: Int, maxCompletionTokens: Int) {
        self.sourceTokenLimit = sourceTokenLimit
        self.maxCompletionTokens = maxCompletionTokens
    }
}

public protocol LocalAITokenCounting: Sendable {
    func tokenCount(forRenderedChatPrompt prompt: String) async throws -> Int
}

public enum LocalAITokenBudgetRole: Sendable {
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

public struct LocalAITokenBudgeter: Sendable {
    public static let safetyMarginTokens = 512
    /// Summary response room on a local model. Every point carries a
    /// verbatim source quote, so a full chunk's JSON outgrows 1,024 tokens
    /// (#609).
    public static let localSummaryCompletionTokens = 4_096

    public let contextWindow: Int
    public let tokenCounter: any LocalAITokenCounting
    public var summaryCompletionTokens = 1_024
    /// A merge batch that left only the extraction room could be cut off
    /// before it finished (#610).
    public var summaryMergeCompletionTokens = 1_024

    public init(
        contextWindow: Int,
        tokenCounter: any LocalAITokenCounting,
        summaryCompletionTokens: Int = 1_024,
        summaryMergeCompletionTokens: Int = 1_024
    ) {
        self.contextWindow = contextWindow
        self.tokenCounter = tokenCounter
        self.summaryCompletionTokens = summaryCompletionTokens
        self.summaryMergeCompletionTokens = summaryMergeCompletionTokens
    }

    public func budget(
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
