import Foundation

/// Resolves stable UI catalog keys without changing persisted identifiers or dynamic values.
func preferredLocalizedStringLanguage(bundle: Bundle = .main) -> String {
    bundle.preferredLocalizations.first ?? "en"
}

func localizedCatalogString(
    _ key: String,
    language: String = preferredLocalizedStringLanguage(),
    bundle: Bundle = .main
) -> String {
    let path = bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language)
        ?? URL(fileURLWithPath: bundle.bundlePath).appendingPathComponent("\(language).lproj/Localizable.strings").path
    guard let strings = NSDictionary(contentsOfFile: path) as? [String: String] else {
        return key
    }
    return strings[key] ?? key
}
