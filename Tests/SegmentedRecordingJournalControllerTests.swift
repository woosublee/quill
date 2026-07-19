import Foundation

@main
struct SegmentedRecordingJournalControllerTests {
    static func main() {
        do {
            try initialHandleMatchesRequestedSources()
            try switchingDrainsSegmentsAndPreservesRecordingOrder()
            try timestampOffsetsUseTheOriginalRecordingAnchor()
            try checkpointCommitsEveryActiveSourceInOneGeneration()
            try stopPreserveAndDiscardHaveStableLifecycleSemantics()
            try failedNextWriterLeavesEarlierAudioRecoverable()
            print("SegmentedRecordingJournalControllerTests passed")
        } catch {
            fputs("SegmentedRecordingJournalControllerTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func initialHandleMatchesRequestedSources() throws {
        try withFixture { fixture in
            let controller = try SegmentedRecordingJournalController(
                request: fixture.request(sources: [
                    RecordingJournalSegmentSourceRequest(
                        id: fixture.microphoneSourceID,
                        kind: .microphone
                    )
                ]),
                store: fixture.store
            )

            try expectEqual(controller.recordingID, fixture.recordingID, "recording ID")
            try expectEqual(controller.activeSegment.id, fixture.firstSegmentID, "segment ID")
            try expectEqual(controller.activeSegment.sequence, 0, "segment sequence")
            guard controller.activeSegment.microphoneSink != nil,
                  controller.activeSegment.systemAudioSink == nil else {
                throw TestFailure("microphone segment must expose only its microphone sink")
            }
        }
    }

    private static func switchingDrainsSegmentsAndPreservesRecordingOrder() throws {
        try withFixture { fixture in
            let controller = try SegmentedRecordingJournalController(
                request: fixture.request(sources: [
                    RecordingJournalSegmentSourceRequest(
                        id: fixture.microphoneSourceID,
                        kind: .microphone
                    )
                ]),
                store: fixture.store
            )
            controller.activeSegment.microphoneSink?.enqueue(Data([0x01, 0x00]))

            let combinedSegmentID = UUID()
            let combinedMicrophoneID = UUID()
            let combinedSystemAudioID = UUID()
            let combined = try controller.switchSegment(
                segmentID: combinedSegmentID,
                sources: [
                    RecordingJournalSegmentSourceRequest(
                        id: combinedMicrophoneID,
                        kind: .microphone
                    ),
                    RecordingJournalSegmentSourceRequest(
                        id: combinedSystemAudioID,
                        kind: .systemAudio
                    )
                ]
            )
            combined.microphoneSink?.enqueue(Data([0x02, 0x00]))
            combined.systemAudioSink?.enqueue(Data([0x03, 0x00]))

            let systemSegmentID = UUID()
            let systemSourceID = UUID()
            let system = try controller.switchSegment(
                segmentID: systemSegmentID,
                sources: [RecordingJournalSegmentSourceRequest(
                    id: systemSourceID,
                    kind: .systemAudio
                )]
            )
            system.systemAudioSink?.enqueue(Data([0x04, 0x00]))
            try controller.stopAndClose()

            let manifest = try fixture.store.loadManifest(recordingID: fixture.recordingID)
            try expectEqual(manifest.segments.map(\.sequence), [0, 1, 2], "segment order")
            try expectEqual(
                manifest.segments.map(\.id),
                [fixture.firstSegmentID, combinedSegmentID, systemSegmentID],
                "segment IDs"
            )
            try expectEqual(manifest.pipeline, fixture.pipeline, "stable pipeline snapshot")
            try expectEqual(
                manifest.sources.map(\.committedDataByteCount),
                [2, 2, 2, 2],
                "all segment commits"
            )
            try expectEqual(manifest.state, .stopping, "stopped manifest state")
        }
    }

    private static func timestampOffsetsUseTheOriginalRecordingAnchor() throws {
        try withFixture { fixture in
            let controller = try SegmentedRecordingJournalController(
                request: fixture.request(sources: [
                    RecordingJournalSegmentSourceRequest(
                        id: fixture.microphoneSourceID,
                        kind: .microphone
                    )
                ]),
                store: fixture.store
            )
            controller.activeSegment.microphoneSink?.enqueue(
                Data([0x01, 0x00]),
                firstFrameMonotonicNanoseconds: fixture.anchor + 100_000_000
            )
            let nextID = UUID()
            let next = try controller.switchSegment(
                segmentID: UUID(),
                sources: [RecordingJournalSegmentSourceRequest(
                    id: nextID,
                    kind: .systemAudio
                )]
            )
            next.systemAudioSink?.enqueue(
                Data([0x02, 0x00]),
                firstFrameMonotonicNanoseconds: fixture.anchor + 1_100_000_000
            )
            try controller.stopAndClose()

            let manifest = try fixture.store.loadManifest(recordingID: fixture.recordingID)
            try expectEqual(
                manifest.sources.first(where: { $0.id == fixture.microphoneSourceID })?
                    .firstCommittedFrameOffset,
                1_600,
                "first segment offset"
            )
            try expectEqual(
                manifest.sources.first(where: { $0.id == nextID })?
                    .firstCommittedFrameOffset,
                17_600,
                "switched segment offset"
            )
        }
    }

    private static func checkpointCommitsEveryActiveSourceInOneGeneration() throws {
        try withFixture { fixture in
            let controller = try SegmentedRecordingJournalController(
                request: fixture.request(sources: [
                    RecordingJournalSegmentSourceRequest(
                        id: fixture.microphoneSourceID,
                        kind: .microphone
                    ),
                    RecordingJournalSegmentSourceRequest(
                        id: fixture.systemAudioSourceID,
                        kind: .systemAudio
                    )
                ]),
                store: fixture.store
            )
            controller.activeSegment.microphoneSink?.enqueue(Data([0x01, 0x00]))
            controller.activeSegment.systemAudioSink?.enqueue(Data([0x02, 0x00]))

            try controller.checkpoint()

            let manifest = try fixture.store.loadManifest(recordingID: fixture.recordingID)
            try expectEqual(manifest.generation, 2, "batch checkpoint generation")
            try expectEqual(
                manifest.sources.map(\.committedDataByteCount),
                [2, 2],
                "batch checkpoint bytes"
            )
        }
    }

    private static func stopPreserveAndDiscardHaveStableLifecycleSemantics() throws {
        try withFixture { fixture in
            let stopped = try SegmentedRecordingJournalController(
                request: fixture.request(sources: [
                    RecordingJournalSegmentSourceRequest(
                        id: fixture.microphoneSourceID,
                        kind: .microphone
                    )
                ]),
                store: fixture.store
            )
            stopped.activeSegment.microphoneSink?.enqueue(Data([0x01, 0x00]))
            try stopped.stopAndClose()
            try stopped.stopAndClose()
            try expectEqual(
                try fixture.store.loadManifest(recordingID: fixture.recordingID).state,
                .stopping,
                "idempotent stop"
            )
            do {
                try stopped.discard()
                throw TestFailure("stopped controller must reject discard")
            } catch SegmentedRecordingJournalControllerError.controllerClosed {
                // expected
            }
        }

        try withFixture { fixture in
            let recoverable = try SegmentedRecordingJournalController(
                request: fixture.request(sources: [
                    RecordingJournalSegmentSourceRequest(
                        id: fixture.microphoneSourceID,
                        kind: .microphone
                    )
                ]),
                store: fixture.store
            )
            recoverable.activeSegment.microphoneSink?.enqueue(Data([0x01, 0x00]))
            try recoverable.preserveForRecovery()
            try recoverable.preserveForRecovery()
            try expectEqual(
                try fixture.store.loadManifest(recordingID: fixture.recordingID).state,
                .recoverable,
                "idempotent preserve"
            )
        }

        try withFixture { fixture in
            let discarded = try SegmentedRecordingJournalController(
                request: fixture.request(sources: [
                    RecordingJournalSegmentSourceRequest(
                        id: fixture.microphoneSourceID,
                        kind: .microphone
                    )
                ]),
                store: fixture.store
            )
            try discarded.discard()
            try discarded.discard()
            guard !FileManager.default.fileExists(
                atPath: fixture.store.recordingDirectory(
                    recordingID: fixture.recordingID
                ).path
            ) else {
                throw TestFailure("discard must remove the recording directory")
            }
        }
    }

    private static func failedNextWriterLeavesEarlierAudioRecoverable() throws {
        try withFixture { fixture in
            var writerCount = 0
            let controller = try SegmentedRecordingJournalController(
                request: fixture.request(sources: [
                    RecordingJournalSegmentSourceRequest(
                        id: fixture.microphoneSourceID,
                        kind: .microphone
                    )
                ]),
                store: fixture.store,
                makeWriter: { session, store in
                    writerCount += 1
                    if writerCount == 2 {
                        throw TestFailure("injected next-segment writer failure")
                    }
                    return try RecordingPCMJournalWriter(session: session, store: store)
                }
            )
            controller.activeSegment.microphoneSink?.enqueue(Data([0x01, 0x00]))

            do {
                _ = try controller.switchSegment(
                    segmentID: UUID(),
                    sources: [RecordingJournalSegmentSourceRequest(
                        id: UUID(),
                        kind: .systemAudio
                    )]
                )
                throw TestFailure("switch must surface writer construction failure")
            } catch let error as TestFailure
                where error.description == "injected next-segment writer failure" {
                // expected
            }

            try controller.stopAndClose()
            let manifest = try fixture.store.loadManifest(recordingID: fixture.recordingID)
            try expectEqual(manifest.state, .stopping, "failed switch stopped state")
            try expectEqual(manifest.segments.map(\.sequence), [0, 1], "empty next segment retained")
            try expectEqual(
                manifest.sources.map(\.committedDataByteCount),
                [2, 0],
                "earlier audio preserved after failed switch"
            )
        }
    }

    private static func withFixture(
        _ body: (Fixture) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-segmented-controller-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingID = UUID()
        let firstSegmentID = UUID()
        let anchor: UInt64 = 1_000_000_000
        let pipeline = makePipelineSnapshot()
        let store = RecordingJournalStore(
            audioDirectory: root.appendingPathComponent("audio", isDirectory: true)
        )
        try body(Fixture(
            recordingID: recordingID,
            firstSegmentID: firstSegmentID,
            microphoneSourceID: UUID(),
            systemAudioSourceID: UUID(),
            anchor: anchor,
            pipeline: pipeline,
            store: store
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
        let firstSegmentID: UUID
        let microphoneSourceID: UUID
        let systemAudioSourceID: UUID
        let anchor: UInt64
        let pipeline: RecordingPipelineSnapshot
        let store: RecordingJournalStore

        func request(
            sources: [RecordingJournalSegmentSourceRequest]
        ) -> SegmentedRecordingJournalCreateRequest {
            SegmentedRecordingJournalCreateRequest(
                recordingID: recordingID,
                segmentID: firstSegmentID,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                monotonicAnchorNanoseconds: anchor,
                sources: sources,
                pipeline: pipeline
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
