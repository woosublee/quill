import Foundation

@main
struct NoteSyncZoneTrackerTests {
    static func main() throws {
        try testTurnOnRecreatesDeletedZoneUntilItIsSaved()
        try testTurnOnSurvivesRelaunch()
        try testRestartWithoutTurnOnTreatsDeletionAsDeletedElsewhere()
        print("NoteSyncZoneTrackerTests passed")
    }

    static func makeMarkerURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-zone-tracker-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("awaiting-zone")
    }

    /// Turning sync on again after deleting from iCloud on this Mac: a
    /// deletion reported before the zone is saved again is that old one.
    static func testTurnOnRecreatesDeletedZoneUntilItIsSaved() throws {
        let marker = makeMarkerURL()
        defer { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }
        let tracker = NoteSyncZoneTracker(markerURL: marker)
        tracker.turnedOnByUser()
        precondition(tracker.actionForZoneDeletion == .recreateAndUploadAll, "turning sync on means using iCloud again")
        tracker.zoneSaved()
        precondition(tracker.actionForZoneDeletion == .stopSync, "once saved, a later deletion is another Mac's choice")
    }

    /// Quitting before the zone is saved again must not turn the old
    /// deletion into "deleted from another Mac" on the next launch.
    static func testTurnOnSurvivesRelaunch() throws {
        let marker = makeMarkerURL()
        defer { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }
        NoteSyncZoneTracker(markerURL: marker).turnedOnByUser()
        let relaunched = NoteSyncZoneTracker(markerURL: marker)
        precondition(relaunched.actionForZoneDeletion == .recreateAndUploadAll)
        relaunched.zoneSaved()
        precondition(NoteSyncZoneTracker(markerURL: marker).actionForZoneDeletion == .stopSync)
    }

    /// Starting over or history recovery restarts the engine without the
    /// user turning sync on: a deletion then is another Mac's.
    static func testRestartWithoutTurnOnTreatsDeletionAsDeletedElsewhere() throws {
        let marker = makeMarkerURL()
        defer { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }
        let tracker = NoteSyncZoneTracker(markerURL: marker)
        precondition(tracker.actionForZoneDeletion == .stopSync)
    }
}
