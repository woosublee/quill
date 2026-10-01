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
        precondition(source.contains("openNoteForSearch(visibleIDs.first)"))
        precondition(source.contains("!knownHistoryIDs.contains(newest),\n                      visibleIDs.contains(newest) {"))

        // The header overlays the list at its width, so the no-results view
        // must fill the sidebar or the search field is squeezed away.
        precondition(source.contains("Text(\"No Search Results\")\n                        .font(.system(size: 12))\n                        .foregroundStyle(.tertiary)\n                    Spacer()\n                }\n                // Fill the sidebar: the header overlays this view at its\n                // width, so a narrow view squeezed the search field away.\n                .frame(maxWidth: .infinity)"))

        // The search keeps focus and stays open while it moves the open note,
        // and the header keeps its identity across the no-results view.
        precondition(source.contains("ZStack(alignment: .top) {\n            if appState.pipelineHistory.isEmpty {"))
        precondition(!source.contains("    private var noteList: some View {\n        Group {"))
        precondition(source.components(separatedBy: "openNoteForSearch(focused)").count == 3)
        // #436: a history change while searching opens notes the same way,
        // instead of taking focus from the search field.
        let historyChange = try body(of: ".onReceive(appState.$pipelineHistory)", in: source)
        precondition(historyChange.contains("openNoteForSearch(visibleIDs.first)"))
        precondition(historyChange.contains("openNoteForSearch(newest)"))
        precondition(!historyChange.contains("selection.focus("), "history changes don't open notes around the search")
        precondition(source.contains("if !isFocused && searchText.isEmpty && !isMovingOpenNoteForSearch {"))
        precondition(source.contains("DispatchQueue.main.async {\n            isSearchFieldFocused = true"))
        // #434: the delete-cancel toast shows the time left from when the
        // deletion started, and a partial Cancel keeps that start.
        let appStateSource = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        precondition(appStateSource.contains("PendingNoteDeletion(id: id, entries: entries, startedUptime: startedUptime)"))
        precondition(source.contains("startedUptime: pending.startedUptime,\n                        duration: AppState.noteDeletionCancelWindow"))
        precondition(!source.contains("@State private var startedAt = Date()"), "the countdown runs from the deletion, not from when the toast appears")
        precondition(source.contains("CancelCountdownFill(\n                                        startedUptime: countdown.startedUptime,"))
        // #436: the countdown uses system awake time, like the timer that ends
        // the Cancel window, so it still matches after the Mac sleeps.
        precondition(appStateSource.contains("startedUptime: TimeInterval = ProcessInfo.processInfo.systemUptime"))
        let countdownFill = try body(of: "private struct CancelCountdownFill: View", in: source)
        precondition(countdownFill.contains("now: ProcessInfo.processInfo.systemUptime"))
        precondition(!countdownFill.contains("context.date.timeIntervalSince"), "the countdown doesn't measure wall-clock time")
        // #440: deletion notices sit at the bottom of the note list in the
        // toolbar's glass capsule, never over the note detail, and a deleted
        // summary gets the same Cancel.
        let sidebar = try body(of: "private var sidebarPanel: some View", in: source)
        precondition(sidebar.contains("deletionCapsule"))
        let detailOverlay = try body(of: "var body: some View", in: source)
        precondition(!detailOverlay.contains("NoteBrowserToastView(\n                            message: noteDeletionToastMessage"))
        let capsule = try body(of: "private var deletionCapsule: some View", in: source)
        precondition(capsule.contains("cancel: { appState.cancelPendingNoteDeletion() }"))
        precondition(capsule.contains("cancel: { appState.cancelPendingSummaryDeletion() }"))
        precondition(capsule.contains("localizedCatalogString(\"Summary deleted\")"))
        let capsuleView = try body(of: "private struct NoteDeletionCapsule: View", in: source)
        precondition(capsuleView.contains("glassEffect(.regular, in: shape)"))
        precondition(capsuleView.contains(".lineLimit(3)"), "long notices wrap in the narrow sidebar")
        precondition(capsuleView.contains("QuillTransparency.opaqueBackgroundColor"))
        // The list keeps its last rows clear of the capsule.
        precondition(source.contains("+ (isShowingDeletionCapsule ? deletionCapsuleHeight + 10 : 0))"))
        let appStateSource2 = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        precondition(appStateSource2.contains("!meetingSummaryGeneratingNoteIDs.contains(pending.noteID) else { return }"))
        precondition(source.contains("TimelineView(.periodic(from: steppingStart, by: 1))"))

        // #437: the recording's own note has no toolbar and no Delete… while
        // it records, and asking to delete it explains why not.
        precondition(source.contains("if !appState.isRecordingInProgress(noteID: item.id) {\n                floatingToolbar"))
        precondition(source.contains("|| appState.isRecordingInProgress(noteID: item.id)"))
        precondition(source.contains("\"Can’t delete while recording\""), "short notices fit on one line in the sidebar")
        precondition(source.contains("\"Can’t delete while recovering\""))
        // It stays protected after the stop, until its transcript is saved.
        let appStateSource3 = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        precondition(appStateSource3.contains("if currentRecordingLiveNoteID == noteID { return true }"))
        precondition(appStateSource3.contains("$0.id == noteID || $0.liveNoteID == noteID"))
        precondition(!appStateSource3.contains("return isRecording\n            && pipelineHistory.first(where: { $0.id == noteID })?.machineStatus == .liveRecording"), "only notes tied to recording or transcription work are refused")
        precondition(appStateSource3.contains("if pendingAudioOnlyStopIDs.contains(noteID) { return true }"), "a record-only note being saved is protected too")
        let settingsSource = try String(contentsOfFile: "Sources/SettingsView.swift", encoding: .utf8)
        precondition(settingsSource.contains("|| appState.isRecordingInProgress(noteID: item.id)"), "the Settings history trash button is disabled too")

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
