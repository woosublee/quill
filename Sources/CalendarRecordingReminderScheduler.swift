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

@MainActor
final class CalendarRecordingReminderScheduler {
    typealias EventProvider = (_ timeMin: Date, _ timeMax: Date) async throws -> [GoogleCalendarEvent]

    nonisolated static let notificationIdentifierPrefix = "calendar-recording-reminder"
    nonisolated static let notificationCategoryIdentifier = "calendar-recording-reminder"
    nonisolated static let defaultLeadMinutes = 10
    nonisolated static let defaultRefreshIntervalMinutes = 15
    nonisolated static let leadMinuteOptions = [1, 5, 10, 15, 30, 60]
    nonisolated static let refreshIntervalMinuteOptions = [5, 15, 30, 60]
    nonisolated static let scheduleWindow: TimeInterval = 24 * 60 * 60
    nonisolated static let startedMeetingGracePeriod: TimeInterval = 5 * 60

    private let notificationManager: AppNotificationManager
    private let eventProvider: EventProvider
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var generation = 0
    private var isStarted = false
    private var notifiedReminderIdentifiers: Set<String> = []

    init(
        notificationManager: AppNotificationManager,
        eventProvider: @escaping EventProvider
    ) {
        self.notificationManager = notificationManager
        self.eventProvider = eventProvider
    }

    func start(leadMinutes: Int, refreshIntervalMinutes: Int) {
        generation += 1
        cleanupTask?.cancel()
        cleanupTask = nil
        isStarted = true
        stopTimer()
        scheduleRefresh(leadMinutes: leadMinutes)
        let interval = TimeInterval(Self.normalizedRefreshIntervalMinutes(refreshIntervalMinutes) * 60)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRefresh(leadMinutes: leadMinutes)
            }
        }
    }

    func stop() {
        generation += 1
        let stopGeneration = generation
        isStarted = false
        stopTimer()
        refreshTask?.cancel()
        refreshTask = nil
        cleanupTask?.cancel()
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            let identifiers = await Self.pendingCalendarReminderIdentifiers(notificationManager: notificationManager)
            guard !Task.isCancelled, self.generation == stopGeneration else { return }
            notificationManager.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
    }

    @discardableResult
    func rescheduleNow(leadMinutes: Int) async throws -> Int {
        try await refresh(leadMinutes: leadMinutes, requiresStarted: false)
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
    private func refresh(leadMinutes: Int, requiresStarted: Bool = true) async throws -> Int {
        guard await notificationManager.canShowAlerts() else { return 0 }
        try Task.checkCancellation()
        guard !requiresStarted || isStarted else { return 0 }
        let now = Date()
        let events = try await eventProvider(now, now.addingTimeInterval(Self.scheduleWindow))
        try Task.checkCancellation()
        guard !requiresStarted || isStarted else { return 0 }
        let plan = Self.reminderPlan(
            for: events,
            leadMinutes: leadMinutes,
            now: now,
            calendar: .current
        )
        try Task.checkCancellation()
        guard !requiresStarted || isStarted else { return 0 }
        let deliveredCount = await replacePendingNotifications(plan: plan, calendar: .current)
        return plan.scheduled.count + deliveredCount
    }

    private func replacePendingNotifications(
        plan: CalendarRecordingReminderPlan,
        calendar: Calendar
    ) async -> Int {
        let pendingIDs = Set(await Self.pendingCalendarReminderIdentifiers(notificationManager: notificationManager))
        let deliveredIDs = Set(await notificationManager.deliveredNotificationRequestIdentifiers())
            .filter(Self.isCalendarReminderIdentifier)
        let planIDs = Set((plan.scheduled + plan.immediate).map(\.identifier))
        notifiedReminderIdentifiers = notifiedReminderIdentifiers.intersection(planIDs)
        let immediateNotifiedIDs = pendingIDs.union(deliveredIDs).union(notifiedReminderIdentifiers)
        let scheduledIDs = Set(plan.scheduled.map(\.identifier))
        let pendingToRemove = pendingIDs.subtracting(scheduledIDs)
        if !pendingToRemove.isEmpty {
            notificationManager.removePendingNotificationRequests(withIdentifiers: Array(pendingToRemove))
        }

        var deliveredCount = 0
        for schedule in plan.immediate where !immediateNotifiedIDs.contains(schedule.identifier) {
            if await notificationManager.sendImmediateNotification(Self.notificationRequest(for: schedule, calendar: calendar)) {
                notifiedReminderIdentifiers.insert(schedule.identifier)
                deliveredCount += 1
            }
        }
        for schedule in plan.scheduled where !deliveredIDs.contains(schedule.identifier) {
            do {
                try await notificationManager.add(Self.notificationRequest(for: schedule, calendar: calendar))
            } catch {
            }
        }
        return deliveredCount
    }

    private static func notificationRequest(
        for schedule: CalendarRecordingReminderSchedule,
        calendar: Calendar
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notificationTitle(
            for: schedule,
            now: schedule.delivery == .scheduled ? schedule.fireDate : Date()
        )
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

    nonisolated static func schedules(
        for events: [GoogleCalendarEvent],
        leadMinutes: Int,
        now: Date,
        calendar: Calendar
    ) -> [CalendarRecordingReminderSchedule] {
        reminderPlan(for: events, leadMinutes: leadMinutes, now: now, calendar: calendar).scheduled
    }

    nonisolated static func reminderPlan(
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

    nonisolated static func notificationTitle(for schedule: CalendarRecordingReminderSchedule, now: Date) -> String {
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

    nonisolated static func notificationBody(for event: GoogleCalendarEvent) -> String {
        "Tap to start recording: \(event.title)"
    }

    nonisolated static func isReminderEligible(_ event: GoogleCalendarEvent) -> Bool {
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

    nonisolated static func notificationIdentifier(for event: GoogleCalendarEvent, leadMinutes: Int) -> String {
        let startTimestamp = Int(event.start.timeIntervalSince1970.rounded())
        return "\(notificationIdentifierPrefix):\(event.calendarID):\(event.id):\(startTimestamp):\(normalizedLeadMinutes(leadMinutes))"
    }

    nonisolated static func isCalendarReminderIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix("\(notificationIdentifierPrefix):")
    }

    nonisolated static func calendarReminderIdentifiers(in identifiers: [String]) -> [String] {
        identifiers.filter(isCalendarReminderIdentifier)
    }

    nonisolated static func normalizedLeadMinutes(_ value: Int) -> Int {
        min(max(value, 1), 120)
    }

    nonisolated static func normalizedRefreshIntervalMinutes(_ value: Int) -> Int {
        refreshIntervalMinuteOptions.min { lhs, rhs in
            abs(lhs - value) < abs(rhs - value)
        } ?? defaultRefreshIntervalMinutes
    }
}
