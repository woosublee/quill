import Foundation

@main
struct NotePayloadTests {
    static func main() throws {
        testNoteCarriesDisplayTitleAndSummary()
        testNoteSummaryIsNullWhenMissing()
        testCalendarIsNullWhenNoMatch()
        testAudioPathAndExistsAreResolved()
        testAudioIsNullWhenNoFilename()
        testResourceAttendeeFlagFromEmail()
        testTimestampsUseProvidedFormatter()
        try testListIsNewestFirstWithTitleAndPreview()
        try testListLimitReportsMore()
        try testListQueryMatchesTitleTranscriptAndSummary()
        try testListDateRangeUsesWholeLocalDays()
        try testListAcceptsDateTimes()
        testListRejectsBadDates()
        print("NotePayloadTests passed")
    }

    private static let seoul = TimeZone(identifier: "Asia/Seoul")!

    private static func seoulFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = seoul
        return f
    }

    private static func makeItem(
        id: String = "00000000-0000-0000-0000-0000000000AA",
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
        transcript: String = "clean text",
        calendarMatch: CalendarEventMatch? = nil,
        recordingStartedAt: Date? = nil,
        audioFileName: String? = nil
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: UUID(uuidString: id)!,
            timestamp: timestamp,
            recordingStartedAt: recordingStartedAt,
            calendarMatch: calendarMatch,
            rawTranscript: "raw text",
            postProcessedTranscript: transcript,
            postProcessingPrompt: nil,
            contextSummary: "ctx",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "none",
            postProcessingStatus: "done",
            debugStatus: "",
            customVocabulary: "",
            audioFileName: audioFileName,
            customTitle: nil
        )
    }

    private static func sampleCalendar(
        title: String = "Weekly Sync",
        attendees: [CalendarEventAttendee] = []
    ) -> CalendarEventMatch {
        CalendarEventMatch(
            calendarID: "cal", eventID: "evt", title: title,
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_003_600),
            attendees: attendees,
            matchSource: .overlapSuggestion, titleState: .applied
        )
    }

    private static func note(
        _ item: PipelineHistoryItem,
        title: String = "Note title",
        summary: String? = nil,
        audioDirectory: String = "/tmp",
        fileExists: (URL) -> Bool = { _ in false }
    ) -> [String: Any] {
        NotePayload.make(
            item: item,
            title: title,
            summary: summary,
            audioDirectory: URL(fileURLWithPath: audioDirectory),
            fileExists: fileExists,
            formatter: seoulFormatter()
        )
    }

    private static func testNoteCarriesDisplayTitleAndSummary() {
        let payload = note(
            makeItem(calendarMatch: sampleCalendar()),
            title: "2023-11-15 Weekly Sync",
            summary: "## Overview\n\nPlanned the launch."
        )
        precondition(payload["title"] as? String == "2023-11-15 Weekly Sync")
        precondition(payload["summary"] as? String == "## Overview\n\nPlanned the launch.")
        precondition(payload["transcript"] as? String == "clean text")
        precondition(payload["raw_transcript"] as? String == "raw text")
        precondition(payload["context"] as? String == "ctx")
    }

    private static func testNoteSummaryIsNullWhenMissing() {
        precondition(note(makeItem())["summary"] is NSNull)
        precondition(note(makeItem(), summary: "  ")["summary"] is NSNull)
    }

    private static func testCalendarIsNullWhenNoMatch() {
        precondition(note(makeItem())["calendar"] is NSNull)
    }

    private static func testAudioPathAndExistsAreResolved() {
        let payload = note(
            makeItem(audioFileName: "abc.wav"),
            audioDirectory: "/audio",
            fileExists: { $0.path == "/audio/abc.wav" }
        )
        let audio = payload["audio"] as! [String: Any]
        precondition(audio["filename"] as? String == "abc.wav")
        precondition(audio["path"] as? String == "/audio/abc.wav")
        precondition(audio["exists"] as? Bool == true)
    }

    private static func testAudioIsNullWhenNoFilename() {
        precondition(note(makeItem(), fileExists: { _ in true })["audio"] is NSNull)
    }

    private static func testResourceAttendeeFlagFromEmail() {
        let attendees = [
            CalendarEventAttendee(displayName: "Alex", email: "alex@example.com", responseStatus: "accepted"),
            CalendarEventAttendee(displayName: "Room A", email: "c_x@resource.calendar.google.com", responseStatus: "accepted"),
            // The resource domain appears in the local part / a different domain — must NOT be flagged.
            CalendarEventAttendee(displayName: "Spoof", email: "user.resource.calendar.google.com@example.com", responseStatus: "accepted"),
        ]
        let payload = note(makeItem(calendarMatch: sampleCalendar(attendees: attendees)))
        let cal = payload["calendar"] as! [String: Any]
        let list = cal["attendees"] as! [[String: Any]]
        precondition(list[0]["is_resource"] as? Bool == false)
        precondition(list[0]["email"] as? String == "alex@example.com")
        precondition(list[1]["is_resource"] as? Bool == true)
        precondition(list[2]["is_resource"] as? Bool == false)
    }

    private static func testTimestampsUseProvidedFormatter() {
        let payload = note(makeItem(recordingStartedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        let ts = payload["timestamps"] as! [String: Any]
        // 1_700_000_000 == 2023-11-14T22:13:20Z == 2023-11-15 07:13:20 +09:00
        precondition((ts["recording_started_at"] as? String)?.hasSuffix("+09:00") == true)
        precondition((ts["transcript_created_at"] as? String) != nil)
        precondition(ts["recording_ended_at"] is NSNull)
    }

    // MARK: - list_notes

    /// Three notes a day apart: 2023-11-13, -14 and -15 at 07:13 in Seoul.
    private static func threeNotes() -> [PipelineHistoryItem] {
        let day: TimeInterval = 86_400
        return [
            makeItem(
                id: "00000000-0000-0000-0000-000000000001",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 - 2 * day),
                transcript: "Budget review with finance"
            ),
            makeItem(
                id: "00000000-0000-0000-0000-000000000003",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + 600),
                transcript: "Line one\nline two of a later note",
                calendarMatch: sampleCalendar(title: "Design Crit"),
                recordingStartedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            makeItem(
                id: "00000000-0000-0000-0000-000000000002",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 - day),
                transcript: "Café planning"
            ),
        ]
    }

    private static func list(
        _ arguments: [String: Any],
        items: [PipelineHistoryItem] = threeNotes(),
        summaries: [String: String] = [:]
    ) throws -> (notes: [[String: Any]], hasMore: Bool) {
        let filter = try NotePayload.ListFilter(arguments: arguments, timeZone: seoul)
        let payload = NotePayload.list(
            items,
            filter: filter,
            title: { "Title \($0.id.uuidString.suffix(1))" },
            summary: { summaries[$0.id.uuidString] },
            formatter: seoulFormatter()
        )
        return (payload["notes"] as! [[String: Any]], payload["has_more"] as! Bool)
    }

    private static func expectIDs(_ arguments: [String: Any], _ expected: [String]) throws {
        let found = ids(try list(arguments).notes)
        precondition(found == expected, "\(arguments): expected \(expected), got \(found)")
    }

    private static func ids(_ notes: [[String: Any]]) -> [String] {
        notes.map { String(($0["id"] as! String).suffix(1)) }
    }

    private static func testListIsNewestFirstWithTitleAndPreview() throws {
        let result = try list([:], summaries: ["00000000-0000-0000-0000-000000000003": "Summary"])
        precondition(ids(result.notes) == ["3", "2", "1"])
        precondition(result.hasMore == false)
        let newest = result.notes[0]
        precondition(newest["title"] as? String == "Title 3")
        precondition(newest["recorded_at"] as? String == "2023-11-15T07:13:20+09:00")
        precondition(newest["calendar_event"] as? String == "Design Crit")
        precondition(newest["has_summary"] as? Bool == true)
        precondition(newest["preview"] as? String == "Line one line two of a later note")
        precondition(result.notes[1]["calendar_event"] is NSNull)
        precondition(result.notes[1]["has_summary"] as? Bool == false)
    }

    private static func testListLimitReportsMore() throws {
        let limited = try list(["limit": 2])
        precondition(ids(limited.notes) == ["3", "2"])
        precondition(limited.hasMore == true)
        let exact = try list(["limit": 3])
        precondition(exact.hasMore == false)
        try expectIDs(["limit": 0], ["3"])
    }

    private static func testListQueryMatchesTitleTranscriptAndSummary() throws {
        try expectIDs(["query": "BUDGET"], ["1"])
        try expectIDs(["query": "cafe"], ["2"])
        try expectIDs(["query": "design crit"], ["3"])
        try expectIDs(["query": "Title 2"], ["2"])
        let bySummary = try list(
            ["query": "roadmap"],
            summaries: ["00000000-0000-0000-0000-000000000001": "Agreed the roadmap"]
        )
        precondition(ids(bySummary.notes) == ["1"])
        try expectIDs(["query": "nothing like this"], [])
        try expectIDs(["query": "   "], ["3", "2", "1"])
    }

    private static func testListDateRangeUsesWholeLocalDays() throws {
        try expectIDs(["since": "2023-11-14"], ["3", "2"])
        try expectIDs(["until": "2023-11-14"], ["2", "1"])
        try expectIDs(["since": "2023-11-14", "until": "2023-11-14"], ["2"])
    }

    private static func testListAcceptsDateTimes() throws {
        try expectIDs(["since": "2023-11-14T20:00:00Z"], ["3"])
        try expectIDs(["until": "2023-11-14T05:13:20.000Z"], ["2", "1"])
    }

    private static func testListRejectsBadDates() {
        for arguments: [String: Any] in [["since": "yesterday"], ["until": "2023-13-40"], ["since": 5]] {
            do {
                _ = try NotePayload.ListFilter(arguments: arguments, timeZone: seoul)
                preconditionFailure("Expected \(arguments) to be rejected")
            } catch let error as NotePayload.ListFilterError {
                precondition(error.message.hasPrefix("Error: '"))
            } catch {
                preconditionFailure("Unexpected error \(error)")
            }
        }
    }
}
