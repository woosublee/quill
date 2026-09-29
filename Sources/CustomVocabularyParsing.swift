import Foundation

/// A vocabulary list split into plain terms and explicit
/// heard-form -> correct-form correction pairs.
struct ParsedVocabulary: Equatable, Sendable {
    var terms: [String] = []
    var corrections: [VocabularyCorrection] = []
}

enum CustomVocabularyParser {
    /// Splits raw custom vocabulary into entries on new lines, commas, and
    /// semicolons, trimming whitespace and dropping case-insensitive
    /// duplicates. This is the long-standing vocabulary split.
    static func entries(from rawVocabulary: String) -> [String] {
        let terms = rawVocabulary
            .split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        return terms.filter { seen.insert($0.lowercased()).inserted }
    }

    static func parse(_ rawVocabulary: String) -> ParsedVocabulary {
        parseEntries(entries(from: rawVocabulary))
    }

    /// Entries may use "heard form -> Correct Form" (or "=>" / "→") to teach
    /// the model a specific mishearing. Multiple heard variants can share one
    /// correction with "|": "cloud code | clod code -> Claude Code".
    /// Entries without an arrow behave exactly as before.
    static func parseEntries(_ entries: [String]) -> ParsedVocabulary {
        var parsed = ParsedVocabulary()
        for entry in entries {
            guard let arrow = entry.range(of: "->")
                ?? entry.range(of: "=>")
                ?? entry.range(of: "→") else {
                parsed.terms.append(entry)
                continue
            }
            let correct = entry[arrow.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let heardForms = entry[..<arrow.lowerBound]
                .split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !correct.isEmpty, !heardForms.isEmpty else {
                // Malformed mapping: keep whichever side exists as a plain term.
                let fallback = correct.isEmpty ? heardForms.joined(separator: ", ") : correct
                if !fallback.isEmpty { parsed.terms.append(fallback) }
                continue
            }
            parsed.terms.append(correct)
            for heard in heardForms {
                parsed.corrections.append(VocabularyCorrection(heard: heard, correct: correct))
            }
        }
        // A mapping's correct form may repeat an existing plain entry.
        var seen = Set<String>()
        parsed.terms = parsed.terms.filter { seen.insert($0.lowercased()).inserted }
        return parsed
    }
}
