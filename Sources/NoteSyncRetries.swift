import Foundation

/// Changes that failed to send, each tried again after a wait that grows
/// with every failure: 1, 5, then 30 minutes. One that fails again after
/// that is given up until its note changes, Sync Now, or a relaunch. A
/// change that keeps trying (waiting for iCloud space, or for the store to
/// be read) waits at most 30 minutes and is never given up.
struct NoteSyncRetries<Key: Hashable> {
    static var delays: [TimeInterval] { [60, 5 * 60, 30 * 60] }

    private var failures: [Key: Int] = [:]
    private var due: [Key: Date] = [:]
    private var keepsTrying: Set<Key> = []
    private(set) var givenUp: Set<Key> = []

    /// Keys waiting for their next try.
    var waiting: Set<Key> { Set(due.keys) }
    /// Waiting keys that are never given up.
    var waitingToKeepTrying: Set<Key> { waiting.intersection(keepsTrying) }
    /// Keys that failed and may be given up: waiting or given up already.
    var failing: Set<Key> { waiting.subtracting(keepsTrying).union(givenUp) }

    mutating func failed(_ key: Key, at now: Date, keepTrying: Bool = false) {
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
    mutating func takeDue(at now: Date) -> [Key] {
        let ready = due.filter { $0.value <= now }.map(\.key)
        for key in ready { due[key] = nil }
        return ready
    }

    /// Went through, or isn't needed any more: tries start over.
    mutating func forget(_ key: Key) {
        failures[key] = nil
        due[key] = nil
        keepsTrying.remove(key)
        givenUp.remove(key)
    }

    mutating func forget(where shouldForget: (Key) -> Bool) {
        for key in Set(failures.keys).union(due.keys).union(givenUp) where shouldForget(key) {
            forget(key)
        }
    }

    /// Sync Now: everything waiting or given up is due now, with its tries
    /// started over.
    mutating func retryAll(at now: Date) {
        for key in waiting.union(givenUp) { due[key] = now }
        failures = [:]
        givenUp = []
    }
}
