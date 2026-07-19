import Foundation

@main
struct RecordingRecoveryHistoryTests {
    static func main() {
        do {
            try recoveredMicrophoneArtifactCreatesIdempotentRetryableHistory()
            try recoveredSystemAudioArtifactCreatesIdempotentRetryableHistory()
            try combinedRecoveryModesPersistIdempotently()
            try missingRecoveredAudioPreservesPromotedJournal()
            try existingCompletedHistoryIsNotReplacedDuringJournalCleanup()
            print("RecordingRecoveryHistoryTests passed")
        } catch {
            fputs("RecordingRecoveryHistoryTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func recoveredMicrophoneArtifactCreatesIdempotentRetryableHistory() throws {
        try recoveredArtifactCreatesIdempotentRetryableHistory(
            sourceMode: .microphone,
            sourceKind: .microphone,
            sourceFileName: "microphone.wav.part"
        )
    }

    private static func recoveredSystemAudioArtifactCreatesIdempotentRetryableHistory() throws {
        try recoveredArtifactCreatesIdempotentRetryableHistory(
            sourceMode: .systemAudio,
            sourceKind: .systemAudio,
            sourceFileName: "system-audio.wav.part"
        )
    }

    private static func recoveredArtifactCreatesIdempotentRetryableHistory(
        sourceMode: RecordingAudioSourceMode,
        sourceKind: RecordingJournalSourceKind,
        sourceFileName: String
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-recording-recovery-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingID = UUID()
        let store = RecordingJournalStore(
            audioDirectory: root.appendingPathComponent("audio", isDirectory: true)
        )
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let request = RecordingJournalCreateRequest(
            recordingID: recordingID,
            sourceID: UUID(),
            segmentID: UUID(),
            startedAt: startedAt,
            monotonicAnchorNanoseconds: 100,
            sourceMode: sourceMode,
            sourceKind: sourceKind,
            sourceFileName: sourceFileName,
            pipeline: RecordingPipelineSnapshot(
                trigger: .toggle,
                intent: .commandManual,
                selectedText: "rewrite this",
                title: "Recovered meeting",
                calendar: RecordingCalendarSnapshot(
                    eventID: "event-1",
                    calendarID: "calendar-1",
                    title: "Design Review",
                    startDate: startedAt.addingTimeInterval(-60),
                    endDate: startedAt.addingTimeInterval(300),
                    matchSource: CalendarMatchSource.overlapSuggestion.rawValue,
                    attendeeNames: ["Ada"]
                ),
                transcription: RecordingTranscriptionSnapshot(
                    backend: .nativeWhisper,
                    modelID: "native-model",
                    spokenLanguageCode: "ko",
                    providerSelection: .defaultConfiguration
                ),
                processing: RecordingProcessingSnapshot(
                    postProcessingEnabled: true,
                    preferredModelID: "preferred",
                    fallbackModelID: "fallback",
                    outputLanguage: "ko",
                    preserveExactWording: false,
                    contextCaptureEnabled: true,
                    instructionExecutionGuardEnabled: true,
                    customVocabulary: ["Quill", "FreeFlow"],
                    customSystemPrompt: "Keep names exact"
                )
            )
        )
        let controller = try SingleSourceRecordingJournalController(
            request: request,
            store: store
        )
        controller.sink.enqueue(Data(repeating: 0, count: 32_000))
        _ = try controller.finish()

        let recovered = try requireRecovered(
            RecordingJournalRecoveryExecutor(store: store).recoverAll()[0]
        )
        try expectEqual(
            recovered.manifest.sourceMode,
            sourceMode,
            "recovered source mode"
        )
        try expectEqual(
            recovered.manifest.sources[0].kind,
            sourceKind,
            "recovered source kind"
        )
        let historyStore = PipelineHistoryStore(inMemory: true)
        let bridge = RecordingRecoveryHistory(
            journalStore: store,
            historyStore: historyStore
        )
        _ = try bridge.persist(recovered, maxCount: 50)
        _ = try bridge.persist(recovered, maxCount: 50)

        let items = historyStore.loadAllHistory()
        try expectEqual(items.count, 1, "history row count")
        let item = items[0]
        try expectEqual(item.id, recordingID, "history ID")
        try expectEqual(item.audioFileName, recordingID.uuidString.lowercased() + ".wav", "audio file")
        try expectEqual(item.intent, .commandManual, "intent")
        try expectEqual(item.selectedText, "rewrite this", "selected text")
        try expectEqual(item.recordingStartedAt, startedAt, "recording start")
        try expectEqual(item.recordingEndedAt, startedAt.addingTimeInterval(1), "recording end")
        try expectEqual(item.calendarMatch?.title, "Design Review", "calendar title")
        try expectEqual(item.transcriptionLanguageCode, "ko", "language")
        try expectEqual(item.localTranscriptionModelID, "native-model", "local model")
        guard item.usedLocalTranscription,
              item.usedContextCapture,
              item.usedPostProcessing,
              item.isIncompleteTranscription else {
            throw TestFailure("recovered placeholder flags are incorrect")
        }
        try expectEqual(item.customVocabulary, "Quill\nFreeFlow", "custom vocabulary")
        try expectEqual(item.customSystemPrompt, "Keep names exact", "custom system prompt")

        guard !FileManager.default.fileExists(
            atPath: store.recordingDirectory(recordingID: recordingID).path
        ) else {
            throw TestFailure("history completion must clean finalized inflight directory")
        }
        guard FileManager.default.fileExists(
            atPath: store.permanentURL(recordingID: recordingID).path
        ) else {
            throw TestFailure("history completion must preserve permanent audio")
        }
    }

    private static func combinedRecoveryModesPersistIdempotently() throws {
        for mode in RecoveredRecordingMode.allCases {
            try withCombinedRecoveredFixture(mode: mode) { fixture in
                let historyStore = PipelineHistoryStore(inMemory: true)
                let bridge = RecordingRecoveryHistory(
                    journalStore: fixture.store,
                    historyStore: historyStore
                )

                _ = try bridge.persist(fixture.artifact, maxCount: 50)
                _ = try bridge.persist(fixture.artifact, maxCount: 50)

                var items = historyStore.loadAllHistory()
                try expectEqual(items.count, 1, "\(mode) history row count")
                try expectEqual(items[0].id, fixture.recordingID, "\(mode) history ID")
                try expectEqual(
                    items[0].postProcessingStatus,
                    mode.placeholderStatus,
                    "\(mode) placeholder status"
                )
                try expectEqual(
                    items[0].audioFileName,
                    fixture.recordingID.uuidString.lowercased() + ".wav",
                    "\(mode) audio filename"
                )

                try historyStore.update(items[0].markInterruptedBeforeCompletion())
                items = historyStore.loadAllHistory()
                try expectEqual(
                    items[0].postProcessingStatus,
                    mode.recoveredStatus,
                    "\(mode) recovered status"
                )
                try expectEqual(
                    items[0].recoveredRecordingMode,
                    mode,
                    "\(mode) persisted recovered mode"
                )
                guard !FileManager.default.fileExists(
                    atPath: fixture.store.recordingDirectory(
                        recordingID: fixture.recordingID
                    ).path
                ) else {
                    throw TestFailure("\(mode) inflight directory must be removed")
                }
            }
        }
    }

    private static func missingRecoveredAudioPreservesPromotedJournal() throws {
        try withCombinedRecoveredFixture(mode: .microphoneOnly) { fixture in
            try FileManager.default.removeItem(at: fixture.artifact.audioURL)
            let historyStore = PipelineHistoryStore(inMemory: true)
            let bridge = RecordingRecoveryHistory(
                journalStore: fixture.store,
                historyStore: historyStore
            )

            do {
                _ = try bridge.persist(fixture.artifact, maxCount: 50)
                throw TestFailure("missing recovered audio must fail persistence")
            } catch RecordingArtifactFinalizerError.sourceMissing {
                // expected
            }

            try expectEqual(
                try fixture.store.loadManifest(
                    recordingID: fixture.recordingID
                ).state,
                .promoted,
                "missing audio manifest state"
            )
            try expectEqual(
                historyStore.loadAllHistory().count,
                0,
                "missing audio history count"
            )
            guard FileManager.default.fileExists(
                atPath: fixture.store.recordingDirectory(
                    recordingID: fixture.recordingID
                ).path
            ) else {
                throw TestFailure("missing audio inflight directory must remain")
            }
        }
    }

    private static func existingCompletedHistoryIsNotReplacedDuringJournalCleanup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-recording-recovery-history-cleanup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingID = UUID()
        let store = RecordingJournalStore(
            audioDirectory: root.appendingPathComponent("audio", isDirectory: true)
        )
        let request = RecordingJournalCreateRequest(
            recordingID: recordingID,
            sourceID: UUID(),
            segmentID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_001_000),
            monotonicAnchorNanoseconds: 200,
            sourceMode: .microphone,
            sourceKind: .microphone,
            sourceFileName: "microphone.wav.part",
            pipeline: RecordingPipelineSnapshot(
                trigger: .toggle,
                intent: .dictation,
                selectedText: nil,
                title: nil,
                calendar: nil,
                transcription: RecordingTranscriptionSnapshot(
                    backend: .apiStandard,
                    modelID: "whisper-large-v3",
                    spokenLanguageCode: "en",
                    providerSelection: .defaultConfiguration
                ),
                processing: RecordingProcessingSnapshot(
                    postProcessingEnabled: false,
                    preferredModelID: nil,
                    fallbackModelID: nil,
                    outputLanguage: "auto",
                    preserveExactWording: false,
                    contextCaptureEnabled: false,
                    instructionExecutionGuardEnabled: true,
                    customVocabulary: [],
                    customSystemPrompt: nil
                )
            )
        )
        let controller = try SingleSourceRecordingJournalController(
            request: request,
            store: store
        )
        controller.sink.enqueue(Data([0x01, 0x00]))
        _ = try controller.finish()

        let historyStore = PipelineHistoryStore(inMemory: true)
        let completed = PipelineHistoryItem(
            id: recordingID,
            timestamp: Date(timeIntervalSince1970: 1_700_001_100),
            rawTranscript: "completed raw",
            postProcessedTranscript: "completed result",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "Post-processing succeeded",
            debugStatus: "Done",
            customVocabulary: "",
            audioFileName: recordingID.uuidString.lowercased() + ".wav"
        )
        _ = try historyStore.upsert(completed, maxCount: 50)

        let recovered = try requireRecovered(
            RecordingJournalRecoveryExecutor(store: store).recoverAll()[0]
        )
        _ = try RecordingRecoveryHistory(
            journalStore: store,
            historyStore: historyStore
        ).persist(recovered, maxCount: 50)

        let items = historyStore.loadAllHistory()
        try expectEqual(items.count, 1, "completed history row count")
        try expectEqual(items[0].rawTranscript, "completed raw", "completed raw transcript")
        try expectEqual(items[0].postProcessedTranscript, "completed result", "completed result")
        try expectEqual(items[0].postProcessingStatus, "Post-processing succeeded", "completed status")
        guard !FileManager.default.fileExists(
            atPath: store.recordingDirectory(recordingID: recordingID).path
        ) else {
            throw TestFailure("completed history cleanup must remove inflight directory")
        }
    }

