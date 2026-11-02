import Foundation
import QuillNoteSyncCore

enum NoteSyncStatusText {
    /// "Just now" for the first minute, then "3 min. ago" and so on, in the
    /// app's language. A sync that just finished never reads "in 0 seconds",
    /// and a clock set back never reads "in 10 minutes". The rule is shared
    /// with the iPhone (`NoteSyncStatusPresentation`, #283).
    static func relativeTime(
        _ date: Date,
        now: Date,
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> String {
        NoteSyncStatusPresentation.relativeTime(
            date,
            now: now,
            locale: Locale(identifier: language),
            justNow: localizedCatalogString(NoteSyncStatusPresentation.justNowKey, language: language, bundle: bundle)
        )
    }
}
