import Foundation

/// A vocabulary list split into plain terms and explicit
/// heard-form -> correct-form correction pairs.
struct ParsedVocabulary: Equatable, Sendable {
    var terms: [String] = []
    var corrections: [VocabularyCorrection] = []

    /// Heard forms the output check may let change. A heard form that
    /// matches a correct form ignoring case (`quill -> Quill`) is left out,
    /// so the correct spelling stays protected.
    var outputCheckExemptHeardForms: [String] {
        let correctForms = Set(corrections.map { $0.correct.lowercased() })
        return corrections
            .map(\.heard)
            .filter { !correctForms.contains($0.lowercased()) }
    }
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

    /// Entries may use "heard form -> Correct Form" (or " => " / " → ") to teach
    /// the model a specific mishearing. Multiple heard variants can share one
    /// correction with "|": "cloud code | clod code -> Claude Code".
    /// Entries without an arrow behave exactly as before.
    static func parseEntries(_ entries: [String]) -> ParsedVocabulary {
        var parsed = ParsedVocabulary()
        for entry in entries {
            // The arrow needs whitespace on both sides so existing words
            // such as `ptr->next` or `a=>b` stay plain vocabulary.
            guard let arrow = entry.range(
                of: #"\s(?:->|=>|→)\s"#,
                options: .regularExpression
            ) else {
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
        // A plain entry that is also a heard form (for example `cloud code`
        // added before `cloud code -> Claude Code`) would make the output
        // check require the misheard spelling and reject the correction.
        // A correct form always stays, even when it differs from its heard
        // form only by case (`quill -> Quill`).
        let correctForms = Set(parsed.corrections.map { $0.correct.lowercased() })
        let heardForms = Set(parsed.corrections.map { $0.heard.lowercased() })
            .subtracting(correctForms)
        parsed.terms = parsed.terms.filter { !heardForms.contains($0.lowercased()) }
        return parsed
    }
}
