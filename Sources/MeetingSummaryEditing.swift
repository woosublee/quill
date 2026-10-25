import Foundation

// Editing a saved meeting summary in place (#262). The Summary tab edits a
// copy of the content and saves it here; the generated content is kept the
// first time so the person can revert to it.

extension MeetingSummaryContent {
    /// The content without rows left empty while editing. An action with
    /// only an owner or due date is kept.
    func removingEmptyItems() -> MeetingSummaryContent {
        var copy = self
        copy.keyPoints = keyPoints.filter { !Self.isBlank($0.text) }
        copy.decisions = decisions.filter { !Self.isBlank($0.text) }
        copy.openQuestions = openQuestions.filter { !Self.isBlank($0.text) }
        copy.actionItems = actionItems.filter { !Self.isUntyped($0) }
        return copy
    }

    /// The content without rows that have nothing typed in them, except
    /// the row `keptID` that the person may still be typing in. An action
    /// with only an owner or due date stays, so that typing isn't lost.
    func removingUntypedRows(except keptID: UUID?) -> MeetingSummaryContent {
        var copy = self
        copy.keyPoints = keyPoints.filter { $0.id == keptID || !Self.isUntyped($0) }
        copy.decisions = decisions.filter { $0.id == keptID || !Self.isUntyped($0) }
        copy.openQuestions = openQuestions.filter { $0.id == keptID || !Self.isUntyped($0) }
        copy.actionItems = actionItems.filter { $0.id == keptID || !Self.isUntyped($0) }
        return copy
    }

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

    static func isUntyped(_ point: MeetingSummaryPoint) -> Bool {
        isBlank(point.text)
    }

    static func isUntyped(_ action: MeetingSummaryActionItem) -> Bool {
        isBlank(action.task) && isBlank(action.owner ?? "") && isBlank(action.dueDate ?? "")
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

    /// True when the person would see the same summary: the same text in
    /// the same rows, whatever the rows' IDs, source links, or completion.
    func hasSameVisibleText(as other: MeetingSummaryContent) -> Bool {
        visibleText == other.visibleText
    }

    private var visibleText: [[String?]] {
        [
            [overview.text],
            keyPoints.map(\.text),
            decisions.map(\.text),
            actionItems.flatMap { [$0.task, $0.owner, $0.dueDate] },
            openQuestions.map(\.text),
        ]
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
    /// generated content is kept from before the first edit. Text edited
    /// back to the generated text is no longer an edit.
    func applyingEdit(
        _ editedContent: MeetingSummaryContent,
        at date: Date
    ) -> MeetingSummaryEnvelope? {
        let cleaned = editedContent
            .removingEmptyItems()
            .keepingCompletion(from: content)
        guard !cleaned.hasSameText(as: content) else { return nil }
        var copy = self
        if let originalContent, cleaned.hasSameVisibleText(as: originalContent) {
            copy.content = cleaned
            copy.editedAt = nil
            copy.originalContent = nil
            return copy
        }
        copy.originalContent = originalContent ?? content
        copy.content = cleaned
        copy.editedAt = date
        return copy
    }

    /// A new summary with the same text as `current`, saved without asking:
    /// it keeps the current rows, completion, and edit, so nothing on screen
    /// changes, and takes the new source links and when it was made.
    func keepingRows(of current: MeetingSummaryEnvelope) -> MeetingSummaryEnvelope {
        func points(
            _ new: [MeetingSummaryPoint],
            _ old: [MeetingSummaryPoint]
        ) -> [MeetingSummaryPoint] {
            zip(new, old).map {
                MeetingSummaryPoint(id: $1.id, text: $1.text, sourceQuote: $0.sourceQuote)
            }
        }
        var copy = self
        copy.content.keyPoints = points(content.keyPoints, current.content.keyPoints)
        copy.content.decisions = points(content.decisions, current.content.decisions)
        copy.content.openQuestions = points(content.openQuestions, current.content.openQuestions)
        copy.content.actionItems = zip(content.actionItems, current.content.actionItems).map {
            MeetingSummaryActionItem(
                id: $1.id,
                task: $1.task,
                owner: $1.owner,
                dueDate: $1.dueDate,
                sourceQuote: $0.sourceQuote,
                isCompleted: $1.isCompleted
            )
        }
        copy.content.overview.text = current.content.overview.text
        copy.editedAt = current.editedAt
        copy.originalContent = current.originalContent
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
