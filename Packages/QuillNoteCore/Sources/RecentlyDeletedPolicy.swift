import Foundation

/// How long deleted notes stay in Recently Deleted, and the days a row
/// shows, the same on the Mac and the iPhone
/// (woosublee/quill-universal-private#282). Each app keeps its own note
/// list and the split between live and deleted notes.
public enum RecentlyDeletedPolicy {
    public static let retention: TimeInterval = 30 * 24 * 60 * 60

    public static func expiry(deletedAt: Date) -> Date {
        deletedAt.addingTimeInterval(retention)
    }

    public static func isExpired(deletedAt: Date, now: Date) -> Bool {
        now >= expiry(deletedAt: deletedAt)
    }

    /// Whole days left, rounded up, so a note with 29 days and an hour left
    /// shows 30 and one about to expire shows 1.
    public static func daysLeft(deletedAt: Date, now: Date) -> Int {
        let remaining = expiry(deletedAt: deletedAt).timeIntervalSince(now)
        guard remaining > 0 else { return 0 }
        return Int((remaining / 86_400).rounded(.up))
    }

    /// The days a row shows. With sync on, an expired note still here waits
    /// for iCloud to confirm it can go (#562), so it shows its last day, not 0.
    public static func daysShown(deletedAt: Date, now: Date, isWaitingForSync: Bool) -> Int {
        let left = daysLeft(deletedAt: deletedAt, now: now)
        return left == 0 && isWaitingForSync ? 1 : left
    }
}
