import Foundation
import QuillSummaryFormatCore

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct MeetingSummaryOutputValidatorTests {
    static func main() throws {
        try testRejectsSourceQuoteOutsideTranscript()
        try testRejectsOverviewWithoutEvidence()
        try testRejectsOverviewWithMoreThanTwoEvidenceQuotes()
        try testRejectsOverviewWithDuplicateEvidenceQuotes()
        try testAcceptsOverviewWithTwoDistinctEvidenceQuotes()
        try testRejectsGeneratedPartialProseAsMergeEvidence()
        try testRejectsActionOwnerOutsideSourceQuote()
        try testAcceptsKoreanDateGroundingForISODueDate()
        try testEvidenceRepairPreservesLocalizedDateGroundedISODueDate()
        try testAcceptsJapaneseDateGroundingForISODueDate()
        try testRejectsYearlessLocalizedDateForISODueDate()
        try testRejectsWrongLanguageInGeneratedProse()
        try testPreservesSourceQuoteLanguageWhileValidatingGeneratedProse()
        try testSameAsSpokenLanguageRejectsEnglishSummaryForKorean()
        try testTraditionalChineseIsAcceptedForTraditionalAndGenericChinese()
        try testTraditionalChineseIsRejectedForSimplifiedChinese()
        testEvidenceRepairReplacesWhitespaceAndPunctuationVariantWithSourceSubstring()
        testEvidenceRepairMapsLowercaseExpansionToOriginalSourceSubstring()
        testEvidenceRepairMarksUnresolvedCitationUnverified()
        testEvidenceRepairSanitizesUngroundedActionMetadata()
        print("MeetingSummaryOutputValidatorTests passed")
    }

    private static func testRejectsSourceQuoteOutsideTranscript() throws {
        try expectFailure(.sourceQuoteNotFound) {
            try MeetingSummaryOutputValidator().validate(
                v2WithQuote("invented source"),
                against: "Minsu will send it."
            )
        }
    }

    private static func testRejectsOverviewWithoutEvidence() throws {
        try expectFailure(.overviewEvidenceCountInvalid) {
            try MeetingSummaryOutputValidator().validate(
                v2WithOverviewQuotes([]),
                against: "First source quote."
            )
        }
    }

    private static func testRejectsOverviewWithMoreThanTwoEvidenceQuotes() throws {
        try expectFailure(.overviewEvidenceCountInvalid) {
            try MeetingSummaryOutputValidator().validate(
                v2WithOverviewQuotes([
                    "First source quote.",
                    "Second source quote.",
                    "Third source quote."
                ]),
                against: "First source quote. Second source quote. Third source quote."
            )
        }
    }

    private static func testRejectsOverviewWithDuplicateEvidenceQuotes() throws {
        try expectFailure(.overviewEvidenceQuoteDuplicate) {
            try MeetingSummaryOutputValidator().validate(
                v2WithOverviewQuotes([
                    "First source quote.",
                    " First source quote. "
                ]),
                against: "First source quote."
            )
        }
    }

    private static func testAcceptsOverviewWithTwoDistinctEvidenceQuotes() throws {
        try MeetingSummaryOutputValidator().validate(
            v2WithOverviewQuotes([
                "First source quote.",
                "Second source quote."
            ]),
            against: "First source quote. Second source quote."
        )
    }

    private static func testRejectsGeneratedPartialProseAsMergeEvidence() throws {
        let partial = v2WithQuote(
            "The team will ship Friday.",
            overview: "The launch is cancelled."
        )
        try expectFailure(.sourceQuoteNotFound) {
            try MeetingSummaryOutputValidator().validate(
                v2WithQuote(
                    "The launch is cancelled.",
                    overview: "The release status changed."
                ),
                againstValidatedRecords: [partial]
            )
        }
    }

    private static func testRejectsActionOwnerOutsideSourceQuote() throws {
        try expectFailure(.ownerNotGrounded) {
            try MeetingSummaryOutputValidator().validate(
                v2WithOwner("Jiyun", quote: "Minsu will send it"),
                against: "Minsu will send it"
            )
        }
    }

    private static func testAcceptsKoreanDateGroundingForISODueDate() throws {
        let quote = "민수는 2026년 8월 15일까지 배포합니다."
        try MeetingSummaryOutputValidator().validate(
            v2WithDueDate("2026-08-15", quote: quote),
            against: quote
        )
    }

    private static func testEvidenceRepairPreservesLocalizedDateGroundedISODueDate() throws {
        let sourceQuote = "민수는 2026년 8월 15일까지 배포합니다."
        let repaired = MeetingSummaryEvidenceRepairer().repair(
            v2WithDueDate("2026-08-15", quote: sourceQuote),
            sourceTexts: [sourceQuote]
        )

        precondition(repaired.verification == .verified)
        precondition(repaired.draft.actionItems[0].dueDate == "2026-08-15")
        try MeetingSummaryOutputValidator().validate(repaired.draft, against: sourceQuote)
    }

    private static func testAcceptsJapaneseDateGroundingForISODueDate() throws {
        let quote = "田中さんは2026年8月15日までに提出します。"
        try MeetingSummaryOutputValidator().validate(
            v2WithDueDate("2026-08-15", quote: quote),
            against: quote
        )
    }

    private static func testRejectsYearlessLocalizedDateForISODueDate() throws {
        let quote = "민수는 8월 15일까지 배포합니다."
        try expectFailure(.dueDateNotGrounded) {
            try MeetingSummaryOutputValidator().validate(
                v2WithDueDate("2026-08-15", quote: quote),
                against: quote
            )
        }
    }

    private static func testRejectsWrongLanguageInGeneratedProse() throws {
        try expectFailure(.languageMismatch) {
            try MeetingSummaryOutputValidator().validate(
                v2WithQuote(
                    "회의에서 다음 주 화요일에 출시하기로 결정했습니다.",
                    overview: "会议决定下周二发布产品，负责人将在今天完成说明文档。"
                ),
                outputLanguage: "Korean",
                against: "회의에서 다음 주 화요일에 출시하기로 결정했습니다."
            )
        }
    }

    private static func testPreservesSourceQuoteLanguageWhileValidatingGeneratedProse() throws {
        let sourceQuote = "The release will ship next Tuesday."
        try MeetingSummaryOutputValidator().validate(
            v2WithQuote(sourceQuote, overview: "출시는 다음 주 화요일로 정했습니다."),
            outputLanguage: "Korean",
            against: sourceQuote
        )
    }

    private static func testSameAsSpokenLanguageRejectsEnglishSummaryForKorean() throws {
        let language = MeetingSummaryLanguageContext(
            requestedOutputLanguage: "",
            appliedLanguageCode: "ko",
            resolutionSource: .engineDetected
        )
        let draft = v2WithQuote(
            "회의에서 다음 주 화요일에 출시하기로 결정했습니다.",
            overview: "The team decided to release next Tuesday."
        )

        try expectFailure(.languageMismatch) {
            try MeetingSummaryOutputValidator().validate(
                draft,
                outputLanguage: language.appliedLanguageCode,
                against: "회의에서 다음 주 화요일에 출시하기로 결정했습니다."
            )
        }
    }

    private static func testTraditionalChineseIsAcceptedForTraditionalAndGenericChinese() throws {
        let quote = "團隊決定下週二發布產品，並在今天完成說明文件。"
        let draft = v2WithQuote(
            quote,
            overview: "團隊決定下週二發布產品。"
        )

        try MeetingSummaryOutputValidator().validate(
            draft,
            outputLanguage: "zh-Hant",
            against: quote
        )
        try MeetingSummaryOutputValidator().validate(
            draft,
            outputLanguage: "zh",
            against: quote
        )
    }

    private static func testTraditionalChineseIsRejectedForSimplifiedChinese() throws {
        let quote = "團隊決定下週二發布產品，並在今天完成說明文件。"
        try expectFailure(.languageMismatch) {
            try MeetingSummaryOutputValidator().validate(
                v2WithQuote(
                    quote,
                    overview: "團隊決定下週二發布產品。"
                ),
                outputLanguage: "zh-Hans",
                against: quote
            )
        }
    }

    private static func testEvidenceRepairReplacesWhitespaceAndPunctuationVariantWithSourceSubstring() {
        let sourceQuote = "Minsu will send the release notes\non Friday."
        let repaired = MeetingSummaryEvidenceRepairer().repair(
            v2WithQuote("“Minsu will send the release notes on Friday”"),
            sourceTexts: [sourceQuote]
        )

        precondition(repaired.verification == .verified)
        precondition(repaired.draft.overview.sourceQuotes == [sourceQuote])
    }

    private static func testEvidenceRepairMapsLowercaseExpansionToOriginalSourceSubstring() {
        let sourceQuote = "İstanbul will send the release notes."
        let repaired = MeetingSummaryEvidenceRepairer().repair(
            v2WithQuote("istanbul will send the release notes"),
            sourceTexts: [sourceQuote]
        )

        precondition(repaired.verification == .verified)
        precondition(repaired.draft.overview.sourceQuotes == [sourceQuote])
    }

    private static func testEvidenceRepairMarksUnresolvedCitationUnverified() {
        let repaired = MeetingSummaryEvidenceRepairer().repair(
            v2WithQuote("Invented source quote."),
            sourceTexts: ["Minsu will send the release notes."]
        )

        precondition(repaired.verification == .unverified)
        precondition(
            repaired.draft.overview.sourceQuotes == ["Invented source quote."],
            "unresolved summary evidence remains visible but is marked unverified"
        )
    }

    private static func testEvidenceRepairSanitizesUngroundedActionMetadata() {
        let sourceQuote = "Minsu will send the release notes on Friday."
        let repaired = MeetingSummaryEvidenceRepairer().repair(
            v2WithOwner("Jiyun", quote: sourceQuote),
            sourceTexts: [sourceQuote]
        )

        precondition(repaired.verification == .unverified)
        precondition(repaired.draft.actionItems[0].owner == nil)
        precondition(repaired.draft.actionItems[0].dueDate == nil)
    }

    private static func v2WithQuote(
        _ quote: String,
        overview: String = "The team reviewed the release schedule."
    ) -> MeetingSummaryDraftContentV2 {
        MeetingSummaryDraftContentV2(
            overview: MeetingSummaryEvidenceText(
                text: overview,
                sourceQuotes: [quote]
            ),
            keyPoints: [],
            decisions: [],
            actionItems: [],
            openQuestions: []
        )
    }

    private static func v2WithOverviewQuotes(
        _ quotes: [String]
    ) -> MeetingSummaryDraftContentV2 {
        MeetingSummaryDraftContentV2(
            overview: MeetingSummaryEvidenceText(
                text: "The team reviewed the release schedule.",
                sourceQuotes: quotes
            ),
            keyPoints: [],
            decisions: [],
            actionItems: [],
            openQuestions: []
        )
    }

    private static func v2WithOwner(
        _ owner: String,
        quote: String
    ) -> MeetingSummaryDraftContentV2 {
        MeetingSummaryDraftContentV2(
            overview: MeetingSummaryEvidenceText(
                text: "The team assigned the delivery task.",
                sourceQuotes: [quote]
            ),
            keyPoints: [],
            decisions: [],
            actionItems: [
                MeetingSummaryActionItem(
                    id: UUID(),
                    task: "Send it",
                    owner: owner,
                    dueDate: nil,
                    sourceQuote: quote,
                    isCompleted: false
                )
            ],
            openQuestions: []
        )
    }

    private static func v2WithDueDate(
        _ dueDate: String,
        quote: String
    ) -> MeetingSummaryDraftContentV2 {
        MeetingSummaryDraftContentV2(
            overview: MeetingSummaryEvidenceText(
                text: "The team assigned the delivery task.",
                sourceQuotes: [quote]
            ),
            keyPoints: [],
            decisions: [],
            actionItems: [
                MeetingSummaryActionItem(
                    id: UUID(),
                    task: "Send it",
                    owner: nil,
                    dueDate: dueDate,
                    sourceQuote: quote,
                    isCompleted: false
                )
            ],
            openQuestions: []
        )
    }

    private static func expectFailure(
        _ expected: MeetingSummaryOutputValidationError,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
        } catch let error as MeetingSummaryOutputValidationError {
            guard error == expected else {
                throw MeetingSummaryOutputValidatorTestFailure(
                    "Expected \(expected), got \(error)"
                )
            }
            return
        }
        throw MeetingSummaryOutputValidatorTestFailure("Expected \(expected)")
    }
}

private struct MeetingSummaryOutputValidatorTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
