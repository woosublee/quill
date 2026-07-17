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
    localizedCatalogStrings(language: language, bundle: bundle)[key] ?? key
}

func localizedCatalogFormat(
    _ key: String,
    _ arguments: CVarArg...,
    language: String = preferredLocalizedStringLanguage(),
    bundle: Bundle = .main
) -> String {
    String(
        format: localizedCatalogString(key, language: language, bundle: bundle),
        locale: Locale(identifier: language),
        arguments: arguments
    )
}

private let localizedCatalogCache = NSCache<NSString, NSDictionary>()
private let localizedCatalogCacheLock = NSLock()

private func localizedCatalogStrings(language: String, bundle: Bundle) -> [String: String] {
    let cacheKey = "\(bundle.bundlePath)\u{0}\(language)" as NSString

    localizedCatalogCacheLock.lock()
    if let cached = localizedCatalogCache.object(forKey: cacheKey) as? [String: String] {
        localizedCatalogCacheLock.unlock()
        return cached
    }
    localizedCatalogCacheLock.unlock()

    let path = bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language)
        ?? URL(fileURLWithPath: bundle.bundlePath).appendingPathComponent("\(language).lproj/Localizable.strings").path
    guard let strings = NSDictionary(contentsOfFile: path) as? [String: String] else {
        return [:]
    }

    localizedCatalogCacheLock.lock()
    localizedCatalogCache.setObject(strings as NSDictionary, forKey: cacheKey)
    localizedCatalogCacheLock.unlock()
    return strings
}
