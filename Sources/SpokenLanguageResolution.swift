import NaturalLanguage
import QuillAITextCore

struct TranscriptionResult: Equatable, Sendable {
    let text: String
    let spokenLanguage: SpokenLanguageResolution
}

enum TranscriptTextNormalizer {
    static func normalized(
        _ text: String,
        removingTimestampPrefixes: Bool = false
    ) -> String {
        let source: String
        if removingTimestampPrefixes {
            source = text
                .split(separator: "\n")
                .map { line in
                    String(line).replacingOccurrences(
                        of: #"^\[[^\]]+\]\s*"#,
                        with: "",
                        options: .regularExpression
                    )
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        } else {
            source = text
        }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let reducedPunctuation = trimmed.replacingOccurrences(
            of: #"([!?.,])\1+"#,
            with: #"$1"#,
            options: .regularExpression
        )
        let collapsedWhitespace = reducedPunctuation.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let normalized = collapsedWhitespace.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let contentOnly = normalized.trimmingCharacters(
            in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        )
        return contentOnly.isEmpty ? "" : normalized
    }
}
