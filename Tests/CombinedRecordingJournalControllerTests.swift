import Foundation

@main
struct CombinedRecordingJournalControllerTests {
    static func main() {
        do {
            try independentSinksCheckpointInOneGeneration()
            try checkpointPreservesNonemptySourceWhenOtherSourceIsEmpty()
            try stopDrainsBothSourcesAndReturnsStableResult()
            try preserveForRecoveryCommitsBothSources()
            try preserveFailureStillMarksJournalRecoverable()
            try failedMicrophoneDrainStillClosesSystemAudioWriter()
            try checkpointFailureCallbackRunsOffLifecycleQueue()
            try discardRemovesCombinedJournal()
            try initializationFailureRollsBackCombinedJournal()
            try reusedInitializationFailurePreservesCombinedJournal()
            try deinitAvoidsLifecycleQueueSync()
            print("CombinedRecordingJournalControllerTests passed")
        } catch {
            fputs(
                "CombinedRecordingJournalControllerTests failed: \(error)\n",
                stderr
            )
            exit(1)
        }
    }

    private static func independentSinksCheckpointInOneGeneration() throws {
        try withFixture { fixture in
            let controller = try CombinedRecordingJournalController(
                request: fixture.request,
                store: fixture.store
            )
            controller.microphoneSink.enqueue(
                Data([0x01, 0x00, 0x02, 0x00])
            )
            controller.systemAudioSink.enqueue(Data([0x03, 0x00]))

            try controller.checkpoint()

            let manifest = try fixture.store.loadManifest(
                recordingID: fixture.recordingID
            )
            try expectEqual(manifest.generation, 2, "checkpoint generation")
            try expectEqual(
                committedBytes(
                    in: manifest,
                    kind: .microphone
                ),
                4,
                "microphone bytes"
            )
            try expectEqual(
                committedBytes(
                    in: manifest,
                    kind: .systemAudio
                ),
                2,
                "System Audio bytes"
            )
        }
    }

    private static func checkpointPreservesNonemptySourceWhenOtherSourceIsEmpty() throws {
        try withFixture { fixture in
            let controller = try CombinedRecordingJournalController(
                request: fixture.request,
                store: fixture.store
            )
            controller.microphoneSink.enqueue(Data([0x01, 0x00]))

            try controller.checkpoint()

            let manifest = try fixture.store.loadManifest(
                recordingID: fixture.recordingID
            )
            try expectEqual(
                committedBytes(in: manifest, kind: .microphone),
                2,
                "one-source microphone bytes"
            )
            try expectEqual(
                committedBytes(in: manifest, kind: .systemAudio),
                0,
                "one-source empty System Audio bytes"
            )
        }
    }

    private static func stopDrainsBothSourcesAndReturnsStableResult() throws {
        try withFixture { fixture in
            let controller = try CombinedRecordingJournalController(
                request: fixture.request,
                store: fixture.store
            )
            controller.microphoneSink.enqueue(Data([0x01, 0x00]))
            controller.systemAudioSink.enqueue(
                Data([0x02, 0x00, 0x03, 0x00])
            )

            let first = try controller.stopAndClose()
            let second = try controller.stopAndClose()

            try expectEqual(second, first, "repeated stop result")
            try expectEqual(
                first.microphoneCommit.dataByteCount,
                2,
                "stopped microphone bytes"
            )
            try expectEqual(
                first.systemAudioCommit.dataByteCount,
                4,
                "stopped System Audio bytes"
            )
            let manifest = try fixture.store.loadManifest(
                recordingID: fixture.recordingID
            )
            try expectEqual(manifest.state, .stopping, "stopped state")
            try expectEqual(manifest.generation, 3, "stopped generation")
        }
    }

