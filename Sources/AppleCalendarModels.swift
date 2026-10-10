import Foundation

/// Calendar access as Quill uses it. Write-only and restricted access count
/// as denied because Quill needs to read events.
enum AppleCalendarAuthorization: Equatable {
    case notDetermined
    case granted
    case denied
}

struct AppleCalendarInfo: Identifiable, Equatable {
    let id: String
    let title: String
    /// The account in the Mac Calendar app, such as iCloud or Exchange.
    let sourceTitle: String
    let colorHex: String?
}

struct AppleCalendarDisplayGroup: Equatable {
    let title: String
    let calendars: [AppleCalendarInfo]
}

extension Array where Element == AppleCalendarInfo {
    /// Groups calendars by account in the order the accounts first appear.
    func groupedBySource() -> [AppleCalendarDisplayGroup] {
        var order: [String] = []
        var bySource: [String: [AppleCalendarInfo]] = [:]
        for calendar in self {
            if bySource[calendar.sourceTitle] == nil {
                order.append(calendar.sourceTitle)
            }
            bySource[calendar.sourceTitle, default: []].append(calendar)
        }
        return order.map { source in
            AppleCalendarDisplayGroup(
                title: source,
                calendars: (bySource[source] ?? []).sorted {
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
            )
        }
    }
}

enum AppleParticipantResponse {
    case accepted
    case declined
    case tentative
    case pending
    case unknown
}

/// EventKit-free copy of an `EKParticipant`, so attendee mapping is testable.
struct AppleParticipantData {
    let name: String?
    let url: URL?
    let response: AppleParticipantResponse
    let isOptional: Bool
    let isCurrentUser: Bool

