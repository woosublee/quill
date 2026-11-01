import Foundation
import QuillNoteCore

/// The shared delete confirmation and Recently Deleted day count
/// (quill-universal-private#282). Several notes always say their audio and
/// summaries go with them.
@main
struct NoteDeletionConfirmationTests {
    static func main() {
        let restorable = NoteDeletionConfirmation(count: 1, includesRecordingPieces: false, includesUnrecovered: false, canMoveToRecentlyDeleted: true)
        precondition(restorable.title == .deleteNote && restorable.message == .restorableNote)

        let gone = NoteDeletionConfirmation(count: 1, includesRecordingPieces: false, includesUnrecovered: true, canMoveToRecentlyDeleted: false)
        precondition(gone.title == .deleteNote && gone.message == .cannotBeRecovered)

        let pieces = NoteDeletionConfirmation(count: 1, includesRecordingPieces: true, includesUnrecovered: true, canMoveToRecentlyDeleted: false)
        precondition(pieces.title == .deleteNoteAndRecordingPieces && pieces.message == .recordingPiecesDeleted)

        let several = NoteDeletionConfirmation(count: 3, includesRecordingPieces: false, includesUnrecovered: false, canMoveToRecentlyDeleted: false)
        precondition(several.title == .deleteNotes(count: 3) && several.message == .restorableNotes)
        precondition(several.titleKey == "Delete %lld notes?")
        precondition(several.messageKey.contains("audio and summaries"), "several notes mention summaries")

        let mixed = NoteDeletionConfirmation(count: 2, includesRecordingPieces: true, includesUnrecovered: true, canMoveToRecentlyDeleted: true)
        precondition(mixed.message == .unrecoveredNotesDeletedRightAway)
        precondition(mixed.messageKey.hasPrefix("Audio and summaries are deleted too."))

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        precondition(RecentlyDeletedPolicy.retention == 30 * 24 * 60 * 60)
        precondition(RecentlyDeletedPolicy.daysLeft(deletedAt: t0, now: t0) == 30)
        let expired = t0.addingTimeInterval(31 * 86_400)
        precondition(RecentlyDeletedPolicy.daysShown(deletedAt: t0, now: expired, isWaitingForSync: true) == 1)
        precondition(RecentlyDeletedPolicy.daysShown(deletedAt: t0, now: expired, isWaitingForSync: false) == 0)
        print("NoteDeletionConfirmationTests passed")
    }
}
