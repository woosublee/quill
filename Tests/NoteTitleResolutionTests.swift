import Foundation

@main
struct NoteTitleResolutionTests {
    static func main() {
        testCustomTitleWins()
        testAppliedCalendarTitleWinsOverTranscriptTitle()
        testSuggestedCalendarTitleDoesNotOverrideTranscriptTitle()
        testFallbackUsedWhenNoContentOrAppliedCalendarTitle()
        testTranscribingFallbackWinsOverFailedEmptyContent()
        testAppliedCalendarTitleKeepsWinningWhileTranscribing()
        print("NoteTitleResolutionTests passed")
    }

    private static func testCustomTitleWins() {
        let item = item(transcript: "Transcript title", calendarMatch: match(title: "Calendar title", titleState: .applied))
        let title = NoteTitleResolver.displayTitle(for: item, customTitle: "Manual title")
        assert(title == "Manual title")
    }

    private static func testAppliedCalendarTitleWinsOverTranscriptTitle() {
        let item = item(transcript: "Transcript title", calendarMatch: match(title: "Calendar title", titleState: .applied))
        let title = NoteTitleResolver.displayTitle(for: item, customTitle: nil)
        assert(title == "Calendar title")
    }

    private static func testSuggestedCalendarTitleDoesNotOverrideTranscriptTitle() {
        let item = item(transcript: "Transcript title", calendarMatch: match(title: "Calendar title", titleState: .suggested))
        let title = NoteTitleResolver.displayTitle(for: item, customTitle: nil)
        assert(title == "Transcript title")
    }

    private static func testFallbackUsedWhenNoContentOrAppliedCalendarTitle() {
        let item = item(transcript: "", calendarMatch: nil)
        let title = NoteTitleResolver.displayTitle(for: item, customTitle: nil)
        assert(title == "(No content)")
    }

    private static func testTranscribingFallbackWinsOverFailedEmptyContent() {
        let item = item(transcript: "", calendarMatch: nil, postProcessingStatus: "Error: Previous failure")
        let title = NoteTitleResolver.displayTitle(for: item, customTitle: nil, isTranscribing: true)
        assert(title == "Transcribing...")
    }

    private static func testAppliedCalendarTitleKeepsWinningWhileTranscribing() {
        let item = item(transcript: "", calendarMatch: match(title: "Calendar title", titleState: .applied), postProcessingStatus: "Error: Previous failure")
        let title = NoteTitleResolver.displayTitle(for: item, customTitle: nil, isTranscribing: true)
        assert(title == "Calendar title")
    }

    private static func item(transcript: String, calendarMatch: CalendarEventMatch?, postProcessingStatus: String = "Post-processing succeeded") -> PipelineHistoryItem {
        PipelineHistoryItem(
            timestamp: Date(timeIntervalSince1970: 1),
            calendarMatch: calendarMatch,
            rawTranscript: transcript,
            postProcessedTranscript: transcript,
            postProcessingPrompt: nil,
            contextSummary: "",
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: postProcessingStatus,
            debugStatus: "Done",
            customVocabulary: ""
        )
    }

    private static func match(title: String, titleState: CalendarTitleState) -> CalendarEventMatch {
        CalendarEventMatch(calendarID: "calendar", eventID: "event", title: title, start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 2), matchSource: .overlapSuggestion, titleState: titleState)
    }
}
