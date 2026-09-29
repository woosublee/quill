import Foundation

@main
struct PipelineHistoryMeetingSummaryTests {
    static func main() throws {
        try testLegacyItemDecodesMissingSummaryAsNil()
        try testSummaryRoundTripsThroughCodable()
        try testSummaryPersistsEvidenceBearingV2()
        try testUnverifiedSummaryRoundTripsThroughCoreDataStore()
        try testSummaryRoundTripsThroughCoreDataStore()
        try testSpokenLanguageAndSummaryAttemptRoundTrip()
        testUnavailableSpokenLanguageNeverRetainsCode()
        testItemCopyHelpersPreserveSummary()
        testMeetingSummaryAttemptCopyHelperPreservesSummary()
        testNoteSearchMatchesTitleAndTranscript()
        testNoteSearchMatchesSummaryOnlyText()
        testNoteSearchIgnoresRawTranscriptOnlyText()
        testNoteSearchMatchesKoreanAndDiacritics()
        testNoteSearchRefreshesCachedSummaryText()
        print("PipelineHistoryMeetingSummaryTests passed")
    }

    private static func testLegacyItemDecodesMissingSummaryAsNil() throws {
        let data = try JSONEncoder().encode(makeItem())
        let decoded = try JSONDecoder().decode(
            PipelineHistoryItem.self,
            from: data
        )

        precondition(decoded.meetingSummaryJSON == nil)
        precondition(decoded.meetingSummary == nil)
    }

    private static func testSummaryRoundTripsThroughCodable() throws {
        let item = makeItem().withMeetingSummary(.fixture(actions: []))
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(
            PipelineHistoryItem.self,
            from: data
        )

        precondition(decoded.meetingSummary == item.meetingSummary)
    }

    private static func testSummaryPersistsEvidenceBearingV2() throws {
        let item = makeItem().withMeetingSummary(.fixture(actions: []))
        let summaryJSON = try unwrap(item.meetingSummaryJSON)
        let root = try JSONSerialization.jsonObject(with: summaryJSON) as? [String: Any]
        let content = root?["content"] as? [String: Any]
        let overview = content?["overview"] as? [String: Any]

        precondition(root?["schemaVersion"] as? Int == 4)
        precondition(overview?["text"] as? String == "Release review")
        precondition(overview?["sourceQuotes"] as? [String] == ["Decision: ship Friday."])
    }

    private static func testUnverifiedSummaryRoundTripsThroughCoreDataStore() throws {
        let store = PipelineHistoryStore(inMemory: true)
        let unverified = MeetingSummaryEnvelope(
            schemaVersion: MeetingSummaryEnvelope.currentSchemaVersion,
            promptVersion: 3,
            generatedAt: Date(timeIntervalSince1970: 1_000),
            sourceFingerprint: "f",
            modelID: "summary/model",
            backendKind: .local,
            evidenceVerification: .unverified,
            content: MeetingSummaryContent(
                overview: MeetingSummaryEvidenceText(
                    text: "Release review",
                    sourceQuotes: ["Invented citation."]
                ),
                keyPoints: [],
                decisions: [],
                actionItems: [],
                openQuestions: []
            )
        )
        _ = try store.append(
            makeItem().withMeetingSummary(unverified),
            maxCount: 10
        )
        let loaded = try unwrap(store.loadAllHistory().first)

        precondition(loaded.meetingSummary?.effectiveEvidenceVerification == .unverified)
    }

    private static func testSummaryRoundTripsThroughCoreDataStore() throws {
        let store = PipelineHistoryStore(inMemory: true)
        let item = makeItem().withMeetingSummary(.fixture(actions: []))
        _ = try store.append(item, maxCount: 10)
        let loaded = try unwrap(store.loadAllHistory().first)

        precondition(loaded.meetingSummary == item.meetingSummary)
    }

    private static func testSpokenLanguageAndSummaryAttemptRoundTrip() throws {
        let attempt = MeetingSummaryAttempt(
            occurredAt: Date(timeIntervalSince1970: 2_100),
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
                code: .meetingSummaryInvalidResponse,
                context: QuillUserIssueContext(
                    meetingSummaryFailureSubtype: .contextBudget
                )
            ),
            sourceFingerprint: String(repeating: "a", count: 64)
        )
        let item = makeItem(
            spokenLanguageCode: "ko",
            spokenLanguageResolution: .engineDetected,
            meetingSummaryAttempt: attempt
        )
        let store = PipelineHistoryStore(inMemory: true)

