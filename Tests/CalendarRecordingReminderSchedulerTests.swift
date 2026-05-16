import Foundation
import UserNotifications

@main
struct CalendarRecordingReminderSchedulerTests {
    static func main() async {
        testLeadMinutesAffectFireDate()
        testMultipleLeadMinutesCreateMultipleSchedules()
        testPastReminderTimeForUpcomingMeetingBecomesImmediate()
        testRecentlyStartedMeetingBecomesImmediate()
        testMixedImmediateAndScheduledLeadTimesForSameEvent()
        testSkipsMeetingsStartedOutsideGracePeriod()
        testExcludesAllDayTitlelessInvalidAndSelfDeclinedEvents()
        testNotificationIdentifierIsStable()
        testNotificationIdentifierNormalizesUnsupportedLeadMinutes()
        testReminderGroupIdentifierIgnoresLeadMinutes()
        testCalendarReminderIdentifierFilteringUsesPrefix()
        testNotificationTitleDescribesRelativeStartTime()
        testNormalizesLeadMinutes()
        testNormalizesLeadMinuteSelections()
        testNormalizesRefreshIntervalMinutesToSupportedOptions()
        await testRescheduleReturnsSuccessfulNotificationCount()
        await testRescheduleKeepsStalePendingWhenScheduledAddFails()
        await testRescheduleSendsImmediateNotificationForPendingIdentifier()
        await testRescheduleRemovesStalePendingAfterScheduledAddSucceeds()
        await testImmediateReminderUsesInAppPresenterBeforeNotification()
        await testPresenterFailureFallsBackToImmediateNotification()
        await testShownInAppReminderRemovesOnlyMatchingPendingNotification()
        await testAcceptedButNotYetShownReminderKeepsPendingNotificationUntilShown()
        await testImmediateReminderUsesInAppPresenterWhenAlertsAreUnavailable()
        await testScheduledReminderCreatesInAppTimerAndKeepsLocalFallback()
        await testScheduledReminderDelaysLocalFallbackPastInAppFireDate()
        print("CalendarRecordingReminderSchedulerTests passed")
    }

    private static func testLeadMinutesAffectFireDate() {
        let now = Date(timeIntervalSince1970: 1_000)
        let event = calendarEvent(id: "meeting", start: 1_900, end: 2_200)

        let schedules = CalendarRecordingReminderScheduler.schedules(
            for: [event],
            leadMinutes: [10],
            now: now,
            calendar: .current
        )

        assert(schedules.count == 1)
        assert(schedules[0].fireDate == Date(timeIntervalSince1970: 1_300))
    }

    private static func testMultipleLeadMinutesCreateMultipleSchedules() {
        let now = Date(timeIntervalSince1970: 1_000)
        let event = calendarEvent(calendarID: "calendar", id: "meeting", start: 4_600, end: 4_900)

        let schedules = CalendarRecordingReminderScheduler.schedules(
            for: [event],
            leadMinutes: [10, 30, 1],
            now: now,
            calendar: .current
        )

        assert(schedules.map { Int($0.fireDate.timeIntervalSince1970) } == [2_800, 4_000, 4_540])
        assert(schedules.map(\.identifier) == [
            "calendar-recording-reminder:calendar:meeting:4600:30",
            "calendar-recording-reminder:calendar:meeting:4600:10",
            "calendar-recording-reminder:calendar:meeting:4600:1",
        ])
    }

    private static func testPastReminderTimeForUpcomingMeetingBecomesImmediate() {
        let now = Date(timeIntervalSince1970: 1_000)
        let event = calendarEvent(id: "soon", start: 1_100, end: 1_500)

        let plan = CalendarRecordingReminderScheduler.reminderPlan(
            for: [event],
            leadMinutes: [10],
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
            leadMinutes: [10],
            now: now,
            calendar: .current
        )

        assert(plan.scheduled.isEmpty)
        assert(plan.immediate.map { $0.event.id } == ["started"])
    }

