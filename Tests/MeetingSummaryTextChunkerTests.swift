import Foundation
import QuillAITextCore

@main
struct MeetingSummaryTextChunkerTests {
    static func main() {
        testShortTextProducesOneChunk()
        testLongTextCoversEveryCharacterExactlyOnce()
        testRepeatedRunsProduceIdenticalChunks()
        testUnicodeOffsetsUseStringCharacters()
        testChunksStayWithinUTF8SourceBudget()
        print("MeetingSummaryTextChunkerTests passed")
    }

    private static func testShortTextProducesOneChunk() {
        let chunks = MeetingSummaryTextChunker(maxCharacters: 40)
            .chunks(for: "One short paragraph.")

        precondition(chunks.count == 1)
        precondition(chunks[0].text == "One short paragraph.")
        precondition(chunks[0].startOffset == 0)
        precondition(chunks[0].endOffset == 20)
    }

    private static func testLongTextCoversEveryCharacterExactlyOnce() {
        let input = (1...20)
            .map { "Paragraph \($0). Decision sentence." }
            .joined(separator: "\n\n")
        let chunks = MeetingSummaryTextChunker(maxCharacters: 90)
            .chunks(for: input)

        precondition(chunks.count > 1)
        precondition(chunks.map(\.text).joined() == input)
        for pair in zip(chunks, chunks.dropFirst()) {
            precondition(pair.0.endOffset == pair.1.startOffset)
        }
    }

    private static func testRepeatedRunsProduceIdenticalChunks() {
        let input = String(
            repeating: "Sentence one. Sentence two.\n",
            count: 30
        )
        let chunker = MeetingSummaryTextChunker(maxCharacters: 120)

        precondition(chunker.chunks(for: input) == chunker.chunks(for: input))
    }

    private static func testChunksStayWithinUTF8SourceBudget() {
        let input = String(repeating: "회의 결정 😊. ", count: 20)
        let chunks = MeetingSummaryTextChunker(maximumSourceBytes: 48)
            .chunks(for: input)

        precondition(chunks.count > 1)
        precondition(chunks.map(\.text).joined() == input)
        precondition(chunks.allSatisfy { $0.text.utf8.count <= 48 })
    }

    private static func testUnicodeOffsetsUseStringCharacters() {
        let input = "회의 😊 결정. 다음 문장입니다."
        let chunks = MeetingSummaryTextChunker(maxCharacters: 8)
            .chunks(for: input)

        precondition(chunks.map(\.text).joined() == input)
        precondition(chunks.last?.endOffset == input.count)
    }
}
