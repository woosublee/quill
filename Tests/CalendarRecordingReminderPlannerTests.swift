import Foundation
import QuillNoteCore

/// The calendar rules shared with the iPhone (QuillNoteCore, #697): the
/// reminder planner, the Apple event id, and the Apple attendee mapping.
@main
struct CalendarRecordingReminderPlannerTests {
    static func main() {
        testSharedReminderRulesKeepTheirSavedShapes()
        precondition(
            CalendarEvent.appleEventID(itemIdentifier: "ABC", start: Date(timeIntervalSince1970: 1_800_000_000.7))
                == "ABC@1800000000",
            "the Apple event id keeps the whole seconds of the start"
        )
        print("CalendarRecordingReminderPlannerTests passed")
    }

    /// The reminder rules moved to QuillNoteCore for the iPhone too (#697).
    /// Pending notifications from an older build use these identifiers, so
    /// their shape can't change.
    private static func testSharedReminderRulesKeepTheirSavedShapes() {
        let meeting = CalendarEvent(
            id: "evt", calendarID: "primary", title: "Weekly sync",
            start: Date(timeIntervalSince1970: 10_000), end: Date(timeIntervalSince1970: 13_600),
            isAllDay: false, attendees: []
        )
        precondition(CalendarRecordingReminderPlanner.groupIdentifier(for: meeting) == "primary:evt:10000")
        precondition(
            CalendarRecordingReminderPlanner.identifier(for: meeting, leadMinutes: 12)
                == "calendar-recording-reminder:primary:evt:10000:10"
        )
        precondition(CalendarRecordingReminderPlanner.normalizedLeadMinutes([]) == [10])
        precondition(CalendarRecordingReminderPlanner.normalizedLeadMinutes([61, 4, 5]) == [5, 60])
        let plan = CalendarRecordingReminderPlanner.plan(
            for: [meeting],
            leadMinutes: [5, 60],
            now: Date(timeIntervalSince1970: 9_000)
        )
        precondition(plan.scheduled.map(\.fireDate) == [Date(timeIntervalSince1970: 9_700)])
        precondition(plan.immediate.map(\.fireDate) == [Date(timeIntervalSince1970: 9_000)])
        let late = CalendarRecordingReminderPlanner.plan(
            for: [meeting],
            leadMinutes: [5],
            now: Date(timeIntervalSince1970: 10_000 + 301)
        )
        precondition(late.scheduled.isEmpty && late.immediate.isEmpty, "past the 5 minute grace period")

        let declined = CalendarEvent(
            id: "d", calendarID: "primary", title: "Declined",
            start: Date(timeIntervalSince1970: 10_000), end: Date(timeIntervalSince1970: 11_000), isAllDay: false,
            attendees: [AppleParticipantData(
                name: "  Me ", url: URL(string: "mailto:me@example.com"), response: .declined,
                isOptional: false, isCurrentUser: true
            ).attendee()]
        )
        precondition(declined.attendees.first?.displayName == "Me")
        precondition(declined.attendees.first?.email == "me@example.com")
        precondition(declined.attendees.first?.responseStatus == "declined")
        precondition(!CalendarRecordingReminderPlanner.isReminderEligible(declined))
    }

}
