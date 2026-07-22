import Foundation
import UserNotifications

struct CalendarRecordingReminderPlan: Equatable {
    let scheduled: [CalendarRecordingReminderSchedule]
    let immediate: [CalendarRecordingReminderSchedule]
}

struct CalendarRecordingReminderNotificationAction: Equatable {
    let identifier: String
    let reminderGroupIdentifier: String?
}

struct CalendarRecordingReminderSchedule: Equatable {
    let identifier: String
    let fireDate: Date
    let event: GoogleCalendarEvent
    let delivery: Delivery

    var reminderGroupIdentifier: String {
        CalendarRecordingReminderScheduler.reminderGroupIdentifier(for: event)
    }

    enum Delivery: Equatable {
        case scheduled
        case immediate
    }
}

@MainActor
protocol CalendarRecordingReminderNotificationManaging: AnyObject {
    func canShowAlerts() async -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func pendingNotificationRequestIdentifiers() async -> [String]
    func deliveredNotificationRequestIdentifiers() async -> [String]
    func sendImmediateNotification(_ request: UNNotificationRequest) async -> Bool
}

typealias CalendarRecordingReminderPresentedHandler = (CalendarRecordingReminderSchedule) -> Void

@MainActor
protocol CalendarRecordingReminderInAppPresenting: AnyObject {
    func presentCalendarRecordingReminder(
        _ schedule: CalendarRecordingReminderSchedule,
        onPresented: @escaping CalendarRecordingReminderPresentedHandler
    ) async -> Bool
}

