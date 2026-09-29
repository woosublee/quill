import AVFoundation
import Foundation

@main
struct CombinedRecordingArtifactFinalizerTests {
    static func main() {
        do {
            try alignedSourcesPromoteOneCombinedWAV()
            try microphoneOnlyPromotesDegradedWAV()
            try systemAudioOnlyPromotesDegradedWAV()
            try missingSourceFallsBackToSurvivingSource()
            try unusableSourcesRemainRecoverable()
            try uncommittedTailIsRemovedBeforeMixing()
            try repeatedFinalizationReusesPromotion()
            try promotedFinalizationUsesStoredModeWithoutReopeningSources()
            try conflictingPermanentFilePreservesJournalSources()
            print("CombinedRecordingArtifactFinalizerTests passed")
        } catch {
            fputs("CombinedRecordingArtifactFinalizerTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func alignedSourcesPromoteOneCombinedWAV() throws {
        try withFixture { fixture in
            let journal = try fixture.makeJournal()
            journal.microphoneSink.enqueue(
                pcmData([1_000, 1_000]),
                firstFrameMonotonicNanoseconds: fixture.anchor
            )
            journal.systemAudioSink.enqueue(
                pcmData([3_000, 3_000]),
                firstFrameMonotonicNanoseconds: fixture.anchor + 125_000
            )
            _ = try journal.stopAndClose()

            let result = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )

            try expectEqual(result.mode, .combined, "combined mode")
            try expectEqual(
                result.promotion.recoveryMode,
                .complete,
                "combined promotion recovery mode"
            )
            try expectEqual(
                result.destinationURL,
                fixture.store.permanentURL(recordingID: fixture.recordingID),
                "combined destination"
            )
            try expectEqual(
                try readSamples(from: result.destinationURL),
                [800, 800, 2_400, 2_400],
                "aligned combined samples"
            )
            let manifest = try fixture.store.loadManifest(
                recordingID: fixture.recordingID
            )
            try expectEqual(manifest.state, .promoted, "combined promoted state")
            try expectEqual(manifest.promotion, result.promotion, "combined promotion")
            try expectEqual(
                manifest.promotion?.recoveryMode,
                .complete,
                "persisted combined recovery mode"
            )
        }
    }

    private static func microphoneOnlyPromotesDegradedWAV() throws {
        try withFixture { fixture in
            let journal = try fixture.makeJournal()
            journal.microphoneSink.enqueue(
                pcmData([123, -456, 789]),
                firstFrameMonotonicNanoseconds: fixture.anchor + 500_000_000
            )
            _ = try journal.stopAndClose()

            let result = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )

            try expectEqual(result.mode, .microphoneOnly, "microphone-only mode")
            try expectEqual(
                result.promotion.recoveryMode,
                .microphoneOnly,
                "microphone-only promotion recovery mode"
            )
            try expectEqual(
                try fixture.store.loadManifest(recordingID: fixture.recordingID)
                    .promotion?.recoveryMode,
                .microphoneOnly,
                "persisted microphone-only recovery mode"
            )
            try expectEqual(
                try readSamples(from: result.destinationURL),
                [123, -456, 789],
                "microphone-only samples"
            )
        }
    }

