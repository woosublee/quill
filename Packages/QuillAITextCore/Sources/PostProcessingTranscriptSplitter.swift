import Foundation

/// Splits a transcript into chunks of at most `maximumSourceBytes`: by
/// paragraph, then sentence, then word, then character.
public struct PostProcessingTranscriptSplitter: Sendable {
    public struct Chunk: Equatable, Sendable {
        public let text: String
    }

    public let maximumSourceBytes: Int

    public init(maximumSourceBytes: Int) {
        self.maximumSourceBytes = maximumSourceBytes
    }

    public func chunks(for source: String) -> [Chunk] {
        guard maximumSourceBytes > 0 else { return [] }
        let paragraphs = source.components(separatedBy: "\n\n")
        let segments = paragraphs.flatMap(splitParagraph)
        return segments.map(Chunk.init(text:))
    }

    private func splitParagraph(_ paragraph: String) -> [String] {
        let trimmedParagraph = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedParagraph.isEmpty else { return [] }
        guard trimmedParagraph.utf8.count > maximumSourceBytes else {
            return [trimmedParagraph]
        }

        let sentences = sentenceFragments(in: trimmedParagraph)
        var chunks: [String] = []
        var current = ""
        for sentence in sentences {
            let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSentence.isEmpty else { continue }
            if trimmedSentence.utf8.count > maximumSourceBytes {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                chunks.append(contentsOf: splitWordsOrBytes(trimmedSentence))
                continue
            }

            let candidate = current.isEmpty ? trimmedSentence : "\(current) \(trimmedSentence)"
            if candidate.utf8.count <= maximumSourceBytes {
                current = candidate
            } else {
                if !current.isEmpty { chunks.append(current) }
                current = trimmedSentence
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func sentenceFragments(in text: String) -> [String] {
        let pattern = #"[^.!?。！？]+[.!?。！？]+|[^.!?。！？]+$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return [text]
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let fragments = expression.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
        return fragments.isEmpty ? [text] : fragments
    }

    private func splitWordsOrBytes(_ text: String) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count > 1 else { return splitAtSafeByteBoundaries(text) }

        var chunks: [String] = []
        var current = ""
        for word in words {
            if word.utf8.count > maximumSourceBytes {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                chunks.append(contentsOf: splitAtSafeByteBoundaries(word))
                continue
            }
            let candidate = current.isEmpty ? word : "\(current) \(word)"
            if candidate.utf8.count <= maximumSourceBytes {
                current = candidate
            } else {
                if !current.isEmpty { chunks.append(current) }
                current = word
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func splitAtSafeByteBoundaries(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        var currentByteCount = 0

        for character in text {
            let characterByteCount = String(character).utf8.count
            if !current.isEmpty,
               currentByteCount + characterByteCount > maximumSourceBytes {
                chunks.append(current)
                current = String(character)
                currentByteCount = characterByteCount
            } else {
                current.append(character)
                currentByteCount += characterByteCount
            }
        }

        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
