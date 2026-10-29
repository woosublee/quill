import SwiftUI

/// Design tokens shared by the Mac and the iPhone (#623, #697). Names and
/// values match docs/design-system/tokens.json (`space-12` is
/// `QuillSpacing.space12`). A token can have a value per platform, as the
/// note toolbar's buttons do. QuillDesignTokensTests compares every token
/// here with that file. New views take their values from here instead of
/// writing literals.

public enum QuillSpacing {
    public static let space2: CGFloat = 2
    public static let space3: CGFloat = 3
    public static let space4: CGFloat = 4
    public static let space6: CGFloat = 6
    public static let space8: CGFloat = 8
    public static let space10: CGFloat = 10
    public static let space12: CGFloat = 12
    public static let space14: CGFloat = 14
    public static let space16: CGFloat = 16
    public static let space20: CGFloat = 20
    public static let space24: CGFloat = 24
    public static let space40: CGFloat = 40

    /// Every step by its token name, smallest first.
    public static let scale: [(name: String, value: CGFloat)] = [
        ("space-2", space2), ("space-3", space3), ("space-4", space4),
        ("space-6", space6), ("space-8", space8), ("space-10", space10),
        ("space-12", space12), ("space-14", space14), ("space-16", space16),
        ("space-20", space20), ("space-24", space24), ("space-40", space40),
    ]
}

public enum QuillRadius {
    public static let radius3: CGFloat = 3
    public static let radius6: CGFloat = 6
    public static let radius8: CGFloat = 8
    public static let radius9: CGFloat = 9
    public static let radius10: CGFloat = 10
    public static let radius12: CGFloat = 12
    public static let radius18: CGFloat = 18
    public static let radius26: CGFloat = 26

    /// Every step by its token name, smallest first. Capsules use `Capsule()`.
    public static let scale: [(name: String, value: CGFloat)] = [
        ("radius-3", radius3), ("radius-6", radius6), ("radius-8", radius8),
        ("radius-9", radius9), ("radius-10", radius10), ("radius-12", radius12),
        ("radius-18", radius18), ("radius-26", radius26),
    ]
}

/// Colors that are not plain system colors. Everything else uses the system
/// semantic colors (`.primary`, `.secondary`, `Color.accentColor`).
public enum QuillColor {
    public struct RGB: Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public var color: Color { Color(red: red, green: green, blue: blue) }
    }

    /// A fill or stroke drawn as the label color or white at some opacity.
    /// `primary` follows the appearance (dark ink in light, light ink in dark).
    public struct Tint: Sendable, Equatable {
        public enum Base: Sendable, Equatable {
            case primary
            case white
        }

        public let base: Base
        public let opacity: Double

        public var color: Color {
            switch base {
            case .primary: return Color.primary.opacity(opacity)
            case .white: return Color.white.opacity(opacity)
            }
        }
    }

    /// A tint for each appearance.
    public struct SchemeTint: Sendable, Equatable {
        public let light: Tint
        public let dark: Tint

        public func color(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? dark.color : light.color
        }
    }

    /// `issue-warning`: muted amber for warning icons. Icon color only; it is
    /// below 3:1 on light backgrounds, so text stays secondary.
    public static let issueWarningRGB = RGB(red: 0.95, green: 0.70, blue: 0.36)
    /// `issue-error`: softened red for error icons. Icon color only.
    public static let issueErrorRGB = RGB(red: 1.0, green: 0.48, blue: 0.44)

    public static let issueWarning = issueWarningRGB.color
    public static let issueError = issueErrorRGB.color

    /// `stroke-glass`: the 0.6 pt edge of a glass capsule (the note toolbar).
    public static let strokeGlass = SchemeTint(
        light: Tint(base: .primary, opacity: 0.10),
        dark: Tint(base: .white, opacity: 0.10)
    )
    /// `fill-toolbar-hover`: a round toolbar button under the pointer.
    public static let fillToolbarHover = SchemeTint(
        light: Tint(base: .primary, opacity: 0.07),
        dark: Tint(base: .white, opacity: 0.08)
    )
    /// `fill-pressed`: a capsule or toolbar button being pressed. The label
    /// color in both appearances, which tokens.json writes as black and white.
    public static let fillPressed = SchemeTint(
        light: Tint(base: .primary, opacity: 0.12),
        dark: Tint(base: .primary, opacity: 0.12)
    )

    /// Every tint by its token name.
    public static let tints: [(name: String, value: SchemeTint)] = [
        ("stroke-glass", strokeGlass),
        ("fill-toolbar-hover", fillToolbarHover),
        ("fill-pressed", fillPressed),
    ]
}

/// Named shadows. SwiftUI's `radius` is half the CSS blur in tokens.json.
public struct QuillShadow: Sendable, Equatable {
    public let opacity: Double
    public let radius: CGFloat
    public let x: CGFloat
    public let y: CGFloat

    /// `shadow-glass`: glass capsules (the note toolbar, the deletion notice).
    public static let glass = QuillShadow(opacity: 0.085, radius: 14, x: 0, y: 4)

    /// Every shadow by its token name.
    public static let all: [(name: String, value: QuillShadow)] = [
        ("shadow-glass", glass),
    ]
}

extension View {
    /// Draws a named black shadow.
    public func quillShadow(_ shadow: QuillShadow) -> some View {
        self.shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius, x: shadow.x, y: shadow.y)
    }
}

/// Control sizes. Some differ per platform: the Mac is sized for a pointer,
/// the iPhone for a finger.
public enum QuillControlSize {
    /// `size-note-toolbar`: the floating note toolbar's height.
    public static let noteToolbar: CGFloat = 48
    /// `size-note-toolbar-button`: a note toolbar button. On the iPhone it is
    /// the minimum touch target and grows with Dynamic Type.
    public static let noteToolbarButtonMac: CGFloat = 36
    public static let noteToolbarButtonIPhone: CGFloat = 44

    #if os(macOS)
    public static let noteToolbarButton = noteToolbarButtonMac
    #else
    public static let noteToolbarButton = noteToolbarButtonIPhone
    #endif
}
