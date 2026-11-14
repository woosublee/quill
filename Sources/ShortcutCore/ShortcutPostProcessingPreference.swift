import Foundation

/// Whether a dictation shortcut runs post-processing: the Settings switch,
/// or always on or off for that shortcut (upstream #347, mapped onto
/// Quill's post-processing switch, since Quill has no "Preserve exact
/// wording" mode).
enum ShortcutPostProcessingPreference: String, CaseIterable, Hashable {
    case inherit
    case on
    case off

    static let holdStorageKey = "hold_shortcut_post_processing_preference"
    static let toggleStorageKey = "toggle_shortcut_post_processing_preference"

    static func storageKey(for mode: RecordingTriggerMode) -> String {
        switch mode {
        case .hold: return holdStorageKey
        case .toggle: return toggleStorageKey
        }
    }

    /// A missing or unknown value follows the Settings switch.
    static func load(from defaults: UserDefaults, key: String) -> Self {
        guard let rawValue = defaults.string(forKey: key),
              let preference = Self(rawValue: rawValue) else {
            return .inherit
        }
        return preference
    }

    func save(to defaults: UserDefaults, key: String) {
        defaults.set(rawValue, forKey: key)
    }

    /// The choice a recording keeps from its start: `nil` follows the
    /// Settings switch. A recording not started by a dictation shortcut
    /// (the menu bar, the Note Browser, a calendar reminder, MCP) always
    /// follows it. A recording keeps its starting shortcut's choice even
    /// when it moves from Hold to Talk to Tap to Toggle.
    static func override(
        startedBy shortcut: RecordingTriggerMode?,
        hold: Self,
        toggle: Self
    ) -> Bool? {
        let preference: Self
        switch shortcut {
        case nil: return nil
        case .hold: preference = hold
        case .toggle: preference = toggle
        }
        switch preference {
        case .inherit: return nil
        case .on: return true
        case .off: return false
        }
    }
}
