import Foundation

@main
struct CalendarEventMatcherTests {
    static func main() {
        testChoosesLongestPositiveOverlap()
        testExcludesZeroOverlapEvents()
        testExcludesAllDayEvents()
        testTieBreaksByStartClosestToRecordingStart()
        testTieBreaksExactTimingByCalendarAndEventID()
        testExcludesInvalidEventIntervals()
        testInvalidRecordingIntervalReturnsNil()
        testExcludesTitlelessEvents()
        print("CalendarEventMatcherTests passed")
    }

    private static func testChoosesLongestPositiveOverlap() {
        let recordingStart = Date(timeIntervalSince1970: 1_000)
        let recordingEnd = Date(timeIntervalSince1970: 1_600)
        let short = event(id: "short", title: "Short", start: 900, end: 1_100)
        let long = event(id: "long", title: "Long", start: 1_100, end: 1_700)
        let matched = CalendarEventMatcher.bestMatch(recordingStartedAt: recordingStart, recordingEndedAt: recordingEnd, events: [short, long])
        assert(matched?.id == "long")
    }

    private static func testExcludesZeroOverlapEvents() {
        let matched = CalendarEventMatcher.bestMatch(
            recordingStartedAt: Date(timeIntervalSince1970: 1_000),
            recordingEndedAt: Date(timeIntervalSince1970: 1_600),
            events: [event(id: "before", title: "Before", start: 100, end: 999), event(id: "after", title: "After", start: 1_600, end: 1_900)]
        )
        assert(matched == nil)
    }

    private static func testExcludesAllDayEvents() {
        let matched = CalendarEventMatcher.bestMatch(
            recordingStartedAt: Date(timeIntervalSince1970: 1_000),
            recordingEndedAt: Date(timeIntervalSince1970: 1_600),
            events: [event(id: "holiday", title: "Holiday", start: 0, end: 86_400, isAllDay: true), event(id: "meeting", title: "Meeting", start: 1_100, end: 1_500)]
        )
        assert(matched?.id == "meeting")
    }

    private static func testTieBreaksByStartClosestToRecordingStart() {
        let matched = CalendarEventMatcher.bestMatch(
            recordingStartedAt: Date(timeIntervalSince1970: 1_000),
            recordingEndedAt: Date(timeIntervalSince1970: 1_600),
            events: [event(id: "far", title: "Far", start: 700, end: 1_200), event(id: "near", title: "Near", start: 900, end: 1_200)]
        )
        assert(matched?.id == "near")
    }

    private static func testTieBreaksExactTimingByCalendarAndEventID() {
        let recordingStart = Date(timeIntervalSince1970: 1_000)
        let recordingEnd = Date(timeIntervalSince1970: 1_600)
        let laterCalendar = event(id: "event", calendarID: "b-calendar", title: "Meeting", start: 900, end: 1_500)
        let earlierCalendar = event(id: "event", calendarID: "a-calendar", title: "Meeting", start: 900, end: 1_500)
        let calendarMatched = CalendarEventMatcher.bestMatch(recordingStartedAt: recordingStart, recordingEndedAt: recordingEnd, events: [laterCalendar, earlierCalendar])
        assert(calendarMatched?.calendarID == "a-calendar")

        let laterEventID = event(id: "b-event", title: "Meeting", start: 900, end: 1_500)
        let earlierEventID = event(id: "a-event", title: "Meeting", start: 900, end: 1_500)
        let eventMatched = CalendarEventMatcher.bestMatch(recordingStartedAt: recordingStart, recordingEndedAt: recordingEnd, events: [laterEventID, earlierEventID])
        assert(eventMatched?.id == "a-event")
    }

    private static func testExcludesInvalidEventIntervals() {
        let matched = CalendarEventMatcher.bestMatch(
            recordingStartedAt: Date(timeIntervalSince1970: 1_000),
            recordingEndedAt: Date(timeIntervalSince1970: 1_600),
            events: [
                event(id: "zero", title: "Zero", start: 1_100, end: 1_100),
                event(id: "negative", title: "Negative", start: 1_400, end: 1_300),
                event(id: "valid", title: "Valid", start: 1_100, end: 1_500),
            ]
        )
        assert(matched?.id == "valid")
    }

    private static func testInvalidRecordingIntervalReturnsNil() {
        let zeroLengthMatched = CalendarEventMatcher.bestMatch(
            recordingStartedAt: Date(timeIntervalSince1970: 1_000),
            recordingEndedAt: Date(timeIntervalSince1970: 1_000),
            events: [event(id: "meeting", title: "Meeting", start: 900, end: 1_100)]
        )
        assert(zeroLengthMatched == nil)

        let negativeLengthMatched = CalendarEventMatcher.bestMatch(
            recordingStartedAt: Date(timeIntervalSince1970: 1_100),
            recordingEndedAt: Date(timeIntervalSince1970: 1_000),
            events: [event(id: "meeting", title: "Meeting", start: 900, end: 1_200)]
        )
        assert(negativeLengthMatched == nil)

        let missingStartMatched = CalendarEventMatcher.bestMatch(
            recordingStartedAt: nil,
            recordingEndedAt: Date(timeIntervalSince1970: 1_000),
            events: [event(id: "meeting", title: "Meeting", start: 900, end: 1_200)]
        )
        assert(missingStartMatched == nil)

        let missingEndMatched = CalendarEventMatcher.bestMatch(
            recordingStartedAt: Date(timeIntervalSince1970: 1_000),
            recordingEndedAt: nil,
            events: [event(id: "meeting", title: "Meeting", start: 900, end: 1_200)]
        )
        assert(missingEndMatched == nil)
    }

    private static func testExcludesTitlelessEvents() {
        let matched = CalendarEventMatcher.bestMatch(
            recordingStartedAt: Date(timeIntervalSince1970: 1_000),
            recordingEndedAt: Date(timeIntervalSince1970: 1_600),
            events: [event(id: "blank", title: "   ", start: 900, end: 1_700), event(id: "named", title: "Named", start: 1_100, end: 1_500)]
        )
        assert(matched?.id == "named")
    }

    private static func event(id: String, calendarID: String = "calendar", title: String, start: TimeInterval, end: TimeInterval, isAllDay: Bool = false) -> GoogleCalendarEvent {
        GoogleCalendarEvent(id: id, calendarID: calendarID, title: title, start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end), isAllDay: isAllDay, attendees: [])
    }
}