    private static func systemAudioOnlyPromotesDegradedWAV() throws {
        try withFixture { fixture in
            let journal = try fixture.makeJournal()
            journal.systemAudioSink.enqueue(
                pcmData([321, -654]),
                firstFrameMonotonicNanoseconds: fixture.anchor + 750_000_000
            )
            _ = try journal.stopAndClose()

            let result = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )

            try expectEqual(result.mode, .systemAudioOnly, "System Audio-only mode")
            try expectEqual(
                result.promotion.recoveryMode,
                .systemAudioOnly,
                "System Audio-only promotion recovery mode"
            )
            try expectEqual(
                try fixture.store.loadManifest(recordingID: fixture.recordingID)
                    .promotion?.recoveryMode,
                .systemAudioOnly,
                "persisted System Audio-only recovery mode"
            )
            try expectEqual(
                try readSamples(from: result.destinationURL),
                [321, -654],
                "System Audio-only samples"
            )
        }
    }

    private static func missingSourceFallsBackToSurvivingSource() throws {
        try withFixture { fixture in
            let journal = try fixture.makeJournal()
            journal.microphoneSink.enqueue(
                pcmData([100, 200]),
                firstFrameMonotonicNanoseconds: fixture.anchor
            )
            journal.systemAudioSink.enqueue(
                pcmData([300, 400]),
                firstFrameMonotonicNanoseconds: fixture.anchor
            )
            let stopped = try journal.stopAndClose()
            try FileManager.default.removeItem(at: stopped.systemAudioSourceURL)

            let result = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )

            try expectEqual(result.mode, .microphoneOnly, "missing source degraded mode")
            try expectEqual(
                try readSamples(from: result.destinationURL),
                [100, 200],
                "missing source degraded samples"
            )
            let repeated = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )
            try expectEqual(
                repeated.mode,
                .microphoneOnly,
                "missing source repeated degraded mode"
            )
        }
    }

    private static func unusableSourcesRemainRecoverable() throws {
        try withFixture { fixture in
            let journal = try fixture.makeJournal()
            let stopped = try journal.stopAndClose()

            do {
                _ = try fixture.finalizer.finalizeAndPromote(
                    recordingID: fixture.recordingID
                )
                throw TestFailure("empty combined sources must not finalize")
            } catch CombinedRecordingArtifactFinalizerError.noRecoverableSources {
                // expected
            }

            guard FileManager.default.fileExists(atPath: stopped.microphoneSourceURL.path),
                  FileManager.default.fileExists(atPath: stopped.systemAudioSourceURL.path) else {
                throw TestFailure("unusable journal sources must be preserved")
            }
            try expectEqual(
                try fixture.store.loadManifest(recordingID: fixture.recordingID).state,
                .stopping,
                "unusable manifest state"
            )
        }
    }

    private static func uncommittedTailIsRemovedBeforeMixing() throws {
        try withFixture { fixture in
            let journal = try fixture.makeJournal()
            journal.microphoneSink.enqueue(
                pcmData([10, 20]),
                firstFrameMonotonicNanoseconds: fixture.anchor
            )
            let stopped = try journal.stopAndClose()
            try appendRaw(Data([0xFF, 0xEE, 0xDD]), to: stopped.microphoneSourceURL)

            let result = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )

            try expectEqual(
                try readSamples(from: result.destinationURL),
                [10, 20],
                "committed boundary samples"
            )
            try expectEqual(
                try fileSize(stopped.microphoneSourceURL),
                UInt64(RecordingCanonicalWAV.headerByteCount + 4),
                "committed source size"
            )
        }
    }

    private static func repeatedFinalizationReusesPromotion() throws {
        try withFixture { fixture in
            let journal = try fixture.makeJournal()
            journal.microphoneSink.enqueue(
                pcmData([1, 2]),
                firstFrameMonotonicNanoseconds: fixture.anchor
            )
            _ = try journal.stopAndClose()

            let first = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )
            let generation = try fixture.store.loadManifest(
                recordingID: fixture.recordingID
            ).generation
            let second = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )

            try expectEqual(second, first, "repeated combined finalization")
            try expectEqual(
                try fixture.store.loadManifest(recordingID: fixture.recordingID).generation,
                generation,
                "repeated promotion generation"
            )
        }
    }

    private static func promotedFinalizationUsesStoredModeWithoutReopeningSources() throws {
        try withFixture { fixture in
            let journal = try fixture.makeJournal()
            journal.microphoneSink.enqueue(
                pcmData([100, 200]),
                firstFrameMonotonicNanoseconds: fixture.anchor
            )
            let stopped = try journal.stopAndClose()
            let first = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )
            try expectEqual(
                first.promotion.recoveryMode,
                .microphoneOnly,
                "stored promoted mode"
            )
            try FileManager.default.removeItem(at: stopped.microphoneSourceURL)
            try FileManager.default.removeItem(at: stopped.systemAudioSourceURL)

            let repeated = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )

            try expectEqual(
                repeated.mode,
                .microphoneOnly,
                "repeated stored mode"
            )
            try expectEqual(
                repeated.promotion.recoveryMode,
                .microphoneOnly,
                "repeated promotion recovery mode"
            )
        }
    }

    private static func conflictingPermanentFilePreservesJournalSources() throws {
        try withFixture { fixture in
            let journal = try fixture.makeJournal()
            journal.microphoneSink.enqueue(
                pcmData([1, 2]),
                firstFrameMonotonicNanoseconds: fixture.anchor
            )
            let stopped = try journal.stopAndClose()
            let destination = fixture.store.permanentURL(
                recordingID: fixture.recordingID
            )
            try Data(repeating: 0xCC, count: 80).write(to: destination)
            let destinationBefore = try Data(contentsOf: destination)

            do {
                _ = try fixture.finalizer.finalizeAndPromote(
                    recordingID: fixture.recordingID
                )
                throw TestFailure("conflicting permanent file must fail")
            } catch RecordingArtifactFinalizerError.promotionConflict {
                // expected
            }

            try expectEqual(
                try Data(contentsOf: destination),
                destinationBefore,
                "conflicting permanent preservation"
            )
            guard FileManager.default.fileExists(atPath: stopped.microphoneSourceURL.path),
                  FileManager.default.fileExists(atPath: stopped.systemAudioSourceURL.path) else {
                throw TestFailure("promotion failure must preserve journal sources")
            }
        }
    }

    private static func withFixture(
        _ body: (Fixture) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-combined-artifact-finalizer-tests-\(UUID().uuidString)",
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
        try body(Fixture(
            recordingID: recordingID,
            anchor: anchor,
            store: store,
            request: request,
            finalizer: CombinedRecordingArtifactFinalizer(
                store: store,
                mixdownService: AudioMixdownService()
            )
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

    private static func pcmData(_ samples: [Int16]) -> Data {
        var data = Data()
        for sample in samples {
            let value = UInt16(bitPattern: sample)
            data.append(UInt8(value & 0x00FF))
            data.append(UInt8(value >> 8))
        }
        return data
    }

    private static func readSamples(from url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frameCount
        )!
        try file.read(into: buffer, frameCount: frameCount)
        guard let samples = buffer.floatChannelData?[0] else {
            throw TestFailure("missing readable audio samples")
        }
        return (0..<Int(buffer.frameLength)).map {
            let scaled = Int((samples[$0] * 32_768).rounded())
            return Int16(min(Int(Int16.max), max(Int(Int16.min), scaled)))
        }
    }

    private static func appendRaw(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private static func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw TestFailure("missing file size")
        }
        return size.uint64Value
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
        let store: RecordingJournalStore
        let request: CombinedRecordingJournalCreateRequest
        let finalizer: CombinedRecordingArtifactFinalizer

        func makeJournal() throws -> LegacyCombinedJournal {
            try LegacyCombinedJournal(request: request, store: store)
        }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}

/// Writes a legacy combined-layout journal directly through the store and
/// PCM writers so recovery of journals left by older builds stays covered.
private struct LegacyCombinedJournal {
    struct StopResult {
        let microphoneSourceURL: URL
        let microphoneCommit: RecordingJournalSourceCommit
        let systemAudioSourceURL: URL
        let systemAudioCommit: RecordingJournalSourceCommit
    }

    let microphoneSink: RecordingJournalSourceSink
    let systemAudioSink: RecordingJournalSourceSink

    private let recordingID: UUID
    private let store: RecordingJournalStore
    private let session: CombinedRecordingJournalSession
    private let microphoneWriter: RecordingPCMJournalWriter
    private let systemAudioWriter: RecordingPCMJournalWriter

    init(
        request: CombinedRecordingJournalCreateRequest,
        store: RecordingJournalStore
    ) throws {
        let session = try store.createCombined(request)
        let microphoneWriter = try RecordingPCMJournalWriter(
            session: session.microphoneSession,
            store: store
        )
        let systemAudioWriter = try RecordingPCMJournalWriter(
            session: session.systemAudioSession,
            store: store
        )
        self.recordingID = request.recordingID
        self.store = store
        self.session = session
        self.microphoneWriter = microphoneWriter
        self.systemAudioWriter = systemAudioWriter
        self.microphoneSink = RecordingJournalSourceSink(
            writer: microphoneWriter,
            monotonicAnchorNanoseconds: request.monotonicAnchorNanoseconds
        )
        self.systemAudioSink = RecordingJournalSourceSink(
            writer: systemAudioWriter,
            monotonicAnchorNanoseconds: request.monotonicAnchorNanoseconds
        )
    }

    func stopAndClose() throws -> StopResult {
        _ = try store.transition(recordingID: recordingID, to: .stopping)
        let microphoneCommit = try microphoneWriter.drainAndCloseSnapshot()
        let systemAudioCommit = try systemAudioWriter.drainAndCloseSnapshot()
        _ = try store.recordCheckpoints(
            recordingID: recordingID,
            commitsBySourceID: [
                session.microphoneSession.sourceID: microphoneCommit,
                session.systemAudioSession.sourceID: systemAudioCommit
            ]
        )
        return StopResult(
            microphoneSourceURL: session.microphoneSession.sourceURL,
            microphoneCommit: microphoneCommit,
            systemAudioSourceURL: session.systemAudioSession.sourceURL,
            systemAudioCommit: systemAudioCommit
        )
    }
}
