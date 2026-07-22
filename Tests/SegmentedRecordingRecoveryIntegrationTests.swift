import Foundation

@main
struct SegmentedRecordingRecoveryIntegrationTests {
    static func main() {
        do {
            try repeatedLaunchRecoversOrderedSegmentsOnce()
            try repeatedLaunchPersistsPartialIssueOnce()
            try manualEmptyRecordingPreservesInflightFiles()
            try recoveredHistoryDeletionDoesNotReappear()
            print("SegmentedRecordingRecoveryIntegrationTests passed")
        } catch {
            fputs("SegmentedRecordingRecoveryIntegrationTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func repeatedLaunchRecoversOrderedSegmentsOnce() throws {
        try withFixture { fixture in
            let controller = try fixture.makeController()
            controller.activeSegment.microphoneSink?.enqueue(pcmData([1, 2]))
            let combined = try controller.switchSegment(
                segmentID: UUID(),
                sources: [
                    RecordingJournalSegmentSourceRequest(id: UUID(), kind: .microphone),
                    RecordingJournalSegmentSourceRequest(id: UUID(), kind: .systemAudio)
                ]
            )
            combined.microphoneSink?.enqueue(pcmData([1_000, 1_000]))
            combined.systemAudioSink?.enqueue(
                pcmData([3_000, 3_000]),
                firstFrameMonotonicNanoseconds: fixture.anchor + 62_500
            )
            let last = try controller.switchSegment(
                segmentID: UUID(),
                sources: [RecordingJournalSegmentSourceRequest(
                    id: UUID(),
                    kind: .systemAudio
                )]
            )
            last.systemAudioSink?.enqueue(pcmData([7, 8]))
            try controller.checkpoint()

            try runRecoveryLaunch(fixture)
            try runRecoveryLaunch(fixture)

            try assertConverged(fixture, expectedMode: .complete)
            try expectEqual(
                try readSamples(
                    fixture.journalStore.permanentURL(recordingID: fixture.recordingID)
                ),
                [1, 2, 800, 3_200, 2_400, 7, 8],
                "complete repeated-launch samples"
            )
        }
    }

    private static func repeatedLaunchPersistsPartialIssueOnce() throws {
        try withFixture { fixture in
            let controller = try fixture.makeController()
            controller.activeSegment.microphoneSink?.enqueue(pcmData([1, 2]))
            let damagedSourceID = UUID()
            let next = try controller.switchSegment(
                segmentID: UUID(),
                sources: [RecordingJournalSegmentSourceRequest(
                    id: damagedSourceID,
                    kind: .systemAudio
                )]
            )
            next.systemAudioSink?.enqueue(pcmData([3, 4]))
            let last = try controller.switchSegment(
                segmentID: UUID(),
                sources: [RecordingJournalSegmentSourceRequest(
                    id: UUID(),
                    kind: .microphone
                )]
            )
            last.microphoneSink?.enqueue(pcmData([5, 6]))
            try controller.checkpoint()
            let manifest = try fixture.journalStore.loadManifest(
                recordingID: fixture.recordingID
            )
            let source = manifest.sources.first { $0.id == damagedSourceID }!
            try FileManager.default.removeItem(at: try fixture.journalStore.sourceURL(
                recordingID: fixture.recordingID,
                fileName: source.fileName
            ))

            let executor = RecordingJournalRecoveryExecutor(store: fixture.journalStore)
            let artifact = try requireRecovered(executor.recoverAll()[0])
            try expectEqual(
                artifact.promotion.resolvedRecoveryIssues,
                [RecordingRecoveryIssue(
                    segmentSequence: 1,
                    sourceKind: .systemAudio,
                    reason: .sourceMissing
                )],
                "durable partial issue"
            )
            _ = try RecordingRecoveryHistory(
                journalStore: fixture.journalStore,
                historyStore: fixture.historyStore
            ).persist(artifact, maxCount: 50)
            try normalizeHistory(fixture.historyStore)
            try runRecoveryLaunch(fixture)

            try assertConverged(fixture, expectedMode: .partial)
            try expectEqual(
                try readSamples(
                    fixture.journalStore.permanentURL(recordingID: fixture.recordingID)
                ),
                [1, 2, 5, 6],
                "partial repeated-launch samples"
            )
        }
    }

    private static func manualEmptyRecordingPreservesInflightFiles() throws {
        try withFixture { fixture in
            let controller = try fixture.makeController()
            try controller.checkpoint()
            let result = RecordingJournalRecoveryExecutor(store: fixture.journalStore)
                .recoverAll()[0]

            guard case .manualRecoveryRequired = result else {
                throw TestFailure("all-empty segmented recording must remain manual")
            }
            guard FileManager.default.fileExists(
                atPath: fixture.journalStore.recordingDirectory(
                    recordingID: fixture.recordingID
                ).path
            ) else {
                throw TestFailure("manual recovery must preserve inflight files")
            }
        }
    }

    private static func recoveredHistoryDeletionDoesNotReappear() throws {
        try withFixture { fixture in
            let controller = try fixture.makeController()
            controller.activeSegment.microphoneSink?.enqueue(pcmData([1, 2]))
            try controller.checkpoint()
            try runRecoveryLaunch(fixture)

            if let assets = try fixture.historyStore.delete(id: fixture.recordingID),
               let audioFileName = assets.audioFileName {
                try FileManager.default.removeItem(
                    at: fixture.journalStore.audioDirectory
                        .appendingPathComponent(audioFileName)
                )
            }
            try runRecoveryLaunch(fixture)

            try expectEqual(fixture.historyStore.loadAllHistory().count, 0, "deleted history")
            guard !FileManager.default.fileExists(
                atPath: fixture.journalStore.permanentURL(
                    recordingID: fixture.recordingID
                ).path
            ) else {
                throw TestFailure("deleted permanent WAV remains")
            }
        }
    }

    private static func runRecoveryLaunch(_ fixture: Fixture) throws {
        let history = RecordingRecoveryHistory(
            journalStore: fixture.journalStore,
            historyStore: fixture.historyStore
        )
        for result in RecordingJournalRecoveryExecutor(
            store: fixture.journalStore
        ).recoverAll() {
            if case .recovered(let artifact) = result {
                _ = try history.persist(artifact, maxCount: 50)
            }
        }
        try normalizeHistory(fixture.historyStore)
    }

    private static func normalizeHistory(_ store: PipelineHistoryStore) throws {
        for item in store.loadAllHistory() where item.isIncompleteTranscription {
            try store.update(item.markInterruptedBeforeCompletion())
        }
    }

    private static func assertConverged(
        _ fixture: Fixture,
        expectedMode: RecoveredRecordingMode
    ) throws {
        let permanentURL = fixture.journalStore.permanentURL(
            recordingID: fixture.recordingID
        )
        let permanentFiles = try FileManager.default.contentsOfDirectory(
            at: fixture.journalStore.audioDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent == permanentURL.lastPathComponent }
        try expectEqual(permanentFiles.count, 1, "permanent WAV count")
        let items = fixture.historyStore.loadAllHistory()
        try expectEqual(items.count, 1, "history row count")
        try expectEqual(items[0].id, fixture.recordingID, "history recording ID")
        try expectEqual(items[0].recoveredRecordingMode, expectedMode, "history mode")
        guard !FileManager.default.fileExists(
            atPath: fixture.journalStore.recordingDirectory(
                recordingID: fixture.recordingID
            ).path
        ) else {
            throw TestFailure("converged recording retains inflight directory")
        }
    }

    private static func withFixture(_ body: (Fixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-segmented-recovery-integration-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingID = UUID()
        let anchor: UInt64 = 1_000_000_000
        try body(Fixture(
            recordingID: recordingID,
            anchor: anchor,
            journalStore: RecordingJournalStore(
                audioDirectory: root.appendingPathComponent("audio", isDirectory: true)
            ),
            historyStore: PipelineHistoryStore(inMemory: true)
        ))
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

    private static func readSamples(_ url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        let payload = data.dropFirst(RecordingCanonicalWAV.headerByteCount)
        return stride(from: 0, to: payload.count, by: 2).map { index in
            let lower = UInt16(payload[payload.startIndex + index])
            let upper = UInt16(payload[payload.startIndex + index + 1]) << 8
            return Int16(bitPattern: lower | upper)
        }
    }

    private static func requireRecovered(
        _ result: RecordingJournalRecoveryResult
    ) throws -> RecoveredRecordingArtifact {
        guard case .recovered(let artifact) = result else {
            throw TestFailure("expected recovered artifact")
        }
        return artifact
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
                contextCaptureEnabled: false,
                instructionExecutionGuardEnabled: true,
                customVocabulary: [],
                customSystemPrompt: nil
            )
        )
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
        let anchor: UInt64
        let journalStore: RecordingJournalStore
        let historyStore: PipelineHistoryStore

        func makeController() throws -> SegmentedRecordingJournalController {
            try SegmentedRecordingJournalController(
                request: SegmentedRecordingJournalCreateRequest(
                    recordingID: recordingID,
                    segmentID: UUID(),
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    monotonicAnchorNanoseconds: anchor,
                    sources: [RecordingJournalSegmentSourceRequest(
                        id: UUID(),
                        kind: .microphone
                    )],
                    pipeline: pipelineSnapshot()
                ),
                store: journalStore
            )
        }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
