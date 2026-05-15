import Foundation

@main
struct PipelineHistoryCalendarMetadataTests {
    static func main() throws {
        try testCustomTitleRoundTripsThroughPipelineHistoryItemCodable()
        try testCalendarMetadataRoundTripsThroughPipelineHistoryItemCodable()
        testCalendarMetadataCopyHelpersPreserveFields()
        try testLegacyEncodedHistoryItemDecodesMissingCalendarMetadataAsNil()
        try testCustomTitlePersistsThroughPipelineHistoryStore()
        try testCalendarMetadataPersistsThroughPipelineHistoryStore()
        testStartupTokenLoadPolicyOnlyLoadsForEnabledRemindersWithSelectedCalendars()
        print("PipelineHistoryCalendarMetadataTests passed")
    }

    private static func testStartupTokenLoadPolicyOnlyLoadsForEnabledRemindersWithSelectedCalendars() {
        assert(!GoogleCalendarStartupTokenLoadPolicy.shouldLoadToken(
            remindersEnabled: false,
            selectedCalendarIDs: ["primary"]
        ))
        assert(!GoogleCalendarStartupTokenLoadPolicy.shouldLoadToken(
            remindersEnabled: true,
            selectedCalendarIDs: []
        ))
        assert(GoogleCalendarStartupTokenLoadPolicy.shouldLoadToken(
            remindersEnabled: true,
            selectedCalendarIDs: ["primary"]
        ))
    }

    private static func testCustomTitleRoundTripsThroughPipelineHistoryItemCodable() throws {
        let item = PipelineHistoryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000086")!,
            timestamp: Date(timeIntervalSince1970: 1_600),
            rawTranscript: "raw",
            postProcessedTranscript: "processed",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "Post-processing succeeded",
            debugStatus: "Done",
            customVocabulary: "",
            customTitle: "Manual title"
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(PipelineHistoryItem.self, from: data)
        assert(decoded.customTitle == "Manual title")
    }

    private static func testCalendarMetadataRoundTripsThroughPipelineHistoryItemCodable() throws {
        let start = Date(timeIntervalSince1970: 1_800)
        let end = Date(timeIntervalSince1970: 2_400)
        let item = PipelineHistoryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000057")!,
            timestamp: Date(timeIntervalSince1970: 1_700),
            recordingStartedAt: start,
            recordingEndedAt: end,
            calendarMatch: CalendarEventMatch(
                accountID: "user@example.com",
                calendarID: "calendar-1",
                eventID: "event-1",
                title: "Design Review",
                start: start,
                end: end,
                attendees: [CalendarEventAttendee(displayName: "Ada Lovelace", email: "ada@example.com", responseStatus: "accepted", isOptional: false, isSelf: false)],
                matchSource: .overlapSuggestion,
                titleState: .suggested
            ),
            rawTranscript: "raw",
            postProcessedTranscript: "processed",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "Post-processing succeeded",
            debugStatus: "Done",
            customVocabulary: ""
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(PipelineHistoryItem.self, from: data)
        assert(decoded.recordingStartedAt == start)
        assert(decoded.recordingEndedAt == end)
        assert(decoded.calendarMatch?.title == "Design Review")
        assert(decoded.calendarMatch?.attendees.first?.email == "ada@example.com")
        assert(decoded.calendarMatch?.titleState == .suggested)
    }

    private static func testCalendarMetadataCopyHelpersPreserveFields() {
        let start = Date(timeIntervalSince1970: 3_000)
        let end = Date(timeIntervalSince1970: 3_600)
        let match = CalendarEventMatch(accountID: "user@example.com", calendarID: "calendar-2", eventID: "event-2", title: "Planning", start: start, end: end, matchSource: .overlapSuggestion, titleState: .suggested)
        let placeholder = PipelineHistoryItem.transcriptionRecoveryPlaceholder(
            timestamp: start,
            recordingStartedAt: start,
            recordingEndedAt: end,
            calendarMatch: match,
            intent: .dictation,
            selectedText: nil,
            capturedSelection: nil,
            contextSummary: "",
            contextSystemPrompt: nil,
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            systemPrompt: nil,
            customVocabulary: "",
            customSystemPrompt: "",
            audioFileName: "audio.wav",
            usedLocalTranscription: false,
            usedContextCapture: false,
            usedPostProcessing: true,
            transcriptionLanguageCode: "ko",
            localTranscriptionModelID: "mlx-community/whisper-large-v3-turbo",
            contextAppName: nil,
            contextBundleIdentifier: nil,
            contextWindowTitle: nil
        )
        let interrupted = placeholder.markInterruptedBeforeCompletion()
        assert(interrupted.recordingStartedAt == start)
        assert(interrupted.recordingEndedAt == end)
        assert(interrupted.calendarMatch == match)
    }

