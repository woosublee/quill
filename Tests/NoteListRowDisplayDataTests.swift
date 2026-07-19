import Foundation

@main
struct NoteListRowDisplayDataTests {
    static func main() {
        testFormatsRowDate()
        testFormatsExplicitLocaleRowDates()
        testFormatsExplicitLocaleDetailTimestamps()
        testFormatsJapaneseDetailTimestamp()
        testFormatsSameMorningRowDateStartTime()
        testFormatsMorningToAfternoonRowDateStartTime()
        testFormatsCrossDateRowDateStartTime()
        testFormatsSameMorningRecordingInterval()
        testFormatsMorningToAfternoonRecordingInterval()
        testFormatsSameAfternoonRecordingInterval()
        testFormatsCrossDateRecordingInterval()
        testUsesSingleTimestampWhenRecordingIntervalIsMissing()
        testUsesItemCustomTitleAndContentPreview()
        testDropsAutomaticTitleFromPreview()
        testWhitespaceOnlyCustomTitleDoesNotForceContentPreview()
        testFailurePreviewUsesErrorMessage()
        testFailurePreviewHandlesMissingSpaceAfterPrefix()
        testRecoveredRecordingUsesFriendlyStatusAndPreview()
        testDegradedRecoveredRecordingNamesAvailableSource()
        testStorageInterruptionPreviewCombinesCauseAndMode()
        testTranscribingTitleAndEmptyPreview()
        testRetryingItemHidesExistingPreview()
        print("NoteListRowDisplayDataTests passed")
    }

    private static func testFormatsRowDate() {
        let item = historyItem(
            timestamp: date(year: 2025, month: 5, day: 5, hour: 9, minute: 0),
            transcript: "Team sync notes"
        )

        let rowDate = NoteTimestampFormatter.rowTimestamp(for: item, locale: Locale(identifier: "ko_KR"))

        assert(rowDate == "5월 5일 오전 9:00", "Unexpected row date: \(rowDate)")
    }

