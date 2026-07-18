import AVFoundation
import Foundation

@main
struct SingleSourceRecordingJournalControllerTests {
    static func main() {
        do {
            try initializationFailureRollsBackInflightJournal()
            try microphoneFinishPromotesReadableCanonicalWAV()
            try microphoneExplicitDiscardRemovesInflightJournal()
            try discardFailureLeavesHiddenTombstoneAndRetriesRemoval()
            try microphoneRuntimeFailurePreservesRecoverableJournal()
            try repeatedMicrophoneFinishReturnsSamePromotedArtifact()
            try systemAudioFinishPromotesReadableCanonicalWAV()
            try systemAudioExplicitDiscardRemovesInflightJournal()
            try systemAudioRuntimeFailurePreservesRecoverableJournal()
            try repeatedSystemAudioFinishReturnsSamePromotedArtifact()
            print("SingleSourceRecordingJournalControllerTests passed")
        } catch {
            fputs("SingleSourceRecordingJournalControllerTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func initializationFailureRollsBackInflightJournal() throws {
        try withMicrophoneFixture { fixture in
            do {
                _ = try SingleSourceRecordingJournalController(
                    request: fixture.request,
                    store: fixture.store,
                    makeWriter: { session, store in
                        throw TestFailure("injected writer failure")
                    }
                )
                throw TestFailure("controller initialization must fail")
            } catch let error as TestFailure
                where error.description == "injected writer failure" {
                // expected
            }

            guard !FileManager.default.fileExists(
                atPath: fixture.store.recordingDirectory(
                    recordingID: fixture.recordingID
                ).path
            ) else {
                throw TestFailure(
                    "failed initialization must remove its inflight journal"
                )
            }
        }
    }

    private static func microphoneFinishPromotesReadableCanonicalWAV() throws {
        try withFixture(
            sourceMode: .microphone,
            sourceKind: .microphone,
            sourceFileName: "microphone.wav.part"
        ) { fixture in
            let controller = try SingleSourceRecordingJournalController(
                request: fixture.request,
                store: fixture.store
            )
            controller.sink.enqueue(Data([0x01, 0x00, 0x02, 0x00]))
            try controller.checkpoint()

            let checkpointed = try fixture.store.loadManifest(
                recordingID: fixture.recordingID
            )
            try expectEqual(checkpointed.state, .recording, "checkpoint state")
            try expectEqual(
                checkpointed.sources[0].committedDataByteCount,
                4,
                "checkpoint bytes"
            )

            let promotedURL = try controller.finish()
            try verifyPromotedWAV(
                at: promotedURL,
                fixture: fixture,
                expectedDataByteCount: 4
            )
        }
    }

    private static func microphoneExplicitDiscardRemovesInflightJournal() throws {
        try withMicrophoneFixture { fixture in
            let controller = try SingleSourceRecordingJournalController(
                request: fixture.request,
                store: fixture.store
            )
            controller.sink.enqueue(Data([0x01, 0x00]))
            try controller.discard()
            try controller.discard()
            try verifyDiscarded(fixture: fixture)
        }
    }

    private static func discardFailureLeavesHiddenTombstoneAndRetriesRemoval() throws {
        let fileManager = FailingTombstoneRemovalFileManager()
        try withFixture(
            sourceMode: .microphone,
            sourceKind: .microphone,
            sourceFileName: "microphone.wav.part",
            fileManager: fileManager
        ) { fixture in
            let controller = try SingleSourceRecordingJournalController(
                request: fixture.request,
                store: fixture.store
            )
            controller.sink.enqueue(Data([0x01, 0x00]))
            let directory = fixture.store.recordingDirectory(
                recordingID: fixture.recordingID
            )
            let inflightDirectory = fixture.store.inflightDirectory
            fileManager.failNextTombstoneRemoval = true

            do {
                try controller.discard()
                throw TestFailure("first discard must fail deletion")
            } catch let error as TestFailure {
                throw error
            } catch {
                // expected
            }
            guard !FileManager.default.fileExists(atPath: directory.path) else {
                throw TestFailure(
                    "discard failure must move journal out of recovery scan"
                )
            }
            let tombstone = inflightDirectory.appendingPathComponent(
                ".discarded-\(fixture.recordingID.uuidString.lowercased())",
                isDirectory: true
            )
            guard FileManager.default.fileExists(atPath: tombstone.path) else {
                throw TestFailure("discard failure must leave hidden tombstone")
            }
            let candidates = InflightRecordingRecovery(
                store: fixture.store
            ).scan()
            try expectEqual(candidates.count, 1, "tombstone candidate count")
            try expectEqual(
                candidates[0].action,
                .discard,
                "tombstone recovery action"
            )
            let results = RecordingJournalRecoveryExecutor(
                store: fixture.store
            ).recoverAll()
            guard case .discarded(let recordingID) = results.first else {
                throw TestFailure("startup recovery must delete tombstone")
            }
            try expectEqual(recordingID, fixture.recordingID, "tombstone ID")
            guard !FileManager.default.fileExists(atPath: tombstone.path) else {
                throw TestFailure("startup recovery must remove hidden tombstone")
            }

            try controller.discard()
            try verifyDiscarded(fixture: fixture)
        }
    }

    private static func microphoneRuntimeFailurePreservesRecoverableJournal() throws {
        try withMicrophoneFixture { fixture in
            let controller = try SingleSourceRecordingJournalController(
                request: fixture.request,
                store: fixture.store
            )
            controller.sink.enqueue(Data([0x01, 0x00, 0x02, 0x00]))
            try controller.preserveForRecovery()
            try controller.preserveForRecovery()
            try verifyRecoverable(
                fixture: fixture,
                sourceMode: .microphone,
                sourceKind: .microphone
            )
        }
    }

    private static func repeatedMicrophoneFinishReturnsSamePromotedArtifact() throws {
        try withMicrophoneFixture { fixture in
            let controller = try SingleSourceRecordingJournalController(
                request: fixture.request,
                store: fixture.store
            )
            controller.sink.enqueue(Data([0x01, 0x00]))
            let first = try controller.finish()
            let second = try controller.finish()
            try expectEqual(second, first, "repeated microphone finish URL")
        }
    }

    private static func systemAudioFinishPromotesReadableCanonicalWAV() throws {
        try withSystemAudioFixture { fixture in
            let controller = try SingleSourceRecordingJournalController(
                request: fixture.request,
                store: fixture.store
            )
            controller.sink.enqueue(Data([0x01, 0x00, 0x02, 0x00]))

            let promotedURL = try controller.finish()
            try verifyPromotedWAV(
                at: promotedURL,
                fixture: fixture,
                expectedDataByteCount: 4
            )
            let manifest = try fixture.store.loadManifest(
                recordingID: fixture.recordingID
            )
            try expectEqual(manifest.sourceMode, .systemAudio, "source mode")
            try expectEqual(manifest.sources[0].kind, .systemAudio, "source kind")
        }
    }

    private static func systemAudioExplicitDiscardRemovesInflightJournal() throws {
        try withSystemAudioFixture { fixture in
            let controller = try SingleSourceRecordingJournalController(
                request: fixture.request,
                store: fixture.store
            )
            controller.sink.enqueue(Data([0x01, 0x00]))
            try controller.discard()
            try controller.discard()

            try verifyDiscarded(fixture: fixture)
        }
    }

    private static func systemAudioRuntimeFailurePreservesRecoverableJournal() throws {
        try withSystemAudioFixture { fixture in
            let controller = try SingleSourceRecordingJournalController(
                request: fixture.request,
                store: fixture.store
            )
            controller.sink.enqueue(Data([0x01, 0x00, 0x02, 0x00]))
            try controller.preserveForRecovery()
            try controller.preserveForRecovery()

            try verifyRecoverable(
                fixture: fixture,
                sourceMode: .systemAudio,
                sourceKind: .systemAudio
            )
        }
    }

    private static func repeatedSystemAudioFinishReturnsSamePromotedArtifact() throws {
        try withSystemAudioFixture { fixture in
            let controller = try SingleSourceRecordingJournalController(
                request: fixture.request,
                store: fixture.store
            )
            controller.sink.enqueue(Data([0x01, 0x00]))
            let first = try controller.finish()
            let second = try controller.finish()
            try expectEqual(second, first, "repeated finish URL")
        }
    }

    private static func verifyDiscarded(
        fixture: Fixture
    ) throws {
        guard !FileManager.default.fileExists(
            atPath: fixture.store.recordingDirectory(
                recordingID: fixture.recordingID
            ).path
        ) else {
            throw TestFailure("explicit discard must remove inflight recording")
        }
        guard !FileManager.default.fileExists(
            atPath: fixture.store.permanentURL(
                recordingID: fixture.recordingID
            ).path
        ) else {
            throw TestFailure("explicit discard must not promote audio")
        }
    }

    private static func verifyRecoverable(
        fixture: Fixture,
        sourceMode: RecordingAudioSourceMode,
        sourceKind: RecordingJournalSourceKind
    ) throws {
        let manifest = try fixture.store.loadManifest(
            recordingID: fixture.recordingID
        )
        try expectEqual(manifest.state, .recoverable, "recoverable state")
        try expectEqual(
            manifest.sources[0].committedDataByteCount,
            4,
            "recoverable bytes"
        )
        try expectEqual(manifest.sourceMode, sourceMode, "source mode")
        try expectEqual(manifest.sources[0].kind, sourceKind, "source kind")
        guard FileManager.default.fileExists(
            atPath: fixture.store.recordingDirectory(
                recordingID: fixture.recordingID
            ).path
        ) else {
            throw TestFailure("runtime failure must preserve inflight journal")
        }
    }

    private static func verifyPromotedWAV(
        at promotedURL: URL,
        fixture: Fixture,
        expectedDataByteCount: UInt64
    ) throws {
        try expectEqual(
            promotedURL,
            fixture.store.permanentURL(recordingID: fixture.recordingID),
            "promoted URL"
        )
        let promotion = try RecordingCanonicalWAV.validateFile(at: promotedURL)
        try expectEqual(
            promotion.dataByteCount,
            expectedDataByteCount,
            "promoted bytes"
        )
        let audioFile = try AVAudioFile(forReading: promotedURL)
        try expectEqual(
            UInt64(audioFile.length),
            expectedDataByteCount / 2,
            "promoted audio frame count"
        )
        let manifest = try fixture.store.loadManifest(
            recordingID: fixture.recordingID
        )
        try expectEqual(manifest.state, .promoted, "promoted manifest state")
    }

    private static func withMicrophoneFixture(
        _ body: (Fixture) throws -> Void
    ) throws {
        try withFixture(
            sourceMode: .microphone,
            sourceKind: .microphone,
            sourceFileName: "microphone.wav.part",
            body
        )
    }

    private static func withSystemAudioFixture(
        _ body: (Fixture) throws -> Void
    ) throws {
        try withFixture(
            sourceMode: .systemAudio,
            sourceKind: .systemAudio,
            sourceFileName: "system-audio.wav.part",
            body
        )
    }

    private static func withFixture(
        sourceMode: RecordingAudioSourceMode,
        sourceKind: RecordingJournalSourceKind,
        sourceFileName: String,
        fileManager: FileManager = .default,
        _ body: (Fixture) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-single-source-journal-controller-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingID = UUID()
        let store = RecordingJournalStore(
            audioDirectory: root.appendingPathComponent(
                "audio",
                isDirectory: true
            ),
            fileManager: fileManager
        )
        let request = RecordingJournalCreateRequest(
            recordingID: recordingID,
            sourceID: UUID(),
            segmentID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            monotonicAnchorNanoseconds: 100,
            sourceMode: sourceMode,
            sourceKind: sourceKind,
            sourceFileName: sourceFileName,
            pipeline: makePipelineSnapshot()
        )
        try body(Fixture(
            recordingID: recordingID,
            store: store,
            request: request
        ))
    }

    private static func makePipelineSnapshot() -> RecordingPipelineSnapshot {
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

    private static func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ label: String
    ) throws {
        guard actual == expected else {
            throw TestFailure("\(label): expected \(expected), got \(actual)")
        }
    }

    private final class FailingTombstoneRemovalFileManager: FileManager {
        var failNextTombstoneRemoval = false

        override func removeItem(at URL: URL) throws {
            if failNextTombstoneRemoval,
               URL.lastPathComponent.hasPrefix(".discarded-") {
                failNextTombstoneRemoval = false
                throw CocoaError(.fileWriteUnknown)
            }
            try super.removeItem(at: URL)
        }
    }

    private struct Fixture {
        let recordingID: UUID
        let store: RecordingJournalStore
        let request: RecordingJournalCreateRequest
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
