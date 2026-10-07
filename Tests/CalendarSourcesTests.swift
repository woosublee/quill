import Foundation

@main
struct CalendarSourcesTests {
    static func main() throws {
        testMergeRemovesSameEventFromBothProvidersKeepingFirst()
        testMergeKeepsDifferentEventsAndSortsByStart()
        testMergeTreatsTitleCaseAndWhitespaceAsSame()
        testMergeKeepsSameTitleAtDifferentTimes()
        testParticipantMapping()
        testRowState()
        testSelectionPrunesRemovedCalendars()
        testGroupsBySourceInFirstSeenOrder()
        testSelectionSummaryText()
        try testCombineKeepsAppleWhenGoogleFails()
        testReminderAvailability()
        print("CalendarSourcesTests passed")
    }

    static func event(_ id: String, _ title: String, _ start: TimeInterval, _ end: TimeInterval, provider: CalendarProvider, allDay: Bool = false, attendees: [CalendarEventAttendee] = []) -> CalendarEvent {
        CalendarEvent(id: id, calendarID: provider == .google ? "primary" : "A1B2-UUID", title: title,
                      start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end),
                      isAllDay: allDay, attendees: attendees, provider: provider)
    }

    /// The same Google account connected directly and through the Mac
    /// Calendar app must yield one reminder, keeping Google's attendees.
    static func testMergeRemovesSameEventFromBothProvidersKeepingFirst() {
        let google = event("g1", "Weekly sync", 1_000, 2_800, provider: .google,
                           attendees: [CalendarEventAttendee(displayName: "Mina", email: "mina@example.com")])
        let apple = event("a1", "Weekly sync", 1_000, 2_800, provider: .apple)
        let merged = CalendarEventMerger.merge([[google], [apple]])
        precondition(merged.count == 1)
        precondition(merged[0].provider == .google)
        precondition(merged[0].attendees.count == 1)
    }

    static func testMergeKeepsDifferentEventsAndSortsByStart() {
        let later = event("g2", "Retro", 5_000, 6_000, provider: .google)
        let earlier = event("a2", "Dentist", 1_000, 2_000, provider: .apple)
        let merged = CalendarEventMerger.merge([[later], [earlier]])
        precondition(merged.map(\.id) == ["a2", "g2"])
    }

    static func testMergeTreatsTitleCaseAndWhitespaceAsSame() {
        let google = event("g3", "Design Review ", 1_000, 2_000, provider: .google)
        let apple = event("a3", "design review", 1_000, 2_000, provider: .apple)
        precondition(CalendarEventMerger.merge([[google], [apple]]).count == 1)
    }

    static func testMergeKeepsSameTitleAtDifferentTimes() {
        let morning = event("g4", "Standup", 1_000, 1_900, provider: .google)
        let tomorrow = event("a4", "Standup", 87_400, 88_300, provider: .apple)
        precondition(CalendarEventMerger.merge([[morning], [tomorrow]]).count == 2)
    }

    static func testParticipantMapping() {
        let me = AppleParticipantData(name: "Woo", url: URL(string: "mailto:me@example.com"), response: .declined, isOptional: false, isCurrentUser: true)
        let a = me.attendee()
        precondition(a.email == "me@example.com" && a.responseStatus == "declined" && a.isSelf && a.displayName == "Woo")
        let room = AppleParticipantData(name: nil, url: URL(string: "https://example.com/room"), response: .pending, isOptional: true, isCurrentUser: false)
        let r = room.attendee()
        precondition(r.email == nil && r.responseStatus == "needsAction" && r.isOptional && r.displayName == nil)
        precondition(AppleParticipantData(name: "X", url: nil, response: .unknown, isOptional: false, isCurrentUser: false).attendee().responseStatus == nil)
    }

    static func testRowState() {
        precondition(AppleCalendarRowState.resolve(isEnabled: false, authorization: .granted, selectedCount: 2) == .notConnected)
        precondition(AppleCalendarRowState.resolve(isEnabled: true, authorization: .denied, selectedCount: 2) == .needsAccess)
        precondition(AppleCalendarRowState.resolve(isEnabled: true, authorization: .notDetermined, selectedCount: 0) == .notConnected)
        precondition(AppleCalendarRowState.resolve(isEnabled: true, authorization: .granted, selectedCount: 0) == .connected(needsSelection: true))
        precondition(AppleCalendarRowState.resolve(isEnabled: true, authorization: .granted, selectedCount: 1) == .connected(needsSelection: false))
    }

    static func testSelectionPrunesRemovedCalendars() {
        let available = [AppleCalendarInfo(id: "A", title: "Personal", sourceTitle: "iCloud", colorHex: nil)]
        precondition(AppleCalendarSelection.pruned(["A", "GONE"], available: available) == ["A"])
    }

    static func testGroupsBySourceInFirstSeenOrder() {
        let calendars = [
            AppleCalendarInfo(id: "1", title: "Work", sourceTitle: "Exchange", colorHex: nil),
            AppleCalendarInfo(id: "2", title: "Personal", sourceTitle: "iCloud", colorHex: nil),
            AppleCalendarInfo(id: "3", title: "Family", sourceTitle: "iCloud", colorHex: nil),
        ]
        let groups = calendars.groupedBySource()
        precondition(groups.map(\.title) == ["Exchange", "iCloud"])
        precondition(groups[1].calendars.map(\.title) == ["Family", "Personal"])
    }

    static func testSelectionSummaryText() {
        let bundle = Bundle.main
        precondition(CalendarSelectionSummary.text(names: [], language: "en", bundle: bundle) == "Choose calendars to use")
        precondition(CalendarSelectionSummary.text(names: ["Personal"], language: "en", bundle: bundle) == "Personal")
        precondition(CalendarSelectionSummary.text(names: ["Personal", "Work"], language: "en", bundle: bundle) == "Personal, Work")
        precondition(CalendarSelectionSummary.text(names: ["Personal", "Work", "Family", "Gym"], language: "en", bundle: bundle) == "Personal, Work and 2 more")
    }

    struct FetchFailure: Error {}

    /// A Google token that needs reconnecting must not stop Apple events
    /// from driving reminders and note titles.
    static func testCombineKeepsAppleWhenGoogleFails() throws {
        let apple = [event("a5", "Sync", 1_000, 2_000, provider: .apple)]
        let combined = try CalendarEventCollection.combine(google: .failure(FetchFailure()), apple: apple)
        precondition(combined.map(\.id) == ["a5"])
        do {
            _ = try CalendarEventCollection.combine(google: .failure(FetchFailure()), apple: nil)
            preconditionFailure("Google-only failure must still throw")
        } catch is FetchFailure {}
        let none = try CalendarEventCollection.combine(google: nil, apple: nil)
        precondition(none.isEmpty)
        let google = [event("g5", "Sync", 1_000, 2_000, provider: .google)]
        let both = try CalendarEventCollection.combine(google: .success(google), apple: apple)
        precondition(both.map(\.id) == ["g5"])
    }

    static func testReminderAvailability() {
        precondition(!CalendarReminderAvailability.isAvailable(googleConnected: false, googleSelected: 0, appleRowState: .notConnected, appleSelected: 0))
        precondition(CalendarReminderAvailability.isAvailable(googleConnected: true, googleSelected: 1, appleRowState: .notConnected, appleSelected: 0))
        precondition(CalendarReminderAvailability.isAvailable(googleConnected: false, googleSelected: 0, appleRowState: .connected(needsSelection: false), appleSelected: 2))
        precondition(!CalendarReminderAvailability.isAvailable(googleConnected: false, googleSelected: 0, appleRowState: .needsAccess, appleSelected: 2))
        precondition(!CalendarReminderAvailability.isAvailable(googleConnected: true, googleSelected: 0, appleRowState: .connected(needsSelection: true), appleSelected: 0))
    }
}
