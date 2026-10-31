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

enum QuillTransparency {
    /// The opaque color used in place of a translucent material.
    static let opaqueBackgroundColor = Color(nsColor: .windowBackgroundColor)

    /// The material, or an opaque window color under Reduce Transparency.
    static func background(_ material: Material, reduceTransparency: Bool) -> AnyShapeStyle {
        reduceTransparency ? AnyShapeStyle(opaqueBackgroundColor) : AnyShapeStyle(material)
    }
}