    private static func withCombinedRecoveredFixture(
        mode: RecoveredRecordingMode,
        _ body: (CombinedRecoveredFixture) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-combined-recovery-history-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingID = UUID()
        let anchor: UInt64 = 1_000_000_000
        let store = RecordingJournalStore(
            audioDirectory: root.appendingPathComponent("audio", isDirectory: true)
        )
        let request = CombinedRecordingJournalCreateRequest(
            recordingID: recordingID,
            microphoneSourceID: UUID(),
            systemAudioSourceID: UUID(),
            segmentID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            monotonicAnchorNanoseconds: anchor,
            pipeline: makeCombinedPipelineSnapshot()
        )
        let controller = try CombinedRecordingJournalController(
            request: request,
            store: store
        )
        switch mode {
        case .complete:
            controller.microphoneSink.enqueue(
                Data([0x01, 0x00, 0x02, 0x00]),
                firstFrameMonotonicNanoseconds: anchor
            )
            controller.systemAudioSink.enqueue(
                Data([0x03, 0x00, 0x04, 0x00]),
                firstFrameMonotonicNanoseconds: anchor
            )
        case .microphoneOnly:
            controller.microphoneSink.enqueue(
                Data([0x01, 0x00, 0x02, 0x00]),
                firstFrameMonotonicNanoseconds: anchor
            )
        case .systemAudioOnly:
            controller.systemAudioSink.enqueue(
                Data([0x03, 0x00, 0x04, 0x00]),
                firstFrameMonotonicNanoseconds: anchor
            )
        }
        _ = try controller.stopAndClose()
        let artifact = try requireRecovered(
            RecordingJournalRecoveryExecutor(store: store).recoverAll()[0]
        )
        try expectEqual(artifact.mode, mode, "combined fixture recovery mode")
        try body(CombinedRecoveredFixture(
            recordingID: recordingID,
            store: store,
            artifact: artifact
        ))
    }

