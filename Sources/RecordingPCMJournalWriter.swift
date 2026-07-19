import Foundation

protocol NormalizedPCM16Sink: AnyObject {
    func enqueue(_ copiedPCM16LE: Data)
    func enqueue(
        _ copiedPCM16LE: Data,
        firstFrameMonotonicNanoseconds: UInt64
    )
}

extension NormalizedPCM16Sink {
    func enqueue(
        _ copiedPCM16LE: Data,
        firstFrameMonotonicNanoseconds: UInt64
    ) {
        enqueue(copiedPCM16LE)
    }
}

struct RecordingPCMJournalWriterOperations {
    let write: (FileHandle, Data) throws -> Void
    let fullSync: (Int32) throws -> Void
    let close: (FileHandle) throws -> Void

    static let live = RecordingPCMJournalWriterOperations(
        write: { try $0.write(contentsOf: $1) },
        fullSync: RecordingJournalDurability.fullSync,
        close: { try $0.close() }
    )
}

struct RecordingPCMJournalFailureCloseResult: Equatable {
    let commit: RecordingJournalSourceCommit?
    let failure: RecordingJournalPersistenceFailure?
}

final class RecordingPCMJournalWriter: NormalizedPCM16Sink {
    private static let queueKey = DispatchSpecificKey<UInt8>()
    private let queue = DispatchQueue(label: "com.woosublee.quill.recording-journal.pcm-writer")
    private let session: RecordingJournalSession
    private let store: RecordingJournalStore
    private let operations: RecordingPCMJournalWriterOperations

    private var handle: FileHandle?
    private var writtenDataByteCount: UInt64
    private var firstCommittedFrameOffset: UInt64?
    private var failure: RecordingPCMJournalWriterError?
    private var persistenceFailure: RecordingJournalPersistenceFailure?
    private var persistenceFailureHandler: ((RecordingJournalPersistenceFailure) -> Void)?
    private var didReportPersistenceFailure = false
    private var isClosed = false

    init(
        session: RecordingJournalSession,
        store: RecordingJournalStore,
        operations: RecordingPCMJournalWriterOperations = .live
    ) throws {
        self.session = session
        self.store = store
        self.operations = operations
        self.queue.setSpecific(key: Self.queueKey, value: 1)
        let physicalSize = try RecordingJournalDurability.fileSize(at: session.sourceURL)
        guard physicalSize >= UInt64(RecordingCanonicalWAV.headerByteCount) else {
            throw RecordingJournalStoreError.invalidSourceFile
        }
        self.writtenDataByteCount = physicalSize - UInt64(RecordingCanonicalWAV.headerByteCount)
        self.handle = try FileHandle(forWritingTo: session.sourceURL)
        try self.handle?.seekToEnd()
    }

    deinit {
        let close = {
            try? self.handle?.close()
            self.handle = nil
            self.isClosed = true
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            close()
        } else {
            queue.sync(execute: close)
        }
    }

    func setPersistenceFailureHandler(
        _ handler: @escaping (RecordingJournalPersistenceFailure) -> Void
    ) {
        queue.sync {
            persistenceFailureHandler = handler
            reportPersistenceFailureIfNeededLocked()
        }
    }

    func enqueue(_ copiedPCM16LE: Data) {
        enqueue(copiedPCM16LE, firstCommittedFrameOffset: 0)
    }

    func enqueue(
        _ copiedPCM16LE: Data,
        firstCommittedFrameOffset requestedFrameOffset: UInt64?
    ) {
        queue.async { [self] in
            guard failure == nil else { return }
            guard !isClosed, let handle else {
                failure = .writerClosed
                return
            }
            guard copiedPCM16LE.count.isMultiple(of: Int(RecordingPCMFormat.canonical.bytesPerFrame)) else {
                failure = .oddByteChunk
                return
            }
            guard !copiedPCM16LE.isEmpty else { return }

            let resolvedFrameOffset = requestedFrameOffset ?? 0
            if let firstCommittedFrameOffset,
               firstCommittedFrameOffset != resolvedFrameOffset {
                failure = .conflictingFrameOffset
                return
            }

            do {
                try operations.write(handle, copiedPCM16LE)
                writtenDataByteCount += UInt64(copiedPCM16LE.count)
                if firstCommittedFrameOffset == nil {
                    firstCommittedFrameOffset = resolvedFrameOffset
                }
            } catch {
                recordPersistenceFailureLocked(error, operation: .appendPCM)
            }
        }
    }

