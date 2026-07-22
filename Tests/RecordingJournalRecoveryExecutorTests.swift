import AVFoundation
import Foundation

@main
struct RecordingJournalRecoveryExecutorTests {
    static func main() {
        do {
            try microphoneRecordingJournalIsRecoveredAndPromoted()
            try promotedMicrophoneArtifactIsReusedIdempotently()
            try systemAudioRecordingJournalIsRecoveredAndPromoted()
            try promotedSystemAudioArtifactIsReusedIdempotently()
            try combinedRecordingJournalIsRecoveredWithAlignment()
            try microphoneOnlyCombinedJournalIsRecoveredWithoutLeadingSilence()
            try systemAudioOnlyCombinedJournalIsRecoveredWithoutLeadingSilence()
            try unusableCombinedSourcesRemainManual()
            try unexpectedCombinedSourceIOFailureIsPreserved()
            try combinedPromotionRenameCrashWindowReusesSameInode()
            try segmentedRecordingJournalIsRecoveredCompletely()
            try damagedSegmentedJournalIsRecoveredPartially()
            try unusableSegmentedJournalRemainsManual()
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
            try expectEqual(result.mode, .complete, "microphone recovery mode")
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
            try expectEqual(result.mode, .complete, "System Audio recovery mode")
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

    private static func combinedRecordingJournalIsRecoveredWithAlignment() throws {
        try withCombinedFixture { fixture in
            try checkpointCombinedJournal(
                fixture,
                microphoneSamples: [1_000, 1_000],
                microphoneTimestamp: fixture.anchor,
                systemAudioSamples: [3_000, 3_000],
                systemAudioTimestamp: fixture.anchor + 125_000
            )

            let artifact = try requireRecovered(
                RecordingJournalRecoveryExecutor(store: fixture.store)
                    .recoverAll()[0]
            )

            try expectEqual(artifact.mode, .complete, "combined recovery mode")
            try expectEqual(
                artifact.promotion.recoveryMode,
                .complete,
                "combined promotion mode"
            )
            try expectEqual(
                try readPCM16Samples(from: artifact.audioURL),
                [800, 800, 2_400, 2_400],
                "combined aligned samples"
            )
            try expectEqual(artifact.manifest.state, .promoted, "combined promoted state")
        }
    }

    private static func microphoneOnlyCombinedJournalIsRecoveredWithoutLeadingSilence() throws {
        try withCombinedFixture { fixture in
            try checkpointCombinedJournal(
                fixture,
                microphoneSamples: [123, -456, 789],
                microphoneTimestamp: fixture.anchor + 500_000_000,
                systemAudioSamples: [],
                systemAudioTimestamp: fixture.anchor
            )

            let artifact = try requireRecovered(
                RecordingJournalRecoveryExecutor(store: fixture.store)
                    .recoverAll()[0]
            )

            try expectEqual(artifact.mode, .microphoneOnly, "microphone-only mode")
            try expectEqual(
                artifact.promotion.recoveryMode,
                .microphoneOnly,
                "microphone-only promotion mode"
            )
            try expectEqual(
                try readPCM16Samples(from: artifact.audioURL),
                [123, -456, 789],
                "microphone-only samples"
            )
        }
    }

    private static func systemAudioOnlyCombinedJournalIsRecoveredWithoutLeadingSilence() throws {
        try withCombinedFixture { fixture in
            try checkpointCombinedJournal(
                fixture,
                microphoneSamples: [],
                microphoneTimestamp: fixture.anchor,
                systemAudioSamples: [321, -654],
                systemAudioTimestamp: fixture.anchor + 750_000_000
            )

            let artifact = try requireRecovered(
                RecordingJournalRecoveryExecutor(store: fixture.store)
                    .recoverAll()[0]
            )

            try expectEqual(artifact.mode, .systemAudioOnly, "System Audio-only mode")
            try expectEqual(
                artifact.promotion.recoveryMode,
                .systemAudioOnly,
                "System Audio-only promotion mode"
            )
            try expectEqual(
                try readPCM16Samples(from: artifact.audioURL),
                [321, -654],
                "System Audio-only samples"
            )
        }
    }

    private static func unusableCombinedSourcesRemainManual() throws {
        try withCombinedFixture { fixture in
            try checkpointCombinedJournal(
                fixture,
                microphoneSamples: [],
                microphoneTimestamp: fixture.anchor,
                systemAudioSamples: [],
                systemAudioTimestamp: fixture.anchor
            )
            let directory = fixture.store.recordingDirectory(
                recordingID: fixture.recordingID
            )

            let result = RecordingJournalRecoveryExecutor(store: fixture.store)
                .recoverAll()[0]

            guard case .manualRecoveryRequired = result else {
                throw TestFailure("empty combined sources must remain manual, got \(result)")
            }
            guard FileManager.default.fileExists(atPath: directory.path) else {
                throw TestFailure("manual combined journal must be preserved")
            }
        }
    }

    private static func unexpectedCombinedSourceIOFailureIsPreserved() throws {
        try withCombinedFixture { fixture in
            let sourceURLs = try checkpointCombinedJournal(
                fixture,
                microphoneSamples: [100, 200],
                microphoneTimestamp: fixture.anchor,
                systemAudioSamples: [300, 400],
                systemAudioTimestamp: fixture.anchor
            )
            try FileManager.default.setAttributes(
                [.immutable: true],
                ofItemAtPath: sourceURLs.systemAudio.path
            )
            defer {
                try? FileManager.default.setAttributes(
                    [.immutable: false],
                    ofItemAtPath: sourceURLs.systemAudio.path
                )
            }
            let directory = fixture.store.recordingDirectory(
                recordingID: fixture.recordingID
            )

            let result = RecordingJournalRecoveryExecutor(store: fixture.store)
                .recoverAll()[0]

            guard case .failed = result else {
                throw TestFailure("unexpected combined I/O must fail, got \(result)")
            }
            guard FileManager.default.fileExists(atPath: directory.path),
                  FileManager.default.fileExists(atPath: sourceURLs.microphone.path),
                  FileManager.default.fileExists(atPath: sourceURLs.systemAudio.path) else {
                throw TestFailure("failed combined recovery must preserve journal files")
            }
        }
    }

    private static func combinedPromotionRenameCrashWindowReusesSameInode() throws {
        try withCombinedFixture { fixture in
            try checkpointCombinedJournal(
                fixture,
                microphoneSamples: [100, 200],
                microphoneTimestamp: fixture.anchor,
                systemAudioSamples: [300, 400],
                systemAudioTimestamp: fixture.anchor
            )
            _ = try fixture.store.transition(
                recordingID: fixture.recordingID,
                to: .recoverable
            )
            let manifestURL = fixture.store.recordingDirectory(
                recordingID: fixture.recordingID
            ).appendingPathComponent("manifest.json")
            let prePromotionManifest = try Data(contentsOf: manifestURL)
            let promoted = try CombinedRecordingArtifactFinalizer(
                store: fixture.store,
                mixdownService: AudioMixdownService()
            ).finalizeAndPromote(recordingID: fixture.recordingID)
            try prePromotionManifest.write(to: manifestURL, options: .atomic)
            let inode = try inodeNumber(promoted.destinationURL)
            let executor = RecordingJournalRecoveryExecutor(store: fixture.store)

            let first = try requireRecovered(executor.recoverAll()[0])
            let second = try requireRecovered(executor.recoverAll()[0])

            try expectEqual(first.audioURL, promoted.destinationURL, "crash-window URL")
            try expectEqual(second.audioURL, first.audioURL, "repeated crash-window URL")
            try expectEqual(try inodeNumber(first.audioURL), inode, "first crash-window inode")
            try expectEqual(try inodeNumber(second.audioURL), inode, "second crash-window inode")
            try expectEqual(second.manifest.state, .promoted, "crash-window promoted state")
        }
    }

    private static func segmentedRecordingJournalIsRecoveredCompletely() throws {
        try withSegmentedFixture { fixture in
            let controller = try fixture.makeController()
            controller.activeSegment.microphoneSink?.enqueue(pcmData([1, 2]))
            let next = try controller.switchSegment(
                segmentID: UUID(),
                sources: [RecordingJournalSegmentSourceRequest(
                    id: UUID(),
                    kind: .systemAudio
                )]
            )
            next.systemAudioSink?.enqueue(pcmData([3, 4]))
            try controller.checkpoint()

            let artifact = try requireRecovered(
                RecordingJournalRecoveryExecutor(store: fixture.store)
                    .recoverAll()[0]
            )

            try expectEqual(artifact.mode, .complete, "segmented complete mode")
            try expectEqual(
                try readPCM16Samples(from: artifact.audioURL),
                [1, 2, 3, 4],
                "segmented complete samples"
            )
        }
    }

    private static func damagedSegmentedJournalIsRecoveredPartially() throws {
        try withSegmentedFixture { fixture in
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
            try controller.checkpoint()
            let manifest = try fixture.store.loadManifest(recordingID: fixture.recordingID)
            let source = manifest.sources.first { $0.id == damagedSourceID }!
            try FileManager.default.removeItem(at: try fixture.store.sourceURL(
                recordingID: fixture.recordingID,
                fileName: source.fileName
            ))

            let artifact = try requireRecovered(
                RecordingJournalRecoveryExecutor(store: fixture.store)
                    .recoverAll()[0]
            )

            try expectEqual(artifact.mode, .partial, "segmented partial mode")
            try expectEqual(
                artifact.promotion.resolvedRecoveryIssues,
                [RecordingRecoveryIssue(
                    segmentSequence: 1,
                    sourceKind: .systemAudio,
                    reason: .sourceMissing
                )],
                "segmented partial issues"
            )
            try expectEqual(
                try readPCM16Samples(from: artifact.audioURL),
                [1, 2],
                "segmented partial samples"
            )
        }
    }

    private static func unusableSegmentedJournalRemainsManual() throws {
        try withSegmentedFixture { fixture in
            let controller = try fixture.makeController()
            try controller.checkpoint()
            let directory = fixture.store.recordingDirectory(
                recordingID: fixture.recordingID
            )

            let result = RecordingJournalRecoveryExecutor(store: fixture.store)
                .recoverAll()[0]

            guard case .manualRecoveryRequired = result else {
                throw TestFailure("empty segmented journal must remain manual")
            }
            guard FileManager.default.fileExists(atPath: directory.path) else {
                throw TestFailure("manual segmented journal must be preserved")
            }
        }
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

    @discardableResult
    private static func checkpointCombinedJournal(
        _ fixture: CombinedFixture,
        microphoneSamples: [Int16],
        microphoneTimestamp: UInt64,
        systemAudioSamples: [Int16],
        systemAudioTimestamp: UInt64
    ) throws -> (microphone: URL, systemAudio: URL) {
        let controller = try CombinedRecordingJournalController(
            request: fixture.request,
            store: fixture.store
        )
        if !microphoneSamples.isEmpty {
            controller.microphoneSink.enqueue(
                pcmData(microphoneSamples),
                firstFrameMonotonicNanoseconds: microphoneTimestamp
            )
        }
        if !systemAudioSamples.isEmpty {
            controller.systemAudioSink.enqueue(
                pcmData(systemAudioSamples),
                firstFrameMonotonicNanoseconds: systemAudioTimestamp
            )
        }
        try controller.checkpoint()
        return (
            try fixture.store.sourceURL(
                recordingID: fixture.recordingID,
                fileName: "microphone.wav.part"
            ),
            try fixture.store.sourceURL(
                recordingID: fixture.recordingID,
                fileName: "system-audio.wav.part"
            )
        )
    }

    private static func withCombinedFixture(
        _ body: (CombinedFixture) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-combined-recovery-executor-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
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
            pipeline: makePipelineSnapshot()
        )
        try body(CombinedFixture(
            recordingID: recordingID,
            anchor: anchor,
            store: store,
            request: request
        ))
    }

    private static func withSegmentedFixture(
        _ body: (SegmentedFixture) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-segmented-recovery-executor-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingID = UUID()
        let store = RecordingJournalStore(
            audioDirectory: root.appendingPathComponent("audio", isDirectory: true)
        )
        try body(SegmentedFixture(
            recordingID: recordingID,
            store: store,
            anchor: 1_000_000_000
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

    private static func readPCM16Samples(from url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        guard data.count >= RecordingCanonicalWAV.headerByteCount else {
            throw TestFailure("recovered WAV is too short")
        }
        let payload = data.dropFirst(RecordingCanonicalWAV.headerByteCount)
        guard payload.count.isMultiple(of: 2) else {
            throw TestFailure("recovered WAV has an odd PCM payload")
        }
        return stride(from: 0, to: payload.count, by: 2).map { index in
            let lower = UInt16(payload[payload.startIndex + index])
            let upper = UInt16(payload[payload.startIndex + index + 1]) << 8
            return Int16(bitPattern: lower | upper)
        }
    }

    private static func inodeNumber(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.systemFileNumber] as? NSNumber else {
            throw TestFailure("missing inode for \(url.path)")
        }
        return number.uint64Value
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

    private struct CombinedFixture {
        let recordingID: UUID
        let anchor: UInt64
        let store: RecordingJournalStore
        let request: CombinedRecordingJournalCreateRequest
    }

    private struct SegmentedFixture {
        let recordingID: UUID
        let store: RecordingJournalStore
        let anchor: UInt64

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
                    pipeline: makePipelineSnapshot()
                ),
                store: store
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
