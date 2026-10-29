import Foundation
import QuillProviderCore

/// Cloud consent (#693): the shared per-origin record, and which saved keys
/// on the Mac need it and what withdrawing clears. Synthetic hosts only.
@main
struct CloudConsentTests {
    static func main() {
        do {
            try consentIsPerOrigin()
            try onlyANewKeyForANewOriginNeedsConsent()
            try ledgerPersistsGrantsWithTheirDates()
            try targetsFollowTheTranscriptionFallback()
            try unconsentedTargetsListEachNewProvider()
            try withdrawalClearsEveryKeyThatGoesThere()
            try displayNameShowsAnythingButPlainHTTPS()
            try copyKeysAreStable()
            print("CloudConsentTests passed")
        } catch {
            fputs("CloudConsentTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
    }

    static let mainURL = "https://api.example-cloud.test/openai/v1"
    static let otherURL = "https://transcribe.example-voice.test/v1"

    static func consentIsPerOrigin() throws {
        var ledger = CloudConsentLedger()
        try expect(!ledger.hasConsent(forBaseURL: mainURL), "no consent at first")
        ledger.grant(forBaseURL: mainURL, at: Date(timeIntervalSince1970: 100))
        try expect(ledger.hasConsent(forBaseURL: "https://API.example-cloud.test/other"), "another path is the same provider")
        try expect(!ledger.hasConsent(forBaseURL: "http://api.example-cloud.test/openai/v1"), "another scheme asks again")
        try expect(!ledger.hasConsent(forBaseURL: "https://api.example-cloud.test:8443/v1"), "another port asks again")
        try expect(!ledger.hasConsent(forBaseURL: otherURL), "another host asks again")
        try expect(ledger.grants == ["https://api.example-cloud.test": Date(timeIntervalSince1970: 100)], "only the origin is kept")
        ledger.revoke(forBaseURL: "https://api.example-cloud.test/v2")
        try expect(ledger.grants.isEmpty, "revoking any path of the origin removes it")
        ledger.grant(forBaseURL: "not a url")
        try expect(ledger.grants.isEmpty, "a URL with no origin is never granted")
    }

    static func onlyANewKeyForANewOriginNeedsConsent() throws {
        var ledger = CloudConsentLedger()
        try expect(ledger.needsConsent(forBaseURL: mainURL, key: "sk-synthetic"), "a key for a new provider asks")
        try expect(!ledger.needsConsent(forBaseURL: mainURL, key: "  "), "an empty key sends nothing")
        try expect(!ledger.needsConsent(forBaseURL: "not a url", key: "sk-synthetic"), "a bad URL can't be sent to")
        ledger.grant(forBaseURL: mainURL)
        try expect(!ledger.needsConsent(forBaseURL: mainURL, key: "sk-synthetic"), "an agreed provider doesn't ask again")
    }

    static func ledgerPersistsGrantsWithTheirDates() throws {
        let suite = "cloud-consent-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(description: "defaults suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        var ledger = CloudConsentLedger.load(from: defaults)
        try expect(ledger.grants.isEmpty, "nothing stored at first")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        ledger.grant(forBaseURL: mainURL, at: date)
        ledger.save(to: defaults)
        let loaded = CloudConsentLedger.load(from: defaults)
        try expect(loaded.grantedAt(forBaseURL: mainURL) == date, "the grant and its date survive a reload")
        ledger.revokeAll()
        ledger.save(to: defaults)
        try expect(CloudConsentLedger.load(from: defaults).grants.isEmpty, "revoking all is stored too")
    }

    static func targetsFollowTheTranscriptionFallback() throws {
        var settings = CloudConsentTargets(apiBaseURL: mainURL, apiKey: "", transcriptionAPIURL: "", transcriptionAPIKey: "")
        try expect(settings.targets.isEmpty, "no key, nothing is sent")
        settings.apiKey = "sk-main"
        try expect(settings.targets.map(\.host) == ["api.example-cloud.test"], "one provider when transcription uses the main pair")
        settings.transcriptionAPIURL = otherURL
        try expect(
            settings.targets.map(\.host) == ["api.example-cloud.test", "transcribe.example-voice.test"],
            "the main key goes to a separate transcription URL too"
        )
        settings.apiKey = ""
        try expect(settings.targets.isEmpty, "no key at all, nothing is sent")
        settings.transcriptionAPIKey = "sk-voice"
        try expect(settings.targets.map(\.host) == ["transcribe.example-voice.test"], "only the transcription key is sent")
    }

    static func unconsentedTargetsListEachNewProvider() throws {
        var ledger = CloudConsentLedger()
        let settings = CloudConsentTargets(apiBaseURL: mainURL, apiKey: "sk-main", transcriptionAPIURL: otherURL, transcriptionAPIKey: "")
        try expect(settings.unconsented(in: ledger).count == 2, "both new providers ask")
        ledger.grant(forBaseURL: mainURL)
        try expect(settings.unconsented(in: ledger).map(\.baseURL) == [otherURL], "only the one not agreed to asks")
    }

    static func withdrawalClearsEveryKeyThatGoesThere() throws {
        let mainOrigin = "https://api.example-cloud.test"
        let otherOrigin = "https://transcribe.example-voice.test"

        let shared = CloudConsentTargets(apiBaseURL: mainURL, apiKey: "sk-main", transcriptionAPIURL: "", transcriptionAPIKey: "sk-voice")
        try expect(
            shared.withdrawal(forOrigin: mainOrigin)
                == .init(clearsAPIKey: true, clearsTranscriptionAPIKey: true, clearsTranscriptionAPIURL: false),
            "both keys go to the main provider, so both are cleared"
        )

        let fallback = CloudConsentTargets(apiBaseURL: mainURL, apiKey: "sk-main", transcriptionAPIURL: otherURL, transcriptionAPIKey: "")
        try expect(
            fallback.withdrawal(forOrigin: otherOrigin)
                == .init(clearsAPIKey: false, clearsTranscriptionAPIKey: false, clearsTranscriptionAPIURL: true),
            "the main key stops going to the transcription provider; the main provider keeps it"
        )
        try expect(
            fallback.withdrawal(forOrigin: mainOrigin) == .init(clearsAPIKey: true),
            "withdrawing the main provider clears the main key, which also stops the fallback"
        )

        let separate = CloudConsentTargets(apiBaseURL: mainURL, apiKey: "sk-main", transcriptionAPIURL: otherURL, transcriptionAPIKey: "sk-voice")
        try expect(
            separate.withdrawal(forOrigin: otherOrigin)
                == .init(clearsTranscriptionAPIKey: true, clearsTranscriptionAPIURL: true),
            "a separate transcription key and its URL are cleared, so the main key doesn't fall back to it"
        )
        try expect(separate.withdrawal(forOrigin: "https://unrelated.example.test") == .init(), "an unused origin clears nothing")

        let transcriptionOnly = CloudConsentTargets(apiBaseURL: mainURL, apiKey: "", transcriptionAPIURL: otherURL, transcriptionAPIKey: "sk-voice")
        try expect(
            transcriptionOnly.withdrawal(forOrigin: otherOrigin) == .init(clearsTranscriptionAPIKey: true),
            "with no main key there's nothing to fall back to, so the URL stays"
        )
    }

    static func displayNameShowsAnythingButPlainHTTPS() throws {
        func name(_ url: String) -> String? {
            CloudConsentTargets(apiBaseURL: url, apiKey: "sk-main", transcriptionAPIURL: "", transcriptionAPIKey: "")
                .targets.first?.displayName
        }
        try expect(name(mainURL) == "api.example-cloud.test", "plain HTTPS shows the host")
        try expect(name("http://api.example-cloud.test/v1") == "http://api.example-cloud.test", "HTTP shows its scheme")
        try expect(name("https://api.example-cloud.test:8443/v1") == "https://api.example-cloud.test:8443", "a port shows")
        try expect(name("http://[::1]:8080/v1") == "http://[::1]:8080", "an IPv6 address keeps its port")
        try expect(name("https://[::1]/v1") == "[::1]", "plain HTTPS on IPv6 shows the host")
    }

    static func copyKeysAreStable() throws {
        try expect(CloudConsentCopy.titleFormatKey == "Send to %@?", "title key")
        try expect(
            CloudConsentCopy.bodyKey(mentionsScreenContext: true).contains("screen context"),
            "the Mac's copy mentions screen context"
        )
        try expect(
            !CloudConsentCopy.bodyKey(mentionsScreenContext: false).contains("screen context"),
            "the iPhone's copy doesn't"
        )
    }
}
