import Foundation
import QuillNoteCore

/// How rows split between the note list and Recently Deleted. The
/// retention and day count are shared with the iPhone (`QuillNoteCore`).
extension RecentlyDeletedPolicy {
    /// Live notes keep their order. Deleted notes are newest deletion first.
    static func partition(
        _ items: [PipelineHistoryItem]
    ) -> (live: [PipelineHistoryItem], deleted: [PipelineHistoryItem]) {
        let live = items.filter { $0.deletedAt == nil }
        let deleted = items
            .filter { $0.deletedAt != nil }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        return (live, deleted)
    }
}
