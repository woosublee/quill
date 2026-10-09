import Foundation

enum NoteSyncZoneDeletionAction: Equatable {
    /// Another Mac chose Turn Off and Delete from iCloud.
    case stopSync
    /// The deletion predates turning sync on here: make the zone again and
    /// upload every note, since the engine may drop saves queued for it.
    case recreateAndUploadAll
}

/// Tells a deletion of the `Notes` zone by another Mac apart from history.
/// After the user turns sync on, a fetch or save can still report the zone
/// this Mac deleted earlier (Turn Off and Delete from iCloud). That stays
/// history until the zone is saved again and a fetch has finished after
/// it, since the save and the first fetch can run at once: turning sync on
/// is the choice to use iCloud. A marker file keeps that window across a
/// relaunch; turning off closes it, and starting over or history recovery
/// never opens it.
struct NoteSyncZoneTracker {
    let markerURL: URL
    private var zoneSavedThisRun = false

    init(markerURL: URL) {
        self.markerURL = markerURL
    }

    var actionForZoneDeletion: NoteSyncZoneDeletionAction {
        FileManager.default.fileExists(atPath: markerURL.path) ? .recreateAndUploadAll : .stopSync
    }

    func turnedOnByUser() {
        do {
            try FileManager.default.createDirectory(
                at: markerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: markerURL, options: .atomic)
        } catch {
            print("[NoteSync] Couldn't note that sync was turned on")
        }
    }

    mutating func zoneSaved() {
        zoneSavedThisRun = true
    }

    func fetchFinished() {
        if zoneSavedThisRun { forgetTurnOn() }
    }

    func forgetTurnOn() {
        try? FileManager.default.removeItem(at: markerURL)
    }
}
