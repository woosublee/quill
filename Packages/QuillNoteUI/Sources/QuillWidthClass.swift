import CoreGraphics
import QuillDesignTokens

/// How much width a layout has (#697), from the width of what it arranges.
/// Screens lay out by this, never by device model, so a new size works
/// without a new code path and the iPhone Duo re-lays out as it folds and
/// unfolds. The edges are `QuillBreakpoint` tokens.
///
/// Pass the width of the container the decision is about: the window (or
/// scene) to decide whether the note list sits beside the note, and a
/// column's own width for a view laid out inside that column. A column is
/// narrower than its window, so the two can differ: the Mac's window is
/// always `wide`, while its note column alone can be as narrow as 520 pt.
public enum QuillWidthClass: Int, Comparable, CaseIterable, Sendable {
    /// One phone column: every iPhone in portrait, the iPhone Duo folded,
    /// iPad Slide Over and narrow Split View.
    case compact
    /// Room to spare beside one column, but not for the note list beside
    /// the note: the iPhone Duo unfolded in portrait, an iPad mini in
    /// portrait, half of a large iPad.
    case regular
    /// A window with room for the note list beside the note, as on the Mac
    /// (whose note window is never narrower than `QuillBreakpoint.wide`).
    case wide

    /// The class for a container this many points wide. A width that isn't
    /// a number yet (SwiftUI can propose infinity or zero before layout) or
    /// is negative counts as compact, so a screen starts in its simplest
    /// layout.
    public init(containerWidth width: CGFloat) {
        guard width.isFinite else {
            self = .compact
            return
        }
        if width >= QuillBreakpoint.wide {
            self = .wide
        } else if width >= QuillBreakpoint.regular {
            self = .regular
        } else {
            self = .compact
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
