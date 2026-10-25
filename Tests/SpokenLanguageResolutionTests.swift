import Foundation
import QuillAITextCore

@main
struct SpokenLanguageResolutionTests {
    static func main() {
        testEngineLanguageWinsForAutoDetect()
        testTraditionalChineseEngineLanguagePreservesScript()
        testSupportedEngineAliasesAreNormalized()
        testUnknownScriptSubtagFallsBackToTranscript()
        testUnassignedRegionSubtagRemainsUnavailable()
        testMalformedSupportedPrefixFallsBackToTranscript()
        testMalformedSupportedPrefixRemainsUnavailableWithoutTranscript()
        testPortugueseIsSupportedForExplicitEngineAndTranscriptResolution()
        testKoreanTranscriptIsInferredWhenEngineOmitsLanguage()
        testExplicitLanguageWinsOverEngineAndTranscript()
        testUnresolvableAutoDetectRemainsUnavailable()
        testRealtimeConfiguredLanguageDrivesRequestAndResolution()
        testSummaryOutputLanguageMappings()
        testSharedResolverSupportsTheTranscriptionLanguages()
        print("SpokenLanguageResolutionTests passed")
    }

    private static func testEngineLanguageWinsForAutoDetect() {
        let result = SpokenLanguageResolver.resolve(
            requestedLanguageCode: "auto",
            engineLanguageCode: "ko",
            transcript: "This text must not override the engine result."
        )

        precondition(result == SpokenLanguageResolution(
            languageCode: "ko",
            source: .engineDetected
        ))
    }

    private static func testTraditionalChineseEngineLanguagePreservesScript() {
        for engineLanguageCode in ["zh-Hant", "zh-HK"] {
            let result = SpokenLanguageResolver.resolve(
                requestedLanguageCode: "auto",
                engineLanguageCode: engineLanguageCode,
                transcript: "This English transcript must not override the engine result."
            )

            precondition(result == SpokenLanguageResolution(
                languageCode: "zh-Hant",
                source: .engineDetected
            ))
        }
    }

    private static func testSupportedEngineAliasesAreNormalized() {
        let cases = [
            (engineLanguageCode: "en-AU", expectedLanguageCode: "en"),
            (engineLanguageCode: "es-MX", expectedLanguageCode: "es"),
            (engineLanguageCode: "fr-CA", expectedLanguageCode: "fr"),
        ]

        for testCase in cases {
            let result = SpokenLanguageResolver.resolve(
                requestedLanguageCode: "auto",
                engineLanguageCode: testCase.engineLanguageCode,
                transcript: "한국어 전사문"
            )

            precondition(result == SpokenLanguageResolution(
                languageCode: testCase.expectedLanguageCode,
                source: .engineDetected
            ))
        }
    }

    private static func testUnknownScriptSubtagFallsBackToTranscript() {
        let result = SpokenLanguageResolver.resolve(
            requestedLanguageCode: "auto",
            engineLanguageCode: "en-Abcd",
            transcript: "회의에서 다음 주 화요일에 출시하기로 결정했습니다."
        )

        precondition(result == SpokenLanguageResolution(
            languageCode: "ko",
            source: .transcriptInferred
        ))
    }

    private static func testUnassignedRegionSubtagRemainsUnavailable() {
        let result = SpokenLanguageResolver.resolve(
            requestedLanguageCode: "auto",
            engineLanguageCode: "ko-QQ",
            transcript: "12345 ---"
        )

        precondition(result == SpokenLanguageResolution(
            languageCode: nil,
            source: .unavailable
        ))
    }

    private static func testMalformedSupportedPrefixFallsBackToTranscript() {
        for engineLanguageCode in ["en-not-a-language-code", "en-한국"] {
            let result = SpokenLanguageResolver.resolve(
                requestedLanguageCode: "auto",
                engineLanguageCode: engineLanguageCode,
                transcript: "회의에서 다음 주 화요일에 출시하기로 결정했습니다."
            )

            precondition(result == SpokenLanguageResolution(
                languageCode: "ko",
                source: .transcriptInferred
            ))
        }
    }

    private static func testMalformedSupportedPrefixRemainsUnavailableWithoutTranscript() {
        let result = SpokenLanguageResolver.resolve(
            requestedLanguageCode: "auto",
            engineLanguageCode: "ko-arbitrary-engine-text",
            transcript: "12345 ---"
        )

        precondition(result == SpokenLanguageResolution(
            languageCode: nil,
            source: .unavailable
        ))
    }

