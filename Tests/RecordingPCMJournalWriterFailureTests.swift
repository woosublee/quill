import Darwin
import Foundation

@main
struct RecordingPCMJournalWriterFailureTests {
    static func main() {
        do {
            try appendFailureReportsImmediatelyOnce()
            try syncFailureReportsStructuredReason()
            try closeFailureReportsAndReleasesWriter()
            try invariantFailureDoesNotReportPersistenceFailure()
            try healthyFailureCloseReturnsCommitAndClosesWriter()
            print("RecordingPCMJournalWriterFailureTests passed")
        } catch {
            fputs("RecordingPCMJournalWriterFailureTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func appendFailureReportsImmediatelyOnce() throws {
        try withFixture { fixture in
            let writer = try fixture.makeWriter(operations: RecordingPCMJournalWriterOperations(
                write: { _, _ in
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
                },
                fullSync: RecordingJournalDurability.fullSync,
                close: { try $0.close() }
            ))
            let callback = FailureCapture()
            writer.setPersistenceFailureHandler(callback.record)

            writer.enqueue(pcmData([1]))
            guard callback.wait() == .success else {
                throw TestFailure("append failure callback did not arrive before timeout")
            }
            writer.enqueue(pcmData([2]))
            let result = writer.closeAfterPersistenceFailure()

            try expectEqual(callback.failures.count, 1, "append callback count")
            try expectEqual(callback.failures.first?.reason, .storageFull, "append reason")
            try expectEqual(callback.failures.first?.operation, .appendPCM, "append operation")
            try expectEqual(result.commit, nil, "failed append commit")
            try expectEqual(result.failure?.reason, .storageFull, "failed append close reason")
            let manifest = try fixture.store.loadManifest(recordingID: fixture.session.recordingID)
            try expectEqual(
                manifest.sources[0].committedDataByteCount,
                0,
                "failed append committed bytes"
            )
        }
    }

    private static func syncFailureReportsStructuredReason() throws {
        try withFixture { fixture in
            let writer = try fixture.makeWriter(operations: RecordingPCMJournalWriterOperations(
                write: { try $0.write(contentsOf: $1) },
                fullSync: { _ in
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                },
                close: { try $0.close() }
            ))
            let callback = FailureCapture()
            writer.setPersistenceFailureHandler(callback.record)
            writer.enqueue(pcmData([1, 2]))

            do {
                _ = try writer.checkpointSnapshot()
                throw TestFailure("injected sync failure must throw")
            } catch {
                // expected
            }
            guard callback.wait() == .success else {
                throw TestFailure("sync failure callback did not arrive")
            }

            try expectEqual(callback.failures.count, 1, "sync callback count")
            try expectEqual(callback.failures.first?.reason, .permissionDenied, "sync reason")
            try expectEqual(callback.failures.first?.operation, .syncSource, "sync operation")
            _ = writer.closeAfterPersistenceFailure()
            try expectEqual(callback.failures.count, 1, "sync callback remains one-shot")
        }
    }

    private static func closeFailureReportsAndReleasesWriter() throws {
        try withFixture { fixture in
            let writer = try fixture.makeWriter(operations: RecordingPCMJournalWriterOperations(
                write: { try $0.write(contentsOf: $1) },
                fullSync: RecordingJournalDurability.fullSync,
                close: { _ in
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
            ))
            let callback = FailureCapture()
            writer.setPersistenceFailureHandler(callback.record)
            writer.enqueue(pcmData([1, 2]))

            let result = writer.closeAfterPersistenceFailure()
            guard callback.wait() == .success else {
                throw TestFailure("close failure callback did not arrive")
            }

            try expectEqual(result.commit, nil, "close failure commit")
            try expectEqual(result.failure?.reason, .journalIOFailure, "close failure result")
            try expectEqual(callback.failures.first?.operation, .closeSource, "close operation")
            do {
                _ = try writer.checkpointSnapshot()
                throw TestFailure("writer must remain closed after close error")
            } catch RecordingPCMJournalWriterError.writerClosed {
                // expected
            }
        }
    }

    private static func invariantFailureDoesNotReportPersistenceFailure() throws {
        try withFixture { fixture in
            let writer = try fixture.makeWriter()
            let callback = FailureCapture()
            writer.setPersistenceFailureHandler(callback.record)
            writer.enqueue(Data([0x01]))

            do {
                _ = try writer.checkpointSnapshot()
                throw TestFailure("odd-byte chunk must fail checkpoint")
            } catch RecordingPCMJournalWriterError.oddByteChunk {
                // expected
            }
            try expectEqual(callback.wait(timeout: 0.05), .timedOut, "invariant callback absence")
            try expectEqual(callback.failures.count, 0, "invariant callback count")
            _ = writer.closeAfterPersistenceFailure()
        }
    }

    private static func healthyFailureCloseReturnsCommitAndClosesWriter() throws {
        try withFixture { fixture in
            let writer = try fixture.makeWriter()
            writer.enqueue(pcmData([3, 4, 5]))

            let result = writer.closeAfterPersistenceFailure()

            try expectEqual(result.failure, nil, "healthy close failure")
            try expectEqual(result.commit?.dataByteCount, 6, "healthy close bytes")
            try expectEqual(result.commit?.frameCount, 3, "healthy close frames")
            do {
                _ = try writer.checkpointSnapshot()
                throw TestFailure("closed writer checkpoint must fail")
            } catch RecordingPCMJournalWriterError.writerClosed {
                // expected
            }
        }
    }

    private static func withFixture(_ body: (Fixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quill-writer-failure-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RecordingJournalStore(
            audioDirectory: root.appendingPathComponent("audio", isDirectory: true)
        )
        let session = try store.createSingleSource(RecordingJournalCreateRequest(
            recordingID: UUID(),
            sourceID: UUID(),
            segmentID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            monotonicAnchorNanoseconds: 1_000_000_000,
            sourceMode: .microphone,
            sourceKind: .microphone,
            sourceFileName: "microphone.wav.part",
            pipeline: makePipelineSnapshot()
        ))
        try body(Fixture(store: store, session: session))
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
        let store: RecordingJournalStore
        let session: RecordingJournalSession

        func makeWriter(
            operations: RecordingPCMJournalWriterOperations = .live
        ) throws -> RecordingPCMJournalWriter {
            try RecordingPCMJournalWriter(
                session: session,
                store: store,
                operations: operations
            )
        }
    }

    private final class FailureCapture: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var storage: [RecordingJournalPersistenceFailure] = []

        var failures: [RecordingJournalPersistenceFailure] {
            lock.withLock { storage }
        }

        func record(_ failure: RecordingJournalPersistenceFailure) {
            lock.withLock { storage.append(failure) }
            semaphore.signal()
        }

        func wait(timeout: TimeInterval = 1) -> DispatchTimeoutResult {
            semaphore.wait(timeout: .now() + timeout)
        }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
