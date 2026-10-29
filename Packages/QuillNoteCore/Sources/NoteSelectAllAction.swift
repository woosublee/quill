/// What the note list's Select All button does in selection mode, the same
/// on the Mac and the iPhone (#702). Once every selectable visible note is
/// selected, it reads Deselect All and clears the selection. Each app keeps
/// its own selection state and button, and translates `titleKey` with its
/// own String Catalog.
public enum NoteSelectAllAction: Equatable, Sendable {
    case selectAll
    case deselectAll

    /// Notes that can't be selected, such as a recording in progress, don't
    /// count toward "every". With nothing selectable, the button stays
    /// Select All.
    public init<ID: Hashable>(
        visibleIDs: [ID],
        selectedIDs: Set<ID>,
        isSelectable: (ID) -> Bool
    ) {
        let selectable = visibleIDs.filter(isSelectable)
        let selectsEveryNote = !selectable.isEmpty && selectable.allSatisfy(selectedIDs.contains)
        self = selectsEveryNote ? .deselectAll : .selectAll
    }

    /// The button's String Catalog key.
    public var titleKey: String {
        switch self {
        case .selectAll: return "Select All"
        case .deselectAll: return "Deselect All"
        }
    }
}
