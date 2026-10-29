import Foundation

/// What a note's transcript text is after the person edits it, the same on
/// the Mac and the iPhone (woosublee/quill-universal-private#148). A note
/// keeps its raw transcript and an edited one (the cleanup result or the
/// person's edit). Clearing the transcript, leaving nothing but spaces or
/// line breaks, clears the note's text: both the raw transcript and the
/// edit, so a cleared note shows, summarizes, and syncs as empty. An empty
/// edited transcript alone means "not edited" and shows the raw one, which
/// is why the raw transcript goes too. Retranscribing makes a new raw
/// transcript; the audio stays.
public struct NoteTranscriptEdit: Equatable, Sendable {
    public let rawTranscript: String
    public let editedTranscript: String

    /// The edit left nothing but spaces or line breaks, so the note's text
    /// is cleared.
    public var isCleared: Bool { editedTranscript.isEmpty }

    public init(rawTranscript: String, edit: String) {
        if edit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.rawTranscript = ""
            editedTranscript = ""
        } else {
            self.rawTranscript = rawTranscript
            editedTranscript = edit
        }
    }
}
