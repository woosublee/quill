import Foundation

/// One reminder to record a meeting: when it fires and for which event.
public struct CalendarRecordingReminderSchedule: Equatable, Sendable {
    public enum Delivery: Equatable, Sendable {
        /// Fires at `fireDate`.
        case scheduled
        /// Its time has passed but the meeting hasn't started (or just
        /// started), so it shows now.
        case immediate
    }

    public let identifier: String
    public let fireDate: Date
    public let event: CalendarEvent
    public let delivery: Delivery

    public init(identifier: String, fireDate: Date, event: CalendarEvent, delivery: Delivery) {
        self.identifier = identifier
        self.fireDate = fireDate
        self.event = event
        self.delivery = delivery
    }

    /// The event the reminder is for, whatever its lead time.
    public var reminderGroupIdentifier: String {
        CalendarRecordingReminderPlanner.groupIdentifier(for: event)
    }
}

public struct CalendarRecordingReminderPlan: Equatable, Sendable {
    public let scheduled: [CalendarRecordingReminderSchedule]
    public let immediate: [CalendarRecordingReminderSchedule]

    public init(scheduled: [CalendarRecordingReminderSchedule], immediate: [CalendarRecordingReminderSchedule]) {
        self.scheduled = scheduled
        self.immediate = immediate
    }
}

/// Which meetings get a reminder to record, and when, the same on the Mac
/// and the iPhone. Reading calendars, sending notifications, and the
/// settings stay in each app.
public enum CalendarRecordingReminderPlanner {
    public static let identifierPrefix = "calendar-recording-reminder"
    public static let defaultLeadMinutes = 10
    public static let leadMinuteOptions = [1, 5, 10, 15, 30, 60]
    /// A reminder whose time has passed still shows this long after the
    /// meeting started.
    public static let startedMeetingGracePeriod: TimeInterval = 5 * 60

    public static func isReminderEligible(_ event: CalendarEvent) -> Bool {
        event.isMeetingCandidate
    }

    public static func isReminderIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix("\(identifierPrefix):")
    }

    public static func identifier(for event: CalendarEvent, leadMinutes: Int) -> String {
        "\(identifierPrefix):\(groupIdentifier(for: event)):\(normalizedLeadMinuteOption(leadMinutes))"
    }

    /// One event, whatever its lead time.
    public static func groupIdentifier(for event: CalendarEvent) -> String {
        groupIdentifier(
            calendarID: event.calendarID,
            eventID: event.id,
            startTimestamp: Int(event.start.timeIntervalSince1970.rounded())
        )
    }

    public static func groupIdentifier(calendarID: String, eventID: String, startTimestamp: Int) -> String {
        "\(calendarID):\(eventID):\(startTimestamp)"
    }

    /// The nearest offered lead time.
    public static func normalizedLeadMinuteOption(_ value: Int) -> Int {
        leadMinuteOptions.min { lhs, rhs in
            abs(lhs - value) < abs(rhs - value)
        } ?? defaultLeadMinutes
    }

    /// The offered lead times for `values`, sorted, without repeats; the
    /// default when there are none.
    public static func normalizedLeadMinutes(_ values: [Int]) -> [Int] {
        let normalized = Set(values.map(normalizedLeadMinuteOption)).sorted()
        return normalized.isEmpty ? [defaultLeadMinutes] : normalized
    }

    /// The reminders for `events`, by fire date. A reminder whose time has
    /// passed shows now if the meeting hasn't started, or started within
    /// the grace period.
    public static func plan(
        for events: [CalendarEvent],
        leadMinutes: [Int],
        now: Date
    ) -> CalendarRecordingReminderPlan {
        let leads = normalizedLeadMinutes(leadMinutes)
        let schedules = events.flatMap { event -> [CalendarRecordingReminderSchedule] in
            guard isReminderEligible(event) else { return [] }
            return leads.compactMap { lead in
                let fireDate = event.start.addingTimeInterval(TimeInterval(-lead * 60))
                let identifier = identifier(for: event, leadMinutes: lead)
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
}
