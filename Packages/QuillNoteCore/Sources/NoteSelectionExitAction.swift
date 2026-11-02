/// What the note list's header button reads in selection mode, the same on
/// the Mac and the iPhone (#779). With nothing selected it reads Done; once a
/// note is selected it reads Cancel. Either way it leaves selection mode
/// without acting on the selected notes. Each app keeps its own selection
/// state and button, and translates `titleKey` with its own String Catalog.
public enum NoteSelectionExitAction: CaseIterable, Equatable, Sendable {
    case done
    case cancel

    public init(selectedCount: Int) {
        self = selectedCount > 0 ? .cancel : .done
    }

    /// The button's String Catalog key.
    public var titleKey: String {
        switch self {
        case .done: return "Done"
        case .cancel: return "Cancel"
        }
    }
}
