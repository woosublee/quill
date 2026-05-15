import Foundation

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case calendar
    case prompts
    case macros
    case runLog
    case debug

    var id: String { rawValue }

    static var orderedCases: [SettingsTab] {
        [.general, .appearance, .calendar, .prompts, .macros, .runLog, .debug]
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .calendar: return "Calendar"
        case .prompts: return "Prompts"
        case .macros: return "Voice Macros"
        case .runLog: return "Run Log"
        case .debug: return "Debug"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .calendar: return "calendar"
        case .prompts: return "text.bubble"
        case .macros: return "music.mic"
        case .runLog: return "clock.arrow.circlepath"
        case .debug: return "wrench.and.screwdriver"
        }
    }
}

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

    var displaySortRank: Int {
        if primary { return 0 }
        switch accessRole {
        case "owner", "writer": return 1
        default: return 2
        }
    }
}

struct GoogleCalendarDisplayGroup: Equatable {
    let title: String
    let calendars: [GoogleCalendarInfo]
}

extension Array where Element == GoogleCalendarInfo {
    func sortedForQuillDisplay() -> [GoogleCalendarInfo] {
        sorted { lhs, rhs in
            if lhs.displaySortRank != rhs.displaySortRank {
                return lhs.displaySortRank < rhs.displaySortRank
            }
            let nameComparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
            return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }
    }

    func groupedForQuillDisplay() -> [GoogleCalendarDisplayGroup] {
        let sorted = sortedForQuillDisplay()
        let myCalendars = sorted.filter { $0.displaySortRank < 2 }
        let sharedCalendars = sorted.filter { $0.displaySortRank == 2 }
        return [
            GoogleCalendarDisplayGroup(title: "My calendars", calendars: myCalendars),
            GoogleCalendarDisplayGroup(title: "Shared calendars", calendars: sharedCalendars)
        ].filter { !$0.calendars.isEmpty }
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

enum GoogleCalendarHealthStatus: String, Codable, Equatable {
    case unknown
    case healthy
    case needsReconnect
    case temporaryFailure
}

enum GoogleCalendarHealthFeature: String, Codable, Equatable {
    case calendarList
    case recordingReminders
    case recordingMatch
}

struct GoogleCalendarHealth: Codable, Equatable {
    var status: GoogleCalendarHealthStatus
    var checkedAt: Date?
    var message: String?
    var affectedFeature: GoogleCalendarHealthFeature?

    static let unknown = GoogleCalendarHealth(status: .unknown)

    init(
        status: GoogleCalendarHealthStatus,
        checkedAt: Date? = nil,
        message: String? = nil,
        affectedFeature: GoogleCalendarHealthFeature? = nil
    ) {
        self.status = status
        self.checkedAt = checkedAt
        self.message = message
        self.affectedFeature = affectedFeature
    }
}

struct GoogleCalendarConnectionState: Codable, Equatable {
    var isConnected: Bool
    var accountEmail: String?
    var selectedCalendarIDs: Set<String>
    var lastErrorMessage: String?
    var health: GoogleCalendarHealth

    static let disconnected = GoogleCalendarConnectionState(isConnected: false, accountEmail: nil, selectedCalendarIDs: [], lastErrorMessage: nil)

    init(
        isConnected: Bool,
        accountEmail: String?,
        selectedCalendarIDs: Set<String>,
        lastErrorMessage: String?,
        health: GoogleCalendarHealth = .unknown
    ) {
        self.isConnected = isConnected
        self.accountEmail = accountEmail
        self.selectedCalendarIDs = selectedCalendarIDs
        self.lastErrorMessage = lastErrorMessage
        self.health = health
    }

    private enum CodingKeys: String, CodingKey {
        case isConnected
        case accountEmail
        case selectedCalendarIDs
        case lastErrorMessage
        case health
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isConnected = try container.decode(Bool.self, forKey: .isConnected)
        accountEmail = try container.decodeIfPresent(String.self, forKey: .accountEmail)
        selectedCalendarIDs = try container.decode(Set<String>.self, forKey: .selectedCalendarIDs)
        lastErrorMessage = try container.decodeIfPresent(String.self, forKey: .lastErrorMessage)
        health = try container.decodeIfPresent(GoogleCalendarHealth.self, forKey: .health) ?? .unknown
    }
}

struct GoogleCalendarConnectionMetadata: Codable, Equatable {
    static let storageKey = "google_calendar_connection_metadata"

    let accountEmail: String?

    func connectionState(selectedCalendarIDs: Set<String>) -> GoogleCalendarConnectionState {
        GoogleCalendarConnectionState(
            isConnected: true,
            accountEmail: accountEmail,
            selectedCalendarIDs: selectedCalendarIDs,
            lastErrorMessage: nil
        )
    }
}

struct GoogleCalendarConnectionControls: Equatable {
    let isConnected: Bool
    let isBusy: Bool
    let hasPendingOAuthConnection: Bool

    var primaryActionTitle: String {
        if hasPendingOAuthConnection { return "Cancel" }
        return isConnected ? "Reconnect" : "Connect"
    }

    var allowsPrimaryAction: Bool {
        hasPendingOAuthConnection || !isBusy
    }

    var allowsRefresh: Bool {
        isConnected && !isBusy
    }

    var allowsDisconnect: Bool {
        isConnected && !isBusy
    }
}

struct GoogleCalendarOAuthConfiguration: Equatable {
    let builtInClientID: String
    let builtInClientSecret: String

    private var trimmedBuiltInClientID: String {
        builtInClientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedBuiltInClientSecret: String {
        builtInClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var usesCustomCredentials: Bool { false }

    var clientID: String {
        trimmedBuiltInClientID
    }

    var clientSecret: String {
        guard isConfigured else { return "" }
        return trimmedBuiltInClientSecret
    }

    var isConfigured: Bool {
        !clientID.isEmpty
    }
}
