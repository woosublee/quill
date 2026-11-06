/// Which tab of a note shows: its transcript or its meeting summary, on the
/// Mac and the iPhone (#697).
public enum NoteContentMode: Hashable, Sendable {
    case transcript
    case summary
}
