import CoreGraphics
import EventKit
import Foundation

/// Read-only access to the Mac Calendar app. Quill never creates or edits
/// events. Logs must not include titles, attendees, or calendar names.
/// All EventKit calls stay on the main actor so one store is never used
/// from two threads at once.
@MainActor
final class AppleCalendarService {
    private(set) var store = EKEventStore()

    /// A store created before access was granted keeps returning no
    /// calendars, so Quill makes a new one when access changes.
    func resetStore() {
        store = EKEventStore()
    }

    nonisolated static func authorization() -> AppleCalendarAuthorization {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            switch status {
            case .fullAccess: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied // write-only, denied, restricted
            }
        }
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func requestAccess() async -> Bool {
        do {
            if #available(macOS 14.0, *) {
                return try await store.requestFullAccessToEvents()
            }
            return try await store.requestAccess(to: .event)
        } catch {
            return false
        }
    }

    func calendars() -> [AppleCalendarInfo] {
        guard Self.authorization() == .granted else { return [] }
        return store.calendars(for: .event).map { calendar in
            AppleCalendarInfo(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                sourceTitle: calendar.source?.title ?? "",
                colorHex: calendar.cgColor.flatMap(Self.hex)
            )
        }
    }

    func events(calendarIDs: Set<String>, from start: Date, to end: Date) -> [CalendarEvent] {
        guard Self.authorization() == .granted, !calendarIDs.isEmpty, end > start else { return [] }
        let calendars = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).map { event in
            CalendarEvent(
                // Occurrences of a repeating event share the item identifier.
                id: "\(event.calendarItemIdentifier)@\(Int(event.startDate.timeIntervalSince1970))",
                calendarID: event.calendar.calendarIdentifier,
                title: event.title ?? "",
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                attendees: (event.attendees ?? []).map { Self.participantData($0).attendee() },
                provider: .apple
            )
        }
    }

    private static func participantData(_ participant: EKParticipant) -> AppleParticipantData {
        let response: AppleParticipantResponse = switch participant.participantStatus {
        case .accepted: .accepted
        case .declined: .declined
        case .tentative: .tentative
        case .pending: .pending
        default: .unknown
        }
        return AppleParticipantData(
            name: participant.name,
            url: participant.url,
            response: response,
            isOptional: participant.participantRole == .optional,
            isCurrentUser: participant.isCurrentUser
        )
    }

    private static func hex(_ color: CGColor) -> String? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let components = converted.components,
              components.count >= 3 else {
            return nil
        }
        return String(
            format: "#%02X%02X%02X",
            Int((components[0] * 255).rounded()),
            Int((components[1] * 255).rounded()),
            Int((components[2] * 255).rounded())
        )
    }
}
