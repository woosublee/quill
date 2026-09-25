import AppKit

@main
struct NoteSelectionTests {
    private static let ids = (0..<6).map { index in
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }
    private static let everySelectable: (UUID) -> Bool = { _ in true }

    static func main() throws {
        try testPlainClickSelectsSingleNote()
        try testCommandClickBuildsMultiSelection()
        try testCommandClickBackToOneNoteReturnsToSingleView()
        try testShiftClickSelectsRangeFromAnchor()
        try testSelectionModeTogglesWithPlainClicks()
        try testSelectionModeKeepsEmptySelection()
        try testSelectAllSkipsUnselectableNotes()
        try testUnselectableNotesCannotBeAdded()
        try testEndSelectionModeReturnsToFocusedNote()
        try testRetainVisibleDropsHiddenNotes()
        try testFocusResetsMultiSelection()
        try testNextFocusAfterDeletion()
        try testKeyCommandsRequireExactModifiers()
        print("NoteSelectionTests passed")
    }

    private static func testPlainClickSelectsSingleNote() throws {
        var selection = NoteSelection(focusedID: ids[0])
        selection.click(ids[2], modifier: .none, orderedIDs: ids, isSelectable: everySelectable)

        try expect(selection.focusedID == ids[2], "plain click focuses the note")
        try expect(selection.selectedIDs == [ids[2]], "plain click selects only that note")
        try expect(!selection.showsSelectionUI, "a single note keeps the normal view")
    }

    private static func testCommandClickBuildsMultiSelection() throws {
        var selection = NoteSelection(focusedID: ids[0])
        selection.click(ids[2], modifier: .toggle, orderedIDs: ids, isSelectable: everySelectable)
        selection.click(ids[4], modifier: .toggle, orderedIDs: ids, isSelectable: everySelectable)

        try expect(selection.selectedIDs == [ids[0], ids[2], ids[4]], "command-click adds notes")
        try expect(selection.showsSelectionUI, "two or more notes show the selection UI")
        try expect(selection.focusedID == ids[4], "the last clicked note is focused")
    }

    private static func testCommandClickBackToOneNoteReturnsToSingleView() throws {
        var selection = NoteSelection(focusedID: ids[0])
        selection.click(ids[1], modifier: .toggle, orderedIDs: ids, isSelectable: everySelectable)
        selection.click(ids[1], modifier: .toggle, orderedIDs: ids, isSelectable: everySelectable)

        try expect(selection.selectedIDs == [ids[0]], "command-click removes a note")
        try expect(selection.focusedID == ids[0], "the remaining note is focused")
        try expect(!selection.showsSelectionUI, "one remaining note returns to the normal view")
    }

    private static func testShiftClickSelectsRangeFromAnchor() throws {
        var selection = NoteSelection(focusedID: ids[1])
        selection.click(ids[4], modifier: .extend, orderedIDs: ids, isSelectable: everySelectable)

        try expect(selection.selectedIDs == Set(ids[1...4]), "shift-click selects the range")
        try expect(selection.focusedID == ids[4], "shift-click focuses the clicked note")

        selection.click(ids[2], modifier: .extend, orderedIDs: ids, isSelectable: everySelectable)
        try expect(selection.selectedIDs == Set(ids[1...2]), "the range is measured from the anchor")
    }

    private static func testSelectionModeTogglesWithPlainClicks() throws {
        var selection = NoteSelection(focusedID: ids[0])
        selection.beginSelectionMode()
        try expect(selection.showsSelectionUI, "Select shows the selection UI")
        try expect(selection.selectedIDs.isEmpty, "Select starts with nothing checked")
        try expect(selection.focusedID == ids[0], "the viewed note is kept to return to")

        selection.click(ids[3], modifier: .none, orderedIDs: ids, isSelectable: everySelectable)
        selection.click(ids[0], modifier: .none, orderedIDs: ids, isSelectable: everySelectable)
        try expect(selection.selectedIDs == [ids[0], ids[3]], "plain click adds in selection mode")
        selection.click(ids[0], modifier: .none, orderedIDs: ids, isSelectable: everySelectable)
        try expect(selection.selectedIDs == [ids[3]], "plain click removes in selection mode")
        try expect(selection.showsSelectionUI, "selection mode stays open with one note")
    }

    private static func testSelectionModeKeepsEmptySelection() throws {
        var selection = NoteSelection(focusedID: ids[0])
        selection.beginSelectionMode()
        selection.click(ids[2], modifier: .none, orderedIDs: ids, isSelectable: everySelectable)
        selection.click(ids[2], modifier: .none, orderedIDs: ids, isSelectable: everySelectable)

        try expect(selection.selectedIDs.isEmpty, "selection mode can be empty")
        try expect(selection.showsSelectionUI, "selection mode stays open when empty")
        selection.endSelectionMode()
        try expect(selection.focusedID == ids[2], "Done returns to the last clicked note")
    }

    private static func testSelectAllSkipsUnselectableNotes() throws {
        let busy: Set<UUID> = [ids[1], ids[5]]
        var selection = NoteSelection(focusedID: ids[0])
        selection.selectAll(orderedIDs: ids, isSelectable: { !busy.contains($0) })

        try expect(selection.selectedIDs == [ids[0], ids[2], ids[3], ids[4]], "Select All skips busy notes")
        try expect(selection.showsSelectionUI, "Select All shows the selection UI")
    }

