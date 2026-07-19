import AVFoundation
import Foundation

@main
struct CombinedRecordingStartupRecoveryIntegrationTests {
    static func main() {
        do {
            try repeatedLaunchRecoversCompleteAndDegradedJournalsOnce()
            try promotedHistoryAndFinalizedCrashWindowsConverge()
            try recoveredHistoryDeletionRemovesAudio()
            print("CombinedRecordingStartupRecoveryIntegrationTests passed")
        } catch {
            fputs("CombinedRecordingStartupRecoveryIntegrationTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func repeatedLaunchRecoversCompleteAndDegradedJournalsOnce() throws {
        for mode in [
            RecoveredRecordingMode.complete,
            .microphoneOnly,
            .systemAudioOnly
        ] {
            try withFixture(mode: mode) { fixture in
                try runRecoveryLaunch(
                    journalStore: fixture.journalStore,
                    historyStore: fixture.historyStore
                )
                try runRecoveryLaunch(
                    journalStore: fixture.journalStore,
                    historyStore: fixture.historyStore
                )

                let audioURL = fixture.journalStore.permanentURL(
                    recordingID: fixture.recordingID
                )
                let files = try permanentRecordingFiles(
                    in: fixture.journalStore.audioDirectory,
                    recordingID: fixture.recordingID
                )
                try expectEqual(files.count, 1, "\(mode) permanent file count")
                try expectEqual(
                    files[0].lastPathComponent,
                    audioURL.lastPathComponent,
                    "\(mode) permanent filename"
                )
                let items = fixture.historyStore.loadAllHistory()
                try expectEqual(items.count, 1, "\(mode) history row count")
                try expectEqual(items[0].id, fixture.recordingID, "\(mode) history ID")
                try expectEqual(
                    items[0].postProcessingStatus,
                    mode.recoveredStatus,
                    "\(mode) recovered status"
                )
                try expectEqual(
                    items[0].recoveredRecordingMode,
                    mode,
                    "\(mode) recovered mode"
                )
                _ = try RecordingCanonicalWAV.validateFile(at: audioURL)
                guard !FileManager.default.fileExists(
                    atPath: fixture.journalStore.recordingDirectory(
                        recordingID: fixture.recordingID
                    ).path
                ) else {
                    throw TestFailure("\(mode) inflight directory remains")
                }
            }
        }
    }

    private static func promotedHistoryAndFinalizedCrashWindowsConverge() throws {
        for startingState in [
            RecordingJournalState.promoted,
            .historyStored,
            .finalized
        ] {
            try withFixture(mode: .complete, persistBeforeLaunch: false) { fixture in
                let recovered = try requireRecovered(
                    RecordingJournalRecoveryExecutor(store: fixture.journalStore)
                        .recoverAll()[0]
                )
                if startingState == .historyStored || startingState == .finalized {
                    let history = RecordingRecoveryHistory(
                        journalStore: fixture.journalStore,
                        historyStore: fixture.historyStore
                    )
                    let item = history.makePlaceholder(from: recovered)
                    _ = try fixture.historyStore.upsert(item, maxCount: 50)
                    _ = try fixture.journalStore.transition(
                        recordingID: fixture.recordingID,
                        to: .historyStored,
                        historyItemID: fixture.recordingID
                    )
                }
                if startingState == .finalized {
                    _ = try fixture.journalStore.transition(
                        recordingID: fixture.recordingID,
                        to: .finalized
                    )
                }

                try runRecoveryLaunch(
                    journalStore: fixture.journalStore,
                    historyStore: fixture.historyStore
                )
                try runRecoveryLaunch(
                    journalStore: fixture.journalStore,
                    historyStore: fixture.historyStore
                )

                try expectEqual(
                    fixture.historyStore.loadAllHistory().count,
                    1,
                    "\(startingState) history row count"
                )
                try expectEqual(
                    try permanentRecordingFiles(
                        in: fixture.journalStore.audioDirectory,
                        recordingID: fixture.recordingID
                    ).count,
                    1,
                    "\(startingState) permanent file count"
                )
                guard !FileManager.default.fileExists(
                    atPath: fixture.journalStore.recordingDirectory(
                        recordingID: fixture.recordingID
                    ).path
                ) else {
                    throw TestFailure("\(startingState) inflight directory remains")
                }
            }
        }
    }

    private static func recoveredHistoryDeletionRemovesAudio() throws {
        try withFixture(mode: .microphoneOnly) { fixture in
            try runRecoveryLaunch(
                journalStore: fixture.journalStore,
                historyStore: fixture.historyStore
            )
            if let assets = try fixture.historyStore.delete(
                id: fixture.recordingID
            ), let audioFileName = assets.audioFileName {
                try? FileManager.default.removeItem(
                    at: fixture.journalStore.audioDirectory
                        .appendingPathComponent(audioFileName)
                )
            }

            try expectEqual(fixture.historyStore.loadAllHistory().count, 0, "deleted history")
            guard !FileManager.default.fileExists(
                atPath: fixture.journalStore.permanentURL(
                    recordingID: fixture.recordingID
                ).path
            ) else {
                throw TestFailure("deleted recovered audio remains")
            }
        }
    }

    private static func runRecoveryLaunch(
        journalStore: RecordingJournalStore,
        historyStore: PipelineHistoryStore
    ) throws {
        let executor = RecordingJournalRecoveryExecutor(store: journalStore)
        let history = RecordingRecoveryHistory(
            journalStore: journalStore,
            historyStore: historyStore
        )
        for result in executor.recoverAll() {
            if case .recovered(let artifact) = result {
                _ = try history.persist(artifact, maxCount: 50)
            }
        }
        for item in historyStore.loadAllHistory()
            where item.isIncompleteTranscription {
            try historyStore.update(item.markInterruptedBeforeCompletion())
        }
    }

    private static func withFixture(
        mode: RecoveredRecordingMode,
        persistBeforeLaunch: Bool = false,
        _ body: (Fixture) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-combined-startup-recovery-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingID = UUID()
        let anchor: UInt64 = 1_000_000_000
        let journalStore = RecordingJournalStore(
            audioDirectory: root.appendingPathComponent("audio", isDirectory: true)
        )
        let historyStore = PipelineHistoryStore(inMemory: true)
        let controller = try CombinedRecordingJournalController(
            request: CombinedRecordingJournalCreateRequest(
                recordingID: recordingID,
                microphoneSourceID: UUID(),
                systemAudioSourceID: UUID(),
                segmentID: UUID(),
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                monotonicAnchorNanoseconds: anchor,
                pipeline: pipelineSnapshot()
            ),
            store: journalStore
        )
        switch mode {
        case .complete:
            controller.microphoneSink.enqueue(
                pcmData([1_000, 1_000]),
                firstFrameMonotonicNanoseconds: anchor
            )
            controller.systemAudioSink.enqueue(
                pcmData([3_000, 3_000]),
                firstFrameMonotonicNanoseconds: anchor + 125_000
            )
        case .microphoneOnly:
            controller.microphoneSink.enqueue(
                pcmData([100, 200]),
                firstFrameMonotonicNanoseconds: anchor + 500_000_000
            )
        case .systemAudioOnly:
            controller.systemAudioSink.enqueue(
                pcmData([300, 400]),
                firstFrameMonotonicNanoseconds: anchor + 500_000_000
            )
        case .partial:
            throw TestFailure("partial recovery requires a segmented fixture")
        }
        try controller.checkpoint()
        if persistBeforeLaunch {
            try runRecoveryLaunch(
                journalStore: journalStore,
                historyStore: historyStore
            )
        }
        try body(Fixture(
            recordingID: recordingID,
            journalStore: journalStore,
            historyStore: historyStore
        ))
    }

    private static func permanentRecordingFiles(
        in directory: URL,
        recordingID: UUID
    ) throws -> [URL] {
        let expected = recordingID.uuidString.lowercased() + ".wav"
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent == expected }
    }

    private static func pcmData(_ samples: [Int16]) -> Data {
        var data = Data()
        for sample in samples {
            let value = UInt16(bitPattern: sample)
            data.append(UInt8(value & 0x00FF))
            data.append(UInt8(value >> 8))
        }
        return data
    }

    private static func pipelineSnapshot() -> RecordingPipelineSnapshot {
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
            throw TestFailure("expected recovered artifact, got \(result)")
        }
        return artifact
    }

    private static func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ label: String
    ) throws {
        guard actual == expected else {
            throw TestFailure("\(label): expected \(expected), got \(actual)")
        }
    }

    private struct Fixture {
        let recordingID: UUID
        let journalStore: RecordingJournalStore
        let historyStore: PipelineHistoryStore
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
