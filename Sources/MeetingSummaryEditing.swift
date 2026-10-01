import Foundation

// Editing a saved meeting summary in place (#262). The Summary tab edits a
// copy of the content and saves it here; the generated content is kept the
// first time so the person can revert to it.

extension MeetingSummaryContent {
    /// The content without rows left empty while editing.
    func removingEmptyItems() -> MeetingSummaryContent {
        var copy = self
        copy.keyPoints = keyPoints.filter { !Self.isBlank($0.text) }
        copy.decisions = decisions.filter { !Self.isBlank($0.text) }
        copy.openQuestions = openQuestions.filter { !Self.isBlank($0.text) }
        copy.actionItems = actionItems.filter { !Self.isBlank($0.task) }
        return copy
    }

    /// True when both have the same text, ignoring whether actions are done.
    func hasSameText(as other: MeetingSummaryContent) -> Bool {
        withoutCompletion() == other.withoutCompletion()
    }

    /// Takes each action's completion from `source` when it has the same
    /// action, so saving or reverting text never changes what is checked.
    func keepingCompletion(from source: MeetingSummaryContent) -> MeetingSummaryContent {
        let completion = Dictionary(
            source.actionItems.map { ($0.id, $0.isCompleted) },
            uniquingKeysWith: { first, _ in first }
        )
        var copy = self
        for index in copy.actionItems.indices {
            if let isCompleted = completion[copy.actionItems[index].id] {
                copy.actionItems[index].isCompleted = isCompleted
            }
        }
        return copy
    }

    private func withoutCompletion() -> MeetingSummaryContent {
        var copy = self
        for index in copy.actionItems.indices {
            copy.actionItems[index].isCompleted = false
        }
        return copy
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension MeetingSummaryEnvelope {
    var isEdited: Bool { editedAt != nil }

    /// The summary with the person's edited text, or nil when the text is
    /// unchanged. Empty rows are dropped, completion stays as saved, and the
    /// generated content is kept from before the first edit.
    func applyingEdit(
        _ editedContent: MeetingSummaryContent,
        at date: Date
    ) -> MeetingSummaryEnvelope? {
        let cleaned = editedContent
            .removingEmptyItems()
            .keepingCompletion(from: content)
        guard !cleaned.hasSameText(as: content) else { return nil }
        var copy = self
        copy.originalContent = originalContent ?? content
        copy.content = cleaned
        copy.editedAt = date
        return copy
    }

    /// The generated summary again, keeping which actions are done. Nil when
    /// the summary was never edited.
    func revertedToOriginal() -> MeetingSummaryEnvelope? {
        guard let originalContent else { return nil }
        var copy = self
        copy.content = originalContent.keepingCompletion(from: content)
        copy.editedAt = nil
        copy.originalContent = nil
        return copy
    }
}
