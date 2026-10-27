import Foundation

// The calendar event a note is linked to. It syncs as the note's
// `calendarMatch` bytes (JSONEncoder defaults), so the keys never change.

public enum CalendarProvider: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case google
    case apple

    public var id: String { rawValue }
}

public enum CalendarMatchSource: String, Codable, Equatable, Sendable {
    case overlapSuggestion = "overlap_suggestion"
    case calendarNotification = "calendar_notification"
    case importSelection = "import_selection"
}

public enum CalendarTitleState: String, Codable, Equatable, Sendable {
    case suggested
    case applied
}

public struct CalendarEventAttendee: Codable, Equatable, Sendable {
    public let displayName: String?
    public let email: String?
    public let responseStatus: String?
    public let isOptional: Bool
    public let isSelf: Bool

    public init(
        displayName: String? = nil,
        email: String? = nil,
        responseStatus: String? = nil,
        isOptional: Bool = false,
        isSelf: Bool = false
    ) {
        self.displayName = displayName
        self.email = email
        self.responseStatus = responseStatus
        self.isOptional = isOptional
        self.isSelf = isSelf
    }
}

public struct CalendarEventMatch: Codable, Equatable, Sendable {
    public let accountID: String?
    public let calendarID: String
    public let eventID: String
    public let title: String
    public let start: Date
    public let end: Date
    public let attendees: [CalendarEventAttendee]
    public let matchSource: CalendarMatchSource
    public let titleState: CalendarTitleState
    /// Missing in notes saved before Apple Calendar support; those are Google.
    public let provider: CalendarProvider?

    public init(
        accountID: String? = nil,
        calendarID: String,
        eventID: String,
        title: String,
        start: Date,
        end: Date,
        attendees: [CalendarEventAttendee] = [],
        matchSource: CalendarMatchSource,
        titleState: CalendarTitleState,
        provider: CalendarProvider? = nil
    ) {
        self.accountID = accountID
        self.calendarID = calendarID
        self.eventID = eventID
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.matchSource = matchSource
        self.titleState = titleState
        self.provider = provider
    }

    public var resolvedProvider: CalendarProvider { provider ?? .google }

    public var suggestedTitle: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public var appliedTitle: String? {
        guard titleState == .applied else { return nil }
        return suggestedTitle
    }

    public func applyingTitle() -> CalendarEventMatch {
        CalendarEventMatch(
            accountID: accountID,
            calendarID: calendarID,
            eventID: eventID,
            title: title,
            start: start,
            end: end,
            attendees: attendees,
            matchSource: matchSource,
            titleState: .applied,
            provider: provider
        )
    }
}
