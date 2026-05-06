import Foundation
import UserNotifications

struct CalendarRecordingReminderPlan: Equatable {
    let scheduled: [CalendarRecordingReminderSchedule]
    let immediate: [CalendarRecordingReminderSchedule]
}

struct CalendarRecordingReminderSchedule: Equatable {
    let identifier: String
    let fireDate: Date
    let event: GoogleCalendarEvent
    let delivery: Delivery

    enum Delivery: Equatable {
        case scheduled
        case immediate
    }
}

final class CalendarRecordingReminderScheduler {
    typealias EventProvider = (_ timeMin: Date, _ timeMax: Date) async throws -> [GoogleCalendarEvent]

    static let notificationIdentifierPrefix = "calendar-recording-reminder"
    static let notificationCategoryIdentifier = "calendar-recording-reminder"
    static let defaultLeadMinutes = 10
    static let defaultRefreshIntervalMinutes = 15
    static let leadMinuteOptions = [1, 5, 10, 15, 30, 60]
    static let refreshIntervalMinuteOptions = [5, 15, 30, 60]
    static let scheduleWindow: TimeInterval = 24 * 60 * 60
    static let startedMeetingGracePeriod: TimeInterval = 5 * 60

    private let notificationManager: AppNotificationManager
    private let eventProvider: EventProvider
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var isStarted = false

    init(
        notificationManager: AppNotificationManager = .shared,
        eventProvider: @escaping EventProvider
    ) {
        self.notificationManager = notificationManager
        self.eventProvider = eventProvider
    }

