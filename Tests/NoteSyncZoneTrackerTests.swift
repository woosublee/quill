import Foundation

@main
struct NoteSyncZoneTrackerTests {
    static func main() {
        testFreshStartIgnoresDeletionHistoryOnFirstFetch()
        testFreshStartRecreatesZoneDeletedBeforeTurningOn()
        testRunningSyncTreatsDeletionAsDeletedElsewhere()
        print("NoteSyncZoneTrackerTests passed")
    }

    /// Turning sync on again after deleting from iCloud on this Mac: the
    /// first fetch reports that old deletion, which must not stop sync.
    static func testFreshStartIgnoresDeletionHistoryOnFirstFetch() {
        var tracker = NoteSyncZoneTracker(startedFresh: true)
        precondition(!tracker.zoneDeletionMeansDeletedElsewhere, "a fresh start's first fetch is history")
        tracker.firstFetchFinished()
        precondition(tracker.zoneDeletionMeansDeletedElsewhere, "later deletions come from another Mac")
    }

    static func testFreshStartRecreatesZoneDeletedBeforeTurningOn() {
        var tracker = NoteSyncZoneTracker(startedFresh: true)
        precondition(tracker.recreatesZoneAfterUserDeletedZone, "turning sync on again means using iCloud again")
        tracker.zoneSaved()
        precondition(!tracker.recreatesZoneAfterUserDeletedZone, "once saved, a later user deletion is another Mac's choice")
    }

    static func testRunningSyncTreatsDeletionAsDeletedElsewhere() {
        let tracker = NoteSyncZoneTracker(startedFresh: false)
        precondition(tracker.zoneDeletionMeansDeletedElsewhere)
        precondition(!tracker.recreatesZoneAfterUserDeletedZone)
    }
}
