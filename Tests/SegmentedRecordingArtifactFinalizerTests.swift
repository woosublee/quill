import AVFoundation
import Foundation

@main
struct SegmentedRecordingArtifactFinalizerTests {
    static func main() {
        do {
            try completeSegmentsPromoteOneOrderedWAV()
            try damagedSourcesProduceDeterministicPartialRecovery()
            try emptyCompanionSourceProducesPartialRecovery()
            try emptyPreparationSegmentDoesNotMakeRecoveryPartial()
            try noUsableAudioPreservesInflightRecording()
            try promotedPartialResultReusesStoredMetadataWithoutSources()
            print("SegmentedRecordingArtifactFinalizerTests passed")
        } catch {
            fputs("SegmentedRecordingArtifactFinalizerTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func completeSegmentsPromoteOneOrderedWAV() throws {
        try withFixture { fixture in
            let controller = try fixture.makeController()
            controller.activeSegment.microphoneSink?.enqueue(
                pcmData([1, 2]),
                firstFrameMonotonicNanoseconds: fixture.anchor
            )
            let combined = try controller.switchSegment(
                segmentID: UUID(),
                sources: [
                    RecordingJournalSegmentSourceRequest(id: UUID(), kind: .microphone),
                    RecordingJournalSegmentSourceRequest(id: UUID(), kind: .systemAudio)
                ]
            )
            combined.microphoneSink?.enqueue(
                pcmData([1_000, 1_000]),
                firstFrameMonotonicNanoseconds: fixture.anchor + 1_000_000_000
            )
            combined.systemAudioSink?.enqueue(
                pcmData([3_000, 3_000]),
                firstFrameMonotonicNanoseconds: fixture.anchor + 1_000_062_500
            )
            let system = try controller.switchSegment(
                segmentID: UUID(),
                sources: [RecordingJournalSegmentSourceRequest(
                    id: UUID(),
                    kind: .systemAudio
                )]
            )
            system.systemAudioSink?.enqueue(pcmData([7, 8, 9]))
            try controller.stopAndClose()

            let sourceURLs = try fixture.store.loadManifest(
                recordingID: fixture.recordingID
            ).sources.map {
                try fixture.store.sourceURL(
                    recordingID: fixture.recordingID,
                    fileName: $0.fileName
                )
            }
            let result = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )

            try expectEqual(result.mode, .complete, "complete mode")
            try expectEqual(result.promotion.recoveryMode, .complete, "complete promotion mode")
            try expectEqual(result.promotion.resolvedRecoveryIssues, [], "complete issues")
            try expectEqual(
                result.destinationURL,
                fixture.store.permanentURL(recordingID: fixture.recordingID),
                "recording-ID destination"
            )
            try expectEqual(
                try readSamples(from: result.destinationURL),
                [1, 2, 800, 3_200, 2_400, 7, 8, 9],
                "ordered complete samples"
            )
            try expectEqual(
                try fixture.store.loadManifest(recordingID: fixture.recordingID).state,
                .promoted,
                "complete promoted state"
            )
            guard sourceURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                throw TestFailure("source journals must remain until history finalization")
            }
        }
    }

