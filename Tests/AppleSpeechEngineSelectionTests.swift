import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct AppleSpeechEngineSelectionTests {
    static func main() throws {
        try testInstalledSupportedLocaleUsesSpeechAnalyzer()
        try testMissingAssetsUseLegacyAndStartInstall()
        try testUnavailableAnalyzerOrLocaleUsesLegacy()
        try testDownloadingOrUnsupportedAssetsUseLegacyWithoutInstall()
        try testProgressiveTranscriptReplacesVolatileAndKeepsFinal()
        try testAppleSpeechUsesRoutingTranscriberAndLegacyFallback()
        print("AppleSpeechEngineSelectionTests passed")
    }

    private static func testInstalledSupportedLocaleUsesSpeechAnalyzer() throws {
        let decision = AppleSpeechEngineSelection.decide(
            analyzerAvailable: true,
            localeSupported: true,
            assetState: .installed
        )
        try expect(decision.engine == .speechAnalyzer, "installed locale uses SpeechAnalyzer")
        try expect(!decision.shouldInstallAssets, "installed locale needs no download")
    }

    private static func testMissingAssetsUseLegacyAndStartInstall() throws {
        let decision = AppleSpeechEngineSelection.decide(
            analyzerAvailable: true,
            localeSupported: true,
            assetState: .supported
        )
        try expect(decision.engine == .legacyRecognizer, "recording never waits for a download")
        try expect(decision.shouldInstallAssets, "supported locale starts its asset install")
    }

    private static func testUnavailableAnalyzerOrLocaleUsesLegacy() throws {
        for (analyzerAvailable, localeSupported) in [(false, true), (true, false), (false, false)] {
            let decision = AppleSpeechEngineSelection.decide(
                analyzerAvailable: analyzerAvailable,
                localeSupported: localeSupported,
                assetState: .installed
            )
            try expect(decision.engine == .legacyRecognizer, "unavailable analyzer or locale uses legacy")
            try expect(!decision.shouldInstallAssets, "nothing to install without support")
        }
    }

    private static func testDownloadingOrUnsupportedAssetsUseLegacyWithoutInstall() throws {
        for state in [AppleSpeechAssetState.downloading, .unsupported] {
            let decision = AppleSpeechEngineSelection.decide(
                analyzerAvailable: true,
                localeSupported: true,
                assetState: state
            )
            try expect(decision.engine == .legacyRecognizer, "\(state) uses legacy")
            try expect(!decision.shouldInstallAssets, "\(state) does not start another install")
        }
    }

    private static func testProgressiveTranscriptReplacesVolatileAndKeepsFinal() throws {
        var transcript = AppleSpeechProgressiveTranscript()
        transcript.apply(text: "Synthetic", isFinal: false)
        transcript.apply(text: "Synthetic sample", isFinal: false)
        try expect(transcript.text == "Synthetic sample", "volatile result replaces the previous one")
        transcript.apply(text: "Synthetic sample one.", isFinal: true)
        transcript.apply(text: " Two", isFinal: false)
        try expect(transcript.text == "Synthetic sample one. Two", "final text stays while volatile follows")
        transcript.apply(text: " Two.", isFinal: true)
        try expect(transcript.text == "Synthetic sample one. Two.", "final segments accumulate")
        try expect(transcript.volatileText.isEmpty, "final result clears volatile text")
    }

    // Live Apple Speech routes through SpeechAnalyzer on macOS 26+ and keeps the
    // on-device SFSpeechRecognizer transcriber as the fallback.
    private static func testAppleSpeechUsesRoutingTranscriberAndLegacyFallback() throws {
        let factory = try String(contentsOfFile: "Sources/AppleSpeechLiveTranscriber.swift", encoding: .utf8)
        try expect(
            factory.contains("if isAppleSpeech { return AppleSpeechRoutingLiveTranscriber() }"),
            "factory returns the routing transcriber"
        )
        let routing = try String(contentsOfFile: "Sources/AppleSpeechAnalyzerTranscriber.swift", encoding: .utf8)
        try expect(routing.contains("let legacy = AppleSpeechLiveTranscriber()"), "router falls back to legacy")
        try expect(routing.contains("#if compiler(>=6.2)"), "older toolchains still build")
        try expect(!routing.contains("%{public}@\", text") && !routing.contains("text=%{public}@"),
                   "transcript text is never logged publicly")
        let service = try String(contentsOfFile: "Sources/TranscriptionService.swift", encoding: .utf8)
        try expect(service.contains("AppleSpeechAnalyzerSupport.transcribeFile(fileURL, locale: analyzerLocale)"),
                   "file transcription tries SpeechAnalyzer")
        try expect(service.contains("request.requiresOnDeviceRecognition = true"), "legacy stays on-device")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw TestFailure(message) }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