    func start(leadMinutes: Int, refreshIntervalMinutes: Int) {
        isStarted = true
        stopTimer()
        scheduleRefresh(leadMinutes: leadMinutes)
        let interval = TimeInterval(Self.normalizedRefreshIntervalMinutes(refreshIntervalMinutes) * 60)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.scheduleRefresh(leadMinutes: leadMinutes)
        }
    }

    func stop() {
        isStarted = false
        stopTimer()
        refreshTask?.cancel()
        refreshTask = nil
        Task {
            let identifiers = await Self.pendingCalendarReminderIdentifiers(notificationManager: notificationManager)
            notificationManager.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
    }

    @discardableResult
    func rescheduleNow(leadMinutes: Int) async throws -> Int {
        try await refresh(leadMinutes: leadMinutes)
    }

    private func stopTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func scheduleRefresh(leadMinutes: Int) {
        refreshTask?.cancel()
        refreshTask = Task {
            do {
                _ = try await refresh(leadMinutes: leadMinutes)
            } catch is CancellationError {
            } catch {
            }
        }
    }

    @discardableResult
    private func refresh(leadMinutes: Int) async throws -> Int {
        guard await notificationManager.canShowAlerts() else { return 0 }
        let now = Date()
        let events = try await eventProvider(now, now.addingTimeInterval(Self.scheduleWindow))
        let plan = Self.reminderPlan(
            for: events,
            leadMinutes: leadMinutes,
            now: now,
            calendar: .current
        )
        await Self.replacePendingNotifications(
            plan: plan,
            notificationManager: notificationManager,
            calendar: .current
        )
        return plan.scheduled.count + plan.immediate.count
    }

    private static func replacePendingNotifications(
        plan: CalendarRecordingReminderPlan,
        notificationManager: AppNotificationManager,
        calendar: Calendar
    ) async {
        let existingIdentifiers = await pendingCalendarReminderIdentifiers(notificationManager: notificationManager)
        notificationManager.removePendingNotificationRequests(withIdentifiers: existingIdentifiers)
        let existingIdentifierSet = Set(existingIdentifiers)

        for schedule in plan.immediate where !existingIdentifierSet.contains(schedule.identifier) {
            await notificationManager.sendImmediateNotification(notificationRequest(for: schedule, calendar: calendar))
        }
        for schedule in plan.scheduled {
            try? await notificationManager.add(notificationRequest(for: schedule, calendar: calendar))
        }
    }

    private static func notificationRequest(
        for schedule: CalendarRecordingReminderSchedule,
        calendar: Calendar
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notificationTitle(for: schedule, now: Date())
        content.body = notificationBody(for: schedule.event)
        content.sound = .default
        content.categoryIdentifier = notificationCategoryIdentifier
        content.userInfo = [
            "calendarID": schedule.event.calendarID,
            "eventID": schedule.event.id,
            "eventTitle": schedule.event.title,
            "eventStart": schedule.event.start.timeIntervalSince1970,
        ]
        let trigger: UNNotificationTrigger?
        switch schedule.delivery {
        case .scheduled:
            trigger = UNCalendarNotificationTrigger(
                dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: schedule.fireDate),
                repeats: false
            )
        case .immediate:
            trigger = nil
        }
        return UNNotificationRequest(identifier: schedule.identifier, content: content, trigger: trigger)
    }

    private static func pendingCalendarReminderIdentifiers(notificationManager: AppNotificationManager) async -> [String] {
        calendarReminderIdentifiers(in: await notificationManager.pendingNotificationRequestIdentifiers())
    }

    static func schedules(
        for events: [GoogleCalendarEvent],
        leadMinutes: Int,
        now: Date,
        calendar: Calendar
    ) -> [CalendarRecordingReminderSchedule] {
        reminderPlan(for: events, leadMinutes: leadMinutes, now: now, calendar: calendar).scheduled
    }

    static func reminderPlan(
        for events: [GoogleCalendarEvent],
        leadMinutes: Int,
        now: Date,
        calendar: Calendar
    ) -> CalendarRecordingReminderPlan {
        let normalizedLeadMinutes = normalizedLeadMinutes(leadMinutes)
        let schedules = events.compactMap { event -> CalendarRecordingReminderSchedule? in
            guard isReminderEligible(event) else { return nil }
            let fireDate = event.start.addingTimeInterval(TimeInterval(-normalizedLeadMinutes * 60))
            let identifier = notificationIdentifier(for: event, leadMinutes: normalizedLeadMinutes)
            if fireDate > now {
                return CalendarRecordingReminderSchedule(
                    identifier: identifier,
                    fireDate: fireDate,
                    event: event,
                    delivery: .scheduled
                )
            }
            guard event.start > now || now.timeIntervalSince(event.start) <= startedMeetingGracePeriod else {
                return nil
            }
            return CalendarRecordingReminderSchedule(
                identifier: identifier,
                fireDate: now,
                event: event,
                delivery: .immediate
            )
        }
        .sorted {
            if $0.fireDate != $1.fireDate { return $0.fireDate < $1.fireDate }
            return $0.identifier < $1.identifier
        }
        return CalendarRecordingReminderPlan(
            scheduled: schedules.filter { $0.delivery == .scheduled },
            immediate: schedules.filter { $0.delivery == .immediate }
        )
    }

    static func notificationTitle(for schedule: CalendarRecordingReminderSchedule, now: Date) -> String {
        let minutesUntilStart = Int(ceil(schedule.event.start.timeIntervalSince(now) / 60))
        if minutesUntilStart > 1 {
            return "Meeting starts in \(minutesUntilStart) minutes"
        }
        if minutesUntilStart == 1 {
            return "Meeting starts in 1 minute"
        }
        if schedule.event.start > now {
            return "Meeting starts soon"
        }
        return "Meeting is starting now"
    }

    static func notificationBody(for event: GoogleCalendarEvent) -> String {
        "Tap to start recording: \(event.title)"
    }

    static func isReminderEligible(_ event: GoogleCalendarEvent) -> Bool {
        guard !event.isAllDay,
              event.hasUsableTitle,
              event.end > event.start else {
            return false
        }
        if event.attendees.contains(where: { $0.isSelf && $0.responseStatus == "declined" }) {
            return false
        }
        return true
    }

    static func notificationIdentifier(for event: GoogleCalendarEvent, leadMinutes: Int) -> String {
        let startTimestamp = Int(event.start.timeIntervalSince1970.rounded())
        return "\(notificationIdentifierPrefix):\(event.calendarID):\(event.id):\(startTimestamp):\(normalizedLeadMinutes(leadMinutes))"
    }

    static func isCalendarReminderIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix("\(notificationIdentifierPrefix):")
    }

    static func calendarReminderIdentifiers(in identifiers: [String]) -> [String] {
        identifiers.filter(isCalendarReminderIdentifier)
    }

    static func normalizedLeadMinutes(_ value: Int) -> Int {
        min(max(value, 1), 120)
    }

    static func normalizedRefreshIntervalMinutes(_ value: Int) -> Int {
        refreshIntervalMinuteOptions.min { lhs, rhs in
            abs(lhs - value) < abs(rhs - value)
        } ?? defaultRefreshIntervalMinutes
    }
}
