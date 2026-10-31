import CoreGraphics
import QuillDesignTokens

/// How a note screen lays out for the room it has (#697, the owner's
/// width-layout decisions of 2026-10-31). Pure rules, no views: each app
/// measures its window and its note column and reads the answers here.
///
/// Two widths decide two different things:
/// - The window's (scene's) width, and whether its height is compact,
///   decide whether the note list sits beside the note: only in a `wide`
///   window of regular height. A phone in landscape can be 800 pt or more
///   wide, but its height is compact, so it keeps one column, as Apple's
///   vertical size class does.
/// - The note column's own width decides everything inside the note: its
///   side margins, how wide its text runs, and where the work-status
///   capsule sits.
///
/// | Note column | Side margin | Body width     | Capsule  |
/// | ----------- | ----------- | -------------- | -------- |
/// | compact     | 16          | column width   | top      |
/// | regular     | 24          | at most 680    | centred  |
/// | wide        | 24          | at most 680    | centred  |
///
/// A wide column gets the regular values; the decisions gave it none of its
/// own. A phone in landscape keeps one column, but its note column is
/// regular or wide by width, so its capsule is centred.
///
/// The Mac adopts only the list column width (`listColumnWidth`). Its note
/// column is the window less the list: 520 pt at the window's 800 pt
/// minimum, so `compact` here until the window reaches 880 pt. Its note
/// text uses its own 40 and 60 pt margins with no maximum width and its
/// capsule is always centred, so it keeps its own in-note layout; see
/// `Sources/NoteBrowserView.swift`.
public struct QuillNoteLayout: Equatable, Sendable {
    /// Where the work-status capsule ("Retranscribing...") sits over a
    /// note's text.
    public enum CapsulePlacement: Equatable, Sendable {
        /// In the middle of the visible note area.
        case centered
        /// Above the text, at the top of the note area.
        case top
    }

    /// The note list's column width when it sits beside the note: the
    /// `size-sidebar-notes` token (`QuillLayoutSize.sidebarNotes`), the Mac
    /// note browser's value, named here beside the rule that uses it.
    public static let listColumnWidth = QuillLayoutSize.sidebarNotes

    /// Whether the note list sits beside the note in a window this wide.
    public let showsListBesideNote: Bool
    /// The note column's width class, from its own width.
    public let noteColumnClass: QuillWidthClass
    /// Leading and trailing margin around the note's content.
    public let noteSideMargin: CGFloat
    /// The widest the note's text runs, centred in the column; nil runs it
    /// across the column (inside the side margins).
    public let bodyMaxWidth: CGFloat?
    public let capsulePlacement: CapsulePlacement

    /// - Parameters:
    ///   - windowWidth: the whole window's (scene's) width, before any
    ///     insets or dividers.
    ///   - isHeightCompact: true where the platform reports a compact
    ///     vertical size class (an iPhone in landscape). Always false on
    ///     the Mac.
    ///   - noteColumnWidth: the note column's own width as measured. With
    ///     the list beside the note it is the window less the list (and any
    ///     divider), not the window's width; `init(windowWidth:isHeightCompact:)`
    ///     works it out when nothing else narrows the column.
    public init(windowWidth: CGFloat, isHeightCompact: Bool, noteColumnWidth: CGFloat) {
        showsListBesideNote = Self.showsListBesideNote(windowWidth: windowWidth, isHeightCompact: isHeightCompact)
        let columnClass = QuillWidthClass(containerWidth: noteColumnWidth)
        noteColumnClass = columnClass
        switch columnClass {
        case .compact:
            noteSideMargin = QuillLayoutSize.noteMarginCompact
            bodyMaxWidth = nil
            capsulePlacement = .top
        case .regular, .wide:
            noteSideMargin = QuillLayoutSize.noteMarginRegular
            bodyMaxWidth = QuillLayoutSize.noteBodyMaxWidth
            capsulePlacement = .centered
        }
    }

    /// The layout for a note column that takes the whole window, less the
    /// list column when the list sits beside the note.
    public init(windowWidth: CGFloat, isHeightCompact: Bool) {
        self.init(
            windowWidth: windowWidth,
            isHeightCompact: isHeightCompact,
            noteColumnWidth: Self.noteColumnWidth(windowWidth: windowWidth, isHeightCompact: isHeightCompact)
        )
    }

    /// The note column's width in a window this wide: the window less the
    /// list column when the list sits beside the note, else the window.
    public static func noteColumnWidth(windowWidth: CGFloat, isHeightCompact: Bool) -> CGFloat {
        showsListBesideNote(windowWidth: windowWidth, isHeightCompact: isHeightCompact)
            ? windowWidth - listColumnWidth
            : windowWidth
    }

    /// Whether the note list sits beside the note: a `wide` window whose
    /// height isn't compact. Otherwise the list and the note are separate
    /// screens.
    public static func showsListBesideNote(windowWidth: CGFloat, isHeightCompact: Bool) -> Bool {
        !isHeightCompact && QuillWidthClass(containerWidth: windowWidth) == .wide
    }
}
