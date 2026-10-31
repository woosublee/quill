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
    public static let space5: CGFloat = 5
    public static let space6: CGFloat = 6
    public static let space8: CGFloat = 8
    public static let space9: CGFloat = 9
    public static let space10: CGFloat = 10
    public static let space12: CGFloat = 12
    public static let space14: CGFloat = 14
    public static let space16: CGFloat = 16
    public static let space20: CGFloat = 20
    public static let space22: CGFloat = 22
    public static let space24: CGFloat = 24
    public static let space32: CGFloat = 32
    public static let space40: CGFloat = 40
    public static let space60: CGFloat = 60

    /// Every step by its token name, smallest first.
    public static let scale: [(name: String, value: CGFloat)] = [
        ("space-2", space2), ("space-3", space3), ("space-4", space4),
        ("space-5", space5), ("space-6", space6), ("space-8", space8), ("space-9", space9),
        ("space-10", space10), ("space-12", space12), ("space-14", space14),
        ("space-16", space16), ("space-20", space20), ("space-22", space22), ("space-24", space24),
        ("space-32", space32), ("space-40", space40), ("space-60", space60),
    ]
}

public enum QuillRadius {
    public static let radius3: CGFloat = 3
    public static let radius6: CGFloat = 6
    public static let radius7: CGFloat = 7
    public static let radius8: CGFloat = 8
    public static let radius9: CGFloat = 9
    public static let radius10: CGFloat = 10
    public static let radius12: CGFloat = 12
    public static let radius16: CGFloat = 16
    public static let radius18: CGFloat = 18
    public static let radius20: CGFloat = 20
    public static let radius26: CGFloat = 26

    /// Every step by its token name, smallest first. Capsules use `Capsule()`.
    public static let scale: [(name: String, value: CGFloat)] = [
        ("radius-3", radius3), ("radius-6", radius6), ("radius-7", radius7), ("radius-8", radius8),
        ("radius-9", radius9), ("radius-10", radius10), ("radius-12", radius12),
        ("radius-16", radius16), ("radius-18", radius18), ("radius-20", radius20),
        ("radius-26", radius26),
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

    /// A fill or stroke drawn as the label color, white, or the accent color
    /// at some opacity. `primary` follows the appearance (dark ink in light,
    /// light ink in dark); `accent` is `Color.accentColor`, the system accent
    /// the user picked.
    public struct Tint: Sendable, Equatable {
        public enum Base: Sendable, Equatable {
            case primary
            case white
            case accent
        }

        public let base: Base
        public let opacity: Double

        /// The same base at another opacity (a fill strengthened under
        /// Increase Contrast).
        public func withOpacity(_ opacity: Double) -> Tint {
            Tint(base: base, opacity: opacity)
        }

        public var color: Color {
            switch base {
            case .primary: return Color.primary.opacity(opacity)
            case .white: return Color.white.opacity(opacity)
            case .accent: return Color.accentColor.opacity(opacity)
            }
        }
    }

    /// An opaque color for each appearance.
    public struct SchemeRGB: Sendable {
        public let light: RGB
        public let dark: RGB

        public func color(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? dark.color : light.color
        }
    }

    /// `surface-page-iphone`: the iPhone app's page background, every
    /// screen's (#F5F5F7, #1C1C1E; iOS `backgroundPrimary`).
    public static let surfacePageIPhone = SchemeRGB(
        light: RGB(red: 245.0 / 255, green: 245.0 / 255, blue: 247.0 / 255),
        dark: RGB(red: 28.0 / 255, green: 28.0 / 255, blue: 30.0 / 255)
    )

    /// `surface-note`: the background of a note's page, which the
    /// work-status wash is drawn in. The Mac draws the system text
    /// background (`textBackgroundColor`, `surface-text` in tokens.json);
    /// the iPhone's note page is its app-wide page, `surface-page-iphone`.
    public static func surfaceNote(for colorScheme: ColorScheme) -> Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        surfacePageIPhone.color(for: colorScheme)
        #endif
    }

    /// A tint for each appearance.
    public struct SchemeTint: Sendable, Equatable {
        public let light: Tint
        public let dark: Tint

        public func color(for colorScheme: ColorScheme) -> Color {
            tint(for: colorScheme).color
        }