    private static func testPortugueseIsSupportedForExplicitEngineAndTranscriptResolution() {
        let explicit = SpokenLanguageResolver.resolve(
            requestedLanguageCode: "pt",
            engineLanguageCode: "en",
            transcript: "The English transcript must not override the configured language."
        )
        precondition(explicit == SpokenLanguageResolution(
            languageCode: "pt",
            source: .configured
        ))

        for engineLanguageCode in ["pt-BR", "pt-PT"] {
            let detected = SpokenLanguageResolver.resolve(
                requestedLanguageCode: "auto",
                engineLanguageCode: engineLanguageCode,
                transcript: "회의에서 다음 주 화요일에 출시하기로 결정했습니다."
            )
            precondition(detected == SpokenLanguageResolution(
                languageCode: "pt",
                source: .engineDetected
            ))
        }

        let inferred = SpokenLanguageResolver.resolve(
            requestedLanguageCode: "auto",
            engineLanguageCode: nil,
            transcript: "A equipe decidiu lançar o produto na próxima terça-feira e finalizar a documentação hoje."
        )
        precondition(inferred == SpokenLanguageResolution(
            languageCode: "pt",
            source: .transcriptInferred
        ))
    }

    private static func testKoreanTranscriptIsInferredWhenEngineOmitsLanguage() {
        let result = SpokenLanguageResolver.resolve(
            requestedLanguageCode: "auto",
            engineLanguageCode: nil,
            transcript: "회의에서 다음 주 화요일에 출시하기로 결정했습니다."
        )

        precondition(result == SpokenLanguageResolution(
            languageCode: "ko",
            source: .transcriptInferred
        ))
    }

    private static func testExplicitLanguageWinsOverEngineAndTranscript() {
        let result = SpokenLanguageResolver.resolve(
            requestedLanguageCode: "en",
            engineLanguageCode: "ko",
            transcript: "한국어 전사문"
        )

        precondition(result == SpokenLanguageResolution(
            languageCode: "en",
            source: .configured
        ))
    }

    private static func testUnresolvableAutoDetectRemainsUnavailable() {
        let result = SpokenLanguageResolver.resolve(
            requestedLanguageCode: "auto",
            engineLanguageCode: nil,
            transcript: "12345 ---"
        )

        precondition(result == SpokenLanguageResolution(
            languageCode: nil,
            source: .unavailable
        ))
    }

    private static func testRealtimeConfiguredLanguageDrivesRequestAndResolution() {
        let configuration = RealtimeTranscriptionLanguageConfiguration(
            transcriptionLanguage: .find(code: "ko")
        )
        let result = SpokenLanguageResolver.resolve(
            requestedLanguageCode: configuration.requestedLanguageCode,
            engineLanguageCode: "en",
            transcript: "English transcript"
        )

        precondition(configuration.requestLanguage == "ko")
        precondition(result == SpokenLanguageResolution(
            languageCode: "ko",
            source: .configured
        ))
    }

    private static func testSummaryOutputLanguageMappings() {
        precondition(TranscriptionLanguage.code(forSummaryOutput: "Korean") == "ko")
        precondition(TranscriptionLanguage.code(forSummaryOutput: "Portuguese") == "pt")
        precondition(TranscriptionLanguage.code(forSummaryOutput: "") == nil)
        precondition(TranscriptionLanguage.code(forSummaryOutput: "Same as spoken language") == nil)
        precondition(TranscriptionLanguage.code(forSummaryOutput: "Unsupported") == nil)
        precondition(TranscriptionLanguage.summaryPromptLanguage(for: "ko") == "Korean")
        precondition(TranscriptionLanguage.summaryPromptLanguage(for: "pt") == "Portuguese")
        precondition(TranscriptionLanguage.summaryPromptLanguage(for: "unsupported") == nil)
    }

    /// QuillAITextCore can't see `TranscriptionLanguage`, so it keeps the
    /// codes. The set must stay the transcription languages plus Portuguese.
    private static func testSharedResolverSupportsTheTranscriptionLanguages() {
        let transcriptionCodes = Set(TranscriptionLanguage.all.map(\.code).filter { $0 != "auto" })
        precondition(
            SpokenLanguageResolver.supportedCodes == transcriptionCodes.union(["pt"]),
            "SpokenLanguageResolver.supportedCodes matches TranscriptionLanguage.all plus pt"
        )
    }
}
