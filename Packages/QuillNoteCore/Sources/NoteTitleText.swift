import Foundation

/// A note's title is one line on both apps (quill-universal-private#355,
/// #361). A title saved with line breaks, such as one typed into an older
/// multi-line field or a calendar event's title, reads with each run of
/// line breaks as one space, wherever it shows, is saved, or names a file.
public enum NoteTitleText {
    /// The title as one line: every run of line breaks (with the spaces
    /// around it) becomes one space, the ends are trimmed, and spaces inside
    /// a line stay. Nil when nothing is left.
    public static func oneLine(_ title: String?) -> String? {
        guard let title else { return nil }
        let oneLine = title
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return oneLine.isEmpty ? nil : oneLine
    }
}
