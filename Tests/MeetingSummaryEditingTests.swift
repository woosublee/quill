import Foundation

// #262: editing a saved meeting summary in place, and reverting to the
// generated summary. Synthetic content only.
#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct MeetingSummaryEditingTests {
    static func main() throws {
        try testUneditedSummaryStoresNoEditFields()
        try testSummaryFromBeforeEditingDecodesAsUnedited()
        try testEditKeepsOriginalAndDropsEmptyRows()
        try testEditKeepsSavedCompletion()
        try testCompletionOnlyChangeIsNotAnEdit()
        try testSecondEditKeepsFirstOriginal()
        try testRevertRestoresOriginalAndKeepsCompletion()
        try testUneditedSummaryCannotRevert()
        try testEditedSummaryRoundTrips()
        print("MeetingSummaryEditingTests passed")
    }

    // An unedited summary writes the same JSON keys as before, so an older
    // Quill still reads it.
    private static func testUneditedSummaryStoresNoEditFields() throws {
        let json = try String(decoding: JSONEncoder().encode(envelope()), as: UTF8.self)
        try expect(!json.contains("editedAt"), "unedited summary has no editedAt key")
        try expect(!json.contains("originalContent"), "unedited summary has no originalContent key")
    }

    private static func testSummaryFromBeforeEditingDecodesAsUnedited() throws {
        let legacy = try JSONEncoder().encode(envelope())
        let decoded = try JSONDecoder().decode(MeetingSummaryEnvelope.self, from: legacy)
        try expect(decoded.editedAt == nil && decoded.originalContent == nil, "legacy summary has no edit")
        try expect(!decoded.isEdited, "legacy summary is not edited")
        try expect(decoded == envelope(), "legacy summary decodes unchanged")
    }

    private static func testEditKeepsOriginalAndDropsEmptyRows() throws {
        let original = envelope()
        var content = original.content
        content.keyPoints[0].text = "Synthetic point, corrected"
        content.keyPoints.append(MeetingSummaryPoint(id: UUID(), text: "  ", sourceQuote: nil))
        content.decisions.append(MeetingSummaryPoint(id: pointID(9), text: "Added decision", sourceQuote: nil))
        content.actionItems.append(action(id: 8, task: "", completed: false))
        content.actionItems.append(action(id: 7, task: "Added action", completed: false))
        content.actionItems[0].owner = "Synthetic owner"

        let date = Date(timeIntervalSince1970: 5_000)
        guard let edited = original.applyingEdit(content, at: date) else {
            throw TestFailure("a text change is an edit")
        }
        try expect(edited.editedAt == date && edited.isEdited, "edit time is recorded")
        try expect(edited.originalContent == original.content, "the generated content is kept")
        try expect(edited.content.keyPoints.map(\.text) == ["Synthetic point, corrected"], "empty point is dropped")
        try expect(edited.content.decisions.map(\.text) == ["Added decision"], "added decision is kept")
        try expect(edited.content.actionItems.map(\.task) == ["Synthetic task", "Added action"], "empty action is dropped")
        try expect(edited.content.actionItems[0].owner == "Synthetic owner", "owner edit is kept")
        try expect(edited.content.actionItems[0].sourceQuote == "Synthetic quote.", "source link stays on an edited row")
    }

    // Completion is saved through its own path; an edit never changes it.
    private static func testEditKeepsSavedCompletion() throws {
        let original = envelope(completed: true)
        var content = original.content
        content.overview.text = "Synthetic overview, corrected"
        content.actionItems[0].isCompleted = false
        guard let edited = original.applyingEdit(content, at: Date()) else {
            throw TestFailure("overview change is an edit")
        }
        try expect(edited.content.actionItems[0].isCompleted, "saved completion wins over the draft")
    }

    private static func testCompletionOnlyChangeIsNotAnEdit() throws {
        let original = envelope()
        var content = original.content
        content.actionItems[0].isCompleted = true
        content.keyPoints.append(MeetingSummaryPoint(id: UUID(), text: "", sourceQuote: nil))
        try expect(original.applyingEdit(content, at: Date()) == nil, "no text change saves nothing")
    }

    private static func testSecondEditKeepsFirstOriginal() throws {
        let original = envelope()
        var first = original.content
        first.overview.text = "First edit"
        let once = try required(original.applyingEdit(first, at: Date(timeIntervalSince1970: 1)))
        var second = once.content
        second.overview.text = "Second edit"
        let twice = try required(once.applyingEdit(second, at: Date(timeIntervalSince1970: 2)))
        try expect(twice.originalContent == original.content, "the first generated content stays the original")
        try expect(twice.editedAt == Date(timeIntervalSince1970: 2), "latest edit time")
    }

    private static func testRevertRestoresOriginalAndKeepsCompletion() throws {
        let original = envelope()
        var content = original.content
        content.overview.text = "Edited overview"
        content.actionItems.append(action(id: 7, task: "Added action", completed: false))
        var edited = try required(original.applyingEdit(content, at: Date()))
        // Checked after the edit, through the completion path.
        edited.content.actionItems[0].isCompleted = true

        let reverted = try required(edited.revertedToOriginal())
        try expect(reverted.content.overview.text == "Synthetic overview", "overview is the generated one again")
        try expect(reverted.content.actionItems.map(\.task) == ["Synthetic task"], "added rows go away")
        try expect(reverted.content.actionItems[0].isCompleted, "completion stays checked")
        try expect(!reverted.isEdited && reverted.originalContent == nil, "reverted summary is unedited")
    }

    private static func testUneditedSummaryCannotRevert() throws {
        try expect(envelope().revertedToOriginal() == nil, "nothing to revert")
    }

    private static func testEditedSummaryRoundTrips() throws {
        var content = envelope().content
        content.decisions.append(MeetingSummaryPoint(id: pointID(9), text: "Added decision", sourceQuote: nil))
        let edited = try required(envelope().applyingEdit(content, at: Date(timeIntervalSince1970: 7_000)))
        let decoded = try JSONDecoder().decode(
            MeetingSummaryEnvelope.self,
            from: JSONEncoder().encode(edited)
        )
        try expect(decoded == edited, "edited summary survives saving")
    }

    // MARK: Fixtures

    private static func envelope(completed: Bool = false) -> MeetingSummaryEnvelope {
        MeetingSummaryEnvelope(
            schemaVersion: MeetingSummaryEnvelope.currentSchemaVersion,
            promptVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 2_000),
            sourceFingerprint: String(repeating: "d", count: 64),
            modelID: "summary/model",
            backendKind: .cloud,
            content: MeetingSummaryContent(
                overview: MeetingSummaryEvidenceText(
                    text: "Synthetic overview",
                    sourceQuotes: ["Synthetic quote."]
                ),
                keyPoints: [
                    MeetingSummaryPoint(id: pointID(1), text: "Synthetic point", sourceQuote: "Synthetic quote.")
                ],
                decisions: [],
                actionItems: [
                    MeetingSummaryActionItem(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!,
                        task: "Synthetic task",
                        owner: nil,
                        dueDate: nil,
                        sourceQuote: "Synthetic quote.",
                        isCompleted: completed
                    )
                ],
                openQuestions: []
            )
        )
    }

    private static func action(id: Int, task: String, completed: Bool) -> MeetingSummaryActionItem {
        MeetingSummaryActionItem(
            id: pointID(id),
            task: task,
            owner: nil,
            dueDate: nil,
            sourceQuote: nil,
            isCompleted: completed
        )
    }

    private static func pointID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    private static func required<T>(_ value: T?) throws -> T {
        guard let value else { throw TestFailure("expected a value") }
        return value
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw TestFailure(message) }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
