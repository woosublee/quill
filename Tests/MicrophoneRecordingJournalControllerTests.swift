import AVFoundation
import Foundation

@main
struct MicrophoneRecordingJournalControllerTests {
    static func main() {
        do {
            try finishPromotesReadableCanonicalWAV()
            try explicitDiscardRemovesInflightJournal()
            try runtimeFailurePreservesRecoverableJournal()
            try repeatedFinishReturnsSamePromotedArtifact()
            print("MicrophoneRecordingJournalControllerTests passed")
        } catch {
            fputs("MicrophoneRecordingJournalControllerTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func finishPromotesReadableCanonicalWAV() throws {
        try withFixture { fixture in
            let controller = try MicrophoneRecordingJournalController(
                request: fixture.request,
                store: fixture.store
            )
            controller.sink.enqueue(Data([0x01, 0x00, 0x02, 0x00]))
            try controller.checkpoint()

            let checkpointed = try fixture.store.loadManifest(recordingID: fixture.recordingID)
            try expectEqual(checkpointed.state, .recording, "checkpoint state")
            try expectEqual(checkpointed.sources[0].committedDataByteCount, 4, "checkpoint bytes")

            let promotedURL = try controller.finish()
            try expectEqual(promotedURL, fixture.store.permanentURL(recordingID: fixture.recordingID), "promoted URL")
            let promotion = try RecordingCanonicalWAV.validateFile(at: promotedURL)
            try expectEqual(promotion.dataByteCount, 4, "promoted bytes")

            let audioFile = try AVAudioFile(forReading: promotedURL)
            try expectEqual(Int(audioFile.length), 2, "promoted audio frame count")
            let manifest = try fixture.store.loadManifest(recordingID: fixture.recordingID)
            try expectEqual(manifest.state, .promoted, "promoted manifest state")
        }
    }

    private static func explicitDiscardRemovesInflightJournal() throws {
        try withFixture { fixture in
            let controller = try MicrophoneRecordingJournalController(
                request: fixture.request,
                store: fixture.store
            )
            controller.sink.enqueue(Data([0x01, 0x00]))
            try controller.discard()
            try controller.discard()

            guard !FileManager.default.fileExists(
                atPath: fixture.store.recordingDirectory(recordingID: fixture.recordingID).path
            ) else {
                throw TestFailure("explicit discard must remove inflight recording")
            }
            guard !FileManager.default.fileExists(
                atPath: fixture.store.permanentURL(recordingID: fixture.recordingID).path
            ) else {
                throw TestFailure("explicit discard must not promote audio")
            }
        }
    }

    private static func runtimeFailurePreservesRecoverableJournal() throws {
        try withFixture { fixture in
            let controller = try MicrophoneRecordingJournalController(
                request: fixture.request,
                store: fixture.store
            )
            controller.sink.enqueue(Data([0x01, 0x00, 0x02, 0x00]))
            try controller.preserveForRecovery()
            try controller.preserveForRecovery()

            let manifest = try fixture.store.loadManifest(recordingID: fixture.recordingID)
            try expectEqual(manifest.state, .recoverable, "recoverable state")
            try expectEqual(manifest.sources[0].committedDataByteCount, 4, "recoverable bytes")
            guard FileManager.default.fileExists(
                atPath: fixture.store.recordingDirectory(recordingID: fixture.recordingID).path
            ) else {
                throw TestFailure("runtime failure must preserve inflight journal")
            }
        }
    }

    private static func repeatedFinishReturnsSamePromotedArtifact() throws {
        try withFixture { fixture in
            let controller = try MicrophoneRecordingJournalController(
                request: fixture.request,
                store: fixture.store
            )
            controller.sink.enqueue(Data([0x01, 0x00]))
            let first = try controller.finish()
            let second = try controller.finish()
            try expectEqual(second, first, "repeated finish URL")
        }
    }

    private static func withFixture(_ body: (Fixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-microphone-journal-controller-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingID = UUID()
        let audioDirectory = root.appendingPathComponent("audio", isDirectory: true)
        let store = RecordingJournalStore(audioDirectory: audioDirectory)
        let request = RecordingJournalCreateRequest(
            recordingID: recordingID,
            sourceID: UUID(),
            segmentID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            monotonicAnchorNanoseconds: 100,
            sourceMode: .microphone,
            sourceKind: .microphone,
            sourceFileName: "microphone.wav.part",
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
