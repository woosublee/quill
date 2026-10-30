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
            try clearingAKeyWithdrawsItsAgreedProvider()
            try clearingAKeySavedBeforeConsentOnlyDeletesIt()
            try displayNameShowsAnythingButPlainHTTPS()
            try anUnreadableTranscriptionKeyDoesNotFallBack()
            try keysNeverPrint()
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
        var settings = CloudConsentTargets(apiBaseURL: mainURL, apiKey: "", apiKeyIsUnreadable: false, transcriptionAPIURL: "", transcriptionAPIKey: "", transcriptionAPIKeyIsUnreadable: false)
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
        let settings = CloudConsentTargets(apiBaseURL: mainURL, apiKey: "sk-main", apiKeyIsUnreadable: false, transcriptionAPIURL: otherURL, transcriptionAPIKey: "", transcriptionAPIKeyIsUnreadable: false)
        try expect(settings.unconsented(in: ledger).count == 2, "both new providers ask")
        ledger.grant(forBaseURL: mainURL)
        try expect(settings.unconsented(in: ledger).map(\.baseURL) == [otherURL], "only the one not agreed to asks")
    }

    static func withdrawalClearsEveryKeyThatGoesThere() throws {
        let mainOrigin = "https://api.example-cloud.test"
        let otherOrigin = "https://transcribe.example-voice.test"

        let shared = CloudConsentTargets(apiBaseURL: mainURL, apiKey: "sk-main", apiKeyIsUnreadable: false, transcriptionAPIURL: "", transcriptionAPIKey: "sk-voice", transcriptionAPIKeyIsUnreadable: false)
        try expect(
            shared.withdrawal(forOrigin: mainOrigin)
                == .init(clearsAPIKey: true, clearsTranscriptionAPIKey: true, clearsTranscriptionAPIURL: false),
            "both keys go to the main provider, so both are cleared"
        )

        let fallback = CloudConsentTargets(apiBaseURL: mainURL, apiKey: "sk-main", apiKeyIsUnreadable: false, transcriptionAPIURL: otherURL, transcriptionAPIKey: "", transcriptionAPIKeyIsUnreadable: false)
        try expect(
            fallback.withdrawal(forOrigin: otherOrigin)
                == .init(clearsAPIKey: false, clearsTranscriptionAPIKey: false, clearsTranscriptionAPIURL: true),
            "the main key stops going to the transcription provider; the main provider keeps it"
        )
        try expect(
            fallback.withdrawal(forOrigin: mainOrigin) == .init(clearsAPIKey: true),
            "withdrawing the main provider clears the main key, which also stops the fallback"
        )

        let separate = CloudConsentTargets(apiBaseURL: mainURL, apiKey: "sk-main", apiKeyIsUnreadable: false, transcriptionAPIURL: otherURL, transcriptionAPIKey: "sk-voice", transcriptionAPIKeyIsUnreadable: false)
        try expect(
            separate.withdrawal(forOrigin: otherOrigin)
                == .init(clearsTranscriptionAPIKey: true, clearsTranscriptionAPIURL: true),
            "a separate transcription key and its URL are cleared, so the main key doesn't fall back to it"
        )
        try expect(separate.withdrawal(forOrigin: "https://unrelated.example.test") == .init(), "an unused origin clears nothing")

        let transcriptionOnly = CloudConsentTargets(apiBaseURL: mainURL, apiKey: "", apiKeyIsUnreadable: false, transcriptionAPIURL: otherURL, transcriptionAPIKey: "sk-voice", transcriptionAPIKeyIsUnreadable: false)
        try expect(
            transcriptionOnly.withdrawal(forOrigin: otherOrigin) == .init(clearsTranscriptionAPIKey: true),
            "with no main key there's nothing to fall back to, so the URL stays"
        )
    }

    /// #723: clearing a key that goes to an agreed provider withdraws that
    /// provider, the same withdrawal as Withdraw, so saving it again asks.
    static func clearingAKeyWithdrawsItsAgreedProvider() throws {
        let mainOrigin = "https://api.example-cloud.test"
        let otherOrigin = "https://transcribe.example-voice.test"
        var ledger = CloudConsentLedger()
        ledger.grant(forBaseURL: mainURL)
        ledger.grant(forBaseURL: otherURL)

        // The main key on its own.
        var settings = CloudConsentTargets(apiBaseURL: mainURL, apiKey: "sk-main", apiKeyIsUnreadable: false, transcriptionAPIURL: "", transcriptionAPIKey: "", transcriptionAPIKeyIsUnreadable: false)
        let main = settings.consentedTarget(forClearing: .main, in: ledger)
        try expect(main?.origin == mainOrigin, "clearing the main key withdraws the main provider")
        try expect(settings.consentedTarget(forClearing: .transcription, in: ledger) == nil, "no transcription key, nothing to clear")
        try expect(settings.withdrawal(forOrigin: mainOrigin) == .init(clearsAPIKey: true), "the main key is cleared")

        // After the withdrawal, saving the key again asks again.
        ledger.revoke(forBaseURL: mainURL)
        settings.apiKey = ""
        try expect(settings.targets.isEmpty, "nothing goes anywhere once it's cleared")
        settings.apiKey = "sk-main"
        try expect(settings.unconsented(in: ledger).map(\.origin) == [mainOrigin], "saving the key again asks again")
        ledger.grant(forBaseURL: mainURL)

        // Two keys for one provider: clearing either withdraws it and clears both.
        let shared = CloudConsentTargets(apiBaseURL: mainURL, apiKey: "sk-main", apiKeyIsUnreadable: false, transcriptionAPIURL: "", transcriptionAPIKey: "sk-voice", transcriptionAPIKeyIsUnreadable: false)
        for field in [CloudConsentTargets.KeyField.main, .transcription] {
            let target = shared.consentedTarget(forClearing: field, in: ledger)
            try expect(target?.origin == mainOrigin, "\(field) on the shared provider withdraws it")
            try expect(
                shared.withdrawal(forOrigin: mainOrigin)
                    == .init(clearsAPIKey: true, clearsTranscriptionAPIKey: true),
                "consent is per provider, so both keys are cleared"
            )
        }
        let samePathless = CloudConsentTargets(apiBaseURL: mainURL, apiKey: "sk-main", apiKeyIsUnreadable: false, transcriptionAPIURL: "https://api.example-cloud.test/other/v1", transcriptionAPIKey: "sk-voice", transcriptionAPIKeyIsUnreadable: false)
        try expect(
            samePathless.consentedTarget(forClearing: .transcription, in: ledger)?.origin == mainOrigin,
            "another path on the same origin is the same provider"
        )
        try expect(
            samePathless.withdrawal(forOrigin: mainOrigin) == .init(clearsAPIKey: true, clearsTranscriptionAPIKey: true),
            "and both keys are cleared"
        )

        // A separate transcription provider: its key, and its URL so the
        // main key doesn't start going there.
        let separate = CloudConsentTargets(apiBaseURL: mainURL, apiKey: "sk-main", apiKeyIsUnreadable: false, transcriptionAPIURL: otherURL, transcriptionAPIKey: "sk-voice", transcriptionAPIKeyIsUnreadable: false)
        try expect(separate.consentedTarget(forClearing: .transcription, in: ledger)?.origin == otherOrigin, "the transcription key's provider")
        try expect(separate.consentedTarget(forClearing: .main, in: ledger)?.origin == mainOrigin, "the main key's provider, not the transcription one")
        try expect(
            separate.withdrawal(forOrigin: otherOrigin) == .init(clearsTranscriptionAPIKey: true, clearsTranscriptionAPIURL: true),
            "clearing the transcription key clears its URL too"
        )
        try expect(separate.withdrawal(forOrigin: mainOrigin) == .init(clearsAPIKey: true), "clearing the main key leaves transcription's own pair")

        // The main key falling back to a separate transcription URL: clearing
        // it withdraws the main provider; the main key stops going anywhere.
        let fallback = CloudConsentTargets(apiBaseURL: mainURL, apiKey: "sk-main", apiKeyIsUnreadable: false, transcriptionAPIURL: otherURL, transcriptionAPIKey: "", transcriptionAPIKeyIsUnreadable: false)
        try expect(fallback.consentedTarget(forClearing: .main, in: ledger)?.origin == mainOrigin, "the main key's own provider")
        try expect(fallback.consentedTarget(forClearing: .transcription, in: ledger) == nil, "transcription has no key of its own to clear")
    }

    static func clearingAKeySavedBeforeConsentOnlyDeletesIt() throws {
        let empty = CloudConsentLedger()
        let separate = CloudConsentTargets(apiBaseURL: mainURL, apiKey: "sk-main", apiKeyIsUnreadable: false, transcriptionAPIURL: otherURL, transcriptionAPIKey: "sk-voice", transcriptionAPIKeyIsUnreadable: false)
        try expect(separate.consentedTarget(forClearing: .main, in: empty) == nil, "a main key saved before consent is only deleted")
        try expect(separate.consentedTarget(forClearing: .transcription, in: empty) == nil, "a transcription key saved before consent is only deleted")

        var onlyOther = CloudConsentLedger()
        onlyOther.grant(forBaseURL: otherURL)
        try expect(separate.consentedTarget(forClearing: .main, in: onlyOther) == nil, "another provider's consent doesn't count")
        try expect(separate.consentedTarget(forClearing: .transcription, in: onlyOther)?.baseURL == otherURL, "its own provider's does")

        var agreed = CloudConsentLedger()
        agreed.grant(forBaseURL: mainURL)
        let unreadable = CloudConsentTargets(apiBaseURL: mainURL, apiKey: "", apiKeyIsUnreadable: true, transcriptionAPIURL: "", transcriptionAPIKey: "  ", transcriptionAPIKeyIsUnreadable: true)
        try expect(unreadable.consentedTarget(forClearing: .main, in: agreed) == nil, "an unreadable key's empty field clears nothing; Withdraw does")
        try expect(unreadable.consentedTarget(forClearing: .transcription, in: agreed) == nil, "a blank field clears nothing")

        let noOrigin = CloudConsentTargets(apiBaseURL: "not a url", apiKey: "sk-main", apiKeyIsUnreadable: false, transcriptionAPIURL: "", transcriptionAPIKey: "", transcriptionAPIKeyIsUnreadable: false)
        try expect(noOrigin.consentedTarget(forClearing: .main, in: agreed) == nil, "a key that goes nowhere is only deleted")
    }

    static func displayNameShowsAnythingButPlainHTTPS() throws {
        func name(_ url: String) -> String? {
            CloudConsentTargets(apiBaseURL: url, apiKey: "sk-main", apiKeyIsUnreadable: false, transcriptionAPIURL: "", transcriptionAPIKey: "", transcriptionAPIKeyIsUnreadable: false)
                .targets.first?.displayName
        }
        try expect(name(mainURL) == "api.example-cloud.test", "plain HTTPS shows the host")
        try expect(name("http://api.example-cloud.test/v1") == "http://api.example-cloud.test", "HTTP shows its scheme")
        try expect(name("https://api.example-cloud.test:8443/v1") == "https://api.example-cloud.test:8443", "a port shows")
        try expect(name("http://[::1]:8080/v1") == "http://[::1]:8080", "an IPv6 address keeps its port")
        try expect(name("https://[::1]/v1") == "[::1]", "plain HTTPS on IPv6 shows the host")
    }

    static func anUnreadableTranscriptionKeyDoesNotFallBack() throws {
        let voiceOrigin = "https://transcribe.example-voice.test"
        let settings = CloudConsentTargets(
            apiBaseURL: mainURL,
            apiKey: "sk-main",
            apiKeyIsUnreadable: false,
            transcriptionAPIURL: otherURL,
            transcriptionAPIKey: "",
            transcriptionAPIKeyIsUnreadable: true
        )
        try expect(settings.resolvedTranscriptionKey.isEmpty, "the main key doesn't stand in for an unreadable one")
        try expect(
            settings.targets.map(\.host) == ["api.example-cloud.test", "transcribe.example-voice.test"],
            "the unreadable key's provider is still listed, so it can be withdrawn"
        )
        try expect(
            settings.withdrawal(forOrigin: voiceOrigin)
                == .init(clearsTranscriptionAPIKey: true, clearsTranscriptionAPIURL: true),
            "withdrawing deletes the unreadable key, and the URL the main key would then go to"
        )

        let unreadableMain = CloudConsentTargets(
            apiBaseURL: mainURL,
            apiKey: "",
            apiKeyIsUnreadable: true,
            transcriptionAPIURL: "",
            transcriptionAPIKey: "",
            transcriptionAPIKeyIsUnreadable: false
        )
        try expect(unreadableMain.targets.map(\.host) == ["api.example-cloud.test"], "an unreadable main key's provider is listed")

        var unreadableMainWithVoice = unreadableMain
        unreadableMainWithVoice.transcriptionAPIURL = otherURL
        try expect(
            unreadableMainWithVoice.targets.map(\.host) == ["api.example-cloud.test", "transcribe.example-voice.test"],
            "the separate transcription URL the unreadable main key will go to is listed and asked about"
        )
        try expect(
            unreadableMainWithVoice.withdrawal(forOrigin: voiceOrigin) == .init(clearsTranscriptionAPIURL: true),
            "withdrawing it clears that URL"
        )
        try expect(
            unreadableMain.withdrawal(forOrigin: "https://api.example-cloud.test") == .init(clearsAPIKey: true),
            "withdrawing deletes the unreadable main key"
        )
    }

    static func keysNeverPrint() throws {
        let settings = CloudConsentTargets(
            apiBaseURL: "https://user:secret-token@api.example-cloud.test/v1?key=secret-query",
            apiKey: "sk-secret-main",
            apiKeyIsUnreadable: false,
            transcriptionAPIURL: "",
            transcriptionAPIKey: "sk-secret-voice",
            transcriptionAPIKeyIsUnreadable: false
        )
        var dumped = ""
        dump(settings, to: &dumped)
        var dumpedTargets = ""
        dump(settings.targets, to: &dumpedTargets)
        for text in ["\(settings)", String(reflecting: settings), dumped, "\(settings.targets)", dumpedTargets] {
            try expect(!text.contains("secret"), "a printed value hides the keys and anything typed into a URL")
        }
    }

    static func copyKeysAreStable() throws {
        try expect(CloudConsentCopy.titleFormatKey == "Send to %@?", "title key")
        try expect(
            CloudConsentCopy.withdrawBusyKey == "You can't withdraw while recording or transcribing. Try again when it finishes.",
            "the busy key matches both apps' catalogs"
        )
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
