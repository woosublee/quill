import Foundation

enum CalendarMatchSource: String, Codable, Equatable {
    case overlapSuggestion = "overlap_suggestion"
    case calendarNotification = "calendar_notification"
}

enum CalendarTitleState: String, Codable, Equatable {
    case suggested
    case applied
}

struct CalendarEventAttendee: Codable, Equatable {
    let displayName: String?
    let email: String?
    let responseStatus: String?
    let isOptional: Bool
    let isSelf: Bool

    init(displayName: String? = nil, email: String? = nil, responseStatus: String? = nil, isOptional: Bool = false, isSelf: Bool = false) {
        self.displayName = displayName
        self.email = email
        self.responseStatus = responseStatus
        self.isOptional = isOptional
        self.isSelf = isSelf
    }
}

struct CalendarEventMatch: Codable, Equatable {
    let accountID: String?
    let calendarID: String
    let eventID: String
    let title: String
    let start: Date
    let end: Date
    let attendees: [CalendarEventAttendee]
    let matchSource: CalendarMatchSource
    let titleState: CalendarTitleState

    init(accountID: String? = nil, calendarID: String, eventID: String, title: String, start: Date, end: Date, attendees: [CalendarEventAttendee] = [], matchSource: CalendarMatchSource, titleState: CalendarTitleState) {
        self.accountID = accountID
        self.calendarID = calendarID
        self.eventID = eventID
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.matchSource = matchSource
        self.titleState = titleState
    }

    var suggestedTitle: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var appliedTitle: String? {
        guard titleState == .applied else { return nil }
        return suggestedTitle
    }

    func applyingTitle() -> CalendarEventMatch {
        CalendarEventMatch(accountID: accountID, calendarID: calendarID, eventID: eventID, title: title, start: start, end: end, attendees: attendees, matchSource: matchSource, titleState: .applied)
    }
}

struct GoogleCalendarInfo: Identifiable, Codable, Equatable {
    let id: String
    let summary: String
    let summaryOverride: String?
    let primary: Bool
    let accessRole: String?

    var displayName: String {
        let override = summaryOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !override.isEmpty { return override }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? id : trimmed
    }
}

struct GoogleCalendarEvent: Identifiable, Equatable {
    let id: String
    let calendarID: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let attendees: [CalendarEventAttendee]

    var hasUsableTitle: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func match(accountID: String?, source: CalendarMatchSource, titleState: CalendarTitleState) -> CalendarEventMatch {
        CalendarEventMatch(accountID: accountID, calendarID: calendarID, eventID: id, title: title, start: start, end: end, attendees: attendees, matchSource: source, titleState: titleState)
    }
}

struct GoogleCalendarConnectionState: Codable, Equatable {
    var isConnected: Bool
    var accountEmail: String?
    var selectedCalendarIDs: Set<String>
    var lastErrorMessage: String?

    static let disconnected = GoogleCalendarConnectionState(isConnected: false, accountEmail: nil, selectedCalendarIDs: [], lastErrorMessage: nil)
}