    private static func preserveForRecoveryCommitsBothSources() throws {
        try withFixture { fixture in
            let controller = try CombinedRecordingJournalController(
                request: fixture.request,
                store: fixture.store
            )
            controller.microphoneSink.enqueue(Data([0x01, 0x00]))
            controller.systemAudioSink.enqueue(Data([0x02, 0x00]))

            try controller.preserveForRecovery()
            try controller.preserveForRecovery()

            let manifest = try fixture.store.loadManifest(
                recordingID: fixture.recordingID
            )
            try expectEqual(manifest.state, .recoverable, "recoverable state")
            try expectEqual(
                manifest.sources.map(\.committedDataByteCount),
                [2, 2],
                "recoverable source bytes"
            )
        }
    }

    private static func preserveFailureStillMarksJournalRecoverable() throws {
        try withFixture { fixture in
            let controller = try CombinedRecordingJournalController(
                request: fixture.request,
                store: fixture.store
            )
            controller.microphoneSink.enqueue(Data([0x01, 0x00]))
            controller.systemAudioSink.enqueue(Data([0xFF]))

            do {
                try controller.preserveForRecovery()
                throw TestFailure("odd System Audio chunk must fail preserve")
            } catch RecordingPCMJournalWriterError.oddByteChunk {
                // expected
            }

            let manifest = try fixture.store.loadManifest(
                recordingID: fixture.recordingID
            )
            try expectEqual(
                manifest.state,
                .recoverable,
                "failed preserve state"
            )
        }
    }

    private static func failedMicrophoneDrainStillClosesSystemAudioWriter() throws {
        try withFixture { fixture in
            let controller = try CombinedRecordingJournalController(
                request: fixture.request,
                store: fixture.store
            )
            controller.microphoneSink.enqueue(Data([0xFF]))
            controller.systemAudioSink.enqueue(Data([0x01, 0x00]))

            do {
                try controller.preserveForRecovery()
                throw TestFailure("odd microphone chunk must fail preserve")
            } catch RecordingPCMJournalWriterError.oddByteChunk {
                // expected
            }

            controller.systemAudioSink.enqueue(Data([0x02, 0x00]))
            let systemAudioURL = try fixture.store.sourceURL(
                recordingID: fixture.recordingID,
                fileName: "system-audio.wav.part"
            )
            Thread.sleep(forTimeInterval: 0.05)
            try expectEqual(
                try payloadData(from: systemAudioURL),
                Data([0x01, 0x00]),
                "failed preserve must close System Audio writer"
            )
        }
    }

    private static func checkpointFailureCallbackRunsOffLifecycleQueue() throws {
        try withFixture { fixture in
            let controller = try CombinedRecordingJournalController(
                request: fixture.request,
                store: fixture.store
            )
            let callbackQueue = DispatchQueue(
                label: "com.woosublee.quill.tests.combined-callback"
            )
            let callbackQueueKey = DispatchSpecificKey<UInt8>()
            callbackQueue.setSpecific(key: callbackQueueKey, value: 1)
            let callbackFinished = DispatchSemaphore(value: 0)
            var callbackError: Error?

            controller.microphoneSink.enqueue(Data([0xFF]))
            controller.startCheckpointing(
                every: 0.01,
                callbackQueue: callbackQueue
            ) { _ in
                do {
                    guard DispatchQueue.getSpecific(
                        key: callbackQueueKey
                    ) != nil else {
                        throw TestFailure(
                            "checkpoint failure callback used the lifecycle queue"
                        )
                    }
                    try controller.discard()
                } catch {
                    callbackError = error
                }
                callbackFinished.signal()
            }

            guard callbackFinished.wait(timeout: .now() + 2) == .success else {
                throw TestFailure("checkpoint failure callback timed out")
            }
            if let callbackError { throw callbackError }
        }
    }

    private static func discardRemovesCombinedJournal() throws {
        try withFixture { fixture in
            let controller = try CombinedRecordingJournalController(
                request: fixture.request,
                store: fixture.store
            )
            controller.microphoneSink.enqueue(Data([0x01, 0x00]))
            controller.systemAudioSink.enqueue(Data([0x02, 0x00]))

            try controller.discard()
            try controller.discard()

            guard !FileManager.default.fileExists(
                atPath: fixture.store.recordingDirectory(
                    recordingID: fixture.recordingID
                ).path
            ) else {
                throw TestFailure("discard must remove combined journal")
            }
        }
    }