    private static func makeCombinedPipelineSnapshot() -> RecordingPipelineSnapshot {
        RecordingPipelineSnapshot(
            trigger: .toggle,
            intent: .dictation,
            selectedText: nil,
            title: nil,
            calendar: nil,
            transcription: RecordingTranscriptionSnapshot(
                backend: .apiStandard,
                modelID: "whisper-large-v3",
                spokenLanguageCode: "auto",
                providerSelection: .defaultConfiguration
            ),
            processing: RecordingProcessingSnapshot(
                postProcessingEnabled: false,
                preferredModelID: nil,
                fallbackModelID: nil,
                outputLanguage: "auto",
                preserveExactWording: false,
                contextCaptureEnabled: false,
                instructionExecutionGuardEnabled: true,
                customVocabulary: [],
                customSystemPrompt: nil
            )
        )
    }

    private static func requireRecovered(
        _ result: RecordingJournalRecoveryResult
    ) throws -> RecoveredRecordingArtifact {
        guard case .recovered(let artifact) = result else {
            throw TestFailure("expected recovered artifact")
        }
        return artifact
    }

    private static func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ label: String
    ) throws {
        guard actual == expected else {
            throw TestFailure("\(label): expected \(String(describing: expected)), got \(String(describing: actual))")
        }
    }

    private struct CombinedRecoveredFixture {
        let recordingID: UUID
        let store: RecordingJournalStore
        let artifact: RecoveredRecordingArtifact
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
