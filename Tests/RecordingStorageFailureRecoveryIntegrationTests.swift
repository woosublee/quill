import AVFoundation
import Darwin
import Foundation

@main
struct RecordingStorageFailureRecoveryIntegrationTests {
    static func main() {
        do {
            try singleSourceFailureRecoversCommittedPrefixOnce()
            try combinedFailurePreservesHealthyCompanionSource()
            try failedInterruptionManifestWriteRecoversAfterStorageRestoration()
            print("RecordingStorageFailureRecoveryIntegrationTests passed")
        } catch {
            fputs("RecordingStorageFailureRecoveryIntegrationTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func singleSourceFailureRecoversCommittedPrefixOnce() throws {
        try withFixture { fixture in
            let failureToggle = LockedFlag()
            let callback = FailureCapture()
            let controller = try fixture.makeController(
                sources: [RecordingJournalSegmentSourceRequest(
                    id: fixture.microphoneSourceID,
                    kind: .microphone
                )],
                callback: callback,
                makeWriter: { session, store in
                    try RecordingPCMJournalWriter(
                        session: session,
                        store: store,
                        operations: RecordingPCMJournalWriterOperations(
                            write: { handle, data in
                                if failureToggle.value {
                                    throw NSError(
                                        domain: NSPOSIXErrorDomain,
                                        code: Int(ENOSPC)
                                    )
                                }
                                try handle.write(contentsOf: data)
                            },
                            fullSync: RecordingJournalDurability.fullSync,
                            close: { try $0.close() }
                        )
                    )
                }
            )
            controller.activeSegment.microphoneSink?.enqueue(pcmData([1, 2]))
            try controller.checkpoint()
            failureToggle.value = true
            controller.activeSegment.microphoneSink?.enqueue(pcmData([9, 10]))
            guard callback.wait() == .success else {
                throw TestFailure("single-source terminal callback did not arrive")
            }

            _ = try controller.closeAfterPersistenceFailure()
            let finalizer = SegmentedRecordingArtifactFinalizer(
                store: fixture.store,
                mixdownService: AudioMixdownService()
            )
            let first = try finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )
            let firstInode = try inode(at: first.destinationURL)
            let second = try finalizer.finalizeAndPromote(
                recordingID: fixture.recordingID
            )
            let recovered = try requireRecovered(
                RecordingJournalRecoveryExecutor(store: fixture.store)
                    .recoverAll()[0]
            )

            try expectEqual(try readSamples(first.destinationURL), [1, 2], "committed prefix")
            try expectEqual(first.mode, .complete, "single-source mode")
            try expectEqual(first.promotion.interruptionReason, .storageFull, "single-source reason")
            try expectEqual(second, first, "promoted finalizer reuse")
            try expectEqual(try inode(at: second.destinationURL), firstInode, "permanent inode")
            try expectEqual(recovered.interruptionReason, .storageFull, "executor reason")
            try expectEqual(callback.failures.count, 1, "single-source callback count")
        }
    }

    private static func combinedFailurePreservesHealthyCompanionSource() throws {
        try withFixture { fixture in
            let callback = FailureCapture()
            let controller = try fixture.makeController(
                sources: [
                    RecordingJournalSegmentSourceRequest(
                        id: fixture.microphoneSourceID,
                        kind: .microphone
                    ),
                    RecordingJournalSegmentSourceRequest(
                        id: fixture.systemAudioSourceID,
                        kind: .systemAudio
                    )
                ],
                callback: callback,
                makeWriter: { session, store in
                    let failWrites = session.sourceID == fixture.microphoneSourceID
                    return try RecordingPCMJournalWriter(
                        session: session,
                        store: store,
                        operations: RecordingPCMJournalWriterOperations(
                            write: { handle, data in
                                if failWrites {
                                    throw NSError(
                                        domain: NSPOSIXErrorDomain,
                                        code: Int(ENOSPC)
                                    )
                                }
                                try handle.write(contentsOf: data)
                            },
                            fullSync: RecordingJournalDurability.fullSync,
                            close: { try $0.close() }
                        )
                    )
                }
            )
            controller.activeSegment.microphoneSink?.enqueue(pcmData([10, 11]))
            controller.activeSegment.systemAudioSink?.enqueue(pcmData([20, 21]))
            guard callback.wait() == .success else {
                throw TestFailure("combined terminal callback did not arrive")
            }

            _ = try controller.closeAfterPersistenceFailure()
            let artifact = try SegmentedRecordingArtifactFinalizer(
                store: fixture.store,
                mixdownService: AudioMixdownService()
            ).finalizeAndPromote(recordingID: fixture.recordingID)

            try expectEqual(try readSamples(artifact.destinationURL), [20, 21], "healthy companion samples")
            try expectEqual(artifact.mode, .partial, "combined partial mode")
            try expectEqual(artifact.promotion.interruptionReason, .storageFull, "combined reason")
            try expectEqual(
                artifact.promotion.resolvedRecoveryIssues,
                [RecordingRecoveryIssue(
                    segmentSequence: 0,
                    sourceKind: .microphone,
                    reason: .noCommittedAudio
                )],
                "combined partial issue"
            )
        }
    }

    private static func failedInterruptionManifestWriteRecoversAfterStorageRestoration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quill-storage-failure-window-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let rejectInterruptedManifest = LockedFlag()
        let store = RecordingJournalStore(
            audioDirectory: root.appendingPathComponent("audio", isDirectory: true),
            manifestWriter: RecordingJournalManifestWriter(write: { data, generation, targetURL, fileManager in
                if rejectInterruptedManifest.value,
                   let manifest = try? RecordingJournalCoding.makeDecoder().decode(
                       RecordingJournalManifest.self,
                       from: data
                   ),
                   manifest.interruptionReason != nil {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
                }
                try RecordingJournalManifestWriter.live.write(
                    data,
                    generation,
                    targetURL,
                    fileManager
                )
            })
        )
        let recordingID = UUID()
        let controller = try SegmentedRecordingJournalController(
            request: SegmentedRecordingJournalCreateRequest(
                recordingID: recordingID,
                segmentID: UUID(),
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                monotonicAnchorNanoseconds: 1_000_000_000,
                sources: [RecordingJournalSegmentSourceRequest(
                    id: UUID(),
                    kind: .microphone
                )],
                pipeline: makePipelineSnapshot()
            ),
            store: store
        )
        controller.activeSegment.microphoneSink?.enqueue(pcmData([5, 6]))
        try controller.checkpoint()
        rejectInterruptedManifest.value = true
        do {
            _ = try store.markRecoverableAfterPersistenceFailure(
                recordingID: recordingID,
                commitsBySourceID: [:],
                interruptionReason: .storageFull
            )
            throw TestFailure("interrupted manifest write must fail")
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain {
            // expected
        }
        let preserved = try store.loadManifest(recordingID: recordingID)
        try expectEqual(preserved.state, .recording, "preserved pre-failure state")
        try expectEqual(preserved.interruptionReason, nil, "preserved generic reason")

        rejectInterruptedManifest.value = false
        let recovered = try requireRecovered(
            RecordingJournalRecoveryExecutor(store: store).recoverAll()[0]
        )
        try expectEqual(recovered.interruptionReason, nil, "restored generic recovery reason")
        try expectEqual(try readSamples(recovered.audioURL), [5, 6], "restored recovery samples")
    }

    private static func withFixture(_ body: (Fixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quill-storage-failure-integration-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Fixture(
            recordingID: UUID(),
            microphoneSourceID: UUID(),
            systemAudioSourceID: UUID(),
            store: RecordingJournalStore(
                audioDirectory: root.appendingPathComponent("audio", isDirectory: true)
            )
        )
        try body(fixture)
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

    private static func readSamples(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frameCount
        ) else {
            throw TestFailure("failed to allocate sample buffer")
        }
        try file.read(into: buffer, frameCount: frameCount)
        guard let samples = buffer.floatChannelData?[0] else {
            throw TestFailure("missing sample data")
        }
        return (0..<Int(buffer.frameLength)).map {
            let scaled = Int((samples[$0] * 32_768).rounded())
            return Int16(min(Int(Int16.max), max(Int(Int16.min), scaled)))
        }
    }

    private static func inode(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw TestFailure("failed to read permanent WAV inode")
        }
        return inode.uint64Value
    }

    private static func requireRecovered(
        _ result: RecordingJournalRecoveryResult
    ) throws -> RecoveredRecordingArtifact {
        guard case .recovered(let artifact) = result else {
            throw TestFailure("expected recovered artifact, got \(result)")
        }
        return artifact
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
        let microphoneSourceID: UUID
        let systemAudioSourceID: UUID
        let store: RecordingJournalStore

        func makeController(
            sources: [RecordingJournalSegmentSourceRequest],
            callback: FailureCapture,
            makeWriter: @escaping (
                RecordingJournalSession,
                RecordingJournalStore
            ) throws -> RecordingPCMJournalWriter
        ) throws -> SegmentedRecordingJournalController {
            try SegmentedRecordingJournalController(
                request: SegmentedRecordingJournalCreateRequest(
                    recordingID: recordingID,
                    segmentID: UUID(),
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    monotonicAnchorNanoseconds: 1_000_000_000,
                    sources: sources,
                    pipeline: makePipelineSnapshot()
                ),
                store: store,
                callbackQueue: DispatchQueue(label: "storage-failure-integration-callback"),
                onTerminalPersistenceFailure: callback.record,
                makeWriter: makeWriter
            )
        }
    }

    private final class FailureCapture: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var storage: [RecordingJournalSourcePersistenceFailure] = []

        var failures: [RecordingJournalSourcePersistenceFailure] {
            lock.withLock { storage }
        }

        func record(_ failure: RecordingJournalSourcePersistenceFailure) {
            lock.withLock { storage.append(failure) }
            semaphore.signal()
        }

        func wait() -> DispatchTimeoutResult {
            semaphore.wait(timeout: .now() + 1)
        }
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false

        var value: Bool {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
