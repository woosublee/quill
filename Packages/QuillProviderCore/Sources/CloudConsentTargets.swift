import Foundation

/// The cloud providers an app's settings send to, and what consent they
/// need (#693), the same on the Mac and the iPhone. The main pair (API base
/// URL and key) carries cleanup, summaries, and transcription (and context
/// on the Mac); the transcription pair falls back to the main URL and key,
/// each on its own, when its field is empty.
///
/// A key the Keychain holds but couldn't return at launch has an empty
/// field. It still goes to its provider once it can be read, so that
/// provider is listed and can be withdrawn; but it never lets the main key
/// stand in for it, as each app's send path refuses that.
public struct CloudConsentTargets: Equatable, Sendable {
    public var apiBaseURL: String
    public var apiKey: String
    public var apiKeyIsUnreadable: Bool
    public var transcriptionAPIURL: String
    public var transcriptionAPIKey: String
    public var transcriptionAPIKeyIsUnreadable: Bool

    public init(
        apiBaseURL: String,
        apiKey: String,
        apiKeyIsUnreadable: Bool,
        transcriptionAPIURL: String,
        transcriptionAPIKey: String,
        transcriptionAPIKeyIsUnreadable: Bool
    ) {
        self.apiBaseURL = apiBaseURL
        self.apiKey = apiKey
        self.apiKeyIsUnreadable = apiKeyIsUnreadable
        self.transcriptionAPIURL = transcriptionAPIURL
        self.transcriptionAPIKey = transcriptionAPIKey
        self.transcriptionAPIKeyIsUnreadable = transcriptionAPIKeyIsUnreadable
    }

    public struct Target: Equatable, Identifiable, Sendable {
        public let origin: String
        public let host: String
        public let baseURL: String
        public var id: String { origin }

        /// The host, or the whole origin when it isn't HTTPS on the default
        /// port, so a switch to `http://` or another port shows.
        public var displayName: String {
            let https = "https://"
            guard origin.hasPrefix(https) else { return origin }
            // A port follows the last colon after any IPv6 brackets.
            let authority = origin.dropFirst(https.count)
            let afterBrackets = authority.split(separator: "]", omittingEmptySubsequences: false).last ?? authority
            return afterBrackets.contains(":") ? origin : String(authority)
        }
    }

    /// What withdrawing consent for one origin clears, so nothing more goes
    /// there. A cleared key is deleted from the Keychain too, an unreadable
    /// one included.
    public struct Withdrawal: Equatable, Sendable {
        public var clearsAPIKey = false
        public var clearsTranscriptionAPIKey = false
        /// Transcription sends the main key to its own URL; clearing that URL
        /// sends transcription back to the main provider instead.
        public var clearsTranscriptionAPIURL = false

        public init(
            clearsAPIKey: Bool = false,
            clearsTranscriptionAPIKey: Bool = false,
            clearsTranscriptionAPIURL: Bool = false
        ) {
            self.clearsAPIKey = clearsAPIKey
            self.clearsTranscriptionAPIKey = clearsTranscriptionAPIKey
            self.clearsTranscriptionAPIURL = clearsTranscriptionAPIURL
        }
    }

    /// A key field a person can clear in settings.
    public enum KeyField: Equatable, Sendable {
        /// The main key, which goes to the API base URL.
        case main
        /// Transcription's own key, which goes to the transcription URL (or
        /// the main URL when that is empty).
        case transcription
    }

    /// The provider whose consent clearing `field`'s key withdraws (#723),
    /// the same on both apps: where that key goes, when that provider has
    /// consent and no other key goes there. Clearing such a key runs the
    /// same withdrawal as Withdraw (`withdrawal(forOrigin:)`), so saving it
    /// again asks again.
    ///
    /// Nil when there's nothing to withdraw, and the key is then only
    /// deleted:
    /// - the field has no saved key (an unreadable key can't be cleared from
    ///   its empty field; Withdraw clears it);
    /// - the key goes nowhere;
    /// - its provider was never agreed to (a key saved before consent
    ///   existed);
    /// - the other key still goes to that provider on its own settings (the
    ///   owner's 2026-10-31 decision): consent stays for it, and that key is
    ///   never deleted with this one. Clearing the last key that goes there
    ///   withdraws it, so clearing both, one after the other, withdraws once.
    public func consentedTarget(
        forClearing field: KeyField,
        in ledger: CloudConsentLedger
    ) -> Target? {
        let baseURL: String
        switch field {
        case .main:
            guard !Self.isBlank(apiKey) else { return nil }
            baseURL = apiBaseURL
        case .transcription:
            guard !Self.isBlank(transcriptionAPIKey) else { return nil }
            baseURL = resolvedTranscriptionURL
        }
        guard let origin = CloudProviderURL.origin(of: baseURL),
              !otherKeyStillGoes(to: origin, afterClearing: field),
              let target = targets.first(where: { $0.origin == origin }),
              ledger.hasConsent(forBaseURL: target.baseURL) else { return nil }
        return target
    }

