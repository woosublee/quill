import Foundation

@main
struct CalendarRecordingReminderSchedulerTests {
    static func main() {
        testLeadMinutesAffectFireDate()
        testPastReminderTimeForUpcomingMeetingBecomesImmediate()
        testRecentlyStartedMeetingBecomesImmediate()
        testSkipsMeetingsStartedOutsideGracePeriod()
        testExcludesAllDayTitlelessInvalidAndSelfDeclinedEvents()
        testNotificationIdentifierIsStable()
        testCalendarReminderIdentifierFilteringUsesPrefix()
        testNotificationTitleDescribesRelativeStartTime()
        testNormalizesLeadMinutes()
        testNormalizesRefreshIntervalMinutesToSupportedOptions()
        print("CalendarRecordingReminderSchedulerTests passed")
    }

    private static func testLeadMinutesAffectFireDate() {
        let now = Date(timeIntervalSince1970: 1_000)
        let event = calendarEvent(id: "meeting", start: 1_900, end: 2_200)

        let schedules = CalendarRecordingReminderScheduler.schedules(
            for: [event],
            leadMinutes: 10,
            now: now,
            calendar: .current
        )

        assert(schedules.count == 1)
        assert(schedules[0].fireDate == Date(timeIntervalSince1970: 1_300))
    }

    private static func testPastReminderTimeForUpcomingMeetingBecomesImmediate() {
        let now = Date(timeIntervalSince1970: 1_000)
        let event = calendarEvent(id: "soon", start: 1_100, end: 1_500)

        let plan = CalendarRecordingReminderScheduler.reminderPlan(
            for: [event],
            leadMinutes: 10,
            now: now,
            calendar: .current
        )

        assert(plan.scheduled.isEmpty)
        assert(plan.immediate.map { $0.event.id } == ["soon"])
    }

    private static func testRecentlyStartedMeetingBecomesImmediate() {
        let now = Date(timeIntervalSince1970: 1_000)
        let event = calendarEvent(id: "started", start: 900, end: 1_500)

        let plan = CalendarRecordingReminderScheduler.reminderPlan(
            for: [event],
            leadMinutes: 10,
            now: now,
            calendar: .current
        )

        assert(plan.scheduled.isEmpty)
        assert(plan.immediate.map { $0.event.id } == ["started"])
    }

    private static func testSkipsMeetingsStartedOutsideGracePeriod() {
        let now = Date(timeIntervalSince1970: 1_000)
        let event = calendarEvent(id: "old", start: 600, end: 1_500)

        let plan = CalendarRecordingReminderScheduler.reminderPlan(
            for: [event],
            leadMinutes: 10,
            now: now,
            calendar: .current
        )

        assert(plan.scheduled.isEmpty)
        assert(plan.immediate.isEmpty)
    }

    private static func testExcludesAllDayTitlelessInvalidAndSelfDeclinedEvents() {
        let now = Date(timeIntervalSince1970: 1_000)
        let valid = calendarEvent(id: "valid", start: 2_000, end: 2_500)
        let allDay = calendarEvent(id: "all-day", start: 2_000, end: 2_500, isAllDay: true)
        let titleless = calendarEvent(id: "titleless", title: "  ", start: 2_000, end: 2_500)
        let invalid = calendarEvent(id: "invalid", start: 2_500, end: 2_500)
        let declined = calendarEvent(
            id: "declined",
            start: 2_000,
            end: 2_500,
            attendees: [CalendarEventAttendee(responseStatus: "declined", isSelf: true)]
        )

        let schedules = CalendarRecordingReminderScheduler.schedules(
            for: [allDay, titleless, invalid, declined, valid],
            leadMinutes: 5,
            now: now,
            calendar: .current
        )

        assert(schedules.map { $0.event.id } == ["valid"])
    }

    private static func testNotificationIdentifierIsStable() {
        let event = calendarEvent(calendarID: "calendar", id: "event", start: 2_000, end: 2_500)

        let identifier = CalendarRecordingReminderScheduler.notificationIdentifier(for: event, leadMinutes: 10)

        assert(identifier == "calendar-recording-reminder:calendar:event:2000:10")
    }

    private static func testCalendarReminderIdentifierFilteringUsesPrefix() {
        let identifiers = CalendarRecordingReminderScheduler.calendarReminderIdentifiers(in: [
            "calendar-recording-reminder:calendar:event:2000:10",
            "obsidian-export:note",
            "calendar-recording-reminder",
        ])

        assert(identifiers == ["calendar-recording-reminder:calendar:event:2000:10"])
    }

    private static func testNotificationTitleDescribesRelativeStartTime() {
        let now = Date(timeIntervalSince1970: 1_000)
        let future = CalendarRecordingReminderSchedule(
            identifier: "future",
            fireDate: now,
            event: calendarEvent(id: "future", start: 1_600, end: 1_900),
            delivery: .scheduled
        )
        let soon = CalendarRecordingReminderSchedule(
            identifier: "soon",
            fireDate: now,
            event: calendarEvent(id: "soon", start: 1_030, end: 1_300),
            delivery: .immediate
        )
        let started = CalendarRecordingReminderSchedule(
            identifier: "started",
            fireDate: now,
            event: calendarEvent(id: "started", start: 995, end: 1_300),
            delivery: .immediate
        )

        assert(CalendarRecordingReminderScheduler.notificationTitle(for: future, now: now) == "Meeting starts in 10 minutes")
        assert(CalendarRecordingReminderScheduler.notificationTitle(for: soon, now: now) == "Meeting starts in 1 minute")
        assert(CalendarRecordingReminderScheduler.notificationTitle(for: started, now: now) == "Meeting is starting now")
    }

    private static func testNormalizesLeadMinutes() {
        assert(CalendarRecordingReminderScheduler.normalizedLeadMinutes(-1) == 1)
        assert(CalendarRecordingReminderScheduler.normalizedLeadMinutes(10) == 10)
        assert(CalendarRecordingReminderScheduler.normalizedLeadMinutes(500) == 120)
    }

    private static func testNormalizesRefreshIntervalMinutesToSupportedOptions() {
        assert(CalendarRecordingReminderScheduler.normalizedRefreshIntervalMinutes(1) == 5)
        assert(CalendarRecordingReminderScheduler.normalizedRefreshIntervalMinutes(14) == 15)
        assert(CalendarRecordingReminderScheduler.normalizedRefreshIntervalMinutes(20) == 15)
        assert(CalendarRecordingReminderScheduler.normalizedRefreshIntervalMinutes(50) == 60)
    }

    private static func calendarEvent(
        calendarID: String = "calendar",
        id: String,
        title: String = "Meeting",
        start: TimeInterval,
        end: TimeInterval,
        isAllDay: Bool = false,
        attendees: [CalendarEventAttendee] = []
    ) -> GoogleCalendarEvent {
        GoogleCalendarEvent(
            id: id,
            calendarID: calendarID,
            title: title,
            start: Date(timeIntervalSince1970: start),
            end: Date(timeIntervalSince1970: end),
            isAllDay: isAllDay,
            attendees: attendees
        )
    }
}
