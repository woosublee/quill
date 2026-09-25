import AppKit

/// How a click on a Note Browser row changes the selection.
enum NoteSelectionModifier {
    /// A plain click.
    case none
    /// ⌘-click: add or remove one note.
    case toggle
    /// ⇧-click: select the range from the anchor note.
    case extend
}

/// Note Browser selection: one focused note shown in the detail pane, or
/// several notes selected for a bulk action.
struct NoteSelection: Equatable {
    /// The note shown when one note is selected; the last clicked note otherwise.
    private(set) var focusedID: UUID?
    private(set) var selectedIDs: Set<UUID>
    /// Entered with the Select button; stays open even with zero or one note.
    private(set) var isSelectionModeRequested = false
    private var anchorID: UUID?

    init(focusedID: UUID? = nil) {
        self.focusedID = focusedID
        self.selectedIDs = focusedID.map { [$0] } ?? []
        self.anchorID = focusedID
    }

    /// Whether the list shows checkboxes and the detail pane shows the selection summary.
    var showsSelectionUI: Bool {
        isSelectionModeRequested || selectedIDs.count > 1
    }

    mutating func click(
        _ id: UUID,
        modifier: NoteSelectionModifier,
        orderedIDs: [UUID],
        isSelectable: (UUID) -> Bool
    ) {
        switch modifier {
        case .none where isSelectionModeRequested:
            toggle(id, isSelectable: isSelectable)
        case .none:
            focus(id)
        case .toggle:
            if !showsSelectionUI, let focusedID, !isSelectable(focusedID) {
                selectedIDs = []
            }
            toggle(id, isSelectable: isSelectable)
        case .extend:
            extend(to: id, orderedIDs: orderedIDs, isSelectable: isSelectable)
        }
        collapseToSingleIfNeeded()
    }

    /// Opens selection mode with nothing checked; the focused note is kept to
    /// return to when selection mode ends.
    mutating func beginSelectionMode() {
        isSelectionModeRequested = true
        selectedIDs = []
        anchorID = nil
    }

    mutating func selectAll(orderedIDs: [UUID], isSelectable: (UUID) -> Bool) {
        let selectable = orderedIDs.filter(isSelectable)
        guard !selectable.isEmpty else { return }
        selectedIDs = Set(selectable)
        if let focusedID, !selectedIDs.contains(focusedID) {
            self.focusedID = selectable.first
        }
        collapseToSingleIfNeeded()
    }

    /// Closes selection mode and keeps only the focused note.
    mutating func endSelectionMode() {
        focus(focusedID)
    }

    /// Shows a single note, closing any multi-selection.
    mutating func focus(_ id: UUID?) {
        isSelectionModeRequested = false
        focusedID = id
        selectedIDs = id.map { [$0] } ?? []
        anchorID = id
    }

    /// Drops notes that are no longer listed, for example after a search or deletion.
    mutating func retainVisible(_ orderedIDs: [UUID]) {
        let visible = Set(orderedIDs)
        selectedIDs.formIntersection(visible)
        if let focusedID, !visible.contains(focusedID) {
            self.focusedID = orderedIDs.first(where: selectedIDs.contains)
        }
        if let anchorID, !visible.contains(anchorID) {
            self.anchorID = focusedID
        }
        collapseToSingleIfNeeded()
    }

    /// The note to show after deleting notes: the next remaining one below, else above.
    static func nextFocusedID(afterDeleting deletedIDs: Set<UUID>, in orderedIDs: [UUID]) -> UUID? {
        guard let lastDeletedIndex = orderedIDs.lastIndex(where: deletedIDs.contains) else {
            return orderedIDs.first
        }
        if let next = orderedIDs[(lastDeletedIndex + 1)...].first(where: { !deletedIDs.contains($0) }) {
            return next
        }
        return orderedIDs[..<lastDeletedIndex].last(where: { !deletedIDs.contains($0) })
    }

    private mutating func toggle(_ id: UUID, isSelectable: (UUID) -> Bool) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            if focusedID == id {
                // Keep the last clicked note to return to when selection mode ends.
                focusedID = selectedIDs.first ?? id
            }
        } else {
            guard isSelectable(id) else { return }
            selectedIDs.insert(id)
            focusedID = id
        }
        anchorID = id
    }

    private mutating func extend(
        to id: UUID,
        orderedIDs: [UUID],
        isSelectable: (UUID) -> Bool
    ) {
        guard let anchor = anchorID ?? focusedID,
              let anchorIndex = orderedIDs.firstIndex(of: anchor),
              let targetIndex = orderedIDs.firstIndex(of: id) else {
            toggle(id, isSelectable: isSelectable)
            return
        }
        let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        selectedIDs = Set(orderedIDs[range].filter(isSelectable))
        if selectedIDs.contains(id) {
            focusedID = id
        } else {
            focusedID = orderedIDs[range].first(where: selectedIDs.contains) ?? focusedID
        }
        anchorID = anchor
    }

    /// Without the Select button, one remaining note returns to the normal view.
    private mutating func collapseToSingleIfNeeded() {
        guard !isSelectionModeRequested, selectedIDs.count <= 1 else { return }
        let remaining = selectedIDs.first ?? focusedID
        let anchor = anchorID
        focus(remaining)
        if let anchor, anchor == remaining {
            anchorID = anchor
        }
    }
}

/// Note Browser list shortcuts.
enum NoteBrowserKeyCommand {
    case selectAll, endSelection, delete

    init?(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        let flags = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        switch keyCode {
        case 0 where flags == .command: self = .selectAll       // A
        case 53 where flags.isEmpty: self = .endSelection       // esc
        case 51 where flags.isEmpty, 117 where flags.isEmpty: self = .delete  // delete, forward delete
        default: return nil
        }
    }
}

/// Outcome of deleting several notes, each listed in the requested order.
struct NoteBulkDeletionResult: Equatable {
    var deletedIDs: [UUID] = []
    /// Still recording or processing, so not attempted.
    var skippedIDs: [UUID] = []
    var failedIDs: [UUID] = []
}