extension AppNotificationManager: CalendarRecordingReminderNotificationManaging {}

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
    nonisolated static let localNotificationFallbackDelay: TimeInterval = 2

    private let notificationManager: CalendarRecordingReminderNotificationManaging
    private weak var inAppPresenter: CalendarRecordingReminderInAppPresenting?
    private let eventProvider: EventProvider
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var inAppTimers: [String: Timer] = [:]
    private var generation = 0
    private var isStarted = false
    private var notifiedReminderIdentifiers: Set<String> = []
    private var externallyHandledReminderIdentifiers: Set<String> = []
    private var externallyHandledReminderGroupIdentifiers: Set<String> = []

    init(
        notificationManager: CalendarRecordingReminderNotificationManaging,
        inAppPresenter: CalendarRecordingReminderInAppPresenting? = nil,
        eventProvider: @escaping EventProvider
    ) {
        self.notificationManager = notificationManager
        self.inAppPresenter = inAppPresenter
        self.eventProvider = eventProvider
    }

    func start(leadMinutes: [Int], refreshIntervalMinutes: Int) {
        let normalizedLeadMinuteValues = Self.normalizedLeadMinutes(leadMinutes)
        generation += 1
        cleanupTask?.cancel()
        cleanupTask = nil
        isStarted = true
        stopTimer()
        scheduleRefresh(leadMinutes: normalizedLeadMinuteValues)
        let interval = TimeInterval(Self.normalizedRefreshIntervalMinutes(refreshIntervalMinutes) * 60)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRefresh(leadMinutes: normalizedLeadMinuteValues)
            }
        }
    }

    func stop() {
        generation += 1
        let stopGeneration = generation
        isStarted = false
        stopTimer()
        invalidateInAppTimers()
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
    func rescheduleNow(leadMinutes: [Int]) async throws -> Int {
        let refreshGeneration = generation
        return try await refresh(leadMinutes: leadMinutes, generation: refreshGeneration, requiresStarted: false)
    }

    func pendingInAppReminderFireDates() -> [Date] {
        inAppTimers.values.map(\.fireDate).sorted()
    }

    func markReminderHandledExternally(identifier: String, reminderGroupIdentifier: String?) {
        externallyHandledReminderIdentifiers.insert(identifier)
        if let reminderGroupIdentifier {
            externallyHandledReminderGroupIdentifiers.insert(reminderGroupIdentifier)
        }
        inAppTimers[identifier]?.invalidate()
        inAppTimers.removeValue(forKey: identifier)
        notificationManager.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    private func stopTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func scheduleRefresh(leadMinutes: [Int]) {
        refreshTask?.cancel()
        let refreshGeneration = generation
        refreshTask = Task {
            do {
                _ = try await refresh(leadMinutes: leadMinutes, generation: refreshGeneration)
            } catch is CancellationError {
            } catch {
            }
        }
    }

    @discardableResult
    private func refresh(
        leadMinutes: [Int],
        generation refreshGeneration: Int,
        requiresStarted: Bool = true
    ) async throws -> Int {
        let canShowAlerts = await notificationManager.canShowAlerts()
        guard canShowAlerts || inAppPresenter != nil else { return 0 }
        try Task.checkCancellation()
        guard generation == refreshGeneration else { return 0 }
        guard !requiresStarted || isStarted else { return 0 }
        let now = Date()
        let events = try await eventProvider(now, now.addingTimeInterval(Self.scheduleWindow))
        try Task.checkCancellation()
        guard generation == refreshGeneration else { return 0 }
        guard !requiresStarted || isStarted else { return 0 }
        let plan = Self.reminderPlan(
            for: events,
            leadMinutes: leadMinutes,
            now: now,
            calendar: .current
        )
        try Task.checkCancellation()
        guard generation == refreshGeneration else { return 0 }
        guard !requiresStarted || isStarted else { return 0 }
        return try await replacePendingNotifications(
            plan: plan,
            calendar: .current,
            generation: refreshGeneration,
            canShowAlerts: canShowAlerts
        )
    }

    private func replacePendingNotifications(
        plan: CalendarRecordingReminderPlan,
        calendar: Calendar,
        generation refreshGeneration: Int,
        canShowAlerts: Bool
    ) async throws -> Int {
        let pendingIDs = Set(await Self.pendingCalendarReminderIdentifiers(notificationManager: notificationManager))
        try Task.checkCancellation()
        guard generation == refreshGeneration else { return 0 }
        let deliveredIDs = Set(await notificationManager.deliveredNotificationRequestIdentifiers())
            .filter(Self.isCalendarReminderIdentifier)
        try Task.checkCancellation()
        guard generation == refreshGeneration else { return 0 }
        let plannedSchedules = plan.scheduled + plan.immediate
        let planIDs = Set(plannedSchedules.map(\.identifier))
        let planGroupIDs = Set(plannedSchedules.map(\.reminderGroupIdentifier))
        externallyHandledReminderIdentifiers = externallyHandledReminderIdentifiers.intersection(planIDs)
        externallyHandledReminderGroupIdentifiers = externallyHandledReminderGroupIdentifiers.intersection(planGroupIDs)
        let externallyHandledIDs = Set(plannedSchedules
            .filter(isExternallyHandled)
            .map(\.identifier))
        cancelStaleInAppTimers(keeping: planIDs.subtracting(externallyHandledIDs))
        notifiedReminderIdentifiers = notifiedReminderIdentifiers.intersection(planIDs)
        let immediateNotifiedIDs = deliveredIDs.union(notifiedReminderIdentifiers)
        let scheduledIDs = Set(plan.scheduled.map(\.identifier))
        let immediateIDs = Set(plan.immediate.map(\.identifier))
        var pendingToRemove = pendingIDs.subtracting(scheduledIDs).subtracting(immediateIDs)
        pendingToRemove.formUnion(pendingIDs.intersection(externallyHandledIDs))
        try Task.checkCancellation()
        guard generation == refreshGeneration else { return 0 }

        var deliveredCount = 0
        for schedule in plan.immediate where !immediateNotifiedIDs.contains(schedule.identifier) && !isExternallyHandled(schedule) {
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return deliveredCount }
            if await presentInApp(schedule) {
                try Task.checkCancellation()
                guard generation == refreshGeneration else { return deliveredCount }
                deliveredCount += 1
                continue
            }
            if canShowAlerts, await notificationManager.sendImmediateNotification(Self.notificationRequest(for: schedule, calendar: calendar)) {
                try Task.checkCancellation()
                guard generation == refreshGeneration else { return deliveredCount }
                notifiedReminderIdentifiers.insert(schedule.identifier)
                if pendingIDs.contains(schedule.identifier) {
                    pendingToRemove.insert(schedule.identifier)
                }
                deliveredCount += 1
            }
        }

        var scheduledCount = 0
        var didFailScheduledAdd = false
        for schedule in plan.scheduled where !deliveredIDs.contains(schedule.identifier) && !isExternallyHandled(schedule) {
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return deliveredCount + scheduledCount }
            do {
                if canShowAlerts {
                    try await notificationManager.add(Self.notificationRequest(
                        for: schedule,
                        calendar: calendar,
                        scheduledDelay: inAppPresenter == nil ? 0 : Self.localNotificationFallbackDelay
                    ))
                }
                scheduleInAppTimer(for: schedule, generation: refreshGeneration)
                scheduledCount += 1
            } catch {
                didFailScheduledAdd = true
            }
        }

        try Task.checkCancellation()
        guard generation == refreshGeneration else { return deliveredCount + scheduledCount }
        if !didFailScheduledAdd && !pendingToRemove.isEmpty {
            notificationManager.removePendingNotificationRequests(withIdentifiers: Array(pendingToRemove))
        }
        return deliveredCount + scheduledCount
    }

    private func presentInApp(_ schedule: CalendarRecordingReminderSchedule) async -> Bool {
        guard let inAppPresenter else { return false }
        return await inAppPresenter.presentCalendarRecordingReminder(schedule) { [weak self] presentedSchedule in
            guard let self else { return }
            self.notifiedReminderIdentifiers.insert(presentedSchedule.identifier)
            self.notificationManager.removePendingNotificationRequests(withIdentifiers: [presentedSchedule.identifier])
        }
    }

    private func isExternallyHandled(_ schedule: CalendarRecordingReminderSchedule) -> Bool {
        externallyHandledReminderIdentifiers.contains(schedule.identifier)
            || externallyHandledReminderGroupIdentifiers.contains(schedule.reminderGroupIdentifier)
    }

    private func scheduleInAppTimer(for schedule: CalendarRecordingReminderSchedule, generation timerGeneration: Int) {
        guard inAppPresenter != nil else { return }
        inAppTimers[schedule.identifier]?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: max(0, schedule.fireDate.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.fireInAppReminder(schedule, generation: timerGeneration)
            }
        }
        inAppTimers[schedule.identifier] = timer
    }

    private func cancelStaleInAppTimers(keeping identifiers: Set<String>) {
        for identifier in Array(inAppTimers.keys) where !identifiers.contains(identifier) {
            inAppTimers[identifier]?.invalidate()
            inAppTimers.removeValue(forKey: identifier)
        }
    }

    private func invalidateInAppTimers() {
        for timer in inAppTimers.values {
            timer.invalidate()
        }
        inAppTimers.removeAll()
    }

    private func fireInAppReminder(_ schedule: CalendarRecordingReminderSchedule, generation timerGeneration: Int) async {
        inAppTimers[schedule.identifier]?.invalidate()
        inAppTimers.removeValue(forKey: schedule.identifier)
        guard generation == timerGeneration, isStarted else { return }
        let deliveredIDs = await notificationManager.deliveredNotificationRequestIdentifiers()
        guard !deliveredIDs.contains(schedule.identifier) else { return }
        guard await presentInApp(schedule) else { return }
    }

    private static func notificationRequest(
        for schedule: CalendarRecordingReminderSchedule,
        calendar: Calendar,
        scheduledDelay: TimeInterval = 0
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
            let notificationFireDate = schedule.fireDate.addingTimeInterval(scheduledDelay)
            trigger = UNCalendarNotificationTrigger(
                dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: notificationFireDate),
                repeats: false
            )
        case .immediate:
            trigger = nil
        }
        return UNNotificationRequest(identifier: schedule.identifier, content: content, trigger: trigger)
    }

    private static func pendingCalendarReminderIdentifiers(notificationManager: CalendarRecordingReminderNotificationManaging) async -> [String] {
        calendarReminderIdentifiers(in: await notificationManager.pendingNotificationRequestIdentifiers())
    }

    nonisolated static func schedules(
        for events: [GoogleCalendarEvent],
        leadMinutes: [Int],
        now: Date,
        calendar: Calendar
    ) -> [CalendarRecordingReminderSchedule] {
        reminderPlan(for: events, leadMinutes: leadMinutes, now: now, calendar: calendar).scheduled
    }

    nonisolated static func reminderPlan(
        for events: [GoogleCalendarEvent],
        leadMinutes: [Int],
        now: Date,
        calendar: Calendar
    ) -> CalendarRecordingReminderPlan {
        let normalizedLeadMinuteValues = normalizedLeadMinutes(leadMinutes)
        let schedules = events.flatMap { event -> [CalendarRecordingReminderSchedule] in
            guard isReminderEligible(event) else { return [] }
            return normalizedLeadMinuteValues.compactMap { normalizedLeadMinutes in
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

    nonisolated static func leadTimeOptionTitle(_ minutes: Int) -> String {
        leadTimeOptionTitle(
            minutes,
            language: preferredLocalizedStringLanguage(),
            bundle: .main
        )
    }

    nonisolated static func leadTimeOptionTitle(
        _ minutes: Int,
        language: String,
        bundle: Bundle
    ) -> String {
        localizedCatalogFormat(
            "%@ min before",
            String(minutes),
            language: language,
            bundle: bundle
        )
    }

    nonisolated static func notificationTitle(for schedule: CalendarRecordingReminderSchedule, now: Date) -> String {
        notificationTitle(for: schedule, now: now, language: preferredLocalizedStringLanguage(), bundle: .main)
    }

    nonisolated static func notificationTitle(for schedule: CalendarRecordingReminderSchedule, now: Date, language: String, bundle: Bundle) -> String {
        let minutesUntilStart = Int(ceil(schedule.event.start.timeIntervalSince(now) / 60))
        if minutesUntilStart > 1 {
            return String(format: localizedCatalogString("Meeting starts in %d minutes", language: language, bundle: bundle), minutesUntilStart)
        }
        if minutesUntilStart == 1 {
            return localizedCatalogString("Meeting starts in 1 minute", language: language, bundle: bundle)
        }
        if schedule.event.start > now {
            return localizedCatalogString("Meeting starts soon", language: language, bundle: bundle)
        }
        return localizedCatalogString("Meeting is starting now", language: language, bundle: bundle)
    }

    nonisolated static func notificationBody(for event: GoogleCalendarEvent) -> String {
        notificationBody(for: event, language: preferredLocalizedStringLanguage(), bundle: .main)
    }

    nonisolated static func notificationBody(for event: GoogleCalendarEvent, language: String, bundle: Bundle) -> String {
        String(format: localizedCatalogString("Tap to start recording: %@", language: language, bundle: bundle), event.title)
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
        let normalizedLeadMinutes = normalizedLeadMinuteOption(leadMinutes)
        return "\(notificationIdentifierPrefix):\(event.calendarID):\(event.id):\(startTimestamp):\(normalizedLeadMinutes)"
    }

    nonisolated static func reminderGroupIdentifier(for event: GoogleCalendarEvent) -> String {
        reminderGroupIdentifier(
            calendarID: event.calendarID,
            eventID: event.id,
            startTimestamp: Int(event.start.timeIntervalSince1970.rounded())
        )
    }

    nonisolated static func reminderGroupIdentifier(from userInfo: [AnyHashable: Any]) -> String? {
        guard let calendarID = userInfo["calendarID"] as? String,
              let eventID = userInfo["eventID"] as? String,
              let eventStart = timeIntervalValue(userInfo["eventStart"]) else { return nil }
        return reminderGroupIdentifier(
            calendarID: calendarID,
            eventID: eventID,
            startTimestamp: Int(eventStart.rounded())
        )
    }

    private nonisolated static func reminderGroupIdentifier(calendarID: String, eventID: String, startTimestamp: Int) -> String {
        "\(calendarID):\(eventID):\(startTimestamp)"
    }

    private nonisolated static func timeIntervalValue(_ value: Any?) -> TimeInterval? {
        if let value = value as? TimeInterval { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
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

    nonisolated static func normalizedLeadMinuteOption(_ value: Int) -> Int {
        leadMinuteOptions.min { lhs, rhs in
            abs(lhs - value) < abs(rhs - value)
        } ?? defaultLeadMinutes
    }

    nonisolated static func normalizedLeadMinutes(_ values: [Int]) -> [Int] {
        let normalized = Set(values.map(normalizedLeadMinuteOption)).sorted()
        return normalized.isEmpty ? [defaultLeadMinutes] : normalized
    }

    nonisolated static func normalizedRefreshIntervalMinutes(_ value: Int) -> Int {
        refreshIntervalMinuteOptions.min { lhs, rhs in
            abs(lhs - value) < abs(rhs - value)
        } ?? defaultRefreshIntervalMinutes
    }
}
