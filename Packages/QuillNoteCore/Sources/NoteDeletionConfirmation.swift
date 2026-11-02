/// What the confirmation for deleting notes says, the same on the Mac and
/// the iPhone (woosublee/quill-universal-private#282). Deleting several
/// notes says their audio and summaries go too. Which notes can be deleted,
/// and the delete itself, stay in each app. Each app translates the cases
/// with its own String Catalog (`titleKey`, `messageKey`).
public struct NoteDeletionConfirmation: Equatable, Sendable {
    public enum Title: Equatable, Sendable {
        case deleteNote
        case deleteNoteAndRecordingPieces
        /// "Delete %lld notes?"
        case deleteNotes(count: Int)

        public var key: String {
            switch self {
            case .deleteNote: return "Delete this note?"
            case .deleteNoteAndRecordingPieces: return "Delete this note and its recording pieces?"
            case .deleteNotes: return "Delete %lld notes?"
            }
        }
    }

    public enum Message: String, Equatable, Sendable, CaseIterable {
        /// One note that moves to Recently Deleted.
        case restorableNote
        /// Several notes that move to Recently Deleted.
        case restorableNotes
        /// One note whose unrecovered recording pieces go with it.
        case recordingPiecesDeleted
        /// Several notes, some for recordings Quill couldn't recover.
        case unrecoveredNotesDeletedRightAway
        /// One note deleted for good.
        case cannotBeRecovered

        public var key: String {
            switch self {
            case .restorableNote:
                return "You can restore it from Recently Deleted for 30 days."
            case .restorableNotes:
                return "Their audio and summaries go with them. You can restore them from Recently Deleted for 30 days."
            case .recordingPiecesDeleted:
                return "The recording pieces Quill couldn't recover will also be deleted. This can't be undone."
            case .unrecoveredNotesDeletedRightAway:
                return "Audio and summaries are deleted too. Notes for recordings Quill couldn't recover are deleted right away, with any recording pieces, and can't be restored."
            case .cannotBeRecovered:
                return "Deleted notes cannot be recovered."
            }
        }
    }

    public let title: Title
    public let message: Message

    /// - Parameters:
    ///   - count: The notes to delete.
    ///   - includesRecordingPieces: One of them still holds the pieces of a
    ///     recording Quill couldn't recover.
    ///   - includesUnrecovered: One of them is for a recording Quill
    ///     couldn't recover, so it is deleted for good.
    ///   - canMoveToRecentlyDeleted: For one note, whether it moves to
    ///     Recently Deleted. Several notes always read as restorable unless
    ///     one is unrecovered.
    public init(
        count: Int,
        includesRecordingPieces: Bool,
        includesUnrecovered: Bool,
        canMoveToRecentlyDeleted: Bool
    ) {
        if count == 1 {
            if includesRecordingPieces {
                title = .deleteNoteAndRecordingPieces
                message = .recordingPiecesDeleted
            } else {
                title = .deleteNote
                message = canMoveToRecentlyDeleted ? .restorableNote : .cannotBeRecovered
            }
        } else {
            title = .deleteNotes(count: count)
            message = includesUnrecovered ? .unrecoveredNotesDeletedRightAway : .restorableNotes
        }
    }

    public var titleKey: String { title.key }
    public var messageKey: String { message.key }
}
