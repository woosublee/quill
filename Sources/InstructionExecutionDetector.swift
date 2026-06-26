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

    private static let assistantPreamblePattern = #"(?i)^\s*(?:(?:sure|certainly|absolutely)\b|here(?:'s| is)\b|i(?:'d| would) be happy to\b|i can\b|(?:claro|por supuesto|con gusto|aquí tienes|aqui tienes)\b|(?:물론입니다|물론이죠|알겠습니다|아래는|다음은|도와드리겠습니다|작성해 드리겠습니다))"#
    private static let leadingPunctuationPattern = #"^[\s,.:;!?\"'“”‘’()\[\]{}—–-]+"#
    private static let leadingFillerPattern = #"(?i)^\s*(?:(?:(?:um+|uh+|erm|er|ah+|eh+|yeah|yep|well|okay|ok|so)\b|음+|어+|저기)[\s,.:;!?—–-]*)+"#

    static func appearsToHaveExecutedInstruction(
        rawTranscript: String,
        cleanedTranscript: String,
        outputLanguage: String
    ) -> Bool {
        let cleanedHasAssistantPreamble = hasAssistantPreamble(in: cleanedTranscript)
        let rawHasSamePreamble = hasAssistantPreamble(in: rawTranscript)

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

    private static func hasAssistantPreamble(in text: String) -> Bool {
        let normalized = text
            .replacingOccurrences(of: leadingPunctuationPattern, with: "", options: .regularExpression)
            .replacingOccurrences(of: leadingFillerPattern, with: "", options: .regularExpression)

        return normalized.range(of: assistantPreamblePattern, options: .regularExpression) != nil
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