    func checkpoint() throws -> RecordingJournalSourceCommit {
        try queue.sync {
            let commit = try checkpointLocked(
                closeAfterCheckpoint: false
            )
            _ = try store.recordCheckpoint(
                recordingID: session.recordingID,
                sourceID: session.sourceID,
                commit: commit
            )
            return commit
        }
    }

    func drainAndClose() throws -> RecordingJournalSourceCommit {
        try queue.sync {
            let commit = try checkpointLocked(
                closeAfterCheckpoint: false
            )
            _ = try store.recordCheckpoint(
                recordingID: session.recordingID,
                sourceID: session.sourceID,
                commit: commit
            )
            try closeLocked()
            return commit
        }
    }

    func checkpointSnapshot() throws -> RecordingJournalSourceCommit {
        try queue.sync {
            try checkpointLocked(closeAfterCheckpoint: false)
        }
    }

    func drainAndCloseSnapshot() throws -> RecordingJournalSourceCommit {
        try queue.sync {
            try checkpointLocked(closeAfterCheckpoint: true)
        }
    }

    func closeAfterPersistenceFailure() -> RecordingPCMJournalFailureCloseResult {
        queue.sync {
            guard !isClosed else {
                return RecordingPCMJournalFailureCloseResult(
                    commit: nil,
                    failure: persistenceFailure
                )
            }

            var commit: RecordingJournalSourceCommit?
            if persistenceFailure == nil, failure == nil, let handle {
                do {
                    try operations.fullSync(handle.fileDescriptor)
                    commit = RecordingJournalSourceCommit(
                        dataByteCount: writtenDataByteCount,
                        frameCount: writtenDataByteCount / UInt64(RecordingPCMFormat.canonical.bytesPerFrame),
                        firstCommittedFrameOffset: writtenDataByteCount > 0
                            ? firstCommittedFrameOffset
                            : nil
                    )
                } catch {
                    recordPersistenceFailureLocked(error, operation: .syncSource)
                }
            }

            if let handle {
                do {
                    try operations.close(handle)
                } catch {
                    commit = nil
                    recordPersistenceFailureLocked(error, operation: .closeSource)
                }
            }
            handle = nil
            isClosed = true

            return RecordingPCMJournalFailureCloseResult(
                commit: persistenceFailure == nil && failure == nil ? commit : nil,
                failure: persistenceFailure
            )
        }
    }

    private func checkpointLocked(
        closeAfterCheckpoint: Bool
    ) throws -> RecordingJournalSourceCommit {
        guard !isClosed, let handle else {
            throw RecordingPCMJournalWriterError.writerClosed
        }
        if let failure { throw failure }

        do {
            try operations.fullSync(handle.fileDescriptor)
        } catch {
            recordPersistenceFailureLocked(error, operation: .syncSource)
            throw error
        }

        let commit = RecordingJournalSourceCommit(
            dataByteCount: writtenDataByteCount,
            frameCount: writtenDataByteCount / UInt64(RecordingPCMFormat.canonical.bytesPerFrame),
            firstCommittedFrameOffset: writtenDataByteCount > 0 ? firstCommittedFrameOffset : nil
        )
        if closeAfterCheckpoint {
            try closeLocked()
        }
        return commit
    }

    private func closeLocked() throws {
        guard !isClosed, let handle else {
            throw RecordingPCMJournalWriterError.writerClosed
        }
        do {
            try operations.close(handle)
            self.handle = nil
            isClosed = true
        } catch {
            self.handle = nil
            isClosed = true
            recordPersistenceFailureLocked(error, operation: .closeSource)
            throw error
        }
    }

    private func recordPersistenceFailureLocked(
        _ error: Error,
        operation: RecordingJournalPersistenceOperation
    ) {
        let persistenceFailure = RecordingJournalPersistenceFailure.knownPersistenceFailure(
            error,
            operation: operation
        )
        if self.persistenceFailure == nil {
            self.persistenceFailure = persistenceFailure
        }
        failure = .writeFailed(error.localizedDescription)
        reportPersistenceFailureIfNeededLocked()
    }

    private func reportPersistenceFailureIfNeededLocked() {
        guard !didReportPersistenceFailure,
              let persistenceFailure,
              let persistenceFailureHandler else {
            return
        }
        didReportPersistenceFailure = true
        persistenceFailureHandler(persistenceFailure)
    }
}