    private static func testLegacyEncodedHistoryItemDecodesMissingCalendarMetadataAsNil() throws {
        let legacy = LegacyPipelineHistoryItem(
            intent: .dictation,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000059")!,
            timestamp: Date(timeIntervalSince1970: 4_000),
            rawTranscript: "raw",
            postProcessedTranscript: "processed",
            contextSummary: "",
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "Post-processing succeeded",
            debugStatus: "Done",
            customVocabulary: "",
            customSystemPrompt: "",
            usedLocalTranscription: false,
            usedContextCapture: true,
            usedPostProcessing: true,
            transcriptionLanguageCode: "ko",
            localTranscriptionModelID: "mlx-community/whisper-large-v3-turbo"
        )
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(PipelineHistoryItem.self, from: data)
        assert(decoded.recordingStartedAt == nil)
        assert(decoded.recordingEndedAt == nil)
        assert(decoded.calendarMatch == nil)
        assert(decoded.customTitle == nil)
    }

    private static func testCustomTitlePersistsThroughPipelineHistoryStore() throws {
        let store = PipelineHistoryStore(inMemory: true)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000087")!
        let item = PipelineHistoryItem(
            id: id,
            timestamp: Date(timeIntervalSince1970: 4_500),
            rawTranscript: "raw",
            postProcessedTranscript: "processed",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "Post-processing succeeded",
            debugStatus: "Done",
            customVocabulary: "",
            customTitle: "Stored manual title"
        )
        _ = try store.append(item, maxCount: 10)
        let loaded = store.loadAllHistory()
        assert(loaded.count == 1)
        assert(loaded[0].id == id)
        assert(loaded[0].customTitle == "Stored manual title")
    }

    private static func testCalendarMetadataPersistsThroughPipelineHistoryStore() throws {
        let store = PipelineHistoryStore(inMemory: true)
        let recordingStart = Date(timeIntervalSince1970: 5_000)
        let recordingEnd = Date(timeIntervalSince1970: 5_900)
        let match = CalendarEventMatch(
            accountID: "user@example.com",
            calendarID: "calendar-3",
            eventID: "event-3",
            title: "Roadmap",
            start: recordingStart,
            end: recordingEnd,
            attendees: [CalendarEventAttendee(displayName: "Grace Hopper", email: "grace@example.com", responseStatus: "tentative", isOptional: true, isSelf: false)],
            matchSource: .overlapSuggestion,
            titleState: .suggested
        )
        let item = PipelineHistoryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000058")!,
            timestamp: Date(timeIntervalSince1970: 4_900),
            recordingStartedAt: recordingStart,
            recordingEndedAt: recordingEnd,
            calendarMatch: match,
            rawTranscript: "raw",
            postProcessedTranscript: "processed",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "Post-processing succeeded",
            debugStatus: "Done",
            customVocabulary: ""
        )
        _ = try store.append(item, maxCount: 10)
        let loaded = store.loadAllHistory()
        assert(loaded.count == 1)
        assert(loaded[0].recordingStartedAt == recordingStart)
        assert(loaded[0].recordingEndedAt == recordingEnd)
        assert(loaded[0].calendarMatch == match)
    }

    private struct LegacyPipelineHistoryItem: Encodable {
        let intent: PipelineHistoryItemIntent
        let id: UUID
        let timestamp: Date
        let rawTranscript: String
        let postProcessedTranscript: String
        let contextSummary: String
        let contextScreenshotStatus: String
        let postProcessingStatus: String
        let debugStatus: String
        let customVocabulary: String
        let customSystemPrompt: String
        let usedLocalTranscription: Bool
        let usedContextCapture: Bool
        let usedPostProcessing: Bool
        let transcriptionLanguageCode: String
        let localTranscriptionModelID: String
    }
}
