import Foundation

/// Tells a deletion of the `Notes` zone by another Mac apart from history.
/// Turning sync on again starts the engine fresh, and its first fetch can
/// still report the zone this Mac deleted earlier (Turn Off and Delete from
/// iCloud), or a save can meet "user deleted zone". Neither means another
/// Mac just deleted it: turning sync on again is the choice to use iCloud.
struct NoteSyncZoneTracker {
    let startedFresh: Bool
    private var finishedFirstFetch = false
    private var savedZone = false

    init(startedFresh: Bool) {
        self.startedFresh = startedFresh
    }

    /// Whether a zone deletion reported by a fetch should stop sync.
    var zoneDeletionMeansDeletedElsewhere: Bool {
        !(startedFresh && !finishedFirstFetch)
    }

    /// Whether a save that met "user deleted zone" should recreate the zone.
    var recreatesZoneAfterUserDeletedZone: Bool {
        startedFresh && !savedZone
    }

    mutating func firstFetchFinished() {
        finishedFirstFetch = true
    }

    mutating func zoneSaved() {
        savedZone = true
    }
}
