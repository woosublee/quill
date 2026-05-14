import Foundation

@main
struct NoteListRowDisplayDataTests {
    static func main() {
        testFormatsRowDate()
        testUsesItemCustomTitleAndContentPreview()
        testDropsAutomaticTitleFromPreview()
        testWhitespaceOnlyCustomTitleDoesNotForceContentPreview()
        testFailurePreviewUsesErrorMessage()
        testFailurePreviewHandlesMissingSpaceAfterPrefix()
        testTranscribingTitleAndEmptyPreview()
        testRetryingItemHidesExistingPreview()
        print("NoteListRowDisplayDataTests passed")
    }

    private static func testFormatsRowDate() {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = 2025
        components.month = 5
        components.day = 5
        components.hour = 9
        components.minute = 0
        let item = historyItem(
            timestamp: components.date!,
            transcript: "Team sync notes"
        )

        let data = NoteListRowDisplayData(item: item, retryingIDs: [])

        assert(data.rowDate == "5월 5일 · 09:00", "Unexpected row date: \(data.rowDate)")
    }

    private static func testUsesItemCustomTitleAndContentPreview() {
        let item = historyItem(
            transcript: "Automatic transcript title\nDetails continue here",
            customTitle: "Manual title"
        )

        let data = NoteListRowDisplayData(item: item, retryingIDs: [])

        assert(data.displayTitle == "Manual title")
        assert(data.preview == "Automatic transcript title\nDetails continue here")
    }

    private static func testDropsAutomaticTitleFromPreview() {
        let item = historyItem(transcript: "Automatic transcript title\nDetails continue here")

        let data = NoteListRowDisplayData(item: item, retryingIDs: [])

        assert(data.displayTitle == "Automatic transcript title")
        assert(data.preview == "Details continue here", "Unexpected preview: \(data.preview)")
    }

    private static func testWhitespaceOnlyCustomTitleDoesNotForceContentPreview() {
        let item = historyItem(
            transcript: "Automatic transcript title\nDetails continue here",
            customTitle: "  \n  "
        )

        let data = NoteListRowDisplayData(item: item, retryingIDs: [])

        assert(data.displayTitle == "Automatic transcript title")
        assert(data.preview == "Details continue here", "Unexpected preview: \(data.preview)")
    }

    private static func testFailurePreviewUsesErrorMessage() {
        let item = historyItem(
            transcript: "Ignored transcript",
            postProcessingStatus: "Error: Network unavailable"
        )

        let data = NoteListRowDisplayData(item: item, retryingIDs: [])

        assert(data.status == .fail)
        assert(data.preview == "Network unavailable")
    }

    private static func testFailurePreviewHandlesMissingSpaceAfterPrefix() {
        let item = historyItem(
            transcript: "Ignored transcript",
            postProcessingStatus: "Error:Network unavailable"
        )

        let data = NoteListRowDisplayData(item: item, retryingIDs: [])

        assert(data.status == .fail)
        assert(data.preview == "Network unavailable", "Unexpected failure preview: \(data.preview)")
    }

    private static func testTranscribingTitleAndEmptyPreview() {
        let id = UUID()
        let item = historyItem(id: id, transcript: "", postProcessingStatus: "importing")

        let data = NoteListRowDisplayData(item: item, retryingIDs: [id])

        assert(data.status == .transcribing)
        assert(data.displayTitle == "Transcribing...")
        assert(data.preview.isEmpty)
    }

    private static func testRetryingItemHidesExistingPreview() {
        let id = UUID()
        let item = historyItem(id: id, transcript: "Previous title\nPrevious content")

        let data = NoteListRowDisplayData(item: item, retryingIDs: [id])

        assert(data.status == .transcribing)
        assert(data.preview.isEmpty, "Expected retrying item to hide stale preview, got: \(data.preview)")
    }

    private static func historyItem(
        id: UUID = UUID(),
        timestamp: Date = Date(timeIntervalSince1970: 1),
        transcript: String,
        postProcessingStatus: String = "Post-processing succeeded",
        customTitle: String? = nil
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: id,
            timestamp: timestamp,
            rawTranscript: transcript,
            postProcessedTranscript: transcript,
            postProcessingPrompt: nil,
            contextSummary: "",
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: postProcessingStatus,
            debugStatus: "Done",
            customVocabulary: "",
            customTitle: customTitle
        )
    }
}
