import Foundation

/// Changes that failed to send, each tried again after a wait that grows
/// with every failure: 1, 5, then 30 minutes. One that fails again after
/// that is given up until its note changes, Sync Now, or a relaunch. A
/// change that keeps trying (waiting for iCloud space, a delete, or one
/// waiting for the store to be read) waits at most 30 minutes and is never
/// given up.
public struct NoteSyncRetries<Key: Hashable> {
    public static var delays: [TimeInterval] { [60, 5 * 60, 30 * 60] }

    private var failures: [Key: Int] = [:]
    private var due: [Key: Date] = [:]
    private var keepsTrying: Set<Key> = []
    public private(set) var givenUp: Set<Key> = []

    public init() {}

    /// Keys waiting for their next try.
    public var waiting: Set<Key> { Set(due.keys) }

    /// When the next retry is due, or nil when nothing waits.
    public var nextDue: Date? { due.values.min() }
    /// Waiting keys not shown as failing: ones that keep trying, and ones
    /// that failed only once (the next try usually works).
    public var waitingQuietly: Set<Key> {
        waiting.filter { keepsTrying.contains($0) || failures[$0] == 1 }
    }
    /// Keys that failed more than once and will be tried again.
    public var failingToRetry: Set<Key> { waiting.subtracting(waitingQuietly) }
    /// Keys shown as failing: tried again or given up already.
    public var failing: Set<Key> { failingToRetry.union(givenUp) }
    /// Every key that failed and hasn't been forgotten: waiting, given up,
    /// or sent again and not confirmed yet.
    public var unconfirmed: Set<Key> { Set(failures.keys) }

    public mutating func failed(_ key: Key, at now: Date, keepTrying: Bool = false) {
        // Tries of the other kind don't count: a note that waited for space
        // gets its own tries once it fails for another reason.
        if keepsTrying.contains(key) != keepTrying { failures[key] = nil }
        givenUp.remove(key)
        let count = (failures[key] ?? 0) + 1
        failures[key] = count
        let delays = Self.delays
        if keepTrying {
            keepsTrying.insert(key)
        } else {
            keepsTrying.remove(key)
            if count > delays.count {
                due[key] = nil
                givenUp.insert(key)
                return
            }
        }
        due[key] = now.addingTimeInterval(delays[min(count, delays.count) - 1])
    }

    /// The keys whose wait is over; they're no longer waiting, but a next
    /// failure still counts the earlier ones.
    public mutating func takeDue(at now: Date) -> [Key] {
        let ready = due.filter { $0.value <= now }.map(\.key)
        for key in ready { due[key] = nil }
        return ready
    }

    /// Sent and not confirmed yet (a change kept from the last run), without
    /// a failure to count or wait for.
    public mutating func remember(_ key: Key) {
        if failures[key] == nil { failures[key] = 0 }
    }

    /// Went through, or isn't needed any more: tries start over.
    public mutating func forget(_ key: Key) {
        failures[key] = nil
        due[key] = nil
        keepsTrying.remove(key)
        givenUp.remove(key)
    }

    public mutating func forget(where shouldForget: (Key) -> Bool) {
        for key in Set(failures.keys).union(due.keys).union(givenUp) where shouldForget(key) {
            forget(key)
        }
    }

    /// Sync Now: every key not confirmed yet (waiting, given up, or kept
    /// from the last run) is due now, with its tries started over. Every
    /// key stays until it goes through.
    public mutating func retryAll(at now: Date) {
        for key in failures.keys {
            due[key] = now
            failures[key] = 0
        }
        givenUp = []
    }
}
