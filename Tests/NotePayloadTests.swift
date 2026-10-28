import Foundation
import QuillNoteCore

@main
struct NotePayloadTests {
    static func main() throws {
        testNoteCarriesDisplayTitleAndSummary()
        testNoteSummaryIsNullWhenMissing()
        testTitleSourceFollowsDisplayTitleOrder()
        testCalendarIsNullWhenNoMatch()
        testAudioCarriesWhereItIs()
        testAudioIsNullWithoutAudio()
        testResourceAttendeeFlagFromEmail()
        testTimestampsUseProvidedFormatter()
        try testListIsNewestFirstWithTitleAndPreview()
        try testListLimitReportsMore()
        try testListOffsetPagesThroughMatches()
        try testListKeepsGivenOrder()
        try testListQueryUsesNoteSearch()
        try testListDateRangeUsesWholeLocalDays()
        try testListAcceptsDateTimes()
        try testListDayWithSkippedMidnight()
        try testListLocalTimeInClockChangeGap()
        testListRejectsNonASCIIDigits()
        testListRejectsBadArguments()
        try testListAcceptsNullAndWholeDoubles()
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
        audioFileName: String? = nil,
        customTitle: String? = nil
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
            customTitle: customTitle
        )
    }

    private static func sampleCalendar(
        title: String = "Weekly Sync",
        attendees: [CalendarEventAttendee] = [],
        titleState: CalendarTitleState = .applied
    ) -> CalendarEventMatch {
        CalendarEventMatch(
            calendarID: "cal", eventID: "evt", title: title,
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_003_600),
            attendees: attendees,
            matchSource: .overlapSuggestion, titleState: titleState
        )
    }

    private static func note(
        _ item: PipelineHistoryItem,
        title: String = "Note title",
        summary: NotePayload.Summary? = nil,
        audio: NotePayload.Audio? = nil
    ) -> [String: Any] {
        NotePayload.make(
            item: item,
            title: title,
            titleSource: NoteTitleResolver.displayTitleSource(for: item).rawValue,
            summary: summary,
            audio: audio,
            formatter: seoulFormatter()
        )
    }

    private static func testNoteCarriesDisplayTitleAndSummary() {
        let payload = note(
            makeItem(calendarMatch: sampleCalendar()),
            title: "2023-11-15 Weekly Sync",
            summary: NotePayload.Summary(markdown: "## Overview\n\nPlanned the launch.", isStale: true)
        )
        precondition(payload["title"] as? String == "2023-11-15 Weekly Sync")
        let summary = payload["summary"] as! [String: Any]
        precondition(summary["markdown"] as? String == "## Overview\n\nPlanned the launch.")
        precondition(summary["is_stale"] as? Bool == true)
        precondition(payload["transcript"] as? String == "clean text")
        precondition(payload["raw_transcript"] as? String == "raw text")
        precondition(payload["context"] as? String == "ctx")
    }

    /// title_source names where NoteTitleResolver.displayTitle took the title.
    private static func testTitleSourceFollowsDisplayTitleOrder() {
        let custom = makeItem(calendarMatch: sampleCalendar(), customTitle: " Mine ")
        precondition(NoteTitleResolver.displayTitle(for: custom) == "Mine")
        let calendar = makeItem(calendarMatch: sampleCalendar(), customTitle: "  ")
        precondition(NoteTitleResolver.displayTitle(for: calendar) == calendar.calendarMatch?.appliedTitle)
        let suggested = sampleCalendar(titleState: .suggested)
        precondition(note(makeItem(calendarMatch: sampleCalendar(), customTitle: "Mine"))["title_source"] as? String == "custom")
        precondition(note(makeItem(calendarMatch: sampleCalendar(), customTitle: "  "))["title_source"] as? String == "calendar")
        precondition(note(makeItem(calendarMatch: suggested))["title_source"] as? String == "automatic")
        precondition(note(makeItem())["title_source"] as? String == "automatic")
    }

    private static func testNoteSummaryIsNullWhenMissing() {
        precondition(note(makeItem())["summary"] is NSNull)
    }

    private static func testCalendarIsNullWhenNoMatch() {
        precondition(note(makeItem())["calendar"] is NSNull)
    }

    private static func testAudioCarriesWhereItIs() {
        let payload = note(
            makeItem(audioFileName: "abc.wav"),
            audio: NotePayload.Audio(filename: "abc.wav", path: "/audio/abc.wav", existsHere: false, inICloud: true)
        )
        let audio = payload["audio"] as! [String: Any]
        precondition(audio["filename"] as? String == "abc.wav")
        precondition(audio["path"] as? String == "/audio/abc.wav")
        precondition(audio["exists"] as? Bool == false)
        precondition(audio["in_icloud"] as? Bool == true)
    }

    private static func testAudioIsNullWithoutAudio() {
        precondition(note(makeItem())["audio"] is NSNull)
    }

    private static func testResourceAttendeeFlagFromEmail() {
        let attendees = [
            CalendarEventAttendee(displayName: "Alex", email: "alex@example.com", responseStatus: "accepted"),
            CalendarEventAttendee(displayName: "Room A", email: "c_x@resource.calendar.google.com", responseStatus: "accepted"),
            // The resource domain appears in the local part / a different domain — must NOT be flagged.
            CalendarEventAttendee(displayName: "Spoof", email: "user.resource.calendar.google.com@example.com", responseStatus: "accepted"),
            CalendarEventAttendee(displayName: "Look-alike", email: "bob@fakeresource.calendar.google.com", responseStatus: "accepted"),
        ]
        let payload = note(makeItem(calendarMatch: sampleCalendar(attendees: attendees)))
        let cal = payload["calendar"] as! [String: Any]
        let list = cal["attendees"] as! [[String: Any]]
        precondition(list[0]["is_resource"] as? Bool == false)
        precondition(list[0]["email"] as? String == "alex@example.com")
        precondition(list[1]["is_resource"] as? Bool == true)
        precondition(list[2]["is_resource"] as? Bool == false)
        precondition(list[3]["is_resource"] as? Bool == false)
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
        let notes = unorderedNotes()
        return [notes[1], notes[2], notes[0]]
    }

    private static func unorderedNotes() -> [PipelineHistoryItem] {
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
        withSummary: Set<String> = []
    ) throws -> (notes: [[String: Any]], hasMore: Bool) {
        let filter = try NotePayload.ListFilter(arguments: arguments, timeZone: seoul)
        let matcher = NoteSearchMatcher()
        let payload = NotePayload.list(
            items,
            filter: filter,
            matches: { matcher.matches($0, query: $1) },
            title: { "Title \($0.id.uuidString.suffix(1))" },
            hasSummary: { withSummary.contains($0.id.uuidString) },
            formatter: seoulFormatter()
        )
        return (payload["notes"] as! [[String: Any]], payload["has_more"] as! Bool)
    }

    private static func expectIDs(
        _ arguments: [String: Any],
        _ expected: [String],
        items: [PipelineHistoryItem] = threeNotes()
    ) throws {
        let found = ids(try list(arguments, items: items).notes)
        precondition(found == expected, "\(arguments): expected \(expected), got \(found)")
    }

    private static func ids(_ notes: [[String: Any]]) -> [String] {
        notes.map { String(($0["id"] as! String).suffix(1)) }
    }

    private static func testListIsNewestFirstWithTitleAndPreview() throws {
        let result = try list([:], withSummary: ["00000000-0000-0000-0000-000000000003"])
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

    private static func testListOffsetPagesThroughMatches() throws {
        let second = try list(["limit": 1, "offset": 1])
        precondition(ids(second.notes) == ["2"] && second.hasMore)
        let last = try list(["limit": 1, "offset": 2])
        precondition(ids(last.notes) == ["1"] && !last.hasMore)
        try expectIDs(["offset": 5], [])
        try expectIDs(["offset": -3], ["3", "2", "1"])
        try expectIDs(["query": "budget", "offset": 1], [])
    }

    /// The list keeps the Note Browser's order rather than re-sorting.
    private static func testListKeepsGivenOrder() throws {
        try expectIDs([:], ["1", "3", "2"], items: unorderedNotes())
    }

    /// The query uses the Note Browser's search: the shown transcript and
    /// the calendar event title match, the hidden raw transcript doesn't.
    private static func testListQueryUsesNoteSearch() throws {
        try expectIDs(["query": "BUDGET"], ["1"])
        try expectIDs(["query": "cafe"], ["2"])
        try expectIDs(["query": "design crit"], ["3"])
        try expectIDs(["query": "raw text"], [])
        try expectIDs(["query": "nothing like this"], [])
        try expectIDs(["query": "   "], ["3", "2", "1"])
    }

    private static func testListDateRangeUsesWholeLocalDays() throws {
        try expectIDs(["since": "2023-11-14"], ["3", "2"])
        try expectIDs(["until": "2023-11-14"], ["2", "1"])
        try expectIDs(["since": "2023-11-14", "until": "2023-11-14"], ["2"])
        // The whole day: a note in its last instant is included, the next
        // day's first instant is not.
        let lastInstant = makeItem(
            id: "00000000-0000-0000-0000-000000000005",
            timestamp: Date(timeIntervalSince1970: 1_699_973_999.9995)  // 2023-11-14 23:59:59.9995 Seoul
        )
        let nextDay = makeItem(
            id: "00000000-0000-0000-0000-000000000006",
            timestamp: Date(timeIntervalSince1970: 1_699_974_000)  // 2023-11-15 00:00 Seoul
        )
        try expectIDs(["until": "2023-11-14"], ["5"], items: [nextDay, lastInstant])
    }

    private static func testListAcceptsDateTimes() throws {
        try expectIDs(["since": "2023-11-14T20:00:00Z"], ["3"])
        try expectIDs(["until": "2023-11-14T05:13:20.000Z"], ["2", "1"])
        // Without an offset a date-time is local (Seoul here).
        try expectIDs(["since": "2023-11-15T07:00:00"], ["3"])
        try expectIDs(["until": "2023-11-14T08:00"], ["2", "1"])
        // An offset without seconds.
        try expectIDs(["since": "2023-11-15T07:00+09:00"], ["3"])
        try expectIDs(["since": "2023-11-14T22:00Z"], ["3"])
    }

    /// Where a clock change skips midnight, the day still parses and starts
    /// at the first moment that exists.
    private static func testListDayWithSkippedMidnight() throws {
        let saoPaulo = TimeZone(identifier: "America/Sao_Paulo")!
        let filter = try NotePayload.ListFilter(arguments: ["since": "2018-11-04", "until": "2018-11-04"], timeZone: saoPaulo)
        let iso = ISO8601DateFormatter()
        iso.timeZone = saoPaulo
        precondition(iso.string(from: filter.since!) == "2018-11-04T01:00:00-02:00")
        precondition(filter.until! > filter.since!)
    }

    private static func testListAcceptsNullAndWholeDoubles() throws {
        try expectIDs(["limit": NSNull(), "offset": NSNull(), "since": NSNull()], ["3", "2", "1"])
        try expectIDs(["limit": NSNumber(value: 1.0)], ["3"])  // JSON numbers arrive as NSNumber
    }

    /// 02:30 doesn't exist on a US spring-forward day; it still parses.
    private static func testListLocalTimeInClockChangeGap() throws {
        let newYork = TimeZone(identifier: "America/New_York")!
        let filter = try NotePayload.ListFilter(arguments: ["since": "2026-03-08T02:30:00"], timeZone: newYork)
        let iso = ISO8601DateFormatter()
        iso.timeZone = newYork
        precondition(iso.string(from: filter.since!).hasPrefix("2026-03-08T03:"))
        let withFraction = try NotePayload.ListFilter(arguments: ["since": "2026-03-09T09:00:00.250"], timeZone: newYork)
        precondition(abs(withFraction.since!.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) - 0.25) < 0.001)
    }

    /// Full-width digits are rejected, not read (they used to crash).
    private static func testListRejectsNonASCIIDigits() {
        for value in ["２０２６-１０-１３", "２０２６-１０-１３T09:00", "٢٠٢٦-١٠-١٣"] {
            do {
                _ = try NotePayload.ListFilter(arguments: ["since": value], timeZone: seoul)
                preconditionFailure("Expected \(value) to be rejected")
            } catch {}
        }
    }

    private static func testListRejectsBadArguments() {
        let bad: [[String: Any]] = [
            ["since": "yesterday"], ["until": "2023-13-40"], ["since": "2023-02-30"], ["since": "2023-11-14T24:00"], ["since": 5],
            ["limit": "20"], ["offset": "20"], ["offset": NSNumber(value: 1.5)], ["limit": true],
        ]
        for arguments in bad {
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