    private static func testFormatsExplicitLocaleRowDates() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            recordingStartedAt: date(year: 2026, month: 5, day: 15, hour: 10, minute: 38),
            recordingEndedAt: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            transcript: "Morning notes"
        )

        let english = NoteTimestampFormatter.rowTimestamp(for: item, locale: Locale(identifier: "en_US"))
        let korean = NoteTimestampFormatter.rowTimestamp(for: item, locale: Locale(identifier: "ko_KR"))

        assert(english == "May 15 at 10:38 AM", "Unexpected English row date: \(english)")
        assert(korean == "5월 15일 오전 10:38", "Unexpected Korean row date: \(korean)")
    }

    private static func testFormatsExplicitLocaleDetailTimestamps() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            recordingStartedAt: date(year: 2026, month: 5, day: 15, hour: 10, minute: 38),
            recordingEndedAt: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            transcript: "Morning notes"
        )

        let english = NoteTimestampFormatter.detailTimestamp(for: item, locale: Locale(identifier: "en_US"))
        let korean = NoteTimestampFormatter.detailTimestamp(for: item, locale: Locale(identifier: "ko_KR"))

        assert(english == "May 15, 2026, 10:38 – 11:12 AM", "Unexpected English interval: \(english)")
        assert(korean == "2026년 5월 15일 오전 10:38~11:12", "Unexpected Korean interval: \(korean)")
    }

    private static func testFormatsJapaneseDetailTimestamp() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            recordingStartedAt: date(year: 2026, month: 5, day: 15, hour: 10, minute: 38),
            recordingEndedAt: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            transcript: "Morning notes"
        )

        let japanese = NoteTimestampFormatter.detailTimestamp(for: item, locale: Locale(identifier: "ja_JP"))

        assert(japanese == "2026年5月15日 10時38分～11時12分", "Unexpected Japanese interval: \(japanese)")
    }

    private static func testFormatsSameMorningRowDateStartTime() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            recordingStartedAt: date(year: 2026, month: 5, day: 15, hour: 10, minute: 38),
            recordingEndedAt: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            transcript: "Morning notes"
        )

        let data = NoteListRowDisplayData(
            item: item,
            retryingIDs: [],
            locale: Locale(identifier: "ko_KR")
        )

        assert(data.rowDate == "5월 15일 오전 10:38", "Unexpected row date: \(data.rowDate)")
    }

    private static func testFormatsMorningToAfternoonRowDateStartTime() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 15, hour: 12, minute: 12),
            recordingStartedAt: date(year: 2026, month: 5, day: 15, hour: 10, minute: 38),
            recordingEndedAt: date(year: 2026, month: 5, day: 15, hour: 12, minute: 12),
            transcript: "Noon notes"
        )

        let data = NoteListRowDisplayData(
            item: item,
            retryingIDs: [],
            locale: Locale(identifier: "ko_KR")
        )

        assert(data.rowDate == "5월 15일 오전 10:38", "Unexpected row date: \(data.rowDate)")
    }

    private static func testFormatsCrossDateRowDateStartTime() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 16, hour: 0, minute: 10),
            recordingStartedAt: date(year: 2026, month: 5, day: 15, hour: 23, minute: 40),
            recordingEndedAt: date(year: 2026, month: 5, day: 16, hour: 0, minute: 10),
            transcript: "Late notes"
        )

        let data = NoteListRowDisplayData(
            item: item,
            retryingIDs: [],
            locale: Locale(identifier: "ko_KR")
        )

        assert(data.rowDate == "5월 15일 오후 11:40", "Unexpected row date: \(data.rowDate)")
    }

    private static func testFormatsSameMorningRecordingInterval() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            recordingStartedAt: date(year: 2026, month: 5, day: 15, hour: 10, minute: 38),
            recordingEndedAt: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            transcript: "Morning notes"
        )

        let formatted = NoteTimestampFormatter.detailTimestamp(for: item, locale: Locale(identifier: "ko_KR"))

        assert(formatted == "2026년 5월 15일 오전 10:38~11:12", "Unexpected interval: \(formatted)")
    }

    private static func testFormatsMorningToAfternoonRecordingInterval() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 15, hour: 12, minute: 12),
            recordingStartedAt: date(year: 2026, month: 5, day: 15, hour: 10, minute: 38),
            recordingEndedAt: date(year: 2026, month: 5, day: 15, hour: 12, minute: 12),
            transcript: "Noon notes"
        )

        let formatted = NoteTimestampFormatter.detailTimestamp(for: item, locale: Locale(identifier: "ko_KR"))

        assert(formatted == "2026년 5월 15일 오전 10:38 ~ 오후 12:12", "Unexpected interval: \(formatted)")
    }

    private static func testFormatsSameAfternoonRecordingInterval() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 15, hour: 14, minute: 22),
            recordingStartedAt: date(year: 2026, month: 5, day: 15, hour: 13, minute: 5),
            recordingEndedAt: date(year: 2026, month: 5, day: 15, hour: 14, minute: 22),
            transcript: "Afternoon notes"
        )

        let formatted = NoteTimestampFormatter.detailTimestamp(for: item, locale: Locale(identifier: "ko_KR"))

        assert(formatted == "2026년 5월 15일 오후 1:05~2:22", "Unexpected interval: \(formatted)")
    }

    private static func testFormatsCrossDateRecordingInterval() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 16, hour: 0, minute: 10),
            recordingStartedAt: date(year: 2026, month: 5, day: 15, hour: 23, minute: 40),
            recordingEndedAt: date(year: 2026, month: 5, day: 16, hour: 0, minute: 10),
            transcript: "Late notes"
        )

        let formatted = NoteTimestampFormatter.detailTimestamp(for: item, locale: Locale(identifier: "ko_KR"))

        assert(formatted == "2026년 5월 15일 오후 11:40 ~ 2026년 5월 16일 오전 12:10", "Unexpected interval: \(formatted)")
    }

    private static func testUsesSingleTimestampWhenRecordingIntervalIsMissing() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 15, hour: 10, minute: 38),
            transcript: "Imported notes"
        )

        let formatted = NoteTimestampFormatter.detailTimestamp(for: item, locale: Locale(identifier: "ko_KR"))

        assert(formatted == "2026년 5월 15일 오전 10:38", "Unexpected timestamp: \(formatted)")
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

    private static func testRecoveredRecordingUsesFriendlyStatusAndPreview() {
        let item = historyItem(
            transcript: "",
            postProcessingStatus: PipelineHistoryItem.recoveredRecordingStatus
        )

        let data = NoteListRowDisplayData(item: item, retryingIDs: [])

        assert(data.status == .recovered)
        assert(data.displayTitle == "Recording interrupted")
        assert(data.preview == "Recovered after an unexpected shutdown. Not yet transcribed.")
    }

    private static func testDegradedRecoveredRecordingNamesAvailableSource() {
        let cases: [(RecoveredRecordingMode, String, String)] = [
            (
                .microphoneOnly,
                "Microphone audio recovered",
                "System Audio could not be recovered. Microphone audio is available for playback or transcription."
            ),
            (
                .systemAudioOnly,
                "System Audio recovered",
                "Microphone audio could not be recovered. System Audio is available for playback or transcription."
            ),
            (
                .partial,
                "Some audio recovered",
                "Some parts of this recording may be missing. The recovered audio is available for playback or transcription."
            )
        ]
        for (mode, title, preview) in cases {
            let item = historyItem(
                transcript: "",
                postProcessingStatus: mode.recoveredStatus
            )
            let data = NoteListRowDisplayData(item: item, retryingIDs: [])

            assert(data.status == .recovered)
            assert(data.displayTitle == title)
            assert(data.preview == preview)
        }
    }

    private static func testStorageInterruptionPreviewCombinesCauseAndMode() {
        let complete = RecoveredRecordingContext(
            mode: .complete,
            interruptionReason: .storageFull
        )
        let completeData = NoteListRowDisplayData(
            item: historyItem(
                transcript: "",
                postProcessingStatus: complete.recoveredStatus
            ),
            retryingIDs: []
        )
        assert(completeData.displayTitle == "Recording stopped: storage full")
        assert(
            completeData.preview == "Quill stopped recording because storage was full. Audio saved before the interruption is available for playback or transcription."
        )

        let partial = RecoveredRecordingContext(
            mode: .partial,
            interruptionReason: .storageFull
        )
        let partialData = NoteListRowDisplayData(
            item: historyItem(
                transcript: "",
                postProcessingStatus: partial.recoveredStatus
            ),
            retryingIDs: []
        )
        assert(partialData.displayTitle == "Recording stopped: storage full")
        assert(
            partialData.preview == "Quill stopped recording because storage was full. Some parts of this recording may be missing. The recovered audio is available for playback or transcription."
        )
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
        recordingStartedAt: Date? = nil,
        recordingEndedAt: Date? = nil,
        transcript: String,
        postProcessingStatus: String = "Post-processing succeeded",
        customTitle: String? = nil
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: id,
            timestamp: timestamp,
            recordingStartedAt: recordingStartedAt,
            recordingEndedAt: recordingEndedAt,
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

    private static func date(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return components.date!
    }
}
