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

/// The detail after a source's "Connected" label:
/// "account (Calendar, Calendar) · Last checked 2:30 PM".
enum CalendarSelectionSummary {
    static func text(account: String?, names: [String], checkedAt: Date?) -> String {
        text(
            account: account,
            names: names,
            checkedTime: checkedAt?.formatted(date: .omitted, time: .shortened),
            language: preferredLocalizedStringLanguage(),
            bundle: .main
        )
    }

    static func text(account: String?, names: [String], checkedTime: String?, language: String, bundle: Bundle) -> String {
        var parts: [String] = []
        let account = account?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if names.isEmpty {
            if !account.isEmpty { parts.append(account) }
            parts.append(localizedCatalogString("Choose calendars to use", language: language, bundle: bundle))
        } else {
            let list = "(" + names.joined(separator: ", ") + ")"
            parts.append(account.isEmpty ? list : "\(account) \(list)")
        }
        if let checkedTime, !checkedTime.isEmpty {
            parts.append(localizedCatalogFormat("Last checked %@", checkedTime, language: language, bundle: bundle))
        }
        return parts.joined(separator: " · ")
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
