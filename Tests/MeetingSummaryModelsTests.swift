import Foundation
import QuillUserIssueCore
import QuillSummaryFormatCore
import QuillSummaryGenerationCore

@main
struct MeetingSummaryModelsTests {
    private static let languageContext = MeetingSummaryLanguageContext(
        requestedOutputLanguage: "English",
        appliedLanguageCode: "en",
        resolutionSource: .configured
    )

    static func main() throws {
        testFingerprintIsDeterministicAndChangesWithTranscript()
        testFingerprintIncludesCalendarMetadata()
        testFingerprintBytesStayFixed()
        try testLegacyV1EnvelopeDecodesDisplayOnlyEvidence()
        try testLegacySummaryDecodesWithoutLanguageContext()
        try testLegacyAttemptDecodesWithoutSourceFingerprint()
        try testAttemptIsBoundToItsSourceFingerprint()
        try testLanguageContextRoundTrips()
        try testFailedAttemptPresentationIncludesLocalizedLanguageDetails()
        try testFailedAttemptPresentationPlacesFailureReasonBeforeLanguage()
        try testLegacySummaryDefaultsToVerifiedEvidence()
        try testUnverifiedEvidenceRoundTrips()
        testNewSummariesUseSchemaVersion4()
        testCompletionStateSurvivesEquivalentRegeneration()
        testMarkdownRendererIncludesAllSections()
        testContentRendererMatchesEnvelopeRenderer()
        try testStoredBytesStayFixed()
        testSourceLocatorFindsExactQuote()
        testSourceLocatorDoesNotInventFuzzyRange()
        print("MeetingSummaryModelsTests passed")
    }

    private static func testFingerprintIsDeterministicAndChangesWithTranscript() {
        let source = MeetingSummarySource(
            transcript: "Decision: ship Friday.",
            calendar: nil,
            languageContext: languageContext
        )
        let same = MeetingSummarySource(
            transcript: "Decision: ship Friday.\n",
            calendar: nil,
            languageContext: languageContext
        )
        let changed = MeetingSummarySource(
            transcript: "Decision: ship Monday.",
            calendar: nil,
            languageContext: languageContext
        )

        precondition(source.fingerprint == same.fingerprint)
        precondition(source.fingerprint != changed.fingerprint)
        precondition(source.fingerprint.count == 64)
    }

    private static func testFingerprintIncludesCalendarMetadata() {
        let start = Date(timeIntervalSince1970: 1_000)
        let calendar = MeetingSummaryCalendarContext(
            title: "Design Review",
            start: start,
            end: start.addingTimeInterval(1_800),
            attendees: ["Ada", "Lin"]
        )
        let withoutCalendar = MeetingSummarySource(
            transcript: "Discuss launch.",
            calendar: nil,
            languageContext: languageContext
        )
        let withCalendar = MeetingSummarySource(
            transcript: "Discuss launch.",
            calendar: calendar,
            languageContext: languageContext
        )

        precondition(withoutCalendar.fingerprint != withCalendar.fingerprint)
    }

    // The fingerprint is stored and synced, so its bytes must not change.
    // These values were computed from the canonical text with an independent
    // SHA-256.
    private static func testFingerprintBytesStayFixed() {
        let transcript = "We reviewed the release plan.\r\nLaunch stays on schedule.\n"
        let withCalendar = MeetingSummarySource(
            transcript: transcript,
            calendar: MeetingSummaryCalendarContext(
                title: "Synthetic Release Sync",
                start: Date(timeIntervalSince1970: 1_800_000_000),
                end: Date(timeIntervalSince1970: 1_800_001_800),
                attendees: ["Mina", "Jun"]
            ),
            languageContext: languageContext
        )
        precondition(withCalendar.fingerprint == "ffb3b8c160b335196e4cacdd369d760022d7c23d8d50a6c8e847588dc60a60f8")
        precondition(
            withCalendar.withoutCalendar.fingerprint
                == "7cf42ab9951b32bc9d76745daa87249eb8a1ad22554f4107231cb993bc94888a"
        )

        // Sub-second times are rounded to milliseconds, as ISO8601DateFormatter
        // does with fractional seconds: .9996 becomes the next whole second.
        let fractional = MeetingSummarySource(
            transcript: transcript,
            calendar: MeetingSummaryCalendarContext(
                title: "Synthetic Release Sync",
                start: Date(timeIntervalSince1970: 1_800_000_000.9996),
                end: Date(timeIntervalSince1970: 1_800_001_800.123456),
                attendees: ["Mina", "Jun"]
            ),
            languageContext: languageContext
        )
        precondition(fractional.fingerprint == "08b2349465d69c84ca548db176b406fa9052dad556f2776433da2affd6891e15")
    }

