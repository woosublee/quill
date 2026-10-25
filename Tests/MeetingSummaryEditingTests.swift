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
        try testLeavingEmptyRowsKeepsOnlyTheFocusedOne()
        try testNewRowButtonGivesWayToFocusedUntypedRow()
        try testEditKeepsSavedCompletion()
        try testEditKeepsActionWithOnlyOwner()
        try testCompletionOnlyChangeIsNotAnEdit()
        try testSecondEditKeepsFirstOriginal()
        try testRevertRestoresOriginalAndKeepsCompletion()
        try testUneditedSummaryCannotRevert()
        try testEditedSummaryRoundTrips()
        try testVisibleTextIgnoresIDsLinksAndCompletion()
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

    // A new row left without typing goes away once focus leaves it; only the
    // row still being typed in stays.
    private static func testLeavingEmptyRowsKeepsOnlyTheFocusedOne() throws {
        var content = envelope().content
        content.keyPoints.append(MeetingSummaryPoint(id: pointID(5), text: "", sourceQuote: nil))
        content.decisions.append(MeetingSummaryPoint(id: pointID(6), text: " ", sourceQuote: nil))
        content.actionItems.append(action(id: 8, task: "", completed: false))
        var ownerOnly = action(id: 9, task: "", completed: false)
        ownerOnly.owner = "Synthetic owner"
        content.actionItems.append(ownerOnly)

        let focusedPoint = content.removingUntypedRows(except: pointID(5))
        try expect(focusedPoint.keyPoints.map(\.id) == [pointID(1), pointID(5)], "the focused empty point stays")
        try expect(focusedPoint.decisions.isEmpty, "an unfocused empty decision is dropped")
        try expect(
            focusedPoint.actionItems.map(\.id) == [content.actionItems[0].id, pointID(9)],
            "an untyped action is dropped, one with an owner stays"
        )

        let focusedAction = content.removingUntypedRows(except: pointID(8))
        try expect(focusedAction.actionItems.map(\.id).contains(pointID(8)), "the focused empty action stays")
        try expect(focusedAction.keyPoints.map(\.text) == ["Synthetic point"], "an unfocused empty point is dropped")
    }

    // The New Item button gives way only to a new row being typed in, so a
    // row that never got focus still leaves a way to add one.
    private static func testNewRowButtonGivesWayToFocusedUntypedRow() throws {
        var content = envelope().content
        try expect(!content.endsWithFocusedUntypedRow(\.keyPoints, focusedID: pointID(1)), "a typed last row keeps the button")
        try expect(!content.endsWithFocusedUntypedRow(\.decisions, focusedID: nil), "an empty section keeps the button")

        content.keyPoints.append(MeetingSummaryPoint(id: pointID(5), text: "", sourceQuote: nil))
        try expect(content.endsWithFocusedUntypedRow(\.keyPoints, focusedID: pointID(5)), "the focused new row takes its place")
        try expect(!content.endsWithFocusedUntypedRow(\.keyPoints, focusedID: nil), "an unfocused new row keeps the button")

        content.actionItems.append(action(id: 8, task: "", completed: false))
        try expect(content.endsWithFocusedUntypedAction(focusedID: pointID(8)), "the focused new action takes its place")
        content.actionItems[1].dueDate = "Friday"
        try expect(!content.endsWithFocusedUntypedAction(focusedID: pointID(8)), "a due date counts as typing")
    }

    // An action with only an owner typed is saved, like it stays on screen.
    private static func testEditKeepsActionWithOnlyOwner() throws {
        let original = envelope()
        var content = original.content
        var ownerOnly = action(id: 9, task: "", completed: false)
        ownerOnly.owner = "Synthetic owner"
        content.actionItems.append(ownerOnly)
        let edited = try required(original.applyingEdit(content, at: Date()))
        try expect(edited.content.actionItems.map(\.id).last == pointID(9), "the owner-only action is saved")
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

    // A regenerated summary counts as the same when the person would see
    // the same text.
    private static func testVisibleTextIgnoresIDsLinksAndCompletion() throws {
        let current = envelope(completed: true).content
        var regenerated = current
        regenerated.keyPoints[0] = MeetingSummaryPoint(id: UUID(), text: "Synthetic point", sourceQuote: nil)
        regenerated.actionItems[0] = action(id: 9, task: "Synthetic task", completed: false)
        try expect(regenerated.hasSameVisibleText(as: current), "IDs, links, and completion don't count")

        var owner = regenerated
        owner.actionItems[0].owner = "Synthetic owner"
        try expect(!owner.hasSameVisibleText(as: current), "an owner counts")
        var moved = regenerated
        moved.decisions = moved.keyPoints
        moved.keyPoints = []
        try expect(!moved.hasSameVisibleText(as: current), "the section a row is in counts")
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