    /// Whether the key other than `field`'s goes to `origin` on its own
    /// settings, an unreadable one included, so clearing `field`'s key
    /// keeps that provider's consent. Only a key that already goes there
    /// counts, never the main key starting to go there because
    /// transcription's own key is gone.
    public func otherKeyStillGoes(to origin: String, afterClearing field: KeyField) -> Bool {
        // The same match Withdraw clears by, so the two never disagree.
        let withdrawal = self.withdrawal(forOrigin: origin)
        switch field {
        case .main: return withdrawal.clearsTranscriptionAPIKey
        case .transcription: return withdrawal.clearsAPIKey
        }
    }

    public var resolvedTranscriptionURL: String {
        let trimmed = Self.trimmed(transcriptionAPIURL)
        return trimmed.isEmpty ? apiBaseURL : trimmed
    }

    /// The key transcription sends now: its own, else the main one, unless
    /// its own is unreadable.
    public var resolvedTranscriptionKey: String {
        let trimmed = Self.trimmed(transcriptionAPIKey)
        guard trimmed.isEmpty else { return trimmed }
        return transcriptionAPIKeyIsUnreadable ? "" : apiKey
    }

    /// Each provider a saved key goes to, once per origin, the main one first.
    public var targets: [Target] {
        var seen: Set<String> = []
        return [(apiBaseURL, hasMainKey), (resolvedTranscriptionURL, hasTranscriptionKey)]
            .compactMap { baseURL, hasKey -> Target? in
                guard hasKey,
                      let origin = CloudProviderURL.origin(of: baseURL),
                      let host = CloudProviderURL.host(of: baseURL),
                      seen.insert(origin).inserted else { return nil }
                return Target(origin: origin, host: host, baseURL: baseURL)
            }
    }

    /// The providers these settings would send to without consent yet.
    public func unconsented(in ledger: CloudConsentLedger) -> [Target] {
        targets.filter { !ledger.hasConsent(forBaseURL: $0.baseURL) }
    }

    public func withdrawal(forOrigin origin: String) -> Withdrawal {
        var withdrawal = Withdrawal()
        let mainMatches = CloudProviderURL.origin(of: apiBaseURL) == origin && hasMainKey
        withdrawal.clearsAPIKey = mainMatches
        guard CloudProviderURL.origin(of: resolvedTranscriptionURL) == origin else { return withdrawal }
        withdrawal.clearsTranscriptionAPIKey = hasOwnTranscriptionKey
        // With its own key gone, transcription would fall back to the main
        // key at the same URL, so a separate URL goes too.
        withdrawal.clearsTranscriptionAPIURL = !mainMatches && hasMainKey
        return withdrawal
    }

    private var hasMainKey: Bool { !Self.isBlank(apiKey) || apiKeyIsUnreadable }

    private var hasOwnTranscriptionKey: Bool {
        !Self.isBlank(transcriptionAPIKey) || transcriptionAPIKeyIsUnreadable
    }

    /// Transcription's URL gets a key: its own, or else the main one. Either
    /// may be unreadable now and go there once it can be read.
    private var hasTranscriptionKey: Bool { hasOwnTranscriptionKey || hasMainKey }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isBlank(_ value: String) -> Bool { trimmed(value).isEmpty }
}

/// A printed or dumped target shows its origin, never anything else typed
/// into its URL.
extension CloudConsentTargets.Target: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "CloudConsentTargets.Target(\(origin))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["origin": origin]) }
}

/// A printed or dumped value shows only whether each key is set and each
/// URL's origin, never a key or anything else typed into a URL.
extension CloudConsentTargets: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "CloudConsentTargets(apiBaseURL: \(Self.origin(apiBaseURL)), apiKey: \(Self.redacted(apiKey, unreadable: apiKeyIsUnreadable)), "
            + "transcriptionAPIURL: \(Self.origin(transcriptionAPIURL)), "
            + "transcriptionAPIKey: \(Self.redacted(transcriptionAPIKey, unreadable: transcriptionAPIKeyIsUnreadable)))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "apiBaseURL": Self.origin(apiBaseURL),
            "apiKey": Self.redacted(apiKey, unreadable: apiKeyIsUnreadable),
            "transcriptionAPIURL": Self.origin(transcriptionAPIURL),
            "transcriptionAPIKey": Self.redacted(transcriptionAPIKey, unreadable: transcriptionAPIKeyIsUnreadable),
        ])
    }

    private static func redacted(_ key: String, unreadable: Bool) -> String {
        if unreadable { return "<unreadable>" }
        return isBlank(key) ? "<empty>" : "<redacted>"
    }

    private static func origin(_ url: String) -> String {
        if isBlank(url) { return "<empty>" }
        return CloudProviderURL.origin(of: url) ?? "<invalid>"
    }
}
