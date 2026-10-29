import Foundation

/// The cloud providers an app's settings send to, and what consent they
/// need (#693), the same on the Mac and the iPhone. The main pair (API base
/// URL and key) carries cleanup, summaries, and transcription (and context
/// on the Mac); the transcription pair falls back to the main URL and key,
/// each on its own, when its field is empty.
public struct CloudConsentTargets: Equatable, Sendable {
    public var apiBaseURL: String
    public var apiKey: String
    public var transcriptionAPIURL: String
    public var transcriptionAPIKey: String

    public init(apiBaseURL: String, apiKey: String, transcriptionAPIURL: String, transcriptionAPIKey: String) {
        self.apiBaseURL = apiBaseURL
        self.apiKey = apiKey
        self.transcriptionAPIURL = transcriptionAPIURL
        self.transcriptionAPIKey = transcriptionAPIKey
    }

    public struct Target: Equatable, Identifiable, Sendable {
        public let origin: String
        public let host: String
        public let baseURL: String
        public var id: String { origin }

        public init(origin: String, host: String, baseURL: String) {
            self.origin = origin
            self.host = host
            self.baseURL = baseURL
        }

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
    /// there.
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

    public var resolvedTranscriptionURL: String {
        let trimmed = transcriptionAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? apiBaseURL : trimmed
    }

    public var resolvedTranscriptionKey: String {
        let trimmed = transcriptionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? apiKey : trimmed
    }

    /// Each provider a saved key goes to, once per origin, the main one first.
    public var targets: [Target] {
        var seen: Set<String> = []
        return [(apiBaseURL, apiKey), (resolvedTranscriptionURL, resolvedTranscriptionKey)]
            .compactMap { baseURL, key -> Target? in
                guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
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
        let mainMatches = CloudProviderURL.origin(of: apiBaseURL) == origin
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        withdrawal.clearsAPIKey = mainMatches
        guard CloudProviderURL.origin(of: resolvedTranscriptionURL) == origin else { return withdrawal }
        if !transcriptionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            withdrawal.clearsTranscriptionAPIKey = true
        }
        // With its own key gone, transcription would fall back to the main
        // key at the same URL, so a separate URL goes too.
        if !mainMatches, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            withdrawal.clearsTranscriptionAPIURL = true
        }
        return withdrawal
    }
}
