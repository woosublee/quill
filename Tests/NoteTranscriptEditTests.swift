import Foundation
import QuillNoteCore

/// A note's transcript after an edit (quill-universal-private#148): clearing
/// it clears the raw transcript too, on both apps. Synthetic text only.
@main
struct NoteTranscriptEditTests {
    static func main() {
        let raw = "Synthetic raw line."

        let edited = NoteTranscriptEdit(rawTranscript: raw, edit: "Synthetic edited line.")
        precondition(edited.rawTranscript == raw, "an edit keeps the raw transcript")
        precondition(edited.editedTranscript == "Synthetic edited line.")
        precondition(!edited.isCleared)

        let padded = NoteTranscriptEdit(rawTranscript: raw, edit: "\n  Synthetic edited line.\n")
        precondition(padded.editedTranscript == "\n  Synthetic edited line.\n", "an edit keeps its own spacing")

        for blank in ["", " ", "\n", " \n\t "] {
            let cleared = NoteTranscriptEdit(rawTranscript: raw, edit: blank)
            precondition(cleared.isCleared, "nothing but spaces or line breaks clears the note")
            precondition(cleared.rawTranscript.isEmpty, "clearing removes the raw transcript too")
            precondition(cleared.editedTranscript.isEmpty, "a cleared edit is stored empty")
        }

        let empty = NoteTranscriptEdit(rawTranscript: "", edit: "Synthetic typed line.")
        precondition(empty.rawTranscript.isEmpty && empty.editedTranscript == "Synthetic typed line.")

        print("NoteTranscriptEditTests passed")
    }
}