    private static func testMixedImmediateAndScheduledLeadTimesForSameEvent() {
        let now = Date(timeIntervalSince1970: 1_000)
        let event = calendarEvent(calendarID: "calendar", id: "soon", start: 1_300, end: 1_700)

        let plan = CalendarRecordingReminderScheduler.reminderPlan(
            for: [event],
            leadMinutes: [10, 1],
            now: now,
            calendar: .current
        )

        assert(plan.immediate.map(\.identifier) == ["calendar-recording-reminder:calendar:soon:1300:10"])
        assert(plan.immediate.map { $0.fireDate } == [now])
        assert(plan.scheduled.map(\.identifier) == ["calendar-recording-reminder:calendar:soon:1300:1"])
        assert(plan.scheduled.map { Int($0.fireDate.timeIntervalSince1970) } == [1_240])
    }

    private static func testSkipsMeetingsStartedOutsideGracePeriod() {
        let now = Date(timeIntervalSince1970: 1_000)
        let event = calendarEvent(id: "old", start: 600, end: 1_500)

        let plan = CalendarRecordingReminderScheduler.reminderPlan(
            for: [event],
            leadMinutes: [10],
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
            leadMinutes: [5],
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

    private static func testNotificationIdentifierNormalizesUnsupportedLeadMinutes() {
        let event = calendarEvent(calendarID: "calendar", id: "event", start: 2_000, end: 2_500)

        let identifier = CalendarRecordingReminderScheduler.notificationIdentifier(for: event, leadMinutes: 14)

        assert(identifier == "calendar-recording-reminder:calendar:event:2000:15")
    }

    private static func testReminderGroupIdentifierIgnoresLeadMinutes() {
        let event = calendarEvent(calendarID: "calendar", id: "event", start: 2_000, end: 2_500)
        let fiveMinuteReminder = CalendarRecordingReminderSchedule(
            identifier: CalendarRecordingReminderScheduler.notificationIdentifier(for: event, leadMinutes: 5),
            fireDate: Date(timeIntervalSince1970: 1_700),
            event: event,
            delivery: .scheduled
        )
        let oneMinuteReminder = CalendarRecordingReminderSchedule(
            identifier: CalendarRecordingReminderScheduler.notificationIdentifier(for: event, leadMinutes: 1),
            fireDate: Date(timeIntervalSince1970: 1_940),
            event: event,
            delivery: .scheduled
        )

        assert(fiveMinuteReminder.reminderGroupIdentifier == oneMinuteReminder.reminderGroupIdentifier)
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

    private static func testNormalizesLeadMinuteSelections() {
        assert(CalendarRecordingReminderScheduler.normalizedLeadMinutes([30, 10, 10, -1, 14, 500]) == [1, 10, 15, 30, 60])
        assert(CalendarRecordingReminderScheduler.normalizedLeadMinutes([]) == [CalendarRecordingReminderScheduler.defaultLeadMinutes])
    }

    private static func testNormalizesRefreshIntervalMinutesToSupportedOptions() {
        assert(CalendarRecordingReminderScheduler.normalizedRefreshIntervalMinutes(1) == 5)
        assert(CalendarRecordingReminderScheduler.normalizedRefreshIntervalMinutes(14) == 15)
        assert(CalendarRecordingReminderScheduler.normalizedRefreshIntervalMinutes(20) == 15)
        assert(CalendarRecordingReminderScheduler.normalizedRefreshIntervalMinutes(50) == 60)
    }

    @MainActor
    private static func testRescheduleReturnsSuccessfulNotificationCount() async {
        let start = Date().addingTimeInterval(3_600).timeIntervalSince1970
        let event = calendarEvent(id: "meeting", start: start, end: start + 1_800)
        let notificationManager = FakeNotificationManager()
        let scheduler = CalendarRecordingReminderScheduler(notificationManager: notificationManager) { _, _ in [event] }

        let count = try! await scheduler.rescheduleNow(leadMinutes: [10])

        assert(count == 1)
        assert(notificationManager.addedIdentifiers == [
            CalendarRecordingReminderScheduler.notificationIdentifier(for: event, leadMinutes: 10)
        ])
    }

    @MainActor
    private static func testRescheduleKeepsStalePendingWhenScheduledAddFails() async {
        let start = Date().addingTimeInterval(3_600).timeIntervalSince1970
        let event = calendarEvent(id: "meeting", start: start, end: start + 1_800)
        let staleIdentifier = CalendarRecordingReminderScheduler.notificationIdentifier(for: event, leadMinutes: 5)
        let notificationManager = FakeNotificationManager(pendingIdentifiers: [staleIdentifier])
        notificationManager.shouldFailAdd = true
        let scheduler = CalendarRecordingReminderScheduler(notificationManager: notificationManager) { _, _ in [event] }

        let count = try! await scheduler.rescheduleNow(leadMinutes: [10])

        assert(count == 0)
        assert(notificationManager.removedIdentifiers.isEmpty)
    }

    @MainActor
    private static func testRescheduleSendsImmediateNotificationForPendingIdentifier() async {
        let start = Date().addingTimeInterval(300).timeIntervalSince1970
        let event = calendarEvent(id: "meeting", start: start, end: start + 1_800)
        let identifier = CalendarRecordingReminderScheduler.notificationIdentifier(for: event, leadMinutes: 10)
        let notificationManager = FakeNotificationManager(pendingIdentifiers: [identifier])
        let scheduler = CalendarRecordingReminderScheduler(notificationManager: notificationManager) { _, _ in [event] }

        let count = try! await scheduler.rescheduleNow(leadMinutes: [10])

        assert(count == 1)
        assert(notificationManager.addedIdentifiers == [identifier])
        assert(notificationManager.removedIdentifiers == [identifier])
    }

    @MainActor
    private static func testRescheduleRemovesStalePendingAfterScheduledAddSucceeds() async {
        let start = Date().addingTimeInterval(3_600).timeIntervalSince1970
        let event = calendarEvent(id: "meeting", start: start, end: start + 1_800)
        let staleIdentifier = CalendarRecordingReminderScheduler.notificationIdentifier(for: event, leadMinutes: 5)
        let notificationManager = FakeNotificationManager(pendingIdentifiers: [staleIdentifier])
        let scheduler = CalendarRecordingReminderScheduler(notificationManager: notificationManager) { _, _ in [event] }

        let count = try! await scheduler.rescheduleNow(leadMinutes: [10])

        assert(count == 1)
        assert(notificationManager.removedIdentifiers == [staleIdentifier])
    }

    @MainActor
    private static func testImmediateReminderUsesInAppPresenterBeforeNotification() async {
        let start = Date().addingTimeInterval(300).timeIntervalSince1970
        let event = calendarEvent(id: "meeting", start: start, end: start + 1_800)
        let identifier = CalendarRecordingReminderScheduler.notificationIdentifier(for: event, leadMinutes: 10)
        let notificationManager = FakeNotificationManager(pendingIdentifiers: [identifier])
        let presenter = FakeInAppPresenter()
        let scheduler = CalendarRecordingReminderScheduler(
            notificationManager: notificationManager,
            inAppPresenter: presenter
        ) { _, _ in [event] }

        let count = try! await scheduler.rescheduleNow(leadMinutes: [10])

        assert(count == 1)
        assert(presenter.presentedIdentifiers == [identifier])
        assert(notificationManager.addedIdentifiers.isEmpty)
        assert(notificationManager.removedIdentifiers == [identifier])
    }

    @MainActor
    private static func testPresenterFailureFallsBackToImmediateNotification() async {
        let start = Date().addingTimeInterval(300).timeIntervalSince1970
        let event = calendarEvent(id: "meeting", start: start, end: start + 1_800)
        let identifier = CalendarRecordingReminderScheduler.notificationIdentifier(for: event, leadMinutes: 10)
        let notificationManager = FakeNotificationManager(pendingIdentifiers: [identifier])
        let presenter = FakeInAppPresenter()
        presenter.shouldPresent = false
        let scheduler = CalendarRecordingReminderScheduler(
            notificationManager: notificationManager,
            inAppPresenter: presenter
        ) { _, _ in [event] }

        let count = try! await scheduler.rescheduleNow(leadMinutes: [10])

        assert(count == 1)
        assert(presenter.presentedIdentifiers == [identifier])
        assert(notificationManager.addedIdentifiers == [identifier])
        assert(notificationManager.removedIdentifiers == [identifier])
    }

    @MainActor
    private static func testShownInAppReminderRemovesOnlyMatchingPendingNotification() async {
        let immediateStart = Date().addingTimeInterval(300).timeIntervalSince1970
        let scheduledStart = Date().addingTimeInterval(3_600).timeIntervalSince1970
        let immediateEvent = calendarEvent(id: "meeting", start: immediateStart, end: immediateStart + 1_800)
        let scheduledEvent = calendarEvent(id: "later", start: scheduledStart, end: scheduledStart + 1_800)
        let matchingIdentifier = CalendarRecordingReminderScheduler.notificationIdentifier(for: immediateEvent, leadMinutes: 10)
        let scheduledIdentifier = CalendarRecordingReminderScheduler.notificationIdentifier(for: scheduledEvent, leadMinutes: 10)
        let notificationManager = FakeNotificationManager(pendingIdentifiers: [matchingIdentifier, scheduledIdentifier])
        let presenter = FakeInAppPresenter()
        let scheduler = CalendarRecordingReminderScheduler(
            notificationManager: notificationManager,
            inAppPresenter: presenter
        ) { _, _ in [immediateEvent, scheduledEvent] }

        let count = try! await scheduler.rescheduleNow(leadMinutes: [10])

        assert(count == 2)
        assert(notificationManager.removedIdentifiers == [matchingIdentifier])
    }

    @MainActor
    private static func testAcceptedButNotYetShownReminderKeepsPendingNotificationUntilShown() async {
        let start = Date().addingTimeInterval(300).timeIntervalSince1970
        let event = calendarEvent(id: "meeting", start: start, end: start + 1_800)
        let identifier = CalendarRecordingReminderScheduler.notificationIdentifier(for: event, leadMinutes: 10)
        let notificationManager = FakeNotificationManager(pendingIdentifiers: [identifier])
        let presenter = FakeInAppPresenter()
        presenter.shouldCallPresentedHandlerImmediately = false
        let scheduler = CalendarRecordingReminderScheduler(
            notificationManager: notificationManager,
            inAppPresenter: presenter
        ) { _, _ in [event] }

        let count = try! await scheduler.rescheduleNow(leadMinutes: [10])

        assert(count == 1)
        assert(notificationManager.removedIdentifiers.isEmpty)
        presenter.markPresented(identifier: identifier)
        assert(notificationManager.removedIdentifiers == [identifier])
    }

    @MainActor
    private static func testImmediateReminderUsesInAppPresenterWhenAlertsAreUnavailable() async {
        let start = Date().addingTimeInterval(300).timeIntervalSince1970
        let event = calendarEvent(id: "meeting", start: start, end: start + 1_800)
        let identifier = CalendarRecordingReminderScheduler.notificationIdentifier(for: event, leadMinutes: 10)
        let notificationManager = FakeNotificationManager(pendingIdentifiers: [identifier])
        notificationManager.canShowAlertsResult = false
        let presenter = FakeInAppPresenter()
        let scheduler = CalendarRecordingReminderScheduler(
            notificationManager: notificationManager,
            inAppPresenter: presenter
        ) { _, _ in [event] }

        let count = try! await scheduler.rescheduleNow(leadMinutes: [10])

        assert(count == 1)
        assert(presenter.presentedIdentifiers == [identifier])
        assert(notificationManager.addedIdentifiers.isEmpty)
        assert(notificationManager.removedIdentifiers == [identifier])
    }

    @MainActor
    private static func testScheduledReminderCreatesInAppTimerAndKeepsLocalFallback() async {
        let start = Date().addingTimeInterval(3_600).timeIntervalSince1970
        let event = calendarEvent(id: "meeting", start: start, end: start + 1_800)
        let identifier = CalendarRecordingReminderScheduler.notificationIdentifier(for: event, leadMinutes: 10)
        let notificationManager = FakeNotificationManager()
        let presenter = FakeInAppPresenter()
        let scheduler = CalendarRecordingReminderScheduler(
            notificationManager: notificationManager,
            inAppPresenter: presenter
        ) { _, _ in [event] }

        let count = try! await scheduler.rescheduleNow(leadMinutes: [10])

        assert(count == 1)
        assert(notificationManager.addedIdentifiers == [identifier])
        assert(notificationManager.removedIdentifiers.isEmpty)
        assert(presenter.presentedIdentifiers.isEmpty)
        assert(scheduler.pendingInAppReminderFireDates().count == 1)
    }

    @MainActor
    private static func testScheduledReminderDelaysLocalFallbackPastInAppFireDate() async {
        let start = floor(Date().timeIntervalSince1970) + 3_600
        let event = calendarEvent(id: "meeting", start: start, end: start + 1_800)
        let notificationManager = FakeNotificationManager()
        let presenter = FakeInAppPresenter()
        let scheduler = CalendarRecordingReminderScheduler(
            notificationManager: notificationManager,
            inAppPresenter: presenter
        ) { _, _ in [event] }

        _ = try! await scheduler.rescheduleNow(leadMinutes: [10])

        guard let trigger = notificationManager.addedRequests.first?.trigger as? UNCalendarNotificationTrigger,
              let localNotificationDate = Calendar.current.date(from: trigger.dateComponents),
              let inAppFireDate = scheduler.pendingInAppReminderFireDates().first else {
            assertionFailure("Expected one scheduled local notification and one in-app timer")
            return
        }
        assert(localNotificationDate.timeIntervalSince(inAppFireDate) >= CalendarRecordingReminderScheduler.localNotificationFallbackDelay - 1)
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

    private enum TestNotificationError: Error {
        case addFailed
    }

    @MainActor
    private final class FakeInAppPresenter: CalendarRecordingReminderInAppPresenting {
        var shouldPresent = true
        var shouldCallPresentedHandlerImmediately = true
        var presentedIdentifiers: [String] = []
        private var pendingPresentedHandlers: [String: (CalendarRecordingReminderSchedule) -> Void] = [:]
        private var schedulesByIdentifier: [String: CalendarRecordingReminderSchedule] = [:]

        func presentCalendarRecordingReminder(
            _ schedule: CalendarRecordingReminderSchedule,
            onPresented: @escaping (CalendarRecordingReminderSchedule) -> Void
        ) async -> Bool {
            presentedIdentifiers.append(schedule.identifier)
            guard shouldPresent else { return false }
            if shouldCallPresentedHandlerImmediately {
                onPresented(schedule)
            } else {
                pendingPresentedHandlers[schedule.identifier] = onPresented
                schedulesByIdentifier[schedule.identifier] = schedule
            }
            return true
        }

        func markPresented(identifier: String) {
            guard let schedule = schedulesByIdentifier[identifier] else { return }
            pendingPresentedHandlers[identifier]?(schedule)
        }
    }

    @MainActor
    private final class FakeNotificationManager: CalendarRecordingReminderNotificationManaging {
        var shouldFailAdd = false
        var canShowAlertsResult = true
        var addedIdentifiers: [String] = []
        var addedRequests: [UNNotificationRequest] = []
        var removedIdentifiers: [String] = []
        private let pendingIdentifiers: [String]

        init(pendingIdentifiers: [String] = []) {
            self.pendingIdentifiers = pendingIdentifiers
        }

        func canShowAlerts() async -> Bool {
            canShowAlertsResult
        }

        func add(_ request: UNNotificationRequest) async throws {
            if shouldFailAdd {
                throw TestNotificationError.addFailed
            }
            addedIdentifiers.append(request.identifier)
            addedRequests.append(request)
        }

        func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
            removedIdentifiers.append(contentsOf: identifiers)
        }

        func pendingNotificationRequestIdentifiers() async -> [String] {
            pendingIdentifiers
        }

        func deliveredNotificationRequestIdentifiers() async -> [String] {
            []
        }

        func sendImmediateNotification(_ request: UNNotificationRequest) async -> Bool {
            addedIdentifiers.append(request.identifier)
            addedRequests.append(request)
            return true
        }
    }
}
