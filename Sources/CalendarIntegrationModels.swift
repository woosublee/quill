import Foundation

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case models
    case prompts
    case shortcuts
    case input
    case calendar
    case sync
    case recovery
    case about
    case runLog
    case debug

    var id: String { rawValue }

    static var orderedCases: [SettingsTab] {
        [.general, .appearance, .models, .prompts, .shortcuts, .input, .calendar, .sync, .recovery, .about, .runLog, .debug]
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .models: return "Models"
        case .prompts: return "Prompts"
        case .shortcuts: return "Shortcuts"
        case .input: return "Input"
        case .calendar: return "Calendar"
        case .sync: return "iCloud Sync"
        case .recovery: return "Recovery"
        case .about: return "About"
        case .runLog: return "Run Log"
        case .debug: return "Debug"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .models: return "waveform.badge.magnifyingglass"
        case .prompts: return "text.bubble"
        case .shortcuts: return "keyboard.fill"
        case .input: return "mic.fill"
        case .calendar: return "calendar"
        case .sync: return "icloud"
        case .recovery: return "arrow.counterclockwise"
        case .about: return "info.circle"
        case .runLog: return "clock.arrow.circlepath"
        case .debug: return "wrench.and.screwdriver"
        }
    }
}

enum CalendarProvider: String, Codable, Equatable, CaseIterable {
    case google
    case apple
}

extension CalendarProvider: Identifiable {
    var id: String { rawValue }
}

enum CalendarMatchSource: String, Codable, Equatable {
    case overlapSuggestion = "overlap_suggestion"
    case calendarNotification = "calendar_notification"
    case importSelection = "import_selection"
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
    /// Missing in notes saved before Apple Calendar support; those are Google.
    let provider: CalendarProvider?

    init(accountID: String? = nil, calendarID: String, eventID: String, title: String, start: Date, end: Date, attendees: [CalendarEventAttendee] = [], matchSource: CalendarMatchSource, titleState: CalendarTitleState, provider: CalendarProvider? = nil) {
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

    var resolvedProvider: CalendarProvider { provider ?? .google }

    var suggestedTitle: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var appliedTitle: String? {
        guard titleState == .applied else { return nil }
        return suggestedTitle
    }

    func applyingTitle() -> CalendarEventMatch {
        CalendarEventMatch(accountID: accountID, calendarID: calendarID, eventID: eventID, title: title, start: start, end: end, attendees: attendees, matchSource: matchSource, titleState: .applied, provider: provider)
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

struct CalendarEvent: Identifiable, Equatable {
    let id: String
    let calendarID: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let attendees: [CalendarEventAttendee]
    let provider: CalendarProvider

    init(
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

    var hasUsableTitle: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func match(accountID: String?, source: CalendarMatchSource, titleState: CalendarTitleState) -> CalendarEventMatch {
        CalendarEventMatch(accountID: accountID, calendarID: calendarID, eventID: id, title: title, start: start, end: end, attendees: attendees, matchSource: source, titleState: titleState, provider: provider)
    }
}

enum GoogleCalendarHealthStatus: String, Codable, Equatable {
    case unknown
    case healthy
    case needsReconnect
    case temporaryFailure
    /// The Mac has no network; checked again when it comes back.
    case offline
}

/// Why a Google Calendar request failed, so being offline, or a refresh
/// replaced by a newer one, doesn't read as a Google problem.
enum GoogleCalendarFetchFailure: Equatable {
    case cancelled
    case offline
    case failed

    /// `isOnline` is the network monitor's view: a timeout or a missing
    /// host while it says offline is the network, otherwise the server.
    static func of(_ error: Error, isOnline: Bool) -> GoogleCalendarFetchFailure {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return .offline
            default:
                break
            }
        }
        return isOnline ? .failed : .offline
    }
}

/// Google events from the last reminder refresh. A refresh caused only by
/// an Apple Calendar change reuses them instead of asking Google again.
struct GoogleReminderEventsCache: Equatable {
    let fetchedAt: Date
    let events: [CalendarEvent]

    /// The cached events in the window, or nil when they are too old.
    func events(from start: Date, to end: Date, now: Date, maxAge: TimeInterval) -> [CalendarEvent]? {
        let age = now.timeIntervalSince(fetchedAt)
        guard age >= 0, age <= maxAge else { return nil }
        return events.filter { $0.end > start && $0.start < end }
    }
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

extension CalendarEvent {
    /// A timed, titled event the person has not declined.
    var isMeetingCandidate: Bool {
        guard !isAllDay, hasUsableTitle, end > start else { return false }
        return !attendees.contains { $0.isSelf && $0.responseStatus == "declined" }
    }
}
