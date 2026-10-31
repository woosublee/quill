import CoreGraphics
import QuillDesignTokens
import QuillNoteUI

/// The note layout rules (#697): the window decides whether the list sits
/// beside the note, the note column decides the rest.
@main
struct QuillNoteLayoutTests {
    static func main() {
        testListBesideNoteFollowsTheWindow()
        testCompactHeightKeepsOneColumn()
        testInNoteLayoutPerColumnClass()
        testInNoteLayoutFollowsTheColumnNotTheWindow()
        testColumnWidthFromTheWindow()
        testWidthsBeforeLayout()
        testListColumnWidthIsTheMacSidebar()
        print("QuillNoteLayoutTests passed")
    }

    private static func layout(window: CGFloat, compactHeight: Bool = false, column: CGFloat) -> QuillNoteLayout {
        QuillNoteLayout(windowWidth: window, isHeightCompact: compactHeight, noteColumnWidth: column)
    }

    private static func testListBesideNoteFollowsTheWindow() {
        let expected: [(String, CGFloat, Bool)] = [
            ("iPhone portrait", 393, false),
            ("iPhone Duo folded", 474, false),
            ("iPad mini portrait", 744, false),
            ("just below wide", QuillBreakpoint.wide - 0.5, false),
            ("Mac note window at its minimum", QuillBreakpoint.wide, true),
            ("11-inch iPad portrait", 820, true),
            ("iPad landscape", 1180, true),
        ]
        for (name, width, beside) in expected {
            precondition(
                QuillNoteLayout.showsListBesideNote(windowWidth: width, isHeightCompact: false) == beside,
                "\(name) (\(width) pt)"
            )
            precondition(QuillNoteLayout(windowWidth: width, isHeightCompact: false).showsListBesideNote == beside, "\(name) (\(width) pt), init")
        }
    }

    /// A phone in landscape is wide enough for the list but its height is
    /// compact, so it keeps one column.
    private static func testCompactHeightKeepsOneColumn() {
        for width: CGFloat in [852, 932, 956, 1180] {
            precondition(!QuillNoteLayout.showsListBesideNote(windowWidth: width, isHeightCompact: true), "\(width) pt, compact height")
        }
        let landscape = layout(window: 932, compactHeight: true, column: 932)
        precondition(!landscape.showsListBesideNote)
        precondition(landscape.noteColumnClass == .wide)
    }

    private static func testInNoteLayoutPerColumnClass() {
        let compact = layout(window: 393, column: 393)
        precondition(compact.noteColumnClass == .compact)
        precondition(compact.noteSideMargin == 16 && compact.noteSideMargin == QuillLayoutSize.noteMarginCompact)
        precondition(compact.bodyMaxWidth == nil, "compact text runs the column's width")

        let regular = layout(window: 744, column: 744)
        precondition(regular.noteColumnClass == .regular)
        precondition(regular.noteSideMargin == 24 && regular.noteSideMargin == QuillLayoutSize.noteMarginRegular)
        precondition(regular.bodyMaxWidth == 680 && regular.bodyMaxWidth == QuillLayoutSize.noteBodyMaxWidth)

        let wide = layout(window: 1366, column: 1366 - QuillNoteLayout.listColumnWidth)
        precondition(wide.noteColumnClass == .wide)
        precondition(wide.noteSideMargin == regular.noteSideMargin)
        precondition(wide.bodyMaxWidth == regular.bodyMaxWidth)
    }

    /// The window can be wide while the note column beside the list is
    /// compact (an 800 pt window leaves 520 pt), and the note's own layout
    /// follows the column.
    private static func testInNoteLayoutFollowsTheColumnNotTheWindow() {
        let narrowColumn = layout(window: 800, column: 800 - QuillNoteLayout.listColumnWidth)
        precondition(narrowColumn.showsListBesideNote)
        precondition(narrowColumn.noteColumnClass == .compact)
        precondition(narrowColumn.noteSideMargin == QuillLayoutSize.noteMarginCompact)

        let wideColumnBesideList = layout(window: 1180, column: 1180 - QuillNoteLayout.listColumnWidth)
        precondition(wideColumnBesideList.showsListBesideNote)
        precondition(wideColumnBesideList.noteColumnClass == .wide)
    }

    /// SwiftUI can propose zero or infinity before layout: both count as
    /// compact, so the screen starts in one column.
    /// Without a measured column, the column is the window less the list
    /// when the list sits beside the note.
    private static func testColumnWidthFromTheWindow() {
        precondition(QuillNoteLayout.noteColumnWidth(windowWidth: 393, isHeightCompact: false) == 393)
        precondition(QuillNoteLayout.noteColumnWidth(windowWidth: 744, isHeightCompact: false) == 744)
        precondition(QuillNoteLayout.noteColumnWidth(windowWidth: 820, isHeightCompact: false) == 540)
        precondition(QuillNoteLayout.noteColumnWidth(windowWidth: 932, isHeightCompact: true) == 932)
        // An 11-inch iPad in portrait shows the list, which leaves a compact note.
        let portrait = QuillNoteLayout(windowWidth: 820, isHeightCompact: false)
        precondition(portrait.showsListBesideNote && portrait.noteColumnClass == .compact)
        precondition(portrait.noteSideMargin == QuillLayoutSize.noteMarginCompact)
        precondition(portrait == layout(window: 820, column: 540))
        // iPad landscape: 1180 − 280 = 900, a wide column.
        let landscape = QuillNoteLayout(windowWidth: 1180, isHeightCompact: false)
        precondition(landscape.noteColumnClass == .wide)
    }

    private static func testWidthsBeforeLayout() {
        for width: CGFloat in [0, .infinity, .nan, -1] {
            let before = layout(window: width, column: width)
            precondition(!before.showsListBesideNote, "\(width)")
            precondition(before.noteColumnClass == .compact, "\(width)")
        }
    }

    private static func testListColumnWidthIsTheMacSidebar() {
        precondition(QuillNoteLayout.listColumnWidth == 280)
        precondition(QuillNoteLayout.listColumnWidth == QuillLayoutSize.sidebarNotes)
    }
}
