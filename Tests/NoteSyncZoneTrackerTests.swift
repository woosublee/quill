import Foundation

@main
struct NoteSyncZoneTrackerTests {
    static func main() throws {
        try testTurnOnRecreatesDeletedZoneUntilItIsSaved()
        try testTurnOnSurvivesRelaunch()
        try testRestartWithoutTurnOnTreatsDeletionAsDeletedElsewhere()
        try testZoneSavedDuringFirstFetchStillTreatsDeletionAsHistory()
        try testTurningOffForgetsTheTurnOn()
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
        var tracker = NoteSyncZoneTracker(markerURL: marker)
        tracker.turnedOnByUser()
        precondition(tracker.actionForZoneDeletion == .recreateAndUploadAll, "turning sync on means using iCloud again")
        tracker.fetchFinished()
        precondition(tracker.actionForZoneDeletion == .recreateAndUploadAll, "a fetch alone doesn't close it: the zone isn't back yet")
        tracker.zoneSaved()
        tracker.fetchFinished()
        precondition(tracker.actionForZoneDeletion == .stopSync, "once saved and fetched, a later deletion is another Mac's choice")
    }

    /// Quitting before the zone is saved again must not turn the old
    /// deletion into "deleted from another Mac" on the next launch.
    static func testTurnOnSurvivesRelaunch() throws {
        let marker = makeMarkerURL()
        defer { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }
        NoteSyncZoneTracker(markerURL: marker).turnedOnByUser()
        var relaunched = NoteSyncZoneTracker(markerURL: marker)
        precondition(relaunched.actionForZoneDeletion == .recreateAndUploadAll)
        relaunched.zoneSaved()
        relaunched.fetchFinished()
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

    /// The zone save and the first fetch can run at once: a deletion the
    /// fetch delivers after the save is still the old one.
    static func testZoneSavedDuringFirstFetchStillTreatsDeletionAsHistory() throws {
        let marker = makeMarkerURL()
        defer { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }
        var tracker = NoteSyncZoneTracker(markerURL: marker)
        tracker.turnedOnByUser()
        tracker.zoneSaved()
        precondition(tracker.actionForZoneDeletion == .recreateAndUploadAll)
    }

    /// A turn-on whose zone never came back must not outlive turning off.
    static func testTurningOffForgetsTheTurnOn() throws {
        let marker = makeMarkerURL()
        defer { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }
        let tracker = NoteSyncZoneTracker(markerURL: marker)
        tracker.turnedOnByUser()
        tracker.forgetTurnOn()
        precondition(NoteSyncZoneTracker(markerURL: marker).actionForZoneDeletion == .stopSync)
    }
}
