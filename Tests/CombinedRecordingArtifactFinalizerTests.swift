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
            try promotedModePropagatesUnexpectedSourceIOFailure()
            try conflictingPermanentFilePreservesJournalSources()
            print("CombinedRecordingArtifactFinalizerTests passed")
        } catch {
            fputs("CombinedRecordingArtifactFinalizerTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func alignedSourcesPromoteOneCombinedWAV() throws {
        try withFixture { fixture in
            let controller = try fixture.makeController()
            controller.microphoneSink.enqueue(
                pcmData([1_000, 1_000]),
                firstFrameMonotonicNanoseconds: fixture.anchor
            )
            controller.systemAudioSink.enqueue(
                pcmData([3_000, 3_000]),
                firstFrameMonotonicNanoseconds: fixture.anchor + 125_000
            )
            _ = try controller.stopAndClose()

            let result = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )

            try expectEqual(result.mode, .combined, "combined mode")
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
        }
    }

    private static func microphoneOnlyPromotesDegradedWAV() throws {
        try withFixture { fixture in
            let controller = try fixture.makeController()
            controller.microphoneSink.enqueue(
                pcmData([123, -456, 789]),
                firstFrameMonotonicNanoseconds: fixture.anchor + 500_000_000
            )
            _ = try controller.stopAndClose()

            let result = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )

            try expectEqual(result.mode, .microphoneOnly, "microphone-only mode")
            try expectEqual(
                try readSamples(from: result.destinationURL),
                [123, -456, 789],
                "microphone-only samples"
            )
        }
    }

    private static func systemAudioOnlyPromotesDegradedWAV() throws {
        try withFixture { fixture in
            let controller = try fixture.makeController()
            controller.systemAudioSink.enqueue(
                pcmData([321, -654]),
                firstFrameMonotonicNanoseconds: fixture.anchor + 750_000_000
            )
            _ = try controller.stopAndClose()

            let result = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )

            try expectEqual(result.mode, .systemAudioOnly, "System Audio-only mode")
            try expectEqual(
                try readSamples(from: result.destinationURL),
                [321, -654],
                "System Audio-only samples"
            )
        }
    }

    private static func missingSourceFallsBackToSurvivingSource() throws {
        try withFixture { fixture in
            let controller = try fixture.makeController()
            controller.microphoneSink.enqueue(
                pcmData([100, 200]),
                firstFrameMonotonicNanoseconds: fixture.anchor
            )
            controller.systemAudioSink.enqueue(
                pcmData([300, 400]),
                firstFrameMonotonicNanoseconds: fixture.anchor
            )
            let stopped = try controller.stopAndClose()
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
            let controller = try fixture.makeController()
            let stopped = try controller.stopAndClose()

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
            let controller = try fixture.makeController()
            controller.microphoneSink.enqueue(
                pcmData([10, 20]),
                firstFrameMonotonicNanoseconds: fixture.anchor
            )
            let stopped = try controller.stopAndClose()
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
            let controller = try fixture.makeController()
            controller.microphoneSink.enqueue(
                pcmData([1, 2]),
                firstFrameMonotonicNanoseconds: fixture.anchor
            )
            _ = try controller.stopAndClose()

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

    private static func promotedModePropagatesUnexpectedSourceIOFailure() throws {
        try withFixture { fixture in
            let controller = try fixture.makeController()
            controller.microphoneSink.enqueue(
                pcmData([100, 200]),
                firstFrameMonotonicNanoseconds: fixture.anchor
            )
            controller.systemAudioSink.enqueue(
                pcmData([300, 400]),
                firstFrameMonotonicNanoseconds: fixture.anchor
            )
            let stopped = try controller.stopAndClose()
            _ = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )
            try FileManager.default.setAttributes(
                [.immutable: true],
                ofItemAtPath: stopped.systemAudioSourceURL.path
            )
            defer {
                try? FileManager.default.setAttributes(
                    [.immutable: false],
                    ofItemAtPath: stopped.systemAudioSourceURL.path
                )
            }

            do {
                _ = try fixture.finalizer.finalizeAndPromote(
                    recordingID: fixture.recordingID
                )
                throw TestFailure(
                    "promoted mode must propagate unexpected source I/O failure"
                )
            } catch let error as TestFailure {
                throw error
            } catch CombinedRecordingArtifactFinalizerError.noRecoverableSources {
                throw TestFailure(
                    "unexpected source I/O failure must not become noRecoverableSources"
                )
            } catch {
                // expected
            }
        }
    }

    private static func conflictingPermanentFilePreservesJournalSources() throws {
        try withFixture { fixture in
            let controller = try fixture.makeController()
            controller.microphoneSink.enqueue(
                pcmData([1, 2]),
                firstFrameMonotonicNanoseconds: fixture.anchor
            )
            let stopped = try controller.stopAndClose()
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
                preserveExactWording: false,
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

        func makeController() throws -> CombinedRecordingJournalController {
            try CombinedRecordingJournalController(request: request, store: store)
        }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
