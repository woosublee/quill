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
    public static let space9: CGFloat = 9
    public static let space10: CGFloat = 10
    public static let space12: CGFloat = 12
    public static let space14: CGFloat = 14
    public static let space16: CGFloat = 16
    public static let space20: CGFloat = 20
    public static let space24: CGFloat = 24
    public static let space40: CGFloat = 40
    public static let space60: CGFloat = 60

    /// Every step by its token name, smallest first.
    public static let scale: [(name: String, value: CGFloat)] = [
        ("space-2", space2), ("space-3", space3), ("space-4", space4),
        ("space-6", space6), ("space-8", space8), ("space-9", space9),
        ("space-10", space10), ("space-12", space12), ("space-14", space14),
        ("space-16", space16), ("space-20", space20), ("space-24", space24),
        ("space-40", space40), ("space-60", space60),
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

    /// `hairline-strong`: the 1 pt edge of a banner, an empty-state disc,
    /// and the work-status capsule. The label color in both appearances.
    public static let hairlineStrong = SchemeTint(
        light: Tint(base: .primary, opacity: 0.08),
        dark: Tint(base: .primary, opacity: 0.08)
    )

    /// Every tint by its token name.
    public static let tints: [(name: String, value: SchemeTint)] = [
        ("stroke-glass", strokeGlass),
        ("fill-toolbar-hover", fillToolbarHover),
        ("fill-pressed", fillPressed),
        ("hairline-strong", hairlineStrong),
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

    /// `shadow-status`: the work-status capsule over a note's text
    /// ("Retranscribing...", "Creating summary…").
    public static let status = QuillShadow(opacity: 0.12, radius: 8, x: 0, y: 2)

    /// Every shadow by its token name.
    public static let all: [(name: String, value: QuillShadow)] = [
        ("shadow-glass", glass),
        ("shadow-status", status),
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

    /// `size-status-progress`: the width of a work-status progress bar.
    public static let statusProgress: CGFloat = 200
}

/// Named opacities, applied to a whole view or a fill.
public enum QuillOpacity {
    /// `opacity-status-wash`: the note's own background laid over its text
    /// while work will replace it, so the text stays readable underneath.
    public static let statusWash: Double = 0.35

    /// Every opacity this module carries, by its token name.
    public static let all: [(name: String, value: Double)] = [
        ("opacity-status-wash", statusWash),
    ]
}

/// Text styles. On the Mac a style is a fixed size; on the iPhone and iPad
/// it follows Dynamic Type from the text style docs/design-system/2-platforms.md
/// maps it to. `lineHeight` is the Mac's line box from tokens.json, kept so
/// the test can compare it: SwiftUI sets line spacing, not line height, so
/// `font` doesn't use it.
public struct QuillTypeStyle: Sendable, Equatable {
    /// The system text style an iOS style scales with.
    public enum DynamicStyle: Sendable, Equatable {
        case subheadline
        case footnote

        public var textStyle: Font.TextStyle {
            switch self {
            case .subheadline: return .subheadline
            case .footnote: return .footnote
            }
        }
    }

    /// The Mac size in points.
    public let size: CGFloat
    public let lineHeight: CGFloat
    /// The CSS weight tokens.json uses, 100 to 900 in steps of 100.
    public let weight: Int
    public let dynamicStyle: DynamicStyle
    /// Digits all one width, for numbers that change in place (a percentage).
    public let monospacedDigits: Bool

    public init(size: CGFloat, lineHeight: CGFloat, weight: Int, dynamicStyle: DynamicStyle, monospacedDigits: Bool = false) {
        self.size = size
        self.lineHeight = lineHeight
        self.weight = weight
        self.dynamicStyle = dynamicStyle
        self.monospacedDigits = monospacedDigits
    }

    /// The SwiftUI weight for `weight`, or nil for a value that isn't one of
    /// the nine CSS weights.
    public var fontWeight: Font.Weight? {
        switch weight {
        case 100: return .ultraLight
        case 200: return .thin
        case 300: return .light
        case 400: return .regular
        case 500: return .medium
        case 600: return .semibold
        case 700: return .bold
        case 800: return .heavy
        case 900: return .black
        default: return nil
        }
    }

    public var font: Font {
        let weight = fontWeight ?? .regular
        #if os(macOS)
        let font = Font.system(size: size, weight: weight)
        #else
        let font = Font.system(dynamicStyle.textStyle, weight: weight)
        #endif
        return monospacedDigits ? font.monospacedDigit() : font
    }

    /// `empty-title`: an empty state's title, and the work status shown
    /// alone in the middle of a note with no text yet.
    public static let emptyTitle = QuillTypeStyle(size: 15, lineHeight: 20, weight: 600, dynamicStyle: .subheadline)
    /// `status-title`: the work status over a note's text ("Retranscribing...").
    public static let statusTitle = QuillTypeStyle(size: 13, lineHeight: 16, weight: 600, dynamicStyle: .subheadline)
    /// `status-percent`: the percentage beside a work status's progress bar.
    public static let statusPercent = QuillTypeStyle(
        size: 13, lineHeight: 16, weight: 400, dynamicStyle: .subheadline, monospacedDigits: true
    )
    /// `status-detail`: why work is waiting or paused, under its title.
    public static let statusDetail = QuillTypeStyle(size: 12, lineHeight: 15, weight: 400, dynamicStyle: .footnote)

    /// Every style this module carries, by its token name.
    public static let all: [(name: String, value: QuillTypeStyle)] = [
        ("empty-title", emptyTitle),
        ("status-title", statusTitle),
        ("status-percent", statusPercent),
        ("status-detail", statusDetail),
    ]
}

/// Where a layout changes with the width it has (#697). A layout reads the
/// width of what it arranges, not the device: whether the note list sits
/// beside the note is decided from the window's (scene's) width, and a view
/// inside one column decides from that column's width. The iPhone Duo
/// crosses `regular` when it unfolds, and an iPad window crosses both as
/// Split View and Stage Manager resize it. `QuillWidthClass` in QuillNoteUI
/// turns a width into a class.
public enum QuillBreakpoint {
    /// `breakpoint-regular`: from here a layout has room for more than one
    /// phone column. Every iPhone in portrait and the iPhone Duo folded sit
    /// below it; the Duo unfolded and an iPad mini in portrait sit above it.
    public static let regular: CGFloat = 600
    /// `breakpoint-wide`: a window with room for the note list beside the
    /// note, as on the Mac: its 280 pt list plus its narrowest 520 pt note
    /// (the Mac note window's 800 pt minimum width).
    public static let wide: CGFloat = 800

    /// Every breakpoint by its token name, smallest first.
    public static let scale: [(name: String, value: CGFloat)] = [
        ("breakpoint-regular", regular),
        ("breakpoint-wide", wide),
    ]
}
