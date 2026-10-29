import Foundation

/// Consent to send recordings and what's in them to a cloud provider (#693),
/// shared by both apps. Each app asks once, when a key is saved for a
/// provider, and keeps one grant per origin (`CloudProviderURL.origin`): a
/// different path is the same provider, a different scheme, host, or port is
/// not. Only the origin and the date are kept, never a key, path, or content.
/// Grants stay on the device; they don't sync.
public struct CloudConsentLedger: Equatable, Sendable {
    public static let defaultsKey = "cloud_consent_grants"

    /// When each origin was agreed to.
    public private(set) var grants: [String: Date]

    public init(grants: [String: Date] = [:]) {
        self.grants = grants
    }

    public func hasConsent(forBaseURL baseURL: String) -> Bool {
        grantedAt(forBaseURL: baseURL) != nil
    }

    public func grantedAt(forBaseURL baseURL: String) -> Date? {
        guard let origin = CloudProviderURL.origin(of: baseURL) else { return nil }
        return grants[origin]
    }

    /// Saving `key` for `baseURL` needs a prompt first. An empty key sends
    /// nothing, and a URL with no origin can't be sent to, so neither asks.
    public func needsConsent(forBaseURL baseURL: String, key: String) -> Bool {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              CloudProviderURL.origin(of: baseURL) != nil else { return false }
        return !hasConsent(forBaseURL: baseURL)
    }

    public mutating func grant(forBaseURL baseURL: String, at date: Date = Date()) {
        guard let origin = CloudProviderURL.origin(of: baseURL) else { return }
        grants[origin] = date
    }

    public mutating func revoke(forBaseURL baseURL: String) {
        guard let origin = CloudProviderURL.origin(of: baseURL) else { return }
        grants[origin] = nil
    }

    public mutating func revokeAll() {
        grants = [:]
    }

    public static func load(from defaults: UserDefaults) -> CloudConsentLedger {
        let stored = defaults.dictionary(forKey: defaultsKey) ?? [:]
        return CloudConsentLedger(grants: stored.compactMapValues { $0 as? Date })
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(grants, forKey: Self.defaultsKey)
    }
}

/// The consent prompt's copy keys. Each app translates them with its own
/// String Catalog and draws its own prompt.
public enum CloudConsentCopy {
    /// Takes the provider's host.
    public static let titleFormatKey = "Send to %@?"
    public static let agreeKey = "Agree and Save"
    public static let cancelKey = "Cancel"
    /// What cancelling a new key does.
    public static let cancelClearsKeyKey = "If you cancel, the key isn’t saved and is cleared."
    /// What cancelling any other change does (a new address for a saved
    /// key, or a cleared key that falls back to another one).
    public static let cancelChangesNothingKey = "If you cancel, nothing changes."

    /// One line about the data, not a list of features. The Mac mentions
    /// screen context because its Context feature sends app names, window
    /// titles, and screenshots; the iPhone has no such feature.
    public static func bodyKey(mentionsScreenContext: Bool) -> String {
        mentionsScreenContext
            ? "If you use cloud features, your recordings and what’s in them (transcripts, screen context, and so on) go to this provider. That provider’s privacy practices apply."
            : "If you use cloud features, your recordings and what’s in them (transcripts and so on) go to this provider. That provider’s privacy practices apply."
    }
}
