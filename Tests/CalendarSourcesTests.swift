import Foundation

@main
struct CalendarSourcesTests {
    static func main() throws {
        testMergeRemovesSameEventFromBothProvidersKeepingFirst()
        testMergeKeepsDifferentEventsAndSortsByStart()
        testMergeTreatsTitleCaseAndWhitespaceAsSame()
        testMergeKeepsSameTitleAtDifferentTimes()
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
}