        public func tint(for colorScheme: ColorScheme) -> Tint {
            colorScheme == .dark ? dark : light
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

    /// `hairline`: the 1 pt edge of a settings card and a banner's row button.
    public static let hairline = SchemeTint(
        light: Tint(base: .primary, opacity: 0.06),
        dark: Tint(base: .primary, opacity: 0.06)
    )

    /// `fill-banner`: a notice or status banner's neutral surface.
    public static let fillBanner = SchemeTint(
        light: Tint(base: .primary, opacity: 0.045),
        dark: Tint(base: .primary, opacity: 0.045)
    )
    /// `fill-chip`: a quiet control's fill (the search field, a chip).
    public static let fillChip = SchemeTint(
        light: Tint(base: .primary, opacity: 0.06),
        dark: Tint(base: .primary, opacity: 0.06)
    )
    /// `fill-hover`: a note list row under the pointer.
    public static let fillHover = SchemeTint(
        light: Tint(base: .primary, opacity: 0.05),
        dark: Tint(base: .white, opacity: 0.03)
    )
    /// `fill-selected`: the open note's row.
    public static let fillSelected = SchemeTint(
        light: Tint(base: .primary, opacity: 0.08),
        dark: Tint(base: .white, opacity: 0.07)
    )
    /// `stroke-hover`: a note list row's edge under the pointer (0.5 pt).
    public static let strokeHover = SchemeTint(
        light: Tint(base: .primary, opacity: 0.08),
        dark: Tint(base: .white, opacity: 0.07)
    )
    /// `fill-badge`: a note list row's badge ("Summary", "Audio only").
    public static let fillBadge = SchemeTint(
        light: Tint(base: .primary, opacity: 0.08),
        dark: Tint(base: .primary, opacity: 0.08)
    )
    /// `stroke-selected`: the open note row's edge (0.6 pt).
    public static let strokeSelected = SchemeTint(
        light: Tint(base: .primary, opacity: 0.12),
        dark: Tint(base: .white, opacity: 0.14)
    )
    /// `fill-empty-disc`: the neutral disc behind an empty state's glyph.
    public static let fillEmptyDisc = SchemeTint(
        light: Tint(base: .primary, opacity: 0.04),
        dark: Tint(base: .primary, opacity: 0.04)
    )
    /// `record-ring`: the 1 pt edge of the record button.
    public static let recordRing = SchemeTint(
        light: Tint(base: .white, opacity: 0.18),
        dark: Tint(base: .white, opacity: 0.18)
    )

    /// `accent-tint-selected`: a selected option card or row.
    public static let accentTintSelected = SchemeTint(
        light: Tint(base: .accent, opacity: 0.08),
        dark: Tint(base: .accent, opacity: 0.08)
    )
    /// `accent-stroke-selected`: the 1 pt edge of a selected model row.
    public static let accentStrokeSelected = SchemeTint(
        light: Tint(base: .accent, opacity: 0.3),
        dark: Tint(base: .accent, opacity: 0.3)
    )
    /// `accent-tint-arrived`: a note row for a moment after the note arrives.
    public static let accentTintArrived = SchemeTint(
        light: Tint(base: .accent, opacity: 0.14),
        dark: Tint(base: .accent, opacity: 0.14)
    )
    /// `accent-tint-nav`: the selected settings sidebar item.
    public static let accentTintNav = SchemeTint(
        light: Tint(base: .accent, opacity: 0.15),
        dark: Tint(base: .accent, opacity: 0.15)
    )
    /// `accent-highlight`: the open note's row while the list has keyboard focus.
    public static let accentHighlight = SchemeTint(
        light: Tint(base: .accent, opacity: 0.85),
        dark: Tint(base: .accent, opacity: 0.85)
    )

    /// Every tint by its token name.
    public static let tints: [(name: String, value: SchemeTint)] = [
        ("stroke-glass", strokeGlass),
        ("fill-toolbar-hover", fillToolbarHover),
        ("fill-pressed", fillPressed),
        ("hairline-strong", hairlineStrong),
        ("hairline", hairline),
        ("fill-banner", fillBanner),
        ("fill-chip", fillChip),
        ("fill-hover", fillHover),
        ("fill-selected", fillSelected),
        ("stroke-selected", strokeSelected),
        ("stroke-hover", strokeHover),
        ("fill-badge", fillBadge),
        ("fill-empty-disc", fillEmptyDisc),
        ("record-ring", recordRing),
        ("accent-tint-selected", accentTintSelected),
        ("accent-stroke-selected", accentStrokeSelected),
        ("accent-tint-arrived", accentTintArrived),
        ("accent-tint-nav", accentTintNav),
        ("accent-highlight", accentHighlight),
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

    /// `shadow-banner`: a notice or status banner.
    public static let banner = QuillShadow(opacity: 0.12, radius: 1.5, x: 0, y: 1)

    /// `shadow-record`: the record button.
    public static let record = QuillShadow(opacity: 0.28, radius: 8, x: 0, y: 3)

    /// `shadow-record-iphone`: the iPhone's record button, lighter in light
    /// mode and darker in dark mode than the Mac's (#736 Q11).
    public static let recordIPhone = QuillSchemeShadow(
        light: QuillShadow(opacity: 0.22, radius: 8, x: 0, y: 3),
        dark: QuillShadow(opacity: 0.45, radius: 8, x: 0, y: 3)
    )

    /// `shadow-row-selected`: the open note's row, darker in dark mode.
    public static let rowSelected = QuillSchemeShadow(
        light: QuillShadow(opacity: 0.04, radius: 6, x: 0, y: 1),
        dark: QuillShadow(opacity: 0.08, radius: 6, x: 0, y: 1)
    )

    /// Every single-value shadow by its token name.
    public static let all: [(name: String, value: QuillShadow)] = [
        ("shadow-glass", glass),
        ("shadow-status", status),
        ("shadow-banner", banner),
        ("shadow-record", record),
    ]

    /// Every shadow with a value per appearance, by its token name.
    public static let schemeShadows: [(name: String, value: QuillSchemeShadow)] = [
        ("shadow-row-selected", rowSelected),
        ("shadow-record-iphone", recordIPhone),
    ]
}

/// A named shadow with a value for each appearance.
public struct QuillSchemeShadow: Sendable, Equatable {
    public let light: QuillShadow
    public let dark: QuillShadow

    public func shadow(for colorScheme: ColorScheme) -> QuillShadow {
        colorScheme == .dark ? dark : light
    }
}

extension View {
    /// Draws a named black shadow.
    public func quillShadow(_ shadow: QuillShadow) -> some View {
        self.shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius, x: shadow.x, y: shadow.y)
    }

    /// Draws a named black shadow for the given appearance.
    public func quillShadow(_ shadow: QuillSchemeShadow, colorScheme: ColorScheme) -> some View {
        quillShadow(shadow.shadow(for: colorScheme))
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

    /// `size-touch-min`: the smallest touch target on the iPhone and iPad
    /// (Apple's 44 pt). Controls that grow with Dynamic Type start here.
    public static let touchMin: CGFloat = 44

    /// `size-note-row`: a note list row's fixed height on the Mac. The iPhone
    /// row grows with its text instead.
    public static let noteRow: CGFloat = 80

    /// `size-checkbox`: the round multi-selection checkbox. On the iPhone it
    /// grows with Dynamic Type from this size.
    public static let checkboxMac: CGFloat = 18
    public static let checkboxIPhone: CGFloat = 20

    /// `size-status-dot`: a note row's done, recording, or failed dot.
    public static let statusDot: CGFloat = 6

    /// `size-empty-disc`: the disc behind an empty state's glyph.
    public static let emptyDisc: CGFloat = 80

    /// `size-issue-disc`: the tinted disc behind an issue's glyph (the Mac's
    /// full issue page, the iPhone's empty transcript states).
    public static let issueDisc: CGFloat = 64

    /// `size-record-button`: the round record button. On the iPhone it grows
    /// with Dynamic Type from this size.
    public static let recordButtonMac: CGFloat = 44
    public static let recordButtonIPhone: CGFloat = 56

    /// `size-close`: a small round close or remove button (a close circle,
    /// the overlay stop button, a summary row's remove button). So far only
    /// the summary rows read it; the others move as their screens do. On
    /// the iPhone it is the touch minimum.
    public static let closeMac: CGFloat = 20
    public static let closeIPhone: CGFloat = touchMin

    /// `size-search-field`: the note list's search field height, the same
    /// as the sidebar's other header controls (`size-toolbar-control`). On
    /// the iPhone it is the touch minimum and grows with its text.
    public static let searchFieldMac: CGFloat = 26
    public static let searchFieldIPhone: CGFloat = touchMin

    /// `size-summary-bullet`: the dot before a summary row on the Mac.
    public static let summaryBullet: CGFloat = 4

    #if os(macOS)
    public static let checkbox = checkboxMac
    public static let recordButton = recordButtonMac
    public static let close = closeMac
    public static let searchField = searchFieldMac
    #else
    public static let checkbox = checkboxIPhone
    public static let recordButton = recordButtonIPhone
    public static let close = closeIPhone
    public static let searchField = searchFieldIPhone
    #endif

    /// Every size this enum carries, by its token name (both platforms'
    /// values for a size that has two).
    public static let all: [(name: String, value: CGFloat)] = [
        ("size-note-toolbar", noteToolbar),
        ("size-note-toolbar-button", noteToolbarButtonMac),
        ("size-note-toolbar-button-iphone", noteToolbarButtonIPhone),
        ("size-status-progress", statusProgress),
        ("size-touch-min", touchMin),
        ("size-note-row", noteRow),
        ("size-checkbox", checkboxMac),
        ("size-checkbox-iphone", checkboxIPhone),
        ("size-status-dot", statusDot),
        ("size-empty-disc", emptyDisc),
        ("size-issue-disc", issueDisc),
        ("size-record-button", recordButtonMac),
        ("size-record-button-iphone", recordButtonIPhone),
        ("size-close", closeMac),
        ("size-close-iphone", closeIPhone),
        ("size-search-field", searchFieldMac),
        ("size-search-field-iphone", searchFieldIPhone),
        ("size-summary-bullet", summaryBullet),
    ]
}

/// Note screen layout sizes (#697). `QuillNoteLayout` in QuillNoteUI picks
/// between them by width class; the margins are steps of `QuillSpacing`.
public enum QuillLayoutSize {
    /// `size-sidebar-notes`: the note list's column when it sits beside the
    /// note, on the Mac and in a wide iPad window.
    public static let sidebarNotes: CGFloat = 280
    /// `size-note-margin-compact`: a note's side margins in a compact
    /// column (an iPhone in portrait). `space-16`.
    public static let noteMarginCompact: CGFloat = 16
    /// `size-note-margin-regular`: a note's side margins in a regular or
    /// wide column. `space-24`.
    public static let noteMarginRegular: CGFloat = 24
    /// `size-note-body-max-width`: the widest a note's text runs in a
    /// regular or wide column; the text is centred in wider columns.
    public static let noteBodyMaxWidth: CGFloat = 680
    /// `size-summary-max-width`: the widest the Mac's Summary tab runs
    /// (#736 Q10 keeps it apart from the note body's 680).
    public static let summaryMaxWidth: CGFloat = 760
    /// `size-summary-bottom-inset`: room under the Mac's Summary tab so its
    /// last rows scroll clear of the floating note toolbar.
    public static let summaryBottomInset: CGFloat = 96

    /// Every size this enum carries, by its token name.
    public static let all: [(name: String, value: CGFloat)] = [
        ("size-sidebar-notes", sidebarNotes),
        ("size-note-margin-compact", noteMarginCompact),
        ("size-note-margin-regular", noteMarginRegular),
        ("size-note-body-max-width", noteBodyMaxWidth),
        ("size-summary-max-width", summaryMaxWidth),
        ("size-summary-bottom-inset", summaryBottomInset),
    ]
}

/// Named opacities, applied to a whole view or a fill.
public enum QuillOpacity {
    /// `opacity-status-wash`: the note's own background laid over its text
    /// while work will replace it, so the text stays readable underneath.
    public static let statusWash: Double = 0.35
    /// `opacity-surface-card`: a settings card's control-background fill on
    /// the Mac; the alpha of the `surface-card` color in tokens.json.
    public static let surfaceCard: Double = 0.5
    /// `opacity-summary-bullet`: the secondary color of a Mac summary row's
    /// dot.
    public static let summaryBullet: Double = 0.45

    /// `opacity-issue-disc`: an issue disc's tint, drawn in the issue's own
    /// color (`size-issue-disc`).
    public static let issueDisc: Double = 0.1
    /// `opacity-status-disc`: a note's state disc (recording, audio only),
    /// drawn in the state's color at `size-empty-disc` (#736 Q8).
    public static let statusDisc: Double = 0.08
    /// `opacity-status-glyph`: the symbol inside a state disc.
    public static let statusGlyph: Double = 0.75

    /// Every opacity this module carries, by its token name.
    public static let all: [(name: String, value: Double)] = [
        ("opacity-status-wash", statusWash),
        ("opacity-surface-card", surfaceCard),
        ("opacity-summary-bullet", summaryBullet),
        ("opacity-issue-disc", issueDisc),
        ("opacity-status-disc", statusDisc),
        ("opacity-status-glyph", statusGlyph),
    ]
}

/// Text styles. On the Mac a style is a fixed size; on the iPhone and iPad
/// it follows Dynamic Type from the text style docs/design-system/2-platforms.md
/// maps it to. `lineHeight` is the Mac's line box from tokens.json, kept so
/// the test can compare it: SwiftUI sets line spacing, not line height, so
/// `font` doesn't use it. `tracking` and `trackingIPhone` are the letter
/// spacing on each platform (`letterSpacing` and `letterSpacingIphone` in
/// tokens.json). `quillTextStyle(_:)` applies the font and this platform's
/// tracking, and scales a `scalesFromMacSize` style on iOS.
public struct QuillTypeStyle: Sendable, Equatable {
    /// The system text style an iOS style scales with.
    public enum DynamicStyle: Sendable, Equatable {
        case title
        case callout
        case subheadline
        case footnote
        case caption
        case caption2

        public var textStyle: Font.TextStyle {
            switch self {
            case .title: return .title
            case .callout: return .callout
            case .subheadline: return .subheadline
            case .footnote: return .footnote
            case .caption: return .caption
            case .caption2: return .caption2
            }
        }
    }

    /// The typeface: the system font, or SF Mono.
    public enum Design: Sendable, Equatable {
        case `default`
        case monospaced

        public var fontDesign: Font.Design {
            switch self {
            case .default: return .default
            case .monospaced: return .monospaced
            }
        }
    }

    /// The Mac size in points.
    public let size: CGFloat
    /// The line box height tokens.json gives (size plus its default
    /// leading and any line spacing), for layout math. A text view doesn't
    /// read it: it draws `platformLineSpacing` on top of the font's own
    /// line height.
    public let lineHeight: CGFloat
    /// The CSS weight tokens.json uses, 100 to 900 in steps of 100.
    public let weight: Int
    public let dynamicStyle: DynamicStyle
    /// Digits all one width, for numbers that change in place (a percentage).
    public let monospacedDigits: Bool
    public let design: Design
    /// The Mac's letter spacing in points; 0 for none.
    public let tracking: CGFloat
    /// The iPhone's letter spacing in points.
    public let trackingIPhone: CGFloat
    /// On iOS the style keeps the Mac size and scales it with `dynamicStyle`
    /// instead of taking that text style's own size (the note detail's meta
    /// line). `font` can't scale a fixed size by itself and gives it
    /// unscaled, so such a style is drawn with `quillTextStyle(_:)`.
    public let scalesFromMacSize: Bool
    /// The Mac's extra space between lines in points; 0 for none.
    public let lineSpacing: CGFloat
    /// The iPhone's extra space between lines in points.
    public let lineSpacingIPhone: CGFloat
    /// The Mac's space after a paragraph in points; 0 for none.
    public let paragraphSpacing: CGFloat
    /// The iPhone's space after a paragraph in points.
    public let paragraphSpacingIPhone: CGFloat

    public init(
        size: CGFloat,
        lineHeight: CGFloat,
        weight: Int,
        dynamicStyle: DynamicStyle,
        monospacedDigits: Bool = false,
        design: Design = .default,
        tracking: CGFloat = 0,
        trackingIPhone: CGFloat? = nil,
        scalesFromMacSize: Bool = false,
        lineSpacing: CGFloat = 0,
        lineSpacingIPhone: CGFloat? = nil,
        paragraphSpacing: CGFloat = 0,
        paragraphSpacingIPhone: CGFloat? = nil
    ) {
        self.size = size
        self.lineHeight = lineHeight
        self.weight = weight
        self.dynamicStyle = dynamicStyle
        self.monospacedDigits = monospacedDigits
        self.design = design
        self.tracking = tracking
        self.trackingIPhone = trackingIPhone ?? tracking
        self.scalesFromMacSize = scalesFromMacSize
        self.lineSpacing = lineSpacing
        self.lineSpacingIPhone = lineSpacingIPhone ?? lineSpacing
        self.paragraphSpacing = paragraphSpacing
        self.paragraphSpacingIPhone = paragraphSpacingIPhone ?? paragraphSpacing
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
        #if os(macOS)
        return font(size: size)
        #else
        if scalesFromMacSize { return font(size: size) }
        let font = Font.system(dynamicStyle.textStyle, design: design.fontDesign, weight: fontWeight ?? .regular)
        return monospacedDigits ? font.monospacedDigit() : font
        #endif
    }

    /// This platform's letter spacing.
    public var platformTracking: CGFloat {
        #if os(macOS)
        return tracking
        #else
        return trackingIPhone
        #endif
    }

    /// This platform's extra space between lines.
    public var platformLineSpacing: CGFloat {
        #if os(macOS)
        return lineSpacing
        #else
        return lineSpacingIPhone
        #endif
    }

    /// This platform's space after a paragraph.
    public var platformParagraphSpacing: CGFloat {
        #if os(macOS)
        return paragraphSpacing
        #else
        return paragraphSpacingIPhone
        #endif
    }

    #if os(macOS)
    /// This style as an AppKit font, for a text view (the note title and
    /// the transcript editor), with its design and digits. A weight that
    /// isn't one of the nine CSS weights is regular, as in `font`.
    public var nsFont: NSFont {
        let nsWeight: NSFont.Weight
        switch fontWeight {
        case .ultraLight?: nsWeight = .ultraLight
        case .thin?: nsWeight = .thin
        case .light?: nsWeight = .light
        case .medium?: nsWeight = .medium
        case .semibold?: nsWeight = .semibold
        case .bold?: nsWeight = .bold
        case .heavy?: nsWeight = .heavy
        case .black?: nsWeight = .black
        default: nsWeight = .regular
        }
        if design == .monospaced {
            return NSFont.monospacedSystemFont(ofSize: size, weight: nsWeight)
        }
        if monospacedDigits {
            return NSFont.monospacedDigitSystemFont(ofSize: size, weight: nsWeight)
        }
        return NSFont.systemFont(ofSize: size, weight: nsWeight)
    }
    #endif

    /// This style at a given size, for a view that scales the size itself.
    public func font(size: CGFloat) -> Font {
        let font = Font.system(size: size, weight: fontWeight ?? .regular, design: design.fontDesign)
        return monospacedDigits ? font.monospacedDigit() : font
    }

    /// `note-title`: the note detail's editable title.
    public static let noteTitle = QuillTypeStyle(
        size: 28, lineHeight: 34, weight: 700, dynamicStyle: .title, trackingIPhone: -0.3,
        lineSpacingIPhone: 3
    )
    /// `empty-title`: an empty state's title, and the work status shown
    /// alone in the middle of a note with no text yet.
    public static let emptyTitle = QuillTypeStyle(size: 15, lineHeight: 20, weight: 600, dynamicStyle: .subheadline)
    /// `row-title`: a note list row's title.
    public static let rowTitle = QuillTypeStyle(
        size: 13, lineHeight: 16, weight: 600, dynamicStyle: .subheadline, trackingIPhone: -0.1
    )
    /// `transcript`: a note's transcript text. Each app keeps its own line
    /// and paragraph spacing until #736 Q6 is answered.
    public static let transcript = QuillTypeStyle(
        size: 15, lineHeight: 23, weight: 400, dynamicStyle: .subheadline,
        lineSpacing: 5, lineSpacingIPhone: 6, paragraphSpacing: 6, paragraphSpacingIPhone: 0
    )
    /// `callout`: a notice's or banner's detail line. On iOS it scales from
    /// `.caption`, like `banner-title`, so a banner's detail stays the size
    /// of its title (#744). An empty state's detail is `empty-detail`.
    public static let callout = QuillTypeStyle(size: 12, lineHeight: 15, weight: 400, dynamicStyle: .caption)
    /// `empty-detail`: an empty state's or an issue page's explanation under
    /// its `empty-title`. The Mac size is `callout`'s; on iOS it follows
    /// `.subheadline`, a step under the title's weight, where a banner's
    /// detail (`callout`) stays the size of its title.
    public static let emptyDetail = QuillTypeStyle(
        size: callout.size, lineHeight: callout.lineHeight, weight: callout.weight, dynamicStyle: .subheadline
    )
    /// `row-preview`: a note list row's two-line preview.
    public static let rowPreview = QuillTypeStyle(size: 11.5, lineHeight: 15, weight: 400, dynamicStyle: .subheadline)
    /// `banner-title`: a notice or status banner's title.
    public static let bannerTitle = QuillTypeStyle(size: 12, lineHeight: 15, weight: 600, dynamicStyle: .caption)
    /// `meta-label`: a note list row's date (shown uppercase).
    public static let metaLabel = QuillTypeStyle(size: 9, lineHeight: 11, weight: 600, dynamicStyle: .caption2, tracking: 0.4)
    /// `badge-label`: a note list row's badge ("Summary", "Audio only").
    public static let badgeLabel = QuillTypeStyle(size: 8, lineHeight: 10, weight: 600, dynamicStyle: .caption2)
    /// `meta-mono`: the date on the note detail's meta line (shown uppercase).
    public static let metaMono = QuillTypeStyle(
        size: 10, lineHeight: 13, weight: 400, dynamicStyle: .caption2,
        design: .monospaced, tracking: 0.5, trackingIPhone: 0.2, scalesFromMacSize: true
    )
    /// `meta-chip-mono`: a chip on the note detail's meta line (transcription
    /// method, language).
    public static let metaChipMono = QuillTypeStyle(
        size: 9, lineHeight: 11, weight: 500, dynamicStyle: .caption2,
        design: .monospaced, trackingIPhone: 0.2, scalesFromMacSize: true
    )
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
        ("note-title", noteTitle),
        ("empty-title", emptyTitle),
        ("row-title", rowTitle),
        ("transcript", transcript),
        ("callout", callout),
        ("empty-detail", emptyDetail),
        ("row-preview", rowPreview),
        ("banner-title", bannerTitle),
        ("meta-label", metaLabel),
        ("badge-label", badgeLabel),
        ("meta-mono", metaMono),
        ("meta-chip-mono", metaChipMono),
        ("status-title", statusTitle),
        ("status-percent", statusPercent),
        ("status-detail", statusDetail),
    ]
}

/// Draws text in a `QuillTypeStyle`: its font, this platform's tracking
/// and line spacing, and on iOS a `scalesFromMacSize` style's size scaled
/// with Dynamic Type. Paragraph spacing is a text view's, not SwiftUI
/// text's, so a view that needs it reads `platformParagraphSpacing`.
public struct QuillTextStyleModifier: ViewModifier {
    let style: QuillTypeStyle
    @ScaledMetric private var scaledSize: CGFloat

    public init(_ style: QuillTypeStyle) {
        self.style = style
        _scaledSize = ScaledMetric(wrappedValue: style.size, relativeTo: style.dynamicStyle.textStyle)
    }

    public func body(content: Content) -> some View {
        #if os(macOS)
        let font = style.font
        #else
        let font = style.scalesFromMacSize ? style.font(size: scaledSize) : style.font
        #endif
        // A style with no line spacing of its own keeps what the view
        // around it set.
        let lineSpacing = style.platformLineSpacing
        return content.font(font).kerning(style.platformTracking)
            .transformEnvironment(\.lineSpacing) { if lineSpacing > 0 { $0 = lineSpacing } }
    }
}

extension View {
    /// Draws text in a named type style (see `QuillTextStyleModifier`).
    public func quillTextStyle(_ style: QuillTypeStyle) -> some View {
        modifier(QuillTextStyleModifier(style))
    }
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