    private static func damagedSourcesProduceDeterministicPartialRecovery() throws {
        try withFixture { fixture in
            let controller = try fixture.makeController()
            controller.activeSegment.microphoneSink?.enqueue(pcmData([10, 11]))

            let damagedSegmentID = UUID()
            let damagedMicrophoneID = UUID()
            let missingSystemID = UUID()
            let damaged = try controller.switchSegment(
                segmentID: damagedSegmentID,
                sources: [
                    RecordingJournalSegmentSourceRequest(
                        id: damagedMicrophoneID,
                        kind: .microphone
                    ),
                    RecordingJournalSegmentSourceRequest(
                        id: missingSystemID,
                        kind: .systemAudio
                    )
                ]
            )
            damaged.microphoneSink?.enqueue(pcmData([20, 21]))
            damaged.systemAudioSink?.enqueue(pcmData([30, 31]))

            let lastSegmentID = UUID()
            let last = try controller.switchSegment(
                segmentID: lastSegmentID,
                sources: [RecordingJournalSegmentSourceRequest(
                    id: UUID(),
                    kind: .systemAudio
                )]
            )
            last.systemAudioSink?.enqueue(pcmData([40, 41]))
            try controller.stopAndClose()

            let manifest = try fixture.store.loadManifest(recordingID: fixture.recordingID)
            let damagedMicrophone = try requireSource(
                manifest,
                id: damagedMicrophoneID,
                store: fixture.store
            )
            let missingSystem = try requireSource(
                manifest,
                id: missingSystemID,
                store: fixture.store
            )
            let handle = try FileHandle(forWritingTo: damagedMicrophone)
            try handle.truncate(atOffset: 44)
            try handle.close()
            try FileManager.default.removeItem(at: missingSystem)

            let result = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )

            try expectEqual(result.mode, .partial, "partial mode")
            try expectEqual(
                try readSamples(from: result.destinationURL),
                [10, 11, 40, 41],
                "partial recovery skips damaged middle segment"
            )
            try expectEqual(
                result.promotion.resolvedRecoveryIssues,
                [
                    RecordingRecoveryIssue(
                        segmentSequence: 1,
                        sourceKind: .microphone,
                        reason: .committedPayloadUnavailable
                    ),
                    RecordingRecoveryIssue(
                        segmentSequence: 1,
                        sourceKind: .systemAudio,
                        reason: .sourceMissing
                    )
                ],
                "deterministic partial issues"
            )
        }
    }

    private static func emptyCompanionSourceProducesPartialRecovery() throws {
        try withFixture { fixture in
            let controller = try fixture.makeController()
            let microphoneSourceID = UUID()
            let systemSourceID = UUID()
            let combined = try controller.switchSegment(
                segmentID: UUID(),
                sources: [
                    RecordingJournalSegmentSourceRequest(
                        id: microphoneSourceID,
                        kind: .microphone
                    ),
                    RecordingJournalSegmentSourceRequest(
                        id: systemSourceID,
                        kind: .systemAudio
                    )
                ]
            )
            combined.systemAudioSink?.enqueue(pcmData([7, 8]))
            try controller.stopAndClose()

            let result = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )

            try expectEqual(result.mode, .partial, "empty companion mode")
            try expectEqual(
                result.promotion.resolvedRecoveryIssues,
                [RecordingRecoveryIssue(
                    segmentSequence: 1,
                    sourceKind: .microphone,
                    reason: .noCommittedAudio
                )],
                "empty companion issue"
            )
            try expectEqual(
                try readSamples(from: result.destinationURL),
                [7, 8],
                "empty companion survivor"
            )
        }
    }

    private static func emptyPreparationSegmentDoesNotMakeRecoveryPartial() throws {
        try withFixture { fixture in
            let controller = try fixture.makeController()
            controller.activeSegment.microphoneSink?.enqueue(pcmData([1, 2, 3]))
            _ = try controller.switchSegment(
                segmentID: UUID(),
                sources: [RecordingJournalSegmentSourceRequest(
                    id: UUID(),
                    kind: .systemAudio
                )]
            )
            try controller.stopAndClose()

            let result = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )

            try expectEqual(result.mode, .complete, "empty preparation mode")
            try expectEqual(result.promotion.resolvedRecoveryIssues, [], "empty preparation issues")
            try expectEqual(
                try readSamples(from: result.destinationURL),
                [1, 2, 3],
                "empty preparation samples"
            )
        }
    }

    private static func noUsableAudioPreservesInflightRecording() throws {
        try withFixture { fixture in
            let controller = try fixture.makeController()
            try controller.stopAndClose()

            do {
                _ = try fixture.finalizer.finalizeAndPromote(
                    recordingID: fixture.recordingID
                )
                throw TestFailure("all-empty segmented recording must not finalize")
            } catch SegmentedRecordingArtifactFinalizerError.noRecoverableSegments {
                // expected
            }

            guard FileManager.default.fileExists(
                atPath: fixture.store.recordingDirectory(
                    recordingID: fixture.recordingID
                ).path
            ) else {
                throw TestFailure("no-audio finalization must preserve inflight files")
            }
            guard !FileManager.default.fileExists(
                atPath: fixture.store.permanentURL(
                    recordingID: fixture.recordingID
                ).path
            ) else {
                throw TestFailure("no-audio finalization must not create permanent WAV")
            }
        }
    }

    private static func promotedPartialResultReusesStoredMetadataWithoutSources() throws {
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
            combined.microphoneSink?.enqueue(pcmData([3, 4]))
            combined.systemAudioSink?.enqueue(pcmData([5, 6]))
            try controller.stopAndClose()
            let prePromotion = try fixture.store.loadManifest(recordingID: fixture.recordingID)
            let missingSource = prePromotion.sources.first { $0.kind == .systemAudio }!
            try FileManager.default.removeItem(at: try fixture.store.sourceURL(
                recordingID: fixture.recordingID,
                fileName: missingSource.fileName
            ))

            let first = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )
            for source in prePromotion.sources {
                let url = try fixture.store.sourceURL(
                    recordingID: fixture.recordingID,
                    fileName: source.fileName
                )
                try? FileManager.default.removeItem(at: url)
            }
            let second = try fixture.finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )

            try expectEqual(first.mode, .partial, "first partial mode")
            try expectEqual(second, first, "promoted partial reuse")
        }
    }

    private static func withFixture(
        _ body: (Fixture) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-segmented-finalizer-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingID = UUID()
        let anchor: UInt64 = 1_000_000_000
        let store = RecordingJournalStore(
            audioDirectory: root.appendingPathComponent("audio", isDirectory: true)
        )
        try body(Fixture(
            recordingID: recordingID,
            anchor: anchor,
            store: store,
            finalizer: SegmentedRecordingArtifactFinalizer(
                store: store,
                mixdownService: AudioMixdownService()
            )
        ))
    }

    private static func requireSource(
        _ manifest: RecordingJournalManifest,
        id: UUID,
        store: RecordingJournalStore
    ) throws -> URL {
        guard let source = manifest.sources.first(where: { $0.id == id }) else {
            throw TestFailure("missing test source")
        }
        return try store.sourceURL(
            recordingID: manifest.recordingID,
            fileName: source.fileName
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
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frameCount
        ) else {
            throw TestFailure("failed to allocate read buffer")
        }
        try file.read(into: buffer, frameCount: frameCount)
        guard let samples = buffer.floatChannelData?[0] else {
            throw TestFailure("missing readable audio samples")
        }
        return (0..<Int(buffer.frameLength)).map {
            let scaled = Int((samples[$0] * 32_768).rounded())
            return Int16(min(Int(Int16.max), max(Int(Int16.min), scaled)))
        }
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
        let anchor: UInt64
        let store: RecordingJournalStore
        let finalizer: SegmentedRecordingArtifactFinalizer

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
