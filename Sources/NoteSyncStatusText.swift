import Foundation

enum NoteSyncStatusText {
    /// "Just now" for the first minute, then "3 min. ago" and so on, in the
    /// app's language. A sync that just finished never reads "in 0 seconds",
    /// and a clock set back never reads "in 10 minutes".
    static func relativeTime(
        _ date: Date,
        now: Date,
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> String {
        guard now.timeIntervalSince(date) >= 60 else {
            return localizedCatalogString("Just now", language: language, bundle: bundle)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: language)
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
