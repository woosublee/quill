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
            guard let url, url.scheme?.lowercased() == "mailto" else { return nil }
            let address = String(url.absoluteString.dropFirst("mailto:".count))
            return address.isEmpty ? nil : address
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
    /// Drops calendars that were removed from the Mac Calendar app.
    static func pruned(_ selected: Set<String>, available: [AppleCalendarInfo]) -> Set<String> {
        selected.intersection(available.map(\.id))
    }
}

enum CalendarSelectionSummary {
    static func text(names: [String]) -> String {
        text(names: names, language: preferredLocalizedStringLanguage(), bundle: .main)
    }

    static func text(names: [String], language: String, bundle: Bundle) -> String {
        switch names.count {
        case 0:
            return localizedCatalogString("Choose calendars to use", language: language, bundle: bundle)
        case 1:
            return names[0]
        case 2:
            return localizedCatalogFormat("%@, %@", names[0], names[1], language: language, bundle: bundle)
        default:
            return localizedCatalogFormat(
                "%@, %@ and %lld more",
                names[0],
                names[1],
                Int64(names.count - 2),
                language: language,
                bundle: bundle
            )
        }
    }
}

enum CalendarEventCollection {
    /// `nil` means that source is not in use. One failing source does not
    /// drop the other; a Google error surfaces only when Google is the only
    /// source in use.
    static func combine(
        google: Result<[CalendarEvent], Error>?,
        apple: [CalendarEvent]?
    ) throws -> [CalendarEvent] {
        var groups: [[CalendarEvent]] = []
        switch google {
        case .success(let events):
            groups.append(events)
        case .failure(let error):
            if apple == nil { throw error }
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
