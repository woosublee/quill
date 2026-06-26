import Foundation

enum InstructionExecutionDetector {
    private static let instructionMarkers: Set<String> = [
        "ask", "answer", "compose", "create", "draft", "email", "generate", "make",
        "message", "prompt", "reply", "respond", "response", "summarize", "tell",
        "translate", "write", "claude", "chatgpt", "ai", "llm"
    ]

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "could",
        "for", "from", "had", "has", "have", "he", "her", "him", "his", "i", "if",
        "in", "into", "is", "it", "its", "just", "me", "my", "of", "on", "or", "our",
        "please", "she", "so", "that", "the", "their", "them", "then", "there", "this",
        "to", "um", "uh", "was", "we", "were", "what", "when", "where", "who", "with",
        "would", "you", "your"
    ]

    private static let assistantPreamblePattern = #"(?i)^\s*(sure|certainly|absolutely|here(?:'s| is)|i(?:'d| would) be happy to|i can)\b"#

    static func appearsToHaveExecutedInstruction(
        rawTranscript: String,
        cleanedTranscript: String,
        outputLanguage: String
    ) -> Bool {
        let cleanedHasAssistantPreamble = cleanedTranscript.range(
            of: assistantPreamblePattern,
            options: .regularExpression
        ) != nil
        let rawHasSamePreamble = rawTranscript.range(
            of: assistantPreamblePattern,
            options: .regularExpression
        ) != nil

        if cleanedHasAssistantPreamble && !rawHasSamePreamble {
            return true
        }

        guard outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let rawTokens = significantTokens(in: rawTranscript)
        let cleanedTokens = significantTokens(in: cleanedTranscript)
        guard !rawTokens.isEmpty, !cleanedTokens.isEmpty else { return false }

        let rawMarkers = rawTokens.intersection(instructionMarkers)
        guard !rawMarkers.isEmpty else { return false }

        let preservedMarkers = rawMarkers.intersection(cleanedTokens)
        let overlap = rawTokens.intersection(cleanedTokens)
        let overlapRatio = Double(overlap.count) / Double(max(rawTokens.count, 1))

        return preservedMarkers.isEmpty && overlapRatio < 0.35
    }

    private static func significantTokens(in text: String) -> Set<String> {
        let normalized = text.lowercased()
        let parts = normalized.split { character in
            !character.isLetter && !character.isNumber
        }

        return Set(parts.map(String.init).filter { token in
            token.count > 1 && !stopWords.contains(token)
        })
    }
}