    private static func testLegacyV1EnvelopeDecodesDisplayOnlyEvidence() throws {
        let legacyOverview = "The team reviewed the release."
        let legacyJSON = #"{"schemaVersion":1,"promptVersion":1,"generatedAt":0,"sourceFingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","modelID":"legacy/model","backendKind":"cloud","content":{"overview":"The team reviewed the release.","keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[]}}"#

        let decoded = try JSONDecoder().decode(
            MeetingSummaryEnvelope.self,
            from: Data(legacyJSON.utf8)
        )

        precondition(
            decoded.content.overview.text == legacyOverview,
            "legacy saved summaries remain readable as display-only evidence"
        )
        precondition(
            decoded.content.overview.sourceQuotes.isEmpty,
            "legacy overview does not invent source evidence"
        )
    }

    private static func testLegacySummaryDecodesWithoutLanguageContext() throws {
        let legacyJSON = Data(#"{"schemaVersion":2,"promptVersion":2,"generatedAt":0,"sourceFingerprint":"f","modelID":"m","backendKind":"local","content":{"overview":{"text":"text","sourceQuotes":["quote"]},"keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[]}}"#.utf8)

        let decoded = try JSONDecoder().decode(MeetingSummaryEnvelope.self, from: legacyJSON)

        precondition(decoded.languageContext == nil)
    }

    private static func testLegacyAttemptDecodesWithoutSourceFingerprint() throws {
        let legacyJSON = Data(#"{"occurredAt":0,"outcome":"failed","backendKind":"cloud","modelID":"summary/model","language":null,"issue":null}"#.utf8)

        let decoded = try JSONDecoder().decode(
            MeetingSummaryAttempt.self,
            from: legacyJSON
        )

        precondition(
            decoded.sourceFingerprint == nil,
            "attempts persisted before provenance remain readable but are not current"
        )
    }

    private static func testAttemptIsBoundToItsSourceFingerprint() throws {
        let source = MeetingSummarySource(
            transcript: "Decision: ship Friday.",
            calendar: nil,
            languageContext: languageContext
        )
        let attempt = MeetingSummaryAttempt(
            occurredAt: Date(timeIntervalSince1970: 2_100),
            outcome: .failed,
            backendKind: .cloud,
            modelID: "summary/model",
            providerHost: "api.example.com",
            language: languageContext,
            issue: QuillUserIssueRecord(code: .meetingSummaryUnavailable),
            sourceFingerprint: source.fingerprint
        )
        let encoded = try JSONEncoder().encode(attempt)
        let payload = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]

        precondition(
            payload?["sourceFingerprint"] as? String == source.fingerprint,
            "a provider attempt persists only the safe fingerprint of its submitted source"
        )
        precondition(attempt.isCurrent(for: source))
        precondition(
            !attempt.isCurrent(for: MeetingSummarySource(
                transcript: "Decision: ship Monday.",
                calendar: nil,
                languageContext: languageContext
            )),
            "a diagnostic from source A is not current for source B"
        )
    }

    private static func testLanguageContextRoundTrips() throws {
        let expected = MeetingSummaryLanguageContext(
            requestedOutputLanguage: "",
            appliedLanguageCode: "ko",
            resolutionSource: .engineDetected
        )
        let envelope = MeetingSummaryEnvelope(
            schemaVersion: MeetingSummaryEnvelope.currentSchemaVersion,
            promptVersion: 3,
            generatedAt: Date(timeIntervalSince1970: 1_000),
            sourceFingerprint: "f",
            modelID: "m",
            backendKind: .local,
            languageContext: expected,
            content: MeetingSummaryContent(
                overview: MeetingSummaryEvidenceText(text: "text", sourceQuotes: []),
                keyPoints: [],
                decisions: [],
                actionItems: [],
                openQuestions: []
            )
        )

        let decoded = try JSONDecoder().decode(
            MeetingSummaryEnvelope.self,
            from: JSONEncoder().encode(envelope)
        )

        precondition(decoded.languageContext == expected)
    }

    private static func testFailedAttemptPresentationIncludesLocalizedLanguageDetails() throws {
        let bundleURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/localization")
        guard let bundle = Bundle(path: bundleURL.path) else {
            throw MeetingSummaryModelsTestFailure("Missing localization bundle")
        }
        let attempt = MeetingSummaryAttempt(
            occurredAt: Date(timeIntervalSince1970: 2_000),
            outcome: .failed,
            backendKind: .cloud,
            modelID: "summary/model",
            providerHost: "api.example.com",
            language: MeetingSummaryLanguageContext(
                requestedOutputLanguage: "",
                appliedLanguageCode: "ko",
                resolutionSource: .engineDetected
            ),
            issue: QuillUserIssueRecord(
                code: .meetingSummaryUnavailable,
                context: QuillUserIssueContext(
                    httpStatus: 429,
                    providerHost: "api.example.com",
                    providerCode: "rate_limit_exceeded",
                    modelID: "summary/model"
                )
            )
        )

        guard let english = attempt.issuePresentation(language: "en", bundle: bundle),
              let korean = attempt.issuePresentation(language: "ko", bundle: bundle) else {
            throw MeetingSummaryModelsTestFailure("Failed attempt requires a presentation")
        }
        precondition(english.detailsRows == [
            QuillUserIssueDetailsRow(label: "HTTP status", value: "429"),
            QuillUserIssueDetailsRow(label: "Provider", value: "api.example.com"),
            QuillUserIssueDetailsRow(label: "Provider code", value: "rate_limit_exceeded"),
            QuillUserIssueDetailsRow(label: "Model", value: "summary/model"),
            QuillUserIssueDetailsRow(label: "Summary language", value: "Korean (ko)"),
            QuillUserIssueDetailsRow(label: "Language source", value: "Detected by transcription engine")
        ])
        precondition(korean.detailsRows == [
            QuillUserIssueDetailsRow(label: "HTTP 상태", value: "429"),
            QuillUserIssueDetailsRow(label: "제공자", value: "api.example.com"),
            QuillUserIssueDetailsRow(label: "제공자 코드", value: "rate_limit_exceeded"),
            QuillUserIssueDetailsRow(label: "모델", value: "summary/model"),
            QuillUserIssueDetailsRow(label: "요약 언어", value: "한국어 (ko)"),
            QuillUserIssueDetailsRow(label: "언어 확인 방법", value: "전사 엔진 감지")
        ])
    }

    private static func testFailedAttemptPresentationPlacesFailureReasonBeforeLanguage() throws {
        let bundleURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/localization")
        guard let bundle = Bundle(path: bundleURL.path) else {
            throw MeetingSummaryModelsTestFailure("Missing localization bundle")
        }
        let attempt = MeetingSummaryAttempt(
            occurredAt: Date(timeIntervalSince1970: 2_000),
            outcome: .failed,
            backendKind: .local,
            modelID: "qwen2.5-7b-instruct",
            providerHost: nil,
            language: MeetingSummaryLanguageContext(
                requestedOutputLanguage: "",
                appliedLanguageCode: "ko",
                resolutionSource: .engineDetected
            ),
            issue: QuillUserIssueRecord(
                code: .meetingSummaryInvalidResponse,
                context: QuillUserIssueContext(
                    modelID: "qwen2.5-7b-instruct",
                    localBackend: "Local AI",
                    meetingSummaryFailureSubtype: .jsonSchema
                )
            )
        )

        guard let presentation = attempt.issuePresentation(language: "en", bundle: bundle) else {
            throw MeetingSummaryModelsTestFailure("Missing summary failure presentation")
        }
        precondition(presentation.detailsRows == [
            QuillUserIssueDetailsRow(label: "Model", value: "qwen2.5-7b-instruct"),
            QuillUserIssueDetailsRow(label: "Failure reason", value: "Summary format"),
            QuillUserIssueDetailsRow(label: "Local backend", value: "Local AI"),
            QuillUserIssueDetailsRow(label: "Summary language", value: "Korean (ko)"),
            QuillUserIssueDetailsRow(label: "Language source", value: "Detected by transcription engine")
        ])
    }

    private static func testLegacySummaryDefaultsToVerifiedEvidence() throws {
        let legacyJSON = Data(#"{"schemaVersion":3,"promptVersion":3,"generatedAt":0,"sourceFingerprint":"f","modelID":"m","backendKind":"local","content":{"overview":{"text":"text","sourceQuotes":["quote"]},"keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[]}}"#.utf8)
        let decoded = try JSONDecoder().decode(MeetingSummaryEnvelope.self, from: legacyJSON)

        precondition(decoded.evidenceVerification == nil)
        precondition(decoded.effectiveEvidenceVerification == .verified)
    }

    private static func testUnverifiedEvidenceRoundTrips() throws {
        let envelope = MeetingSummaryEnvelope(
            schemaVersion: MeetingSummaryEnvelope.currentSchemaVersion,
            promptVersion: 3,
            generatedAt: Date(timeIntervalSince1970: 1_000),
            sourceFingerprint: "f",
            modelID: "m",
            backendKind: .local,
            evidenceVerification: .unverified,
            content: MeetingSummaryContent(
                overview: MeetingSummaryEvidenceText(text: "text", sourceQuotes: ["quote"]),
                keyPoints: [],
                decisions: [],
                actionItems: [],
                openQuestions: []
            )
        )
        let decoded = try JSONDecoder().decode(
            MeetingSummaryEnvelope.self,
            from: JSONEncoder().encode(envelope)
        )

        precondition(decoded.evidenceVerification == .unverified)
        precondition(decoded.effectiveEvidenceVerification == .unverified)
    }

    private static func testNewSummariesUseSchemaVersion4() {
        precondition(
            MeetingSummaryEnvelope.currentSchemaVersion == 4,
            "new summaries persist evidence-aware schema v4"
        )
    }

    private static func testCompletionStateSurvivesEquivalentRegeneration() {
        let old = MeetingSummaryEnvelope.fixture(
            actions: [
                MeetingSummaryActionItem(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    task: "Write release notes",
                    owner: "Ada",
                    dueDate: "2026-07-31",
                    sourceQuote: "Ada will write release notes by July 31.",
                    isCompleted: true
                )
            ]
        )
        let regenerated = MeetingSummaryEnvelope.fixture(
            actions: [
                MeetingSummaryActionItem(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                    task: " write release notes ",
                    owner: "ADA",
                    dueDate: " 2026-07-31 ",
                    sourceQuote: "Ada will write release notes by July 31.",
                    isCompleted: false
                )
            ]
        )

        let preserved = regenerated.preservingCompletion(from: old)

        precondition(preserved.content.actionItems[0].isCompleted)
        precondition(
            preserved.content.actionItems[0].id
                == old.content.actionItems[0].id
        )
    }

    private static func testSourceLocatorFindsExactQuote() {
        let transcript = "First paragraph.\nDecision: ship Friday.\nLast paragraph."
        let range = MeetingSummarySourceLocator.range(
            of: "Decision: ship Friday.",
            in: transcript
        )

        precondition(range != nil)
        precondition(String(transcript[range!]) == "Decision: ship Friday.")
    }

    private static func testSourceLocatorDoesNotInventFuzzyRange() {
        let range = MeetingSummarySourceLocator.range(
            of: "Ship on Thursday",
            in: "Decision: ship Friday."
        )

        precondition(range == nil)
    }

    private static func testMarkdownRendererIncludesAllSections() {
        let rendered = MeetingSummaryMarkdownRenderer.render(
            .fixture(actions: [])
        )

        precondition(rendered.contains("## Overview"))
        precondition(rendered.contains("## Key Points"))
        precondition(rendered.contains("## Decisions"))
        precondition(rendered.contains("## Action Items"))
        precondition(rendered.contains("## Open Questions"))
    }

    private static func testContentRendererMatchesEnvelopeRenderer() {
        let envelope = MeetingSummaryEnvelope.fixture(actions: [
            MeetingSummaryActionItem(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
                task: "Send the notes.",
                owner: "Ada",
                dueDate: "Friday",
                sourceQuote: nil,
                isCompleted: true
            )
        ])

        precondition(
            MeetingSummaryMarkdownRenderer.render(envelope.content)
                == MeetingSummaryMarkdownRenderer.render(envelope),
            "rendering the content alone matches rendering its envelope"
        )
    }

    // Both apps read these bytes, so a change here breaks the stored format.
    // The expected values were produced by the code before it moved into the
    // shared modules (#634).
    private static func testStoredBytesStayFixed() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let source = MeetingSummarySource(
            transcript: "Decision: ship Friday.",
            calendar: MeetingSummaryCalendarContext(
                title: "Design Review",
                start: start,
                end: start.addingTimeInterval(1_800),
                attendees: ["Ada", "Lin"]
            ),
            languageContext: languageContext
        )
        let fingerprint = "79f21068f816b89f8c7487be72c3b0e4a5c5b598b2dc14106b6f7cc8ccc8eb61"
        precondition(source.fingerprint == fingerprint, "source fingerprint changed")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func encoded<T: Encodable>(_ value: T) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }

        let envelope = MeetingSummaryEnvelope(
            schemaVersion: MeetingSummaryEnvelope.currentSchemaVersion,
            promptVersion: 3,
            generatedAt: Date(timeIntervalSince1970: 2_000),
            sourceFingerprint: fingerprint,
            modelID: "test/model",
            backendKind: .cloud,
            languageContext: languageContext,
            content: MeetingSummaryContent(
                overview: MeetingSummaryEvidenceText(
                    text: "The team reviewed the release.",
                    sourceQuotes: ["The team reviewed the release."]
                ),
                keyPoints: [
                    MeetingSummaryPoint(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
                        text: "The release remains on schedule.",
                        sourceQuote: "The release remains on schedule."
                    )
                ],
                decisions: [],
                actionItems: [
                    MeetingSummaryActionItem(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
                        task: "Send the notes.",
                        owner: "Ada",
                        dueDate: "Friday",
                        sourceQuote: nil,
                        isCompleted: true
                    )
                ],
                openQuestions: []
            )
        )
        let envelopeJSON = try encoded(envelope)
        precondition(
            envelopeJSON == #"{"backendKind":"cloud","content":{"actionItems":[{"dueDate":"Friday","id":"00000000-0000-0000-0000-000000000020","isCompleted":true,"owner":"Ada","task":"Send the notes."}],"decisions":[],"keyPoints":[{"id":"00000000-0000-0000-0000-000000000010","sourceQuote":"The release remains on schedule.","text":"The release remains on schedule."}],"openQuestions":[],"overview":{"sourceQuotes":["The team reviewed the release."],"text":"The team reviewed the release."}},"generatedAt":-978305200,"languageContext":{"appliedLanguageCode":"en","requestedOutputLanguage":"English","resolutionSource":"configured"},"modelID":"test\/model","promptVersion":3,"schemaVersion":4,"sourceFingerprint":"79f21068f816b89f8c7487be72c3b0e4a5c5b598b2dc14106b6f7cc8ccc8eb61"}"#,
            "summary envelope bytes changed"
        )

        let attempt = MeetingSummaryAttempt(
            occurredAt: Date(timeIntervalSince1970: 2_100),
            outcome: .failed,
            backendKind: .local,
            modelID: "summary/model",
            providerHost: "api.example.com",
            language: languageContext,
            issue: QuillUserIssueRecord(
                code: .meetingSummaryInvalidResponse,
                context: QuillUserIssueContext(
                    httpStatus: 502,
                    providerCode: "Rate-Limit",
                    meetingSummaryFailureSubtype: .jsonSchema,
                    operation: .postProcessing
                )
            ),
            sourceFingerprint: fingerprint
        )
        let attemptJSON = try encoded(attempt)
        precondition(
            attemptJSON == #"{"backendKind":"local","issue":{"code":"meeting-summary-invalid-response","context":{"httpStatus":502,"meetingSummaryFailureSubtype":"jsonSchema","operation":"postProcessing"},"schemaVersion":1,"severity":"warning"},"language":{"appliedLanguageCode":"en","requestedOutputLanguage":"English","resolutionSource":"configured"},"modelID":"summary\/model","occurredAt":-978305100,"outcome":"failed","providerHost":"api.example.com","sourceFingerprint":"79f21068f816b89f8c7487be72c3b0e4a5c5b598b2dc14106b6f7cc8ccc8eb61"}"#,
            "summary attempt bytes changed"
        )

        let issueJSON = try encoded(QuillUserIssueRecord(code: .postProcessingFailed))
        precondition(
            issueJSON
                == #"{"code":"post-processing-failed","context":{},"schemaVersion":1,"severity":"warning"}"#,
            "user issue record bytes changed"
        )
    }
}

private struct MeetingSummaryModelsTestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

private extension MeetingSummaryEnvelope {
    static func fixture(
        actions: [MeetingSummaryActionItem]
    ) -> MeetingSummaryEnvelope {
        MeetingSummaryEnvelope(
            schemaVersion: MeetingSummaryEnvelope.currentSchemaVersion,
            promptVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 2_000),
            sourceFingerprint: String(repeating: "a", count: 64),
            modelID: "test/model",
            backendKind: .cloud,
            content: MeetingSummaryContent(
                overview: MeetingSummaryEvidenceText(
                    text: "The team reviewed the release.",
                    sourceQuotes: ["The team reviewed the release."]
                ),
                keyPoints: [
                    MeetingSummaryPoint(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
                        text: "The release remains on schedule.",
                        sourceQuote: "The release remains on schedule."
                    )
                ],
                decisions: [
                    MeetingSummaryPoint(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                        text: "Ship on Friday.",
                        sourceQuote: "Decision: ship Friday."
                    )
                ],
                actionItems: actions,
                openQuestions: [
                    MeetingSummaryPoint(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
                        text: "Who will announce the release?",
                        sourceQuote: nil
                    )
                ]
            )
        )
    }
}
