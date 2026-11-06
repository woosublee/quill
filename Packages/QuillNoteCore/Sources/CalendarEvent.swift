import Foundation

/// One event read from a calendar, the same on the Mac and the iPhone. A
/// note that matches it keeps a `CalendarEventMatch`. Reading calendars
/// (EventKit, Google) stays in each app.
public struct CalendarEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let calendarID: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let attendees: [CalendarEventAttendee]
    public let provider: CalendarProvider

    public init(
        id: String,
        calendarID: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool,
        attendees: [CalendarEventAttendee],
        provider: CalendarProvider = .google
    ) {
        self.id = id
        self.calendarID = calendarID
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.attendees = attendees
        self.provider = provider
    }

    /// An Apple Calendar event's id. Occurrences of a repeating event share
    /// the item identifier, so the start time is added. Both apps must agree:
    /// it is the `eventID` a note's synced `calendarMatch` keeps, and part of
    /// the reminder identifiers.
    public static func appleEventID(itemIdentifier: String, start: Date) -> String {
        "\(itemIdentifier)@\(Int(start.timeIntervalSince1970))"
    }

    public var hasUsableTitle: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A timed, titled event the person has not declined: one a recording
    /// can be matched to and a reminder is sent for.
    public var isMeetingCandidate: Bool {
        guard !isAllDay, hasUsableTitle, end > start else { return false }
        return !attendees.contains { $0.isSelf && $0.responseStatus == "declined" }
    }

    public func match(
        accountID: String?,
        source: CalendarMatchSource,
        titleState: CalendarTitleState
    ) -> CalendarEventMatch {
        CalendarEventMatch(
            accountID: accountID,
            calendarID: calendarID,
            eventID: id,
            title: title,
            start: start,
            end: end,
            attendees: attendees,
            matchSource: source,
            titleState: titleState,
            provider: provider
        )
    }
}

/// How an Apple Calendar attendee answered.
public enum AppleParticipantResponse: Equatable, Sendable {
    case accepted
    case declined
    case tentative
    case pending
    case unknown
}

/// EventKit-free copy of an `EKParticipant`, so attendee mapping is shared
/// and testable.
public struct AppleParticipantData: Equatable, Sendable {
    public let name: String?
    public let url: URL?
    public let response: AppleParticipantResponse
    public let isOptional: Bool
    public let isCurrentUser: Bool

    public init(
        name: String?,
        url: URL?,
        response: AppleParticipantResponse,
        isOptional: Bool,
        isCurrentUser: Bool
    ) {
        self.name = name
        self.url = url
        self.response = response
        self.isOptional = isOptional
        self.isCurrentUser = isCurrentUser
    }

    /// Uses Google's response strings so the reminder rules apply unchanged,
    /// and an Apple attendee saves the same bytes as a Google one.
    public func attendee() -> CalendarEventAttendee {
        let email: String? = {
            guard let url, url.scheme?.lowercased() == "mailto",
                  let address = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path,
                  !address.isEmpty else { return nil }
            return address
        }()
        let status: String? = switch response {
        case .accepted: "accepted"
        case .declined: "declined"
        case .tentative: "tentative"
        case .pending: "needsAction"
        case .unknown: nil
        }
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarEventAttendee(
            displayName: (trimmedName?.isEmpty ?? true) ? nil : trimmedName,
            email: email,
            responseStatus: status,
            isOptional: isOptional,
            isSelf: isCurrentUser
        )
    }
}

/// Picks the event a recording belongs to: the most overlap, then the
/// nearest start.
public enum CalendarEventMatcher {
    public static func bestMatch(
        recordingStartedAt: Date?,
        recordingEndedAt: Date?,
        events: [CalendarEvent]
    ) -> CalendarEvent? {
        guard let recordingStartedAt, let recordingEndedAt, recordingEndedAt > recordingStartedAt else {
            return nil
        }
        return events
            .filter { !$0.isAllDay && $0.hasUsableTitle && $0.end > $0.start }
            .compactMap { event -> Candidate? in
                let overlapStart = max(recordingStartedAt, event.start)
                let overlapEnd = min(recordingEndedAt, event.end)
                let overlap = overlapEnd.timeIntervalSince(overlapStart)
                guard overlap > 0 else { return nil }
                return Candidate(
                    event: event,
                    overlap: overlap,
                    startDistance: abs(event.start.timeIntervalSince(recordingStartedAt))
                )
            }
            .sorted { lhs, rhs in
                if lhs.overlap != rhs.overlap {
                    return lhs.overlap > rhs.overlap
                }
                if lhs.startDistance != rhs.startDistance {
                    return lhs.startDistance < rhs.startDistance
                }
                if lhs.event.start != rhs.event.start {
                    return lhs.event.start < rhs.event.start
                }
                if lhs.event.calendarID != rhs.event.calendarID {
                    return lhs.event.calendarID < rhs.event.calendarID
                }
                return lhs.event.id < rhs.event.id
            }
            .first?
            .event
    }

    private struct Candidate {
        let event: CalendarEvent
        let overlap: TimeInterval
        let startDistance: TimeInterval
    }
}

/// Combines events from several calendar sources. The same meeting often
/// arrives twice when a Google account is both connected directly and added
/// to the Calendar app; the first group (Google) wins so its richer
/// attendee data is kept.
public enum CalendarEventMerger {
    public static func merge(_ groups: [[CalendarEvent]]) -> [CalendarEvent] {
        var seen = Set<Key>()
        var merged: [CalendarEvent] = []
        for group in groups {
            for event in group where seen.insert(Key(event)).inserted {
                merged.append(event)
            }
        }
        let order = Dictionary(uniqueKeysWithValues: CalendarProvider.allCases.enumerated().map { ($1, $0) })
        return merged.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.provider != rhs.provider {
                return order[lhs.provider, default: 0] < order[rhs.provider, default: 0]
            }
            if lhs.calendarID != rhs.calendarID { return lhs.calendarID < rhs.calendarID }
            return lhs.id < rhs.id
        }
    }

    private struct Key: Hashable {
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool

        init(_ event: CalendarEvent) {
            title = event.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            start = event.start
            end = event.end
            isAllDay = event.isAllDay
        }
    }
}
