import Foundation
import QuillNoteCore
import QuillNoteUI

/// Small note-detail pieces shared with the iPhone (#697): how audio time
/// reads, and the summary field a focus move targets.
@main
struct NoteDetailSharedPiecesTests {
    static func main() {
        precondition(NoteAudioDuration.text(0) == "0:00")
        precondition(NoteAudioDuration.text(9.99) == "0:09", "partial seconds are dropped")
        precondition(NoteAudioDuration.text(65) == "1:05")
        precondition(NoteAudioDuration.text(3_599) == "59:59")
        precondition(NoteAudioDuration.text(3_600) == "1:00:00")
        precondition(NoteAudioDuration.text(37_230) == "10:20:30")
        precondition(NoteAudioDuration.text(.nan) == "0:00")
        precondition(NoteAudioDuration.text(.infinity) == "0:00")
        precondition(NoteAudioDuration.text(-3) == "0:00")
        precondition(NoteAudioDuration.text(1e19) == NoteAudioDuration.text(NoteAudioDuration.maximumSeconds),
                     "an impossible duration doesn't trap")

        let row = UUID()
        precondition(NoteSummaryField.overview.rowID == nil)
        for field in [NoteSummaryField.point(row), .task(row), .owner(row), .dueDate(row)] {
            precondition(field.rowID == row)
        }
        // The Mac's tab picker and both apps' switches expect exactly two tabs.
        for mode in [NoteContentMode.transcript, .summary] {
            switch mode {
            case .transcript, .summary: break
            }
        }
        precondition(NoteContentMode.transcript != NoteContentMode.summary)
        print("NoteDetailSharedPiecesTests passed")
    }
}
