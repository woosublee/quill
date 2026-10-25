import Foundation

public enum ProtectedAtomScanner {
    public static func atoms(from source: String, vocabulary: [String] = []) -> [String] {
        let patterns = [
            #"https?://\S+"#,
            #"--[A-Za-z][A-Za-z0-9-]*"#,
            #"(?<!\S)/(?:[^\s/]+/)*[^\s/]+"#,
            #"\b[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_./:-]*\b"#,
            #"`[^`]+`"#,
            #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            #"(?<![A-Za-z0-9_./:-])\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?(?![A-Za-z0-9_./:-])"#,
            #"(?<![A-Za-z0-9_/:.-])\d{4}-\d{2}-\d{2}(?![A-Za-z0-9_/:-]|\.\d)"#,
            #"(?<![A-Za-z0-9_/:.-])(?:\d{4}|\d{1,2})/\d{1,2}/(?:\d{1,2}|\d{2,4})(?![A-Za-z0-9_/:-]|\.\d)"#,
            #"(?<![A-Za-z0-9_./:-])[-+]?(?:\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+\.\d+|\d+)\s*(?:to|[-–—])\s*[-+]?(?:\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+\.\d+|\d+)(?![A-Za-z0-9_./:-]|\.\d)"#,
            #"(?<![A-Za-z0-9_./:-])[-+]?(?:\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+\.\d+|\d+)(?![A-Za-z0-9_./:-]|\.\d)"#
        ]
        var atoms = patterns.flatMap { matches(of: $0, in: source) }
        atoms.append(contentsOf: vocabulary.filter { term in
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && source.localizedCaseInsensitiveContains(trimmed)
        })

        var seen = Set<String>()
        return atoms.filter { atom in
            seen.insert(atom.lowercased()).inserted
        }
    }

    public static func removingAtoms(
        from source: String,
        atoms: [String]? = nil
    ) -> String {
        (atoms ?? self.atoms(from: source)).reduce(source) { result, atom in
            result.replacingOccurrences(of: atom, with: " ")
        }
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}
