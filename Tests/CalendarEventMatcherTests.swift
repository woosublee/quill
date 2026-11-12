import Foundation
import QuillNoteCore

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
        testSuggestionShowsOnTitledNote()
        testSuggestionHidesWhenTitleMatchesOrDismissed()
        testSuggestionNeedsSuggestedState()
        testLookupNeedsNoEventAndRecordingTime()
        testRecentCandidatesStayInWindow()
        testOpenCheckWaitsFiveMinutes()
        testOpenCheckReplacesOnlyDeletedEvents()
        testLookupRangeSpansRecordings()
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

    // #832: a note with its own title still gets the suggestion.
    private static func testSuggestionShowsOnTitledNote() {
        let match = calendarMatch(title: " Weekly sync ", titleState: .suggested)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let applied = CalendarTitleSuggestion.appliedTitle(suggestedTitle: "Weekly sync", date: date)
        let untitled = CalendarTitleSuggestion.suggestion(calendarMatch: match, customTitle: nil, date: date, isDismissed: false)
        assert(untitled?.suggested == "Weekly sync")
        assert(untitled?.applied == applied)
        let titled = CalendarTitleSuggestion.suggestion(calendarMatch: match, customTitle: "Planning", date: date, isDismissed: false)
        assert(titled?.suggested == "Weekly sync")
    }

    private static func testSuggestionHidesWhenTitleMatchesOrDismissed() {
        let match = calendarMatch(title: "Weekly sync", titleState: .suggested)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let applied = CalendarTitleSuggestion.appliedTitle(suggestedTitle: "Weekly sync", date: date)
        assert(CalendarTitleSuggestion.suggestion(calendarMatch: match, customTitle: applied, date: date, isDismissed: false) == nil)
        assert(CalendarTitleSuggestion.suggestion(calendarMatch: match, customTitle: " Weekly sync ", date: date, isDismissed: false) == nil)
        assert(CalendarTitleSuggestion.suggestion(calendarMatch: match, customTitle: nil, date: date, isDismissed: true) == nil)
    }

    private static func testSuggestionNeedsSuggestedState() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        assert(CalendarTitleSuggestion.suggestion(calendarMatch: nil, customTitle: nil, date: date, isDismissed: false) == nil)
        let applied = calendarMatch(title: "Weekly sync", titleState: .applied)
        assert(CalendarTitleSuggestion.suggestion(calendarMatch: applied, customTitle: nil, date: date, isDismissed: false) == nil)
        let blank = calendarMatch(title: "  ", titleState: .suggested)
        assert(CalendarTitleSuggestion.suggestion(calendarMatch: blank, customTitle: nil, date: date, isDismissed: false) == nil)
    }

    private static func testLookupNeedsNoEventAndRecordingTime() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 2_000)
        assert(CalendarMatchLookup.needsLookup(calendarMatch: nil, recordingStartedAt: start, recordingEndedAt: end))
        assert(!CalendarMatchLookup.needsLookup(
            calendarMatch: calendarMatch(title: "Found", titleState: .suggested),
            recordingStartedAt: start, recordingEndedAt: end
        ))
        assert(!CalendarMatchLookup.needsLookup(calendarMatch: nil, recordingStartedAt: nil, recordingEndedAt: end))
        assert(!CalendarMatchLookup.needsLookup(calendarMatch: nil, recordingStartedAt: end, recordingEndedAt: start))
    }

    private static func testRecentCandidatesStayInWindow() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let recent = now.addingTimeInterval(-3 * 24 * 60 * 60)
        let old = now.addingTimeInterval(-15 * 24 * 60 * 60)
        assert(CalendarMatchLookup.isRecentCandidate(
            calendarMatch: nil, recordingStartedAt: recent, recordingEndedAt: recent.addingTimeInterval(600), now: now
        ))
        assert(!CalendarMatchLookup.isRecentCandidate(
            calendarMatch: nil, recordingStartedAt: old, recordingEndedAt: old.addingTimeInterval(600), now: now
        ))
        assert(CalendarMatchLookup.recentRange(now: now).start == now.addingTimeInterval(-CalendarMatchLookup.recentWindow))
    }

    private static func testOpenCheckWaitsFiveMinutes() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let start = now.addingTimeInterval(-90 * 24 * 60 * 60)
        let end = start.addingTimeInterval(600)
        assert(CalendarMatchLookup.shouldCheckOnOpen(recordingStartedAt: start, recordingEndedAt: end, lastCheckedAt: nil, now: now))
        assert(!CalendarMatchLookup.shouldCheckOnOpen(
            recordingStartedAt: start, recordingEndedAt: end, lastCheckedAt: now.addingTimeInterval(-60), now: now
        ))
        assert(CalendarMatchLookup.shouldCheckOnOpen(
            recordingStartedAt: start, recordingEndedAt: end,
            lastCheckedAt: now.addingTimeInterval(-CalendarMatchLookup.noteOpenInterval), now: now
        ))
        assert(!CalendarMatchLookup.shouldCheckOnOpen(recordingStartedAt: nil, recordingEndedAt: end, lastCheckedAt: nil, now: now))
    }

    // #832: a deleted event gives way to the event now at that time, but
    // only when its calendar was read in full.
    private static func testOpenCheckReplacesOnlyDeletedEvents() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 2_000)
        let saved = calendarMatch(title: "Old", titleState: .applied)
        let replacement = event(id: "new", title: "New", start: 1_000, end: 2_000)
        let stillThere = event(id: "event", title: "Old", start: 1_000, end: 2_000)
        func check(_ saved: CalendarEventMatch?, _ events: [CalendarEvent], read: Set<String> = ["calendar"]) -> String? {
            CalendarMatchLookup.eventToSuggest(
                saved: saved, events: events, readCalendarIDs: read,
                recordingStartedAt: start, recordingEndedAt: end
            )?.id
        }
        assert(check(nil, [replacement]) == "new", "a note with no event gets one")
        assert(check(saved, [stillThere, replacement]) == nil, "an event still there stays")
        assert(check(saved, [replacement]) == "new", "a deleted event gives way")
        assert(check(saved, []) == nil, "with nothing else, the saved event stays")
        assert(check(saved, [replacement], read: []) == nil, "an unread calendar says nothing")
        let mergedCopy = CalendarEvent(
            id: "google-copy", calendarID: "google", title: "Old",
            start: saved.start, end: saved.end, isAllDay: false, attendees: []
        )
        assert(check(saved, [mergedCopy, replacement]) == nil, "the same meeting in another calendar is still there")
        let chosen = CalendarEventMatch(
            calendarID: "calendar", eventID: "event", title: "Old",
            start: saved.start, end: saved.end, matchSource: .importSelection, titleState: .suggested
        )
        assert(check(chosen, [replacement]) == nil, "an event the person chose stays")
    }

    private static func testLookupRangeSpansRecordings() {
        let a = (start: Date(timeIntervalSince1970: 5_000), end: Date(timeIntervalSince1970: 6_000))
        let b = (start: Date(timeIntervalSince1970: 1_000), end: Date(timeIntervalSince1970: 2_000))
        let range = CalendarMatchLookup.lookupRange(for: [a, b])
        assert(range?.start == b.start)
        assert(range?.end == a.end)
        assert(CalendarMatchLookup.lookupRange(for: []) == nil, "nothing to match reads nothing")
    }

    private static func calendarMatch(title: String, titleState: CalendarTitleState) -> CalendarEventMatch {
        CalendarEventMatch(
            calendarID: "calendar",
            eventID: "event",
            title: title,
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000),
            matchSource: .overlapSuggestion,
            titleState: titleState
        )
    }

    private static func event(id: String, calendarID: String = "calendar", title: String, start: TimeInterval, end: TimeInterval, isAllDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, calendarID: calendarID, title: title, start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end), isAllDay: isAllDay, attendees: [])
    }
}
