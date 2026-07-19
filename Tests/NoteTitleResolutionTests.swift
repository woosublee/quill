import Foundation

@main
struct NoteTitleResolutionTests {
    static func main() {
        testItemCustomTitleWins()
        testAppliedCalendarTitleWinsOverTranscriptTitle()
        testSuggestedCalendarTitleDoesNotOverrideTranscriptTitle()
        testFallbackUsedWhenNoContentOrAppliedCalendarTitle()
        testTranscribingFallbackWinsOverFailedEmptyContent()
        testAppliedCalendarTitleKeepsWinningWhileTranscribing()
        testCalendarAppliedTitleIncludesRecordingDate()
        testRecoveredRecordingTitlesNameAvailableSource()
        testStorageInterruptionReasonWinsRecoveredTitle()
        print("NoteTitleResolutionTests passed")
    }

    private static func testItemCustomTitleWins() {
        let item = item(
            transcript: "Transcript title",
            calendarMatch: match(title: "Calendar title", titleState: .applied),
            customTitle: "Manual title"
        )
        let title = NoteTitleResolver.displayTitle(for: item)
        assert(title == "Manual title")
    }

    private static func testAppliedCalendarTitleWinsOverTranscriptTitle() {
        let item = item(transcript: "Transcript title", calendarMatch: match(title: "Calendar title", titleState: .applied))
        let title = NoteTitleResolver.displayTitle(for: item)
        assert(title == "Calendar title")
    }

    private static func testSuggestedCalendarTitleDoesNotOverrideTranscriptTitle() {
        let item = item(transcript: "Transcript title", calendarMatch: match(title: "Calendar title", titleState: .suggested))
        let title = NoteTitleResolver.displayTitle(for: item)
        assert(title == "Transcript title")
    }

    private static func testFallbackUsedWhenNoContentOrAppliedCalendarTitle() {
        let item = item(transcript: "", calendarMatch: nil)
        let title = NoteTitleResolver.displayTitle(for: item)
        assert(title == "(No content)")
    }

    private static func testTranscribingFallbackWinsOverFailedEmptyContent() {
        let item = item(transcript: "", calendarMatch: nil, postProcessingStatus: "Error: Previous failure")
        let title = NoteTitleResolver.displayTitle(for: item, isTranscribing: true)
        assert(title == "Transcribing...")
    }

    private static func testAppliedCalendarTitleKeepsWinningWhileTranscribing() {
        let item = item(transcript: "", calendarMatch: match(title: "Calendar title", titleState: .applied), postProcessingStatus: "Error: Previous failure")
        let title = NoteTitleResolver.displayTitle(for: item, isTranscribing: true)
        assert(title == "Calendar title")
    }

    private static func testCalendarAppliedTitleIncludesRecordingDate() {
        let recordingStartedAt = Date(timeIntervalSince1970: 1_746_422_400)
        let title = NoteTitleResolver.calendarAppliedTitle(
            suggestedTitle: "Team Standup",
            recordingStartedAt: recordingStartedAt
        )
        assert(title == "2025-05-05 Team Standup")
    }

    private static func testRecoveredRecordingTitlesNameAvailableSource() {
        let cases: [(RecoveredRecordingMode, String)] = [
            (.complete, "Recording interrupted"),
            (.microphoneOnly, "Microphone audio recovered"),
            (.systemAudioOnly, "System Audio recovered"),
            (.partial, "Some audio recovered")
        ]
        for (mode, expected) in cases {
            let recovered = item(
                transcript: "",
                calendarMatch: nil,
                postProcessingStatus: mode.recoveredStatus
            )
            assert(NoteTitleResolver.displayTitle(for: recovered) == expected)
        }
    }

    private static func testStorageInterruptionReasonWinsRecoveredTitle() {
        let cases: [(RecordingInterruptionReason, String)] = [
            (.storageFull, "Recording stopped: storage full"),
            (.permissionDenied, "Recording stopped: storage unavailable"),
            (.journalIOFailure, "Recording stopped: save error")
        ]
        for (reason, expected) in cases {
            let context = RecoveredRecordingContext(
                mode: .partial,
                interruptionReason: reason
            )
            let recovered = item(
                transcript: "",
                calendarMatch: nil,
                postProcessingStatus: context.recoveredStatus
            )
            assert(NoteTitleResolver.displayTitle(for: recovered) == expected)
        }
    }

    private static func item(
        transcript: String,
        calendarMatch: CalendarEventMatch?,
        postProcessingStatus: String = "Post-processing succeeded",
        customTitle: String? = nil
    ) -> PipelineHistoryItem {
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
            customVocabulary: "",
            customTitle: customTitle
        )
    }

    private static func match(title: String, titleState: CalendarTitleState) -> CalendarEventMatch {
        CalendarEventMatch(calendarID: "calendar", eventID: "event", title: title, start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 2), matchSource: .overlapSuggestion, titleState: titleState)
    }
}
