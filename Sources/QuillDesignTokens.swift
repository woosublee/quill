import SwiftUI

/// Design tokens shared by Quill's views. Names and values match
/// docs/design-system/tokens.json (`space-12` is `QuillSpacing.space12`).
/// QuillDesignTokensTests compares the spacing and radius scales and the
/// issue colors with that file. New views take their values from here
/// instead of writing literals.

enum QuillSpacing {
    static let space2: CGFloat = 2
    static let space3: CGFloat = 3
    static let space4: CGFloat = 4
    static let space6: CGFloat = 6
    static let space8: CGFloat = 8
    static let space10: CGFloat = 10
    static let space12: CGFloat = 12
    static let space14: CGFloat = 14
    static let space16: CGFloat = 16
    static let space20: CGFloat = 20
    static let space24: CGFloat = 24
    static let space40: CGFloat = 40

    /// Every step by its token name, smallest first.
    static let scale: [(name: String, value: CGFloat)] = [
        ("space-2", space2), ("space-3", space3), ("space-4", space4),
        ("space-6", space6), ("space-8", space8), ("space-10", space10),
        ("space-12", space12), ("space-14", space14), ("space-16", space16),
        ("space-20", space20), ("space-24", space24), ("space-40", space40),
    ]
}

enum QuillRadius {
    static let radius3: CGFloat = 3
    static let radius6: CGFloat = 6
    static let radius8: CGFloat = 8
    static let radius9: CGFloat = 9
    static let radius10: CGFloat = 10
    static let radius12: CGFloat = 12
    static let radius18: CGFloat = 18
    static let radius26: CGFloat = 26

    /// Every step by its token name, smallest first. Capsules use `Capsule()`.
    static let scale: [(name: String, value: CGFloat)] = [
        ("radius-3", radius3), ("radius-6", radius6), ("radius-8", radius8),
        ("radius-9", radius9), ("radius-10", radius10), ("radius-12", radius12),
        ("radius-18", radius18), ("radius-26", radius26),
    ]
}

/// Colors that are not plain system colors. Everything else uses the system
/// semantic colors (`.primary`, `.secondary`, `Color.accentColor`).
enum QuillColor {
    struct RGB {
        let red: Double
        let green: Double
        let blue: Double

        var color: Color { Color(red: red, green: green, blue: blue) }
    }

    /// `issue-warning`: muted amber for warning icons. Icon color only; it is
    /// below 3:1 on light backgrounds, so text stays secondary.
    static let issueWarningRGB = RGB(red: 0.95, green: 0.70, blue: 0.36)
    /// `issue-error`: softened red for error icons. Icon color only.
    static let issueErrorRGB = RGB(red: 1.0, green: 0.48, blue: 0.44)

    static let issueWarning = issueWarningRGB.color
    static let issueError = issueErrorRGB.color
}
