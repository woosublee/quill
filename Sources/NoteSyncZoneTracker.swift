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
/// this Mac deleted earlier (Turn Off and Delete from iCloud). Until the
/// zone is saved again, such a deletion is that history: turning sync on
/// is the choice to use iCloud. A marker file keeps that window across a
/// relaunch; starting over or history recovery never opens it.
struct NoteSyncZoneTracker {
    let markerURL: URL

    init(markerURL: URL) {
        self.markerURL = markerURL
    }

    var actionForZoneDeletion: NoteSyncZoneDeletionAction {
        FileManager.default.fileExists(atPath: markerURL.path) ? .recreateAndUploadAll : .stopSync
    }

    func turnedOnByUser() {
        try? FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data().write(to: markerURL, options: .atomic)
    }

    func zoneSaved() {
        try? FileManager.default.removeItem(at: markerURL)
    }
}
