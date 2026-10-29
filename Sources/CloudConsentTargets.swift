import Foundation
import QuillProviderCore

/// The cloud providers the Mac's settings send to, and what consent they
/// need (#693). The main pair (API base URL and key) carries cleanup,
/// summaries, context, and transcription; the transcription pair falls back
/// to the main URL and key, each on its own, when its field is empty.
struct CloudConsentTargets: Equatable {
    var apiBaseURL: String
    var apiKey: String
    var transcriptionAPIURL: String
    var transcriptionAPIKey: String

    struct Target: Equatable, Identifiable {
        let origin: String
        let host: String
        let baseURL: String
        var id: String { origin }
    }

    /// What withdrawing consent for one origin clears, so nothing more goes
    /// there.
    struct Withdrawal: Equatable {
        var clearsAPIKey = false
        var clearsTranscriptionAPIKey = false
        /// Transcription sends the main key to its own URL; clearing that URL
        /// sends transcription back to the main provider instead.
        var clearsTranscriptionAPIURL = false
    }

    var resolvedTranscriptionURL: String {
        let trimmed = transcriptionAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? apiBaseURL : trimmed
    }

    var resolvedTranscriptionKey: String {
        let trimmed = transcriptionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? apiKey : trimmed
    }

    /// Each provider a saved key goes to, once per origin, the main one first.
    var targets: [Target] {
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
    func unconsented(in ledger: CloudConsentLedger) -> [Target] {
        targets.filter { !ledger.hasConsent(forBaseURL: $0.baseURL) }
    }

    func withdrawal(forOrigin origin: String) -> Withdrawal {
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
