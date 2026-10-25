import Foundation

public struct MeetingSummaryTextChunk: Equatable, Sendable {
    public let index: Int
    public let startOffset: Int
    public let endOffset: Int
    public let text: String

    public init(index: Int, startOffset: Int, endOffset: Int, text: String) {
        self.index = index
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.text = text
    }
}

public struct MeetingSummaryTextChunker: Sendable {
    public static let defaultMaximumSourceBytes = 12_000

    public let maximumSourceBytes: Int

    public init(maximumSourceBytes: Int = Self.defaultMaximumSourceBytes) {
        precondition(maximumSourceBytes > 0)
        self.maximumSourceBytes = maximumSourceBytes
    }

    /// Retained for callers that configured the old character-based chunker.
    /// New Summary production code uses `maximumSourceBytes` from its token budget.
    public init(maxCharacters: Int) {
        self.init(maximumSourceBytes: maxCharacters)
    }

    public func chunks(for text: String) -> [MeetingSummaryTextChunk] {
        guard !text.isEmpty else { return [] }

        var chunks: [MeetingSummaryTextChunk] = []
        var start = text.startIndex
        var startOffset = 0

        while start < text.endIndex {
            let hardEnd = byteBoundedEnd(in: text, from: start)
            let end = hardEnd == text.endIndex
                ? hardEnd
                : preferredBoundary(in: text, from: start, hardEnd: hardEnd)
            let chunkText = String(text[start..<end])
            let endOffset = startOffset + chunkText.count
            chunks.append(
                MeetingSummaryTextChunk(
                    index: chunks.count,
                    startOffset: startOffset,
                    endOffset: endOffset,
                    text: chunkText
                )
            )
            start = end
            startOffset = endOffset
        }

        return chunks
    }

    private func byteBoundedEnd(
        in text: String,
        from start: String.Index
    ) -> String.Index {
        var index = start
        var byteCount = 0
        while index < text.endIndex {
            let next = text.index(after: index)
            let characterBytes = String(text[index..<next]).utf8.count
            if byteCount > 0 && byteCount + characterBytes > maximumSourceBytes {
                break
            }
            byteCount += characterBytes
            index = next
            if byteCount >= maximumSourceBytes { break }
        }
        return index
    }

    private func preferredBoundary(
        in text: String,
        from start: String.Index,
        hardEnd: String.Index
    ) -> String.Index {
        let searchRange = start..<hardEnd

        if let paragraph = text.range(
            of: "\n\n",
            options: .backwards,
            range: searchRange
        ) {
            return paragraph.upperBound
        }

        if let newline = text.range(
            of: "\n",
            options: .backwards,
            range: searchRange
        ) {
            return newline.upperBound
        }

        let terminators: Set<Character> = [".", "?", "!", "。", "？", "！"]
        var index = hardEnd
        while index > start {
            let previous = text.index(before: index)
            if terminators.contains(text[previous]) {
                return index
            }
            index = previous
        }

        return hardEnd
    }
}
