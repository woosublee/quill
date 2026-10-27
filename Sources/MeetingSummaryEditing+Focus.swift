import Foundation
import QuillSummaryFormatCore

// Where the Summary tab's New Item button goes. The editing rules themselves
// are in QuillSummaryFormatCore.
extension MeetingSummaryContent {
    /// True when the last of `points` is an untyped row being typed in,
    /// standing where the New Item button would be.
    func endsWithFocusedUntypedRow(
        _ points: KeyPath<MeetingSummaryContent, [MeetingSummaryPoint]>,
        focusedID: UUID?
    ) -> Bool {
        guard let last = self[keyPath: points].last else { return false }
        return last.id == focusedID && Self.isUntyped(last)
    }

    /// The same as `endsWithFocusedUntypedRow` for action items.
    func endsWithFocusedUntypedAction(focusedID: UUID?) -> Bool {
        guard let last = actionItems.last else { return false }
        return last.id == focusedID && Self.isUntyped(last)
    }
}
