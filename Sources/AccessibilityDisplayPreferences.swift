import AppKit
import SwiftUI

/// Small, pure helpers for the macOS accessibility display preferences
/// (System Settings > Accessibility > Display). Every helper returns its
/// input unchanged when the preference is off, so the default appearance and
/// motion stay exactly as designed. Views pass the SwiftUI environment value;
/// AppKit panel code passes `QuillMotion.systemReduceMotion`.

enum QuillMotion {
    /// The animation to use for `base`: `nil` (no animation) under Reduce Motion.
    static func animation(_ base: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : base
    }

    /// Whether an AppKit panel move or resize should animate.
    static func animatesPanel(_ requested: Bool, reduceMotion: Bool) -> Bool {
        requested && !reduceMotion
    }

    /// The live system setting, for AppKit code outside a SwiftUI environment.
    static var systemReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

enum QuillContrast {
    /// A foreground (text or symbol) opacity. Under Increase Contrast it moves
    /// halfway to fully opaque, so faint text strengthens the most while the
    /// relative order of emphasis is kept.
    static func opacity(_ normal: Double, increased: Bool) -> Double {
        guard increased else { return normal }
        return min(max(normal, 0) * 0.5 + 0.5, 1)
    }

    /// A hairline or tinted-fill opacity. Under Increase Contrast it doubles,
    /// so separators and badge backgrounds read more clearly.
    static func fillOpacity(_ normal: Double, increased: Bool) -> Double {
        guard increased else { return normal }
        return min(max(normal, 0) * 2, 1)
    }

    /// Faint text levels this helper can strengthen.
    enum TextEmphasis: Equatable {
        case secondary, tertiary, quaternary

        var style: HierarchicalShapeStyle {
            switch self {
            case .secondary: return .secondary
            case .tertiary: return .tertiary
            case .quaternary: return .quaternary
            }
        }
    }

    /// `.tertiary` and `.quaternary` text becomes `.secondary` under Increase Contrast.
    static func emphasis(_ normal: TextEmphasis, increased: Bool) -> TextEmphasis {
        increased ? .secondary : normal
    }

    static func hierarchicalStyle(_ normal: TextEmphasis, increased: Bool) -> HierarchicalShapeStyle {
        emphasis(normal, increased: increased).style
    }
}

enum QuillTransparency {
    /// The opaque color used in place of a translucent material.
    static let opaqueBackgroundColor = Color(nsColor: .windowBackgroundColor)

    /// The material, or an opaque window color under Reduce Transparency.
    static func background(_ material: Material, reduceTransparency: Bool) -> AnyShapeStyle {
        reduceTransparency ? AnyShapeStyle(opaqueBackgroundColor) : AnyShapeStyle(material)
    }
}
