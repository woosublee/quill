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

        // #195: the open note follows the search results, and a search with
        // no results shows its own empty detail.
        precondition(source.contains("            } else {\n                keepOpenNoteInSearchResults()\n            }"))
        precondition(source.contains("NoteSelection.focusedID(\n                forSearchResults: filteredHistory.map(\\.id),"))
        precondition(source.contains("NoteSelection.focusedIDAfterClearingSearch("))
        // A search that ends during multi-selection ends its session, and a
        // note the person opens is theirs, even one the search opened.
        precondition(source.contains("if !isSearchActive {\n                    endSearchSession()\n                }"))
        precondition(source.contains(".onChange(of: selectedItemID) { newID in"))
        precondition(source.contains("if newID != noteOpenedBySearch {\n                noteOpenedBySearch = nil\n            }"))
        precondition(source.contains("} else if isSearchActive, filteredHistory.isEmpty {\n            emptyDetailNoSearchResults"))
        precondition(source.contains("selection.focus(visibleIDs.first)"))
        precondition(source.contains("!knownHistoryIDs.contains(newest),\n                      visibleIDs.contains(newest) {"))

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
        // #409: deletion keeps its confirmation, then settled notes get a Cancel toast.
        // #254: unrecovered recordings in the selection are deleted now, with
        // their pieces; AppState sends the rest to the Cancel toast.
        precondition(perform.contains("appState.deleteConfirmedHistoryEntries(ids: ids)"))
        precondition(perform.contains("deleteConfirmedNote(ids[0])"))
        let request = try body(of: "private func requestDeletion(of id: UUID? = nil)", in: source)
        precondition(request.contains("showDeletionConfirmation = true"))
        let single = try body(of: "private func deleteConfirmedNote(_ id: UUID)", in: source)
        precondition(single.contains("if appState.canDeleteHistoryEntryCancellably(id: id) {"))
        precondition(single.contains("appState.deleteHistoryEntryCancellably(id: id)"))
        // A note still recording or processing is deleted for good after the dialog.
        precondition(single.contains("appState.deleteHistoryEntry(id: id)"))
        // Deleting one unchecked note from the context menu keeps selection mode.
        precondition(single.contains("} else if wasFocused, !selection.isSelectionModeRequested {"))
        precondition(source.contains("Text(\"Delete this note?\")"))
        precondition(source.contains("Text(\"You can cancel for a few seconds after deleting.\")"))
        precondition(source.contains("@State private var showDeleteConfirmation = false"))
        precondition(source.contains("localizedCatalogFormat(\"%lld notes deleted\", count)"))
        precondition(source.contains("action: { appState.cancelPendingNoteDeletion() }"))
        precondition(source.contains("if let pending = appState.pendingNoteDeletion {"))
        precondition(source.contains(".announcement: noteDeletionToastMessage(count: pending.noteCount)"))
        let toast = try body(of: "private struct NoteBrowserToastView: View", in: source)
        precondition(toast.contains("Button(action: action)"))
        let monitor0 = try body(of: "private struct NoteBrowserKeyCommandMonitor", in: source)
        precondition(monitor0.contains("charactersIgnoringModifiers: event.charactersIgnoringModifiers"))

        // Busy notes can't join a selection.
        let selectable = try body(of: "private func isBulkSelectable(_ id: UUID, in history: [PipelineHistoryItem]) -> Bool", in: source)
        precondition(selectable.contains(".isBulkSelectable"))
        precondition(selectable.contains("!appState.meetingSummaryGeneratingNoteIDs.contains(id)"))
        // Notes that become busy while checked leave the selection.
        precondition(source.contains(".onChange(of: appState.meetingSummaryGeneratingNoteIDs) { _ in\n            selection.retainSelectable(isBulkSelectable)"))
        precondition(source.contains(".onChange(of: appState.retryingItemIDs) { _ in\n            selection.retainSelectable(isBulkSelectable)"))
        precondition(source.contains("selection.retainSelectable { isBulkSelectable($0, in: newHistory) }"))

        // Keyboard shortcuts stay inside this window and never steal text editing keys.
        let monitor = try body(of: "private struct NoteBrowserKeyCommandMonitor", in: source)
        precondition(monitor.contains("event.window === window"))
        precondition(monitor.contains("!(window.firstResponder is NSText)"))
        precondition(monitor.contains("NSEvent.removeMonitor(monitor)"))
        precondition(source.contains(".background(NoteBrowserKeyCommandMonitor(handle: handleKeyCommand))"))

        // New notes don't replace a multi-selection, and search keeps it to visible notes.
        precondition(source.contains("// Keep a multi-selection; new notes don't take over while selecting."))
        precondition(source.contains("selection.retainVisible(filteredHistory.map(\\.id))"))
        // The history publisher fires before the change lands, so search is applied to the new value.
        precondition(source.contains("selection.retainVisible(newHistory.filter(matchesSearch).map(\\.id))"))
        precondition(source.contains("return appState.pipelineHistory.filter(matchesSearch)"))

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
