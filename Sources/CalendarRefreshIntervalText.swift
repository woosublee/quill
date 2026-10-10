import Foundation

/// The refresh interval choices in Settings › Calendar, in the app's language.
enum CalendarRefreshIntervalText {
    static func title(_ minutes: Int) -> String {
        title(minutes, language: preferredLocalizedStringLanguage(), bundle: .main)
    }

    static func title(_ minutes: Int, language: String, bundle: Bundle) -> String {
        minutes == 60
            ? localizedCatalogString("Every hour", language: language, bundle: bundle)
            : localizedCatalogFormat("Every %@ minutes", String(minutes), language: language, bundle: bundle)
    }
}
