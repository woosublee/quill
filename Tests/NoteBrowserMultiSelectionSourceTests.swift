import Foundation

// #358: Note Browser wiring for selecting and deleting several notes.
@main
struct NoteBrowserMultiSelectionSourceTests {
    static func main() throws {
        let source = try String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)

        // One selection state drives both the single-note view and multi-selection.
        precondition(source.contains("@State private var selection = NoteSelection()"))
        precondition(source.contains("private var selectedItemID: UUID? { selection.focusedID }"))
        precondition(!source.contains("@State private var selectedItemID"))

        // Visible entry points: the Select button and the row context menu.
        precondition(source.contains("Button(\"Select\") { beginSelection() }"))
        precondition(source.contains(".onTapGesture { handleRowClick(item.id) }"))
        precondition(source.contains("Button(\"Select\") { beginSelection(including: item.id) }"))
        precondition(source.contains("Button(\"Delete…\", role: .destructive)"))

        // Modifier clicks map to toggle and range.
        let click = try body(of: "private func handleRowClick(_ id: UUID)", in: source)
        precondition(click.contains("flags.contains(.command)"))
        precondition(click.contains("flags.contains(.shift) ? .extend : .none"))

        // Multi-selection replaces the detail pane, and deletion goes through AppState.
        precondition(source.contains("NoteMultiSelectionPanel(count: selection.selectedIDs.count)"))
        let perform = try body(of: "private func performPendingDeletion()", in: source)
        precondition(perform.contains("appState.deleteHistoryEntries(ids: ids)"))
        precondition(perform.contains("appState.deleteHistoryEntry(id: ids[0])"))

        // Busy notes can't join a selection.
        let selectable = try body(of: "private func isBulkSelectable(_ id: UUID) -> Bool", in: source)
        precondition(selectable.contains(".isBulkSelectable"))

        // Keyboard shortcuts stay inside this window and never steal text editing keys.
        let monitor = try body(of: "private struct NoteBrowserKeyCommandMonitor", in: source)
        precondition(monitor.contains("event.window === window"))
        precondition(monitor.contains("!(window.firstResponder is NSText)"))
        precondition(monitor.contains("NSEvent.removeMonitor(monitor)"))
        precondition(source.contains(".background(NoteBrowserKeyCommandMonitor(handle: handleKeyCommand))"))

        // New notes don't replace a multi-selection, and search keeps it to visible notes.
        precondition(source.contains("// Keep a multi-selection; new notes don't take over while selecting."))
        precondition(source.contains("selection.retainVisible(filteredHistory.map(\\.id))"))

        print("NoteBrowserMultiSelectionSourceTests passed")
    }

    private static func body(of signature: String, in text: String) throws -> String {
        guard let start = text.range(of: signature),
              let open = text[start.upperBound...].firstIndex(of: "{") else {
            throw TestFailure("missing \(signature)")
        }
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" {
                depth -= 1
                if depth == 0 { return String(text[open...index]) }
            }
            index = text.index(after: index)
        }
        throw TestFailure("unterminated \(signature)")
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
