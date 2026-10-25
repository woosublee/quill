import Foundation

public enum TranscriptCleanupMode: Equatable, Sendable {
    case short
    case long

    public static func resolve(for transcript: String) -> TranscriptCleanupMode {
        let proseCharacterCount = transcript.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.letters.contains(scalar) {
                count += 1
            }
        }
        if proseCharacterCount >= 800 {
            return .long
        }

        let normalizedParagraphBreaks = transcript.replacingOccurrences(
            of: #"\r?\n[\t ]*\r?\n"#,
            with: "\n\n",
            options: .regularExpression
        )
        let paragraphCount = normalizedParagraphBreaks
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
        return proseCharacterCount >= 400 && paragraphCount >= 2 ? .long : .short
    }
}