    private static func testUnselectableNotesCannotBeAdded() throws {
        let busy: Set<UUID> = [ids[2]]
        var selection = NoteSelection(focusedID: ids[0])
        selection.click(ids[2], modifier: .toggle, orderedIDs: ids, isSelectable: { !busy.contains($0) })
        try expect(selection.selectedIDs == [ids[0]], "command-click ignores a busy note")

        selection.click(ids[3], modifier: .extend, orderedIDs: ids, isSelectable: { !busy.contains($0) })
        try expect(selection.selectedIDs == [ids[0], ids[1], ids[3]], "a range skips busy notes")

        var single = NoteSelection(focusedID: ids[0])
        single.click(ids[2], modifier: .none, orderedIDs: ids, isSelectable: { !busy.contains($0) })
        try expect(single.focusedID == ids[2], "a busy note can still be opened on its own")
    }

    private static func testEndSelectionModeReturnsToFocusedNote() throws {
        var selection = NoteSelection(focusedID: ids[0])
        selection.beginSelectionMode()
        selection.endSelectionMode()
        try expect(selection.focusedID == ids[0], "Done without choosing returns to the viewed note")
        try expect(selection.selectedIDs == [ids[0]], "Done without choosing keeps the viewed note")

        selection.beginSelectionMode()
        selection.click(ids[3], modifier: .none, orderedIDs: ids, isSelectable: everySelectable)
        selection.endSelectionMode()

        try expect(!selection.showsSelectionUI, "Done closes the selection UI")
        try expect(selection.focusedID == ids[3], "Done keeps the last clicked note")
        try expect(selection.selectedIDs == [ids[3]], "Done leaves only the focused note selected")
    }

    private static func testRetainVisibleDropsHiddenNotes() throws {
        var selection = NoteSelection(focusedID: ids[0])
        selection.click(ids[2], modifier: .toggle, orderedIDs: ids, isSelectable: everySelectable)
        selection.click(ids[4], modifier: .toggle, orderedIDs: ids, isSelectable: everySelectable)
        selection.retainVisible([ids[0], ids[2], ids[3]])

        try expect(selection.selectedIDs == [ids[0], ids[2]], "hidden notes leave the selection")
        try expect(selection.focusedID == ids[0], "a hidden focused note moves to a visible selected note")

        selection.retainVisible([ids[2], ids[3]])
        try expect(selection.selectedIDs == [ids[2]], "one visible note remains")
        try expect(!selection.showsSelectionUI, "one remaining note returns to the normal view")
    }

    private static func testFocusResetsMultiSelection() throws {
        var selection = NoteSelection(focusedID: ids[0])
        selection.beginSelectionMode()
        selection.click(ids[1], modifier: .none, orderedIDs: ids, isSelectable: everySelectable)
        selection.focus(ids[5])

        try expect(selection.focusedID == ids[5], "focus moves to the note")
        try expect(selection.selectedIDs == [ids[5]], "focus leaves a single selection")
        try expect(!selection.showsSelectionUI, "focus closes selection mode")

        selection.focus(nil)
        try expect(selection.focusedID == nil && selection.selectedIDs.isEmpty, "focus nil clears the selection")
    }

    private static func testNextFocusAfterDeletion() throws {
        try expect(
            NoteSelection.nextFocusedID(afterDeleting: [ids[1], ids[3]], in: ids) == ids[4],
            "the next note below the last deleted one is shown"
        )
        try expect(
            NoteSelection.nextFocusedID(afterDeleting: [ids[4], ids[5]], in: ids) == ids[3],
            "without a note below, the nearest note above is shown"
        )
        try expect(
            NoteSelection.nextFocusedID(afterDeleting: Set(ids), in: ids) == nil,
            "nothing is shown after deleting every note"
        )
    }

    private static func testKeyCommandsRequireExactModifiers() throws {
        func command(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags) -> NoteBrowserKeyCommand? {
            NoteBrowserKeyCommand(keyCode: keyCode, charactersIgnoringModifiers: characters, modifierFlags: flags)
        }
        try expect(command(0, "a", .command) == .selectAll, "command-A selects all")
        try expect(command(0, "a", []) == nil, "plain A is ignored")
        try expect(command(0, "a", [.command, .shift]) == nil, "command-shift-A is ignored")
        try expect(command(0, "a", [.command, .capsLock]) == .selectAll, "caps lock does not block command-A")
        // AZERTY: the A letter is on key code 12 and key code 0 types Q.
        try expect(command(12, "a", .command) == .selectAll, "command-A follows the typed letter")
        try expect(command(0, "q", .command) == nil, "command-Q is never taken for select all")
        // Korean input: key code 0 types a non-Latin letter.
        try expect(command(0, "ㅁ", .command) == .selectAll, "command-A works with a non-Latin input source")
        try expect(command(53, "\u{1B}", []) == .endSelection, "esc ends selection")
        try expect(command(51, "\u{7F}", []) == .delete, "delete asks to delete")
        try expect(command(117, "\u{F728}", .function) == .delete, "forward delete asks to delete")
        try expect(command(51, "\u{7F}", .command) == nil, "command-delete is ignored")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw TestFailure(message)
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
