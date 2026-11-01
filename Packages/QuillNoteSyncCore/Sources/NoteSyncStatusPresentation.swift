import Foundation

/// A sync problem the status line can show while sync stays on, ranked the
/// same on the Mac and the iPhone (#283): a full iCloud outranks an account
/// to look at, which outranks being offline. Earlier cases outrank later
/// ones.
public enum NoteSyncProblem: Int, CaseIterable, Comparable, Sendable {
    case storageFull
    case accountNeedsAttention
    case offline

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Whether this problem should stay on screen instead of `other`.
    /// Offline never replaces a full iCloud or an account to look at:
    /// coming back online would clear a notice that still applies.
    public func outranks(_ other: Self) -> Bool {
        self < other
    }

    /// The problem to show when several apply at once, or nil when none do.
    public static func mostUrgent(
        storageFull: Bool,
        accountNeedsAttention: Bool,
        offline: Bool
    ) -> Self? {
        if storageFull { return .storageFull }
        if accountNeedsAttention { return .accountNeedsAttention }
        if offline { return .offline }
        return nil
    }

    /// The status line's copy key. Each app looks it up in its own String
    /// Catalog; the detail line under it names the device, so it stays in
    /// each app.
    public var copyKey: String {
        switch self {
        case .storageFull: "iCloud storage is full, so uploads are paused"
        case .accountNeedsAttention: "iCloud account needs attention"
        case .offline: "Paused · Syncs again when you're online"
        }
    }
}

/// How the sync status line reads, shared by the Mac and the iPhone (#283).
public enum NoteSyncStatusPresentation {
    /// The copy key for a sync that finished within the last minute.
    public static let justNowKey = "Just now"

    /// `justNow` for the first minute, then "3 min. ago" and so on in
    /// `locale`, which should be the app's chosen language rather than the
    /// system's, so the time reads in the same language as the text around
    /// it. A sync that just finished never reads "in 0 seconds", and a
    /// clock set back never reads "in 10 minutes".
    public static func relativeTime(_ date: Date, now: Date, locale: Locale, justNow: String) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return justNow }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