    private static func initializationFailureRollsBackCombinedJournal() throws {
        try withFixture { fixture in
            var writerCount = 0
            do {
                _ = try CombinedRecordingJournalController(
                    request: fixture.request,
                    store: fixture.store,
                    makeWriter: { session, store in
                        writerCount += 1
                        if writerCount == 2 {
                            throw TestFailure("injected second writer failure")
                        }
                        return try RecordingPCMJournalWriter(
                            session: session,
                            store: store
                        )
                    }
                )
                throw TestFailure("controller initialization must fail")
            } catch let error as TestFailure
                where error.description == "injected second writer failure" {
                // expected
            }

            guard !FileManager.default.fileExists(
                atPath: fixture.store.recordingDirectory(
                    recordingID: fixture.recordingID
                ).path
            ) else {
                throw TestFailure(
                    "failed initialization must remove combined journal"
                )
            }
        }
    }

    private static func reusedInitializationFailurePreservesCombinedJournal() throws {
        try withFixture { fixture in
            let session = try fixture.store.createCombined(fixture.request)
            let microphoneBefore = try Data(
                contentsOf: session.microphoneSession.sourceURL
            )
            let systemAudioBefore = try Data(
                contentsOf: session.systemAudioSession.sourceURL
            )
            let manifestBefore = try Data(contentsOf: session.manifestURL)

            do {
                _ = try CombinedRecordingJournalController(
                    request: fixture.request,
                    store: fixture.store,
                    makeWriter: { _, _ in
                        throw TestFailure("injected reused writer failure")
                    }
                )
                throw TestFailure("reused controller initialization must fail")
            } catch let error as TestFailure
                where error.description == "injected reused writer failure" {
                // expected
            }

            try expectEqual(
                try Data(contentsOf: session.manifestURL),
                manifestBefore,
                "reused manifest preservation"
            )
            try expectEqual(
                try Data(contentsOf: session.microphoneSession.sourceURL),
                microphoneBefore,
                "reused microphone preservation"
            )
            try expectEqual(
                try Data(contentsOf: session.systemAudioSession.sourceURL),
                systemAudioBefore,
                "reused System Audio preservation"
            )
        }
    }

    private static func deinitAvoidsLifecycleQueueSync() throws {
        let source = try String(
            contentsOfFile: "Sources/CombinedRecordingJournalController.swift",
            encoding: .utf8
        )
        guard let deinitRange = source.range(of: "deinit {") else {
            throw TestFailure("missing controller deinit")
        }
        let suffix = source[deinitRange.lowerBound...]
        guard let endRange = suffix.range(of: "\n    }\n\n    func startCheckpointing") else {
            throw TestFailure("missing controller deinit boundary")
        }
        let body = String(suffix[..<endRange.lowerBound])
        guard !body.contains("lifecycleQueue.sync"),
              body.contains("checkpointTimer?.cancel()") else {
            throw TestFailure(
                "controller deinit must cancel the timer without queue sync"
            )
        }
    }

    private static func payloadData(from url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard data.count >= RecordingCanonicalWAV.headerByteCount else {
            throw TestFailure("source is shorter than reserved WAV header")
        }
        return data.subdata(
            in: RecordingCanonicalWAV.headerByteCount..<data.count
        )
    }

    private static func committedBytes(
        in manifest: RecordingJournalManifest,
        kind: RecordingJournalSourceKind
    ) -> UInt64? {
        manifest.sources.first(where: { $0.kind == kind })?
            .committedDataByteCount
    }

    private static func withFixture(
        _ body: (Fixture) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-combined-journal-controller-tests-\(UUID().uuidString)",
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
        let request = CombinedRecordingJournalCreateRequest(
            recordingID: recordingID,
            microphoneSourceID: UUID(),
            systemAudioSourceID: UUID(),
            segmentID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            monotonicAnchorNanoseconds: 100,
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
        let request: CombinedRecordingJournalCreateRequest
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
