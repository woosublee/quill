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
        try testAudioOnlyRoundTripPreservesRecordingMetadata()
        try testUpsertKeepsOneRowAndUpdatesAllFields()
        try testDeletedAssetsIncludeHistoryIDForDeleteClearAndTrim()
        testGoogleCalendarConnectionMetadataBuildsConnectedState()
        print("PipelineHistoryCalendarMetadataTests passed")
    }

    private static func testDeletedAssetsIncludeHistoryIDForDeleteClearAndTrim() throws {
        let deleteStore = PipelineHistoryStore(inMemory: true)
        let deleteItem = historyItemForAssetTest(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 3),
            audioFileName: "delete.wav",
            transcriptFileName: "delete.txt"
        )
        _ = try deleteStore.append(deleteItem, maxCount: 10)
        var deleteCallbackIDs: [UUID] = []
        let deleted = try deleteStore.delete(
            id: deleteItem.id,
            beforeDeleting: { deleteCallbackIDs = [$0.historyID] }
        )
        assert(deleteCallbackIDs == [deleteItem.id])
        assert(deleted?.historyID == deleteItem.id)
        assert(deleted?.audioFileName == "delete.wav")
        assert(deleted?.transcriptFileName == "delete.txt")

        let clearStore = PipelineHistoryStore(inMemory: true)
        let clearItems = [
            historyItemForAssetTest(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: 2),
                audioFileName: "clear-a.wav",
                transcriptFileName: nil
            ),
            historyItemForAssetTest(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: 1),
                audioFileName: "clear-b.wav",
                transcriptFileName: "clear-b.txt"
            )
        ]
        for item in clearItems {
            _ = try clearStore.append(item, maxCount: 10)
        }
        var clearCallbackIDs: [UUID] = []
        let cleared = try clearStore.clearAll(
            beforeDeleting: { clearCallbackIDs = $0.map(\.historyID) }
        )
        assert(Set(clearCallbackIDs) == Set(clearItems.map(\.id)))
        assert(Set(cleared.map(\.historyID)) == Set(clearItems.map(\.id)))

        let trimStore = PipelineHistoryStore(inMemory: true)
        let newest = historyItemForAssetTest(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 3),
            audioFileName: "new.wav",
            transcriptFileName: nil
        )
        let oldest = historyItemForAssetTest(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1),
            audioFileName: "old.wav",
            transcriptFileName: "old.txt"
        )
        _ = try trimStore.append(oldest, maxCount: 10)
        _ = try trimStore.append(newest, maxCount: 10)
        var trimCallbackIDs: [UUID] = []
        let trimmed = try trimStore.trim(
            to: 1,
            beforeDeleting: { trimCallbackIDs = $0.map(\.historyID) }
        )
        assert(trimCallbackIDs == [oldest.id])
        assert(trimmed.map(\.historyID) == [oldest.id])
        assert(trimStore.loadAllHistory().map(\.id) == [newest.id])
    }

    private static func historyItemForAssetTest(
        id: UUID,
        timestamp: Date,
        audioFileName: String?,
        transcriptFileName: String?
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: id,
            timestamp: timestamp,
            rawTranscript: "raw",
            postProcessedTranscript: "processed",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "",
            postProcessingStatus: "Post-processing succeeded",
            debugStatus: "Done",
            customVocabulary: "",
            audioFileName: audioFileName,
            transcriptFileName: transcriptFileName
        )
    }

    private static func testGoogleCalendarConnectionMetadataBuildsConnectedState() {
        let metadata = GoogleCalendarConnectionMetadata(accountEmail: "user@example.com")
        let state = metadata.connectionState(selectedCalendarIDs: ["primary"])

        assert(state.isConnected)
        assert(state.accountEmail == "user@example.com")
        assert(state.selectedCalendarIDs == ["primary"])
        assert(state.lastErrorMessage == nil)
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

    private static func testAudioOnlyRoundTripPreservesRecordingMetadata() throws {
        let store = PipelineHistoryStore(inMemory: true)
        let id = UUID()
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 200)
        let calendarMatch = CalendarEventMatch(
            calendarID: "calendar-id",
            eventID: "event-id",
            title: "Weekly Sync",
            start: start,
            end: end,
            matchSource: .calendarNotification,
            titleState: .applied
        )
        let item = PipelineHistoryItem.audioOnly(
            id: id,
            timestamp: end,
            recordingStartedAt: start,
            recordingEndedAt: end,
            calendarMatch: calendarMatch,
            audioFileName: "audio.wav",
            transcriptionLanguageCode: "auto",
            localTranscriptionModelID: "remembered-model"
        )

        _ = try store.append(item, maxCount: 100)
        let loaded = store.loadAllHistory()

        assert(loaded.count == 1)
        assert(loaded[0].id == id)
        assert(loaded[0].machineStatus == .audioOnly)
        assert(loaded[0].calendarMatch?.eventID == "event-id")
        assert(loaded[0].calendarMatch?.appliedTitle == "Weekly Sync")
        assert(loaded[0].recordingStartedAt == start)
        assert(loaded[0].recordingEndedAt == end)
        assert(loaded[0].audioFileName == "audio.wav")
        assert(loaded[0].transcriptFileName == nil)
    }

    private static func testUpsertKeepsOneRowAndUpdatesAllFields() throws {
        let store = PipelineHistoryStore(inMemory: true)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000181")!
        let initial = PipelineHistoryItem(
            id: id,
            timestamp: Date(timeIntervalSince1970: 6_000),
            rawTranscript: "",
            postProcessedTranscript: "",
            postProcessingPrompt: nil,
            contextSummary: "before",
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: PipelineHistoryItem.transcriptionRecoveryPlaceholderStatus,
            debugStatus: "before",
            customVocabulary: "alpha",
            audioFileName: "before.wav",
            usedLocalTranscription: false,
            usedContextCapture: false,
            usedPostProcessing: false,
            transcriptionLanguageCode: "auto",
            localTranscriptionModelID: "before-model"
        )
        let updated = PipelineHistoryItem(
            intent: .commandManual,
            selectedText: "selected",
            capturedSelection: "captured",
            id: id,
            timestamp: Date(timeIntervalSince1970: 6_100),
            recordingStartedAt: Date(timeIntervalSince1970: 6_000),
            recordingEndedAt: Date(timeIntervalSince1970: 6_090),
            rawTranscript: "raw",
            postProcessedTranscript: "processed",
            postProcessingPrompt: "prompt",
            systemPrompt: "system",
            contextSummary: "after",
            contextPrompt: "context",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "Error: Interrupted before transcription completed",
            debugStatus: "after",
            customVocabulary: "beta",
            customSystemPrompt: "custom",
            audioFileName: "after.wav",
            usedLocalTranscription: true,
            usedContextCapture: true,
            usedPostProcessing: true,
            transcriptionLanguageCode: "ko",
            localTranscriptionModelID: "after-model",
            customTitle: "Recovered"
        )

        _ = try store.upsert(initial, maxCount: 10)
        _ = try store.upsert(updated, maxCount: 10)
        let loaded = store.loadAllHistory()
        assert(loaded.count == 1)
        assert(loaded[0].id == id)
        assert(loaded[0].timestamp == updated.timestamp)
        assert(loaded[0].intent == .commandManual)
        assert(loaded[0].selectedText == "selected")
        assert(loaded[0].capturedSelection == updated.capturedSelection)
        assert(loaded[0].recordingStartedAt == updated.recordingStartedAt)
        assert(loaded[0].recordingEndedAt == updated.recordingEndedAt)
        assert(loaded[0].rawTranscript == updated.rawTranscript)
        assert(loaded[0].postProcessedTranscript == updated.postProcessedTranscript)
        assert(loaded[0].postProcessingPrompt == updated.postProcessingPrompt)
        assert(loaded[0].systemPrompt == updated.systemPrompt)
        assert(loaded[0].contextSummary == updated.contextSummary)
        assert(loaded[0].contextPrompt == updated.contextPrompt)
        assert(loaded[0].customVocabulary == updated.customVocabulary)
        assert(loaded[0].customSystemPrompt == updated.customSystemPrompt)
        assert(loaded[0].audioFileName == "after.wav")
        assert(loaded[0].usedLocalTranscription)
        assert(loaded[0].localTranscriptionModelID == "after-model")
        assert(loaded[0].customTitle == "Recovered")
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
