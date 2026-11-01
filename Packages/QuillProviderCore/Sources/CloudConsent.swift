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

/// The consent prompt's, consent rows', and withdrawal's copy keys. Each app
/// translates them with its own String Catalog and draws its own prompt.
public enum CloudConsentCopy {
    /// Takes the provider's host.
    public static let titleFormatKey = "Send to %@?"
    /// The prompt's answer to "Send to …?". Short, so the two buttons sit
    /// side by side in a system alert on both apps.
    public static let sendKey = "Send"
    public static let cancelKey = "Cancel"
    /// What cancelling a new key does.
    public static let cancelClearsKeyKey = "If you cancel, the key isn’t saved and is cleared."
    /// What cancelling any other change does (a new address for a saved
    /// key, or a cleared key that falls back to another one).
    public static let cancelChangesNothingKey = "If you cancel, nothing changes."
    /// Withdrawing, or clearing an agreed key, while recording or
    /// transcribing (#723).
    public static let withdrawBusyKey = "You can't withdraw while recording or transcribing. Try again when it finishes."

    /// The settings rows listing each provider a saved key goes to.
    public static let sectionTitleKey = "Consent to Send"
    /// A row's second line under the provider's name: when it was agreed
    /// to. Takes `agreedDate(_:locale:)`.
    public static let agreedOnFormatKey = "Agreed on %@"
    /// A row's second line for a key saved before consent was asked.
    public static let notAgreedKey = "Not agreed yet"
    public static let withdrawKey = "Withdraw"
    /// Agreeing to a key saved before consent was asked.
    public static let agreeToSavedKeyKey = "Agree…"
    public static let withdrawFooterKey = "Withdrawing clears the key for that provider, so nothing goes to it. To use it again, save the key again."
    /// The withdrawal confirmation's title.
    public static let withdrawTitleKey = "Withdraw consent and clear the key?"
    /// The confirmation's first sentence. Takes the provider's name.
    public static let withdrawNothingMoreFormatKey = "Nothing more goes to %@."

    /// The confirmation's second sentence: what the features that used the
    /// provider do next. It names the device the local model runs on (each
    /// catalog gives the iPhone string an iPad form).
    public static func withdrawEffectKey(onMac: Bool) -> String {
        onMac
            ? "Features that used it switch to a model on this Mac, or turn off."
            : "Features that used it switch to a model on this iPhone, or turn off."
    }

    /// The date in a row's second line, as both apps show it ("November 1,
    /// 2026"; "2026년 11월 1일").
    public static func agreedDate(_ date: Date, locale: Locale) -> String {
        date.formatted(.dateTime.year().month(.wide).day().locale(locale))
    }

    /// One line about the data, not a list of features. The Mac mentions
    /// screen context because its Context feature sends app names, window
    /// titles, and screenshots; the iPhone has no such feature.
    public static func bodyKey(mentionsScreenContext: Bool) -> String {
        mentionsScreenContext
            ? "If you use cloud features, your recordings and what’s in them (transcripts, screen context, and so on) go to this provider. That provider’s privacy practices apply."
            : "If you use cloud features, your recordings and what’s in them (transcripts and so on) go to this provider. That provider’s privacy practices apply."
    }
}

/// One row of the settings' consent list: a provider a saved key goes to,
/// and whether it was agreed to. Both apps draw it on two lines (the
/// provider, then when it was agreed to) with Withdraw, or Agree… for a key
/// saved before consent was asked, on the right.
public struct CloudConsentRow: Equatable, Identifiable, Sendable {
    public enum Status: Equatable, Sendable {
        case agreed(on: Date)
        /// A key saved before consent was asked (#693).
        case notAgreed
    }

    public let target: CloudConsentTargets.Target
    public let status: Status
    public var id: String { target.id }

    public init(target: CloudConsentTargets.Target, status: Status) {
        self.target = target
        self.status = status
    }

    /// A row for each provider the saved keys go to, in `targets` order.
    public static func rows(for targets: CloudConsentTargets, ledger: CloudConsentLedger) -> [CloudConsentRow] {
        targets.targets.map { target in
            CloudConsentRow(
                target: target,
                status: ledger.grantedAt(forBaseURL: target.baseURL).map { .agreed(on: $0) } ?? .notAgreed
            )
        }
    }

    /// The second line's copy key and its argument, if any.
    public func detail(locale: Locale) -> (key: String, argument: String?) {
        switch status {
        case .agreed(let date):
            return (CloudConsentCopy.agreedOnFormatKey, CloudConsentCopy.agreedDate(date, locale: locale))
        case .notAgreed:
            return (CloudConsentCopy.notAgreedKey, nil)
        }
    }

    /// The button on the right: Withdraw for an agreed provider, Agree…
    /// otherwise.
    public var actionKey: String {
        switch status {
        case .agreed: return CloudConsentCopy.withdrawKey
        case .notAgreed: return CloudConsentCopy.agreeToSavedKeyKey
        }
    }
}
