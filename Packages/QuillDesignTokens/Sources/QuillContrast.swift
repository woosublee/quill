import SwiftUI

/// Increase Contrast rules shared by the Mac and the iPhone (woosublee/quill#736):
/// every helper returns its input unchanged when the setting is off, so the
/// default appearance stays exactly as designed. Views pass the SwiftUI
/// environment value (`colorSchemeContrast == .increased`).
public enum QuillContrast {
    /// A foreground (text or symbol) opacity. Under Increase Contrast it moves
    /// halfway to fully opaque, so faint text strengthens the most while the
    /// relative order of emphasis is kept.
    public static func opacity(_ normal: Double, increased: Bool) -> Double {
        guard increased else { return normal }
        return min(max(normal, 0) * 0.5 + 0.5, 1)
    }

    /// A hairline or tinted-fill opacity. Under Increase Contrast it doubles,
    /// so separators and badge backgrounds read more clearly.
    public static func fillOpacity(_ normal: Double, increased: Bool) -> Double {
        guard increased else { return normal }
        return min(max(normal, 0) * 2, 1)
    }

    /// Faint text levels this helper can strengthen.
    public enum TextEmphasis: Equatable, Sendable {
        case secondary, tertiary, quaternary

        public var style: HierarchicalShapeStyle {
            switch self {
            case .secondary: return .secondary
            case .tertiary: return .tertiary
            case .quaternary: return .quaternary
            }
        }
    }

    /// `.tertiary` and `.quaternary` text becomes `.secondary` under Increase Contrast.
    public static func emphasis(_ normal: TextEmphasis, increased: Bool) -> TextEmphasis {
        increased ? .secondary : normal
    }

    public static func hierarchicalStyle(_ normal: TextEmphasis, increased: Bool) -> HierarchicalShapeStyle {
        emphasis(normal, increased: increased).style
    }
}