        _ = try store.append(item, maxCount: 10)
        let loaded = try unwrap(store.loadAllHistory().first)

        precondition(loaded.spokenLanguage == item.spokenLanguage)
        precondition(loaded.meetingSummaryAttempt == attempt)
    }

    private static func testUnavailableSpokenLanguageNeverRetainsCode() {
        let item = makeItem(
            spokenLanguageCode: "en",
            spokenLanguageResolution: .unavailable
        )

        precondition(
            item.spokenLanguage == SpokenLanguageResolution(
                languageCode: nil,
                source: .unavailable
            ),
            "an unavailable result cannot revive an older spoken language code"
        )
    }

    private static func testItemCopyHelpersPreserveSummary() {
        let item = makeItem().withMeetingSummary(
            .fixture(
                actions: [
                    MeetingSummaryActionItem(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
                        task: "Write release notes",
                        owner: "Ada",
                        dueDate: nil,
                        sourceQuote: nil,
                        isCompleted: true
                    )
                ]
            )
        )

        precondition(
            item.withCustomTitle("Release review").meetingSummary
                == item.meetingSummary
        )
        precondition(
            item.markInterruptedBeforeCompletion().meetingSummary
                == item.meetingSummary
        )
    }

    private static func testMeetingSummaryAttemptCopyHelperPreservesSummary() {
        let summary = MeetingSummaryEnvelope.fixture(actions: [])
        let attempt = MeetingSummaryAttempt(
            occurredAt: Date(timeIntervalSince1970: 2_100),
            outcome: .succeeded,
            backendKind: .local,
            modelID: "summary/model",
            providerHost: nil,
            language: nil,
            issue: nil
        )
        let item = makeItem()
            .withMeetingSummary(summary)
            .withMeetingSummaryAttempt(attempt)

        precondition(item.meetingSummary == summary)
        precondition(item.meetingSummaryAttempt == attempt)
    }

    private static func testNoteSearchMatchesTitleAndTranscript() {
        let matcher = NoteSearchMatcher()
        let item = makeSearchItem(
            title: "Quarterly Planning",
            processed: "We reviewed the roadmap."
        )

        precondition(matcher.matches(item, query: "quarterly"))
        precondition(matcher.matches(item, query: "ROADMAP"))
        precondition(!matcher.matches(item, query: "budget"))
        precondition(matcher.matches(item, query: ""))
    }

    private static func testNoteSearchMatchesSummaryOnlyText() {
        let matcher = NoteSearchMatcher()
        let item = makeSearchItem(processed: "Short note.")
            .withMeetingSummary(.searchFixture(
                overview: "Vendor comparison",
                keyPoint: "Latency improved",
                decision: "Adopt plan B",
                action: "Draft contract",
                owner: "Mina",
                question: "Who signs off?"
            ))

        for query in ["vendor", "latency", "plan b", "draft contract", "mina", "signs off"] {
            precondition(matcher.matches(item, query: query), "summary matches \(query)")
        }
        precondition(!matcher.matches(item, query: "pricing"))
    }

    private static func testNoteSearchIgnoresRawTranscriptOnlyText() {
        let matcher = NoteSearchMatcher()
        let item = makeSearchItem(
            raw: "uh the secretword was mentioned",
            processed: "Cleaned text only."
        )

        precondition(!matcher.matches(item, query: "secretword"))
    }

    private static func testNoteSearchMatchesKoreanAndDiacritics() {
        let matcher = NoteSearchMatcher()
        let item = makeSearchItem(title: "주간 회의", processed: "Café menu")
            .withMeetingSummary(.searchFixture(
                overview: "출시 일정 검토",
                keyPoint: "디자인 확정",
                decision: "",
                action: "",
                owner: nil,
                question: ""
            ))

        precondition(matcher.matches(item, query: "회의"))
        precondition(matcher.matches(item, query: "출시 일정"))
        precondition(matcher.matches(item, query: "디자인"))
        precondition(matcher.matches(item, query: "cafe"))
        precondition(!matcher.matches(item, query: "예산"))
    }

    private static func testNoteSearchRefreshesCachedSummaryText() {
        let matcher = NoteSearchMatcher()
        let base = makeSearchItem(processed: "Short note.")
        let first = base.withMeetingSummary(.searchFixture(
            overview: "Alpha topic", keyPoint: "", decision: "",
            action: "", owner: nil, question: ""
        ))
        precondition(matcher.matches(first, query: "alpha"))

        let updated = base.withMeetingSummary(.searchFixture(
            overview: "Beta topic", keyPoint: "", decision: "",
            action: "", owner: nil, question: ""
        ))
        precondition(!matcher.matches(updated, query: "alpha"))
        precondition(matcher.matches(updated, query: "beta"))
        precondition(!matcher.matches(base, query: "beta"))

        // A deleted note's summary text doesn't linger in the cache, and
        // clearing search drops everything.
        precondition(matcher.matches(updated, query: "beta"))
        precondition(matcher.cachedNoteCount == 1)
        matcher.retainCache(for: [])
        precondition(matcher.cachedNoteCount == 0)
        precondition(matcher.matches(updated, query: "beta"))
        matcher.retainCache(for: [updated.id])
        precondition(matcher.cachedNoteCount == 1)
        matcher.clearCache()
        precondition(matcher.cachedNoteCount == 0)
    }

    private static func makeSearchItem(
        title: String? = nil,
        raw: String = "",
        processed: String
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!,
            timestamp: Date(timeIntervalSince1970: 1_000),
            rawTranscript: raw,
            postProcessedTranscript: processed,
            postProcessingPrompt: nil,
            contextSummary: "Synthetic context",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "Post-processing succeeded",
            debugStatus: "Done",
            customVocabulary: "",
            customTitle: title
        )
    }

    private static func makeItem(
        spokenLanguageCode: String? = nil,
        spokenLanguageResolution: SpokenLanguageResolutionSource? = nil,
        meetingSummaryAttempt: MeetingSummaryAttempt? = nil
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
            timestamp: Date(timeIntervalSince1970: 1_000),
            rawTranscript: "Decision: ship Friday.",
            postProcessedTranscript: "Decision: ship Friday.",
            postProcessingPrompt: nil,
            contextSummary: "Unrelated context",
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "Post-processing succeeded",
            debugStatus: "Done",
            customVocabulary: "",
            spokenLanguageCode: spokenLanguageCode,
            spokenLanguageResolution: spokenLanguageResolution,
            meetingSummaryAttempt: meetingSummaryAttempt
        )
    }

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw TestError.missingValue }
        return value
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
            sourceFingerprint: String(repeating: "b", count: 64),
            modelID: "test/model",
            backendKind: .cloud,
            content: MeetingSummaryContent(
                overview: MeetingSummaryEvidenceText(
                    text: "Release review",
                    sourceQuotes: ["Decision: ship Friday."]
                ),
                keyPoints: [],
                decisions: [],
                actionItems: actions,
                openQuestions: []
            )
        )
    }
    static func searchFixture(
        overview: String,
        keyPoint: String,
        decision: String,
        action: String,
        owner: String?,
        question: String
    ) -> MeetingSummaryEnvelope {
        func points(_ text: String) -> [MeetingSummaryPoint] {
            text.isEmpty ? [] : [MeetingSummaryPoint(id: UUID(), text: text, sourceQuote: nil)]
        }
        let actions = action.isEmpty ? [] : [
            MeetingSummaryActionItem(
                id: UUID(),
                task: action,
                owner: owner,
                dueDate: nil,
                sourceQuote: nil,
                isCompleted: false
            )
        ]
        return MeetingSummaryEnvelope(
            schemaVersion: MeetingSummaryEnvelope.currentSchemaVersion,
            promptVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 2_000),
            sourceFingerprint: String(repeating: "c", count: 64),
            modelID: "test/model",
            backendKind: .cloud,
            content: MeetingSummaryContent(
                overview: MeetingSummaryEvidenceText(text: overview, sourceQuotes: []),
                keyPoints: points(keyPoint),
                decisions: points(decision),
                actionItems: actions,
                openQuestions: points(question)
            )
        )
    }
}

private enum TestError: Error {
    case missingValue
}
