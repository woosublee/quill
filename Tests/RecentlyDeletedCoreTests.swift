import Foundation

@main
struct RecentlyDeletedCoreTests {
    static func main() throws {
        testNewNoteStampsEveryGroup()
        testLegacyNoteStartsFromItsTimestamp()
        testOnlyChangedGroupsMoveForward()
        testClockRoundTripsThroughJSON()
        testExpiryBoundary()
        testDaysLeftCountsWholeDaysUp()
        testPartitionSplitsAndOrdersDeletedNewestFirst()
        print("RecentlyDeletedCoreTests passed")
    }

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func item(
        id: UUID = UUID(),
        title: String? = nil,
        raw: String = "synthetic raw",
        edited: String = "synthetic edited",
        timestamp: Date = t0,
        deletedAt: Date? = nil
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: id,
            timestamp: timestamp,
            rawTranscript: raw,
            postProcessedTranscript: edited,
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "succeeded",
            debugStatus: "",
            customVocabulary: "",
            customTitle: title,
            deletedAt: deletedAt
        )
    }

    private static func testNewNoteStampsEveryGroup() {
        let now = t0.addingTimeInterval(10)
        let clock = NoteFieldClock.stamped(previous: nil, current: item(), existing: nil, now: now)
        for group in NoteFieldGroup.allCases {
            precondition(clock.stamp(for: group) == now, "new note stamps \(group)")
        }
    }

    private static func testLegacyNoteStartsFromItsTimestamp() {
        let old = item(title: "Before")
        let new = item(id: old.id, title: "After")
        let now = t0.addingTimeInterval(100)
        let clock = NoteFieldClock.stamped(previous: old, current: new, existing: nil, now: now)
        precondition(clock.stamp(for: .title) == now)
        precondition(clock.stamp(for: .rawTranscript) == t0, "unchanged groups keep the note's timestamp")
    }

    private static func testOnlyChangedGroupsMoveForward() {
        let old = item(title: "A", edited: "one")
        let new = item(id: old.id, title: "A", edited: "two")
        precondition(NoteFieldClock.changedGroups(from: old, to: new) == [.editedTranscript])
        let existing = NoteFieldClock.uniform(t0)
        let now = t0.addingTimeInterval(5)
        let clock = NoteFieldClock.stamped(previous: old, current: new, existing: existing, now: now)
        precondition(clock.stamp(for: .editedTranscript) == now)
        precondition(clock.stamp(for: .title) == t0)
        precondition(clock.stamp(for: .deletion) == t0, "deletion is never stamped by an ordinary save")
    }

    private static func testClockRoundTripsThroughJSON() {
        let clock = NoteFieldClock.uniform(t0).setting(.summary, to: t0.addingTimeInterval(1))
        let data = try! JSONEncoder().encode(clock)
        let decoded = try! JSONDecoder().decode(NoteFieldClock.self, from: data)
        precondition(decoded == clock)
    }

    private static func testExpiryBoundary() {
        let deletedAt = t0
        let exactly = deletedAt.addingTimeInterval(RecentlyDeletedPolicy.retention)
        precondition(RecentlyDeletedPolicy.isExpired(deletedAt: deletedAt, now: exactly))
        precondition(!RecentlyDeletedPolicy.isExpired(deletedAt: deletedAt, now: exactly.addingTimeInterval(-60)))
        precondition(RecentlyDeletedPolicy.retention == 30 * 24 * 60 * 60)
    }

    private static func testDaysLeftCountsWholeDaysUp() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        precondition(RecentlyDeletedPolicy.daysLeft(deletedAt: t0, now: t0, calendar: calendar) == 30)
        precondition(RecentlyDeletedPolicy.daysLeft(deletedAt: t0, now: t0.addingTimeInterval(29 * 86_400 + 60), calendar: calendar) == 1)
        precondition(RecentlyDeletedPolicy.daysLeft(deletedAt: t0, now: t0.addingTimeInterval(31 * 86_400), calendar: calendar) == 0)
    }

    private static func testPartitionSplitsAndOrdersDeletedNewestFirst() {
        let live = item()
        let older = item(deletedAt: t0.addingTimeInterval(10))
        let newer = item(deletedAt: t0.addingTimeInterval(20))
        let result = RecentlyDeletedPolicy.partition([live, older, newer])
        precondition(result.live.map(\.id) == [live.id])
        precondition(result.deleted.map(\.id) == [newer.id, older.id])
    }
}
