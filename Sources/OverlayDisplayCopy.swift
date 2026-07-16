import Foundation

enum OverlayDisplayCopy {
    static func meetingStarts(
        at time: String,
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> String {
        formatted("Starts at %@", value: time, language: language, bundle: bundle)
    }

    static func inputChanged(
        to deviceName: String,
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> String {
        formatted("Input changed to %@", value: deviceName, language: language, bundle: bundle)
    }

    static func updateAvailable(
        version: String,
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> String {
        formatted("Update available: %@", value: version, language: language, bundle: bundle)
    }

    private static func formatted(_ key: String, value: String, language: String, bundle: Bundle) -> String {
        String(format: localizedCatalogString(key, language: language, bundle: bundle), value)
    }
}
