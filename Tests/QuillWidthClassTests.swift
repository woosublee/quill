import CoreGraphics
import QuillDesignTokens
import QuillNoteUI

/// Container width to width class (#697), at the breakpoint tokens' edges
/// and for the widths the breakpoints were chosen around.
@main
struct QuillWidthClassTests {
    static func main() {
        testEdges()
        testWidthsTheBreakpointsWereChosenFor()
        testWidthsBeforeLayoutAreCompact()
        testOrder()
        print("QuillWidthClassTests passed")
    }

    private static func widthClass(_ width: CGFloat) -> QuillWidthClass {
        QuillWidthClass(containerWidth: width)
    }

    /// Each class starts at its breakpoint and ends just below the next.
    private static func testEdges() {
        precondition(widthClass(0) == .compact)
        precondition(widthClass(QuillBreakpoint.regular - 0.5) == .compact)
        precondition(widthClass(QuillBreakpoint.regular) == .regular)
        precondition(widthClass(QuillBreakpoint.wide - 0.5) == .regular)
        precondition(widthClass(QuillBreakpoint.wide) == .wide)
        precondition(widthClass(10_000) == .wide)
    }

    /// The widths in the breakpoint tokens' notes, in points. The iPhone Duo
    /// figures are estimates: its inner and outer screens share an aspect
    /// ratio of about √2, at phone density.
    private static func testWidthsTheBreakpointsWereChosenFor() {
        let expected: [(String, CGFloat, QuillWidthClass)] = [
            ("smallest iPhone, portrait", 320, .compact),
            ("largest iPhone, portrait", 440, .compact),
            ("iPhone Duo folded", 474, .compact),
            ("iPad Slide Over", 375, .compact),
            ("iPhone Duo unfolded, portrait", 670, .regular),
            ("iPad mini, portrait", 744, .regular),
            ("13-inch iPad, half of Split View", 683, .regular),
            ("11-inch iPad, portrait", 820, .wide),
            ("iPhone Duo unfolded, landscape", 947, .wide),
            ("iPad mini, landscape", 1133, .wide),
            ("Mac note window at its minimum", 800, .wide),
        ]
        for (name, width, widthClass) in expected {
            precondition(Self.widthClass(width) == widthClass, "\(name) (\(width) pt) is \(Self.widthClass(width))")
        }
    }

    private static func testWidthsBeforeLayoutAreCompact() {
        precondition(widthClass(.infinity) == .compact)
        precondition(widthClass(-.infinity) == .compact)
        precondition(widthClass(.nan) == .compact)
        precondition(widthClass(-1) == .compact)
    }

    private static func testOrder() {
        precondition(QuillWidthClass.compact < .regular && QuillWidthClass.regular < .wide)
        precondition(QuillWidthClass.allCases == [.compact, .regular, .wide])
    }
}
