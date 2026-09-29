import AVFoundation
import Foundation

@main
struct CombinedRecordingNormalStopIntegrationTests {
    static func main() {
        do {
            try alignedNormalStopPromotesOneWAV()
            try microphoneOnlyNormalStopPromotesDegradedWAV()
            try systemAudioOnlyNormalStopPromotesDegradedWAV()
            try committedBoundaryExcludesPhysicalTail()
            print("CombinedRecordingNormalStopIntegrationTests passed")
        } catch {
            fputs("CombinedRecordingNormalStopIntegrationTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func alignedNormalStopPromotesOneWAV() throws {
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

            let stopped = try journal.stopAndClose()
            try expectEqual(stopped.microphoneCommit.firstCommittedFrameOffset, 0, "microphone offset")
            try expectEqual(stopped.systemAudioCommit.firstCommittedFrameOffset, 2, "System Audio offset")
            let result = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )

            try expectEqual(result.mode, .combined, "aligned mode")
            try expectEqual(try readSamples(from: result.destinationURL), [800, 800, 2_400, 2_400], "aligned output")
            try expectEqual(
                try fixture.store.loadManifest(recordingID: fixture.recordingID).state,
                .promoted,
                "aligned lifecycle"
            )
        }
    }

    private static func microphoneOnlyNormalStopPromotesDegradedWAV() throws {
        try withFixture { fixture in
            let journal = try fixture.makeJournal()
            journal.microphoneSink.enqueue(
                pcmData([12, 34]),
                firstFrameMonotonicNanoseconds: fixture.anchor + 1_000_000_000
            )
            _ = try journal.stopAndClose()

            let result = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )
            try expectEqual(result.mode, .microphoneOnly, "microphone degraded mode")
            try expectEqual(try readSamples(from: result.destinationURL), [12, 34], "microphone degraded output")
        }
    }

    private static func systemAudioOnlyNormalStopPromotesDegradedWAV() throws {
        try withFixture { fixture in
            let journal = try fixture.makeJournal()
            journal.systemAudioSink.enqueue(
                pcmData([56, 78]),
                firstFrameMonotonicNanoseconds: fixture.anchor + 1_000_000_000
            )
            _ = try journal.stopAndClose()

            let result = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )
            try expectEqual(result.mode, .systemAudioOnly, "System Audio degraded mode")
            try expectEqual(try readSamples(from: result.destinationURL), [56, 78], "System Audio degraded output")
        }
    }

    private static func committedBoundaryExcludesPhysicalTail() throws {
        try withFixture { fixture in
            let journal = try fixture.makeJournal()
            journal.microphoneSink.enqueue(
                pcmData([90, 91]),
                firstFrameMonotonicNanoseconds: fixture.anchor
            )
            let stopped = try journal.stopAndClose()
            try appendRaw(Data([0xFF, 0x00, 0xEE, 0x00]), to: stopped.microphoneSourceURL)

            let result = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )
            try expectEqual(try readSamples(from: result.destinationURL), [90, 91], "committed boundary output")
        }
    }

    private static func withFixture(_ body: (Fixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-combined-normal-stop-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingID = UUID()
        let anchor: UInt64 = 2_000_000_000
        let store = RecordingJournalStore(audioDirectory: root.appendingPathComponent("audio", isDirectory: true))
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
            finalizer: CombinedRecordingArtifactFinalizer(store: store, mixdownService: AudioMixdownService())
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
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)!
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

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
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
