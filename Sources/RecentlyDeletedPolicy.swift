import Foundation

/// How long deleted notes stay in Recently Deleted, and how rows split
/// between the note list and Recently Deleted.
enum RecentlyDeletedPolicy {
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    static func expiry(deletedAt: Date) -> Date {
        deletedAt.addingTimeInterval(retention)
    }

    static func isExpired(deletedAt: Date, now: Date) -> Bool {
        now >= expiry(deletedAt: deletedAt)
    }

    /// Whole days left, rounded up, so a note with 29 days and an hour left
    /// shows 30 and one about to expire shows 1.
    static func daysLeft(deletedAt: Date, now: Date) -> Int {
        let remaining = expiry(deletedAt: deletedAt).timeIntervalSince(now)
        guard remaining > 0 else { return 0 }
        return Int((remaining / 86_400).rounded(.up))
    }

    /// The days a row shows. An expired note still here waits for sync to
    /// fetch before it is purged (#562), so it shows its last day, not 0.
    static func daysShown(deletedAt: Date, now: Date, isWaitingForSync: Bool) -> Int {
        let left = daysLeft(deletedAt: deletedAt, now: now)
        return left == 0 && isWaitingForSync ? 1 : left
    }

    /// Live notes keep their order. Deleted notes are newest deletion first.
    static func partition(
        _ items: [PipelineHistoryItem]
    ) -> (live: [PipelineHistoryItem], deleted: [PipelineHistoryItem]) {
        let live = items.filter { $0.deletedAt == nil }
        let deleted = items
            .filter { $0.deletedAt != nil }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        return (live, deleted)
    }
}
