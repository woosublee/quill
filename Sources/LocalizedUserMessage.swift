import Foundation

enum LocalizedUserMessage {
    static func shortcutStatus(shortcut: String, isToggleMode: Bool) -> String {
        shortcutStatus(shortcut: shortcut, isToggleMode: isToggleMode, language: preferredLocalizedStringLanguage(), bundle: .main)
    }

    static func shortcutStatus(shortcut: String, isToggleMode: Bool, language: String, bundle: Bundle) -> String {
        formatted(isToggleMode ? "Tap %@ to dictate" : "Hold %@ to dictate", shortcut, language: language, bundle: bundle)
    }

    static func screenRecordingPermission(detail: String) -> String {
        screenRecordingPermission(detail: detail, language: preferredLocalizedStringLanguage(), bundle: .main)
    }

    static func screenRecordingPermission(detail: String, language: String, bundle: Bundle) -> String {
        formatted("Screen Recording permission is required. %@\n\nQuill requires Screen Recording permission to capture screenshots for context-aware transcription.\n\nGo to System Settings > Privacy & Security > Screen Recording and enable Quill.", detail, language: language, bundle: bundle)
    }

    static func screenshotFailure(detail: String) -> String {
        screenshotFailure(detail: detail, language: preferredLocalizedStringLanguage(), bundle: .main)
    }

    static func screenshotFailure(detail: String, language: String, bundle: Bundle) -> String {
        formatted("Failed to capture screenshot: %@\n\nA screenshot is required for context-aware transcription. Recording has been stopped.", detail, language: language, bundle: bundle)
    }

    static func providerFailure(prefix: String, providerDetail: String) -> String {
        providerFailure(prefix: prefix, providerDetail: providerDetail, language: preferredLocalizedStringLanguage(), bundle: .main)
    }

    static func providerFailure(prefix: String, providerDetail: String, language: String, bundle: Bundle) -> String {
        String(format: localizedCatalogString("%@: %@", language: language, bundle: bundle), prefix, providerDetail)
    }

    private static func formatted(_ key: String, _ value: String, language: String, bundle: Bundle) -> String {
        String(format: localizedCatalogString(key, language: language, bundle: bundle), value)
    }
}
