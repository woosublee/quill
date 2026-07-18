import Foundation

@main
struct RecordingJournalRecoveryExecutorTests {
    static func main() {
        do {
            try microphoneRecordingJournalIsRecoveredAndPromoted()
            try promotedMicrophoneArtifactIsReusedIdempotently()
            try systemAudioRecordingJournalIsRecoveredAndPromoted()
            try promotedSystemAudioArtifactIsReusedIdempotently()
            try manualRecoveryCandidateIsPreserved()
            print("RecordingJournalRecoveryExecutorTests passed")
        } catch {
            fputs("RecordingJournalRecoveryExecutorTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func microphoneRecordingJournalIsRecoveredAndPromoted() throws {
        try withMicrophoneFixture { fixture in
            let result = try recoverCheckpointedJournal(fixture)
            try expectEqual(result.manifest.sourceMode, .microphone, "source mode")
            try expectEqual(
                result.manifest.sources[0].kind,
                .microphone,
                "source kind"
            )
        }
    }

    private static func promotedMicrophoneArtifactIsReusedIdempotently() throws {
        try withMicrophoneFixture { fixture in
            try verifyPromotedArtifactIsReused(fixture)
        }
    }

    private static func systemAudioRecordingJournalIsRecoveredAndPromoted() throws {
        try withSystemAudioFixture { fixture in
            let result = try recoverCheckpointedJournal(fixture)
            try expectEqual(result.manifest.sourceMode, .systemAudio, "source mode")
            try expectEqual(
                result.manifest.sources[0].kind,
                .systemAudio,
                "source kind"
            )
            guard FileManager.default.fileExists(atPath: result.audioURL.path) else {
                throw TestFailure("recovered permanent audio is missing")
            }
            let manifest = try fixture.store.loadManifest(
                recordingID: fixture.recordingID
            )
            try expectEqual(manifest.state, .promoted, "recovered manifest state")
        }
    }

    private static func promotedSystemAudioArtifactIsReusedIdempotently() throws {
        try withSystemAudioFixture { fixture in
            let first = try verifyPromotedArtifactIsReused(fixture)
            try expectEqual(first.manifest.sourceMode, .systemAudio, "source mode")
        }
    }

    private static func recoverCheckpointedJournal(
        _ fixture: Fixture
    ) throws -> RecoveredRecordingArtifact {
        let session = try fixture.store.createSingleSource(fixture.request)
        let writer = try RecordingPCMJournalWriter(
            session: session,
            store: fixture.store
        )
        writer.enqueue(Data([0x01, 0x00, 0x02, 0x00]))
        _ = try writer.checkpoint()

        let executor = RecordingJournalRecoveryExecutor(store: fixture.store)
        let results = executor.recoverAll()
        try expectEqual(results.count, 1, "recovery result count")
        let result = try requireRecovered(results[0])
        try expectEqual(result.recordingID, fixture.recordingID, "recording ID")
        try expectEqual(result.promotion.dataByteCount, 4, "promotion bytes")
        guard FileManager.default.fileExists(atPath: result.audioURL.path) else {
            throw TestFailure("recovered permanent audio is missing")
        }
        let manifest = try fixture.store.loadManifest(
            recordingID: fixture.recordingID
        )
        try expectEqual(manifest.state, .promoted, "recovered manifest state")
        return result
    }

    @discardableResult
    private static func verifyPromotedArtifactIsReused(
        _ fixture: Fixture
    ) throws -> RecoveredRecordingArtifact {
        let controller = try SingleSourceRecordingJournalController(
            request: fixture.request,
            store: fixture.store
        )
        controller.sink.enqueue(Data([0x01, 0x00]))
        let promotedURL = try controller.finish()

        let executor = RecordingJournalRecoveryExecutor(store: fixture.store)
        let first = try requireRecovered(executor.recoverAll()[0])
        let second = try requireRecovered(executor.recoverAll()[0])
        try expectEqual(first.audioURL, promotedURL, "first reused URL")
        try expectEqual(second, first, "idempotent promoted recovery")
        return first
    }

    private static func manualRecoveryCandidateIsPreserved() throws {
        try withFixture(
            sourceMode: .microphone,
            sourceKind: .microphone,
            sourceFileName: "microphone.wav.part"
        ) { fixture in
            let directory = fixture.store.recordingDirectory(
                recordingID: fixture.recordingID
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let marker = directory.appendingPathComponent("keep-me.bin")
            try Data([0xCA, 0xFE]).write(to: marker)

            let executor = RecordingJournalRecoveryExecutor(store: fixture.store)
            let results = executor.recoverAll()
            try expectEqual(results.count, 1, "manual result count")
            guard case .manualRecoveryRequired(let candidate) = results[0] else {
                throw TestFailure("missing manifest must require manual recovery")
            }
            guard candidate.diagnostics.contains(.missingManifest) else {
                throw TestFailure("missing manifest diagnostic not preserved")
            }
            guard FileManager.default.fileExists(atPath: marker.path) else {
                throw TestFailure("manual recovery files must not be deleted")
            }
        }
    }

    private static func requireRecovered(
        _ result: RecordingJournalRecoveryResult
    ) throws -> RecoveredRecordingArtifact {
        guard case .recovered(let artifact) = result else {
            throw TestFailure("expected recovered artifact, got \(result)")
        }
        return artifact
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
        _ body: (Fixture) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-recording-recovery-executor-tests-\(UUID().uuidString)",
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
            )
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
