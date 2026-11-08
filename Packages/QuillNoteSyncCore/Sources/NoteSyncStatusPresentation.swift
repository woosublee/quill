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

/// What the sync status line shows while sync is on, in one fixed order on
/// both apps (the owner's 2026-11-08 decision y2, the iPhone's order): a
/// full iCloud > an account to look at > offline > notes that couldn't sync
/// > recordings waiting for Wi-Fi > uploading > a fetch that failed > up to
/// date. The first three follow `NoteSyncProblem`. A device passes only what
/// it has (the Mac never waits for Wi-Fi).
public enum NoteSyncLine: Equatable, Sendable {
    case storageFull
    case accountNeedsAttention
    case offline
    case notesFailed(Int)
    case waitingForWiFi(Int)
    case uploading(done: Int, total: Int)
    /// The last fetch couldn't reach iCloud.
    case couldNotReachICloud
    /// iCloud refused the last fetch for another reason.
    case couldNotSync
    /// Up to date; nil before the first sync finishes.
    case upToDate(Date?)

    /// Why the last fetch failed.
    public enum FetchFailure: Equatable, Sendable {
        case network
        case account
        case storageFull
        case other
    }

    /// A fetch failure shows behind uploads that are still going up; with no
    /// upload since it failed, it shows first. A fetch refused for the
    /// account or for space shows that notice.
    public static func make(
        accountNeedsAttention: Bool,
        isOnline: Bool,
        isStorageFull: Bool,
        failingNotes: Int,
        waitingForWiFi: Int = 0,
        pendingUploads: Int,
        uploadTotal: Int,
        fetchFailure: FetchFailure? = nil,
        uploadsMovedSinceFetchFailure: Bool = false,
        lastSynced: Date?
    ) -> Self {
        switch NoteSyncProblem.mostUrgent(
            storageFull: isStorageFull || fetchFailure == .storageFull,
            accountNeedsAttention: accountNeedsAttention || fetchFailure == .account,
            offline: !isOnline
        ) {
        case .storageFull?: return .storageFull
        case .accountNeedsAttention?: return .accountNeedsAttention
        case .offline?: return .offline
        case nil: break
        }
        if failingNotes > 0 { return .notesFailed(failingNotes) }
        if waitingForWiFi > 0 { return .waitingForWiFi(waitingForWiFi) }
        let fetchLine: Self? = switch fetchFailure {
        case .network?: .couldNotReachICloud
        case .other?: .couldNotSync
        case .account?, .storageFull?, nil: nil
        }
        if pendingUploads > 0 {
            if let fetchLine, !uploadsMovedSinceFetchFailure { return fetchLine }
            let total = max(uploadTotal, pendingUploads)
            return .uploading(done: total - pendingUploads, total: total)
        }
        if let fetchLine { return fetchLine }
        return .upToDate(lastSynced)
    }

    /// Whether the line draws as a warning. Offline isn't one: notes still
    /// work, and sync goes on by itself when the network is back (decision
    /// y1, the Mac's grey line).
    public var isWarning: Bool {
        switch self {
        case .storageFull, .accountNeedsAttention, .notesFailed, .couldNotReachICloud, .couldNotSync: true
        case .offline, .waitingForWiFi, .uploading, .upToDate: false
        }
    }
}