    /// Uses Google's response strings so the reminder rules apply unchanged.
    func attendee() -> CalendarEventAttendee {
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

enum AppleCalendarRowState: Equatable {
    case notConnected
    case needsAccess
    case connected(needsSelection: Bool)

    static func resolve(
        isEnabled: Bool,
        authorization: AppleCalendarAuthorization,
        selectedCount: Int
    ) -> AppleCalendarRowState {
        guard isEnabled else { return .notConnected }
        switch authorization {
        case .notDetermined:
            return .notConnected
        case .denied:
            return .needsAccess
        case .granted:
            return .connected(needsSelection: selectedCount == 0)
        }
    }
}

enum AppleCalendarSelection {
    /// Selected calendars the Mac Calendar app lists right now. Missing ones
    /// stay selected: a sync or a briefly disabled account can hide them.
    static func visible(_ selected: Set<String>, available: [AppleCalendarInfo]) -> [AppleCalendarInfo] {
        available.filter { selected.contains($0.id) }
    }
}

/// Text for a calendar source row: the selected calendar names beside the
/// source name, and the detail after its "Connected" label.
enum CalendarSelectionSummary {
    /// "(Personal, Work)" or "(Personal, Work and 2 more)"; `nil` when none
    /// is selected.
    static func names(_ names: [String], language: String = preferredLocalizedStringLanguage(), bundle: Bundle = .main) -> String? {
        switch names.count {
        case 0:
            return nil
        case 1, 2:
            return "(" + names.joined(separator: ", ") + ")"
        default:
            let shortened = localizedCatalogFormat(
                "%@, %@ and %lld more",
                names[0],
                names[1],
                Int64(names.count - 2),
                language: language,
                bundle: bundle
            )
            return "(" + shortened + ")"
        }
    }

    static func status(account: String?, hasSelection: Bool, checkedAt: Date?) -> String? {
        status(
            account: account,
            hasSelection: hasSelection,
            checkedTime: checkedAt.map { checkedTimeText($0) },
            language: preferredLocalizedStringLanguage(),
            bundle: .main
        )
    }

    /// The time alone for a check today; a check from another day shows
    /// its date too, so an old check doesn't read as today's.
    static func checkedTimeText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// "Last checked 2:30 PM · account", or the selection hint when nothing
    /// is selected yet.
    static func status(account: String?, hasSelection: Bool, checkedTime: String?, language: String, bundle: Bundle) -> String? {
        var parts: [String] = []
        if !hasSelection {
            parts.append(localizedCatalogString("Choose calendars to use", language: language, bundle: bundle))
        } else if let checkedTime, !checkedTime.isEmpty {
            parts.append(localizedCatalogFormat("Last checked %@", checkedTime, language: language, bundle: bundle))
        }
        if let account = account?.trimmingCharacters(in: .whitespacesAndNewlines), !account.isEmpty {
            parts.append(account)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum CalendarEventCollection {
    /// `nil` means that source is not in use. Note titles can use Apple
    /// events alone when Google fails (`toleratesGoogleFailure`); reminder
    /// scheduling cannot, because a partial list would remove reminders
    /// already scheduled for Google meetings.
    static func combine(
        google: Result<[CalendarEvent], Error>?,
        apple: [CalendarEvent]?,
        toleratesGoogleFailure: Bool
    ) throws -> [CalendarEvent] {
        var groups: [[CalendarEvent]] = []
        switch google {
        case .success(let events):
            groups.append(events)
        case .failure(let error):
            if apple == nil || !toleratesGoogleFailure { throw error }
        case nil:
            break
        }
        if let apple {
            groups.append(apple)
        }
        return CalendarEventMerger.merge(groups)
    }
}

enum CalendarReminderAvailability {
    /// Reminders and title matching need at least one source with selected
    /// calendars Quill can read.
    static func isAvailable(
        googleConnected: Bool,
        googleSelected: Int,
        appleRowState: AppleCalendarRowState,
        appleSelected: Int
    ) -> Bool {
        let google = googleConnected && googleSelected > 0
        let apple = appleRowState == .connected(needsSelection: false) && appleSelected > 0
        return google || apple
    }
}

/// macOS does not list an app under Privacy & Security › Calendars after the
/// person chooses Don't Allow, and it never shows the prompt again. Resetting
/// only Quill's own Calendar decision lets Quill ask once more.
enum AppleCalendarAccessReset {
    static let executablePath = "/usr/bin/tccutil"

    static func arguments(bundleID: String?) -> [String]? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return ["reset", "Calendar", bundleID]
    }

    /// Runs off the main thread; returns whether tccutil succeeded.
    static func run(bundleID: String? = Bundle.main.bundleIdentifier) async -> Bool {
        guard let arguments = arguments(bundleID: bundleID) else { return false }
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }
}

extension AppleCalendarAuthorization {
    /// macOS can keep reporting "not determined" in the same process after
    /// Quill resets its decision and the person declines again, so a
    /// declined request outranks that report.
    static func effective(reported: AppleCalendarAuthorization, lastRequestDeclined: Bool) -> AppleCalendarAuthorization {
        if reported == .notDetermined && lastRequestDeclined {
            return .denied
        }
        return reported
    }
}

enum GoogleCalendarAccount {
    /// The stored account email, or the primary calendar's ID (the account
    /// address) when an older connection saved no email.
    static func label(accountEmail: String?, calendars: [GoogleCalendarInfo]) -> String? {
        if let email = accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            return email
        }
        return calendars.first(where: \.primary)?.id
    }
}

/// Select All / Deselect All in the calendar selection sheet. Only listed
/// calendars change; choices for calendars hidden right now are kept.
enum CalendarBulkSelection {
    static func allSelected(_ selected: Set<String>, listed: [String]) -> Bool {
        !listed.isEmpty && listed.allSatisfy(selected.contains)
    }

    static func toggled(_ selected: Set<String>, listed: [String]) -> Set<String> {
        allSelected(selected, listed: listed)
            ? selected.subtracting(listed)
            : selected.union(listed)
    }
}

enum CalendarCheckTime {
    /// "Last checked" shows minutes, so updating more often only redraws
    /// views that observe app state.
    static func shouldUpdate(previous: Date?, now: Date) -> Bool {
        guard let previous else { return true }
        return Int(now.timeIntervalSince1970 / 60) != Int(previous.timeIntervalSince1970 / 60)
    }
}
