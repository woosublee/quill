import Foundation

@main
struct MeetingSourcePayloadTests {
    static func main() {
        testResolvedTitlePrefersCustomThenCalendar()
        testCalendarIsNullWhenNoMatch()
        testAudioPathAndExistsAreResolved()
        testAudioIsNullWhenNoFilename()
        testResourceAttendeeFlagFromEmail()
        testTimestampsUseProvidedFormatter()
        print("MeetingSourcePayloadTests passed")
    }

    private static func seoulFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return f
    }

    private static func makeItem(
        customTitle: String? = nil,
        calendarMatch: CalendarEventMatch? = nil,
        recordingStartedAt: Date? = nil,
        audioFileName: String? = nil
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            recordingStartedAt: recordingStartedAt,
            calendarMatch: calendarMatch,
            rawTranscript: "raw text",
            postProcessedTranscript: "clean text",
            postProcessingPrompt: nil,
            contextSummary: "ctx",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "none",
            postProcessingStatus: "done",
            debugStatus: "",
            customVocabulary: "",
            audioFileName: audioFileName,
            customTitle: customTitle
        )
    }

    private static func sampleCalendar(attendees: [CalendarEventAttendee]) -> CalendarEventMatch {
        CalendarEventMatch(
            calendarID: "cal", eventID: "evt", title: "Weekly Sync",
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_003_600),
            attendees: attendees,
            matchSource: .overlapSuggestion, titleState: .applied
        )
    }

    private static func testResolvedTitlePrefersCustomThenCalendar() {
        let withCustom = MeetingSourcePayload.make(
            item: makeItem(customTitle: "내 제목", calendarMatch: sampleCalendar(attendees: [])),
            audioDirectory: URL(fileURLWithPath: "/tmp"),
            fileExists: { _ in false }, formatter: seoulFormatter())
        let title = withCustom["title"] as! [String: Any]
        assert(title["resolved"] as? String == "내 제목")
        assert(title["custom"] as? String == "내 제목")
        assert(title["calendar"] as? String == "Weekly Sync")

        let calendarOnly = MeetingSourcePayload.make(
            item: makeItem(customTitle: "  ", calendarMatch: sampleCalendar(attendees: [])),
            audioDirectory: URL(fileURLWithPath: "/tmp"),
            fileExists: { _ in false }, formatter: seoulFormatter())
        let title2 = calendarOnly["title"] as! [String: Any]
        assert(title2["resolved"] as? String == "Weekly Sync")
        assert(title2["custom"] is NSNull)
    }

    private static func testCalendarIsNullWhenNoMatch() {
        let payload = MeetingSourcePayload.make(
            item: makeItem(), audioDirectory: URL(fileURLWithPath: "/tmp"),
            fileExists: { _ in false }, formatter: seoulFormatter())
        assert(payload["calendar"] is NSNull)
    }

    private static func testAudioPathAndExistsAreResolved() {
        let payload = MeetingSourcePayload.make(
            item: makeItem(audioFileName: "abc.wav"),
            audioDirectory: URL(fileURLWithPath: "/audio"),
            fileExists: { $0.path == "/audio/abc.wav" }, formatter: seoulFormatter())
        let audio = payload["audio"] as! [String: Any]
        assert(audio["filename"] as? String == "abc.wav")
        assert(audio["path"] as? String == "/audio/abc.wav")
        assert(audio["exists"] as? Bool == true)
    }

    private static func testAudioIsNullWhenNoFilename() {
        let payload = MeetingSourcePayload.make(
            item: makeItem(), audioDirectory: URL(fileURLWithPath: "/audio"),
            fileExists: { _ in true }, formatter: seoulFormatter())
        assert(payload["audio"] is NSNull)
    }

    private static func testResourceAttendeeFlagFromEmail() {
        let attendees = [
            CalendarEventAttendee(displayName: "우섭", email: "woosub@classting.com", responseStatus: "accepted"),
            CalendarEventAttendee(displayName: "회의실 A", email: "c_x@resource.calendar.google.com", responseStatus: "accepted"),
        ]
        let payload = MeetingSourcePayload.make(
            item: makeItem(calendarMatch: sampleCalendar(attendees: attendees)),
            audioDirectory: URL(fileURLWithPath: "/tmp"),
            fileExists: { _ in false }, formatter: seoulFormatter())
        let cal = payload["calendar"] as! [String: Any]
        let list = cal["attendees"] as! [[String: Any]]
        assert(list[0]["is_resource"] as? Bool == false)
        assert(list[0]["email"] as? String == "woosub@classting.com")
        assert(list[1]["is_resource"] as? Bool == true)
    }

    private static func testTimestampsUseProvidedFormatter() {
        let payload = MeetingSourcePayload.make(
            item: makeItem(recordingStartedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            audioDirectory: URL(fileURLWithPath: "/tmp"),
            fileExists: { _ in false }, formatter: seoulFormatter())
        let ts = payload["timestamps"] as! [String: Any]
        // 1_700_000_000 == 2023-11-15T06:13:20Z == +09:00 14:13:20
        assert((ts["recording_started_at"] as? String)?.hasSuffix("+09:00") == true)
        assert((ts["transcript_created_at"] as? String) != nil)
        assert(ts["recording_ended_at"] is NSNull)
    }
}
