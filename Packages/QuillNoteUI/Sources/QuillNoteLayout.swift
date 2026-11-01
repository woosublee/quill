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
///   side margins and how wide its text runs.
///
/// | Note column | Side margin | Body width     |
/// | ----------- | ----------- | -------------- |
/// | compact     | 16          | column width   |
/// | regular     | 24          | at most 680    |
/// | wide        | 24          | at most 680    |
///
/// A wide column gets the regular values; the decisions gave it none of its
/// own. The work-status capsule ("Retranscribing...") sits in the middle of
/// the visible note area at every width, as on the Mac (owner decision
/// 2026-10-31, #697), so it isn't part of this layout.
///
/// The Mac adopts only the list column width (`listColumnWidth`). Its note
/// column is the window less the list: 520 pt at the window's 800 pt
/// minimum, so `compact` here until the window reaches 880 pt. Its note
/// text uses its own 40 and 60 pt margins with no maximum width, so it keeps
/// its own in-note layout; see
/// `Sources/NoteBrowserView.swift`.
public struct QuillNoteLayout: Equatable, Sendable {
    /// The note list's column width when it sits beside the note: the
    /// `size-sidebar-notes` token (`QuillLayoutSize.sidebarNotes`), 280 on
    /// the Mac and 320 on the iPad (quill-universal-private#306), named here beside the rule that
    /// uses it.
    public static let listColumnWidth = QuillLayoutSize.sidebarNotes

    /// How recording starts and stops in a window this wide (quill-universal-private#306). With the
    /// list beside the note, the Mac's one floating Record button sits at the
    /// bottom of the list column; otherwise (an iPhone, a narrow iPad
    /// window) the full-width recorder bar does, with its timer and pause.
    public static func recordingControl(windowWidth: CGFloat, isHeightCompact: Bool) -> QuillRecordingControl {
        QuillRecordingControl(showsListBesideNote: showsListBesideNote(windowWidth: windowWidth, isHeightCompact: isHeightCompact))
    }

    /// How recording starts and stops in this layout's window.
    public var recordingControl: QuillRecordingControl {
        QuillRecordingControl(showsListBesideNote: showsListBesideNote)
    }

    /// Whether the note list sits beside the note in a window this wide.
    public let showsListBesideNote: Bool
    /// The note column's width class, from its own width.
    public let noteColumnClass: QuillWidthClass
    /// Leading and trailing margin around the note's content.
    public let noteSideMargin: CGFloat
    /// The widest the note's text runs, centred in the column; nil runs it
    /// across the column (inside the side margins).
    public let bodyMaxWidth: CGFloat?

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
        case .regular, .wide:
            noteSideMargin = QuillLayoutSize.noteMarginRegular
            bodyMaxWidth = QuillLayoutSize.noteBodyMaxWidth
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

/// The control a note screen records with (quill-universal-private#306), from `QuillNoteLayout`.
public enum QuillRecordingControl: Equatable, Sendable {
    /// The Mac's round Record button at the bottom of the list column: red
    /// to start, the processing orange with a stop square to stop. No timer
    /// or pause; the recording note's list row shows the time.
    case floatingRecordButton
    /// The full-width recorder bar at the bottom of the screen, with the
    /// elapsed time, pause, and stop (the iPhone's).
    case recorderBar

    /// The one rule: the floating button exactly where the list sits
    /// beside the note.
    init(showsListBesideNote: Bool) {
        self = showsListBesideNote ? .floatingRecordButton : .recorderBar
    }
}
