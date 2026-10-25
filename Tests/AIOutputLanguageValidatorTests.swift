import Foundation
import QuillAITextCore

@main
struct AIOutputLanguageValidatorTests {
    static func main() throws {
        try testKoreanProseIsAcceptedForKoreanSelection()
        try testChineseProseIsRejectedForKoreanSelection()
        try testEnglishProseIsRejectedForKoreanSelection()
        try testIdentifierOnlyOutputIsUncertainForKoreanSelection()
        try testNoConfiguredLanguageDoesNotForceTranslation()
        try testAutomaticKoreanSourceLanguageRejectsEnglishOutput()
        try testLegacyAutomaticKoreanSourceLanguageRejectsEnglishOutput()
        try testKoreanSourceLanguageIsInferredForAutomaticOutput()
        try testEnglishSourceLanguageIsInferredForAutomaticOutput()
        try testShortSourceDoesNotCreateLanguageExpectation()
        try testTranscriptInferredLanguageStillRequiresReliableSourceText()
        try testIdentifierHeavySourceDoesNotCreateLanguageExpectation()
        try testCommandAndPathSourceDoesNotCreateLanguageExpectation()
        try testMixedScriptSourceDoesNotCreateLanguageExpectation()
        print("AIOutputLanguageValidatorTests passed")
    }

    private static func testKoreanProseIsAcceptedForKoreanSelection() throws {
        let result = AIOutputLanguageValidator(outputLanguage: "Korean").validate(
            generatedProse: "회의에서 다음 주 화요일에 출시하기로 결정했습니다. 담당자는 오늘 안에 안내 문서를 작성합니다."
        )

        try expect(result == .accepted, "Korean prose is accepted for Korean output")
    }

    private static func testChineseProseIsRejectedForKoreanSelection() throws {
        let result = AIOutputLanguageValidator(outputLanguage: "Korean").validate(
            generatedProse: "会议决定下周二发布产品，负责人将在今天完成说明文档。"
        )

        try expect(result == .mismatch, "Chinese prose is rejected for Korean output")
    }

    private static func testEnglishProseIsRejectedForKoreanSelection() throws {
        let result = AIOutputLanguageValidator(outputLanguage: "Korean").validate(
            generatedProse: "The team decided to ship the product next Tuesday and will finish the notes today."
        )

        try expect(result == .mismatch, "English prose is rejected for Korean output")
    }

    private static func testIdentifierOnlyOutputIsUncertainForKoreanSelection() throws {
        let result = AIOutputLanguageValidator(outputLanguage: "Korean").validate(
            generatedProse: "quill_release_2026_v2"
        )

        try expect(result == .uncertain, "identifier-only output is handled as uncertain")
    }

    private static func testNoConfiguredLanguageDoesNotForceTranslation() throws {
        let result = AIOutputLanguageValidator(outputLanguage: nil).validate(
            generatedProse: "The team decided to ship next Tuesday."
        )

        try expect(result == .notRequested, "no language selection does not require a language match")
    }

    private static func testAutomaticKoreanSourceLanguageRejectsEnglishOutput() throws {
        let result = AIOutputLanguageValidator(
            outputLanguage: "",
            expectedSourceLanguage: "ko"
        ).validate(
            generatedProse: "The team decided to ship the product next Tuesday and will finish the notes today."
        )

        try expect(result == .mismatch, "automatic Korean source language rejects English output")
    }

    private static func testLegacyAutomaticKoreanSourceLanguageRejectsEnglishOutput() throws {
        let result = AIOutputLanguageValidator(
            outputLanguage: "auto",
            expectedSourceLanguage: "ko"
        ).validate(
            generatedProse: "The team decided to ship the product next Tuesday and will finish the notes today."
        )

        try expect(result == .mismatch, "legacy automatic Korean source language rejects English output")
    }

    private static func testKoreanSourceLanguageIsInferredForAutomaticOutput() throws {
        let detectedLanguage = AIOutputLanguageValidator.inferredSourceLanguage(
            for: "회의에서 다음 주 화요일에 제품을 출시하기로 결정했습니다. 담당자는 오늘 안에 안내 문서를 작성하고 검토 의견을 반영하기로 했습니다."
        )

        try expect(detectedLanguage == "ko", "Korean source language is inferred for automatic output")
    }

    private static func testEnglishSourceLanguageIsInferredForAutomaticOutput() throws {
        let detectedLanguage = AIOutputLanguageValidator.inferredSourceLanguage(
            for: "The team decided to ship the product next Tuesday after reviewing the release notes and rollback plan with the external partners."
        )

        try expect(detectedLanguage == "en", "English source language is inferred for automatic output")
    }

    private static func testShortSourceDoesNotCreateLanguageExpectation() throws {
        for source in ["안녕하세요", "hello"] {
            let detectedLanguage = AIOutputLanguageValidator.inferredSourceLanguage(for: source)
            try expect(detectedLanguage == nil, "short source does not create a language expectation")
        }
    }

    private static func testTranscriptInferredLanguageStillRequiresReliableSourceText() throws {
        let expectedLanguage = AIOutputLanguageValidator.expectedSourceLanguage(
            outputLanguage: "",
            spokenLanguage: SpokenLanguageResolution(
                languageCode: "ko",
                source: .transcriptInferred
            ),
            fallbackSource: "안녕하세요"
        )

        try expect(expectedLanguage == nil, "transcript-inferred language still requires reliable source text")
    }

    private static func testIdentifierHeavySourceDoesNotCreateLanguageExpectation() throws {
        let detectedLanguage = AIOutputLanguageValidator.inferredSourceLanguage(
            for: "quill_release_2026_v2 https://example.com/reports/2026-08-10 --dry-run"
        )

        try expect(detectedLanguage == nil, "identifier-heavy source does not create a language expectation")
    }

    private static func testCommandAndPathSourceDoesNotCreateLanguageExpectation() throws {
        let detectedLanguage = AIOutputLanguageValidator.inferredSourceLanguage(
            for: "--fix /tmp/report.json --config /var/tmp/results.json --output /Users/me/Documents/release.json"
        )

        try expect(detectedLanguage == nil, "command-and-path source does not create a language expectation")
    }

    private static func testMixedScriptSourceDoesNotCreateLanguageExpectation() throws {
        let detectedLanguage = AIOutputLanguageValidator.inferredSourceLanguage(
            for: "We should launch 다음 주 화요일 and document the rollback plan 오늘."
        )

        try expect(detectedLanguage == nil, "mixed-script source does not create a language expectation")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(message) }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
