import Foundation

enum LocalizedUserMessage {
    static func shortcutStatus(shortcut: String, isToggleMode: Bool) -> String {
        formatted(isToggleMode ? "Tap %@ to dictate" : "Hold %@ to dictate", shortcut)
    }

    static func screenRecordingPermission(detail: String) -> String {
        formatted("Screen Recording permission is required. %@", detail)
    }

    static func screenshotFailure(detail: String) -> String {
        formatted("Failed to capture screenshot: %@", detail)
    }

    static func providerFailure(prefix: String, providerDetail: String) -> String {
        String(format: localizedCatalogString("%@: %@"), prefix, providerDetail)
    }

    private static func formatted(_ key: String, _ value: String) -> String {
        String(format: localizedCatalogString(key), value)
    }
}
