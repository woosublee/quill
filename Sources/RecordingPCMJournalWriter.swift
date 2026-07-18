import Foundation

protocol NormalizedPCM16Sink: AnyObject {
    func enqueue(_ copiedPCM16LE: Data)
}

enum RecordingPCMJournalWriterError: Error, Equatable {
    case oddByteChunk
    case writerClosed
    case writeFailed(String)
}

final class RecordingPCMJournalWriter: NormalizedPCM16Sink {
    private static let queueKey = DispatchSpecificKey<UInt8>()
    private let queue = DispatchQueue(label: "com.woosublee.quill.recording-journal.pcm-writer")
    private let session: RecordingJournalSession
    private let store: RecordingJournalStore

    private var handle: FileHandle?
    private var writtenDataByteCount: UInt64
    private var firstCommittedFrameOffset: UInt64?
    private var failure: RecordingPCMJournalWriterError?
    private var isClosed = false

    init(
        session: RecordingJournalSession,
        store: RecordingJournalStore
    ) throws {
        self.session = session
        self.store = store
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

    func enqueue(_ copiedPCM16LE: Data) {
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

            do {
                try handle.write(contentsOf: copiedPCM16LE)
                writtenDataByteCount += UInt64(copiedPCM16LE.count)
                if firstCommittedFrameOffset == nil {
                    firstCommittedFrameOffset = 0
                }
            } catch {
                failure = .writeFailed(error.localizedDescription)
            }
        }
    }

    func checkpoint() throws -> RecordingJournalSourceCommit {
        try queue.sync {
            try checkpointLocked(closeAfterCheckpoint: false)
        }
    }

    func drainAndClose() throws -> RecordingJournalSourceCommit {
        try queue.sync {
            try checkpointLocked(closeAfterCheckpoint: true)
        }
    }

    private func checkpointLocked(
        closeAfterCheckpoint: Bool
    ) throws -> RecordingJournalSourceCommit {
        if let failure { throw failure }
        guard !isClosed, let handle else {
            throw RecordingPCMJournalWriterError.writerClosed
        }

        do {
            try RecordingJournalDurability.fullSync(handle.fileDescriptor)
        } catch {
            failure = .writeFailed(error.localizedDescription)
            throw error
        }

        let commit = RecordingJournalSourceCommit(
            dataByteCount: writtenDataByteCount,
            frameCount: writtenDataByteCount / UInt64(RecordingPCMFormat.canonical.bytesPerFrame),
            firstCommittedFrameOffset: writtenDataByteCount > 0 ? firstCommittedFrameOffset : nil
        )
        _ = try store.recordCheckpoint(
            recordingID: session.recordingID,
            sourceID: session.sourceID,
            commit: commit
        )

        if closeAfterCheckpoint {
            do {
                try handle.close()
                self.handle = nil
                isClosed = true
            } catch {
                failure = .writeFailed(error.localizedDescription)
                throw error
            }
        }
        return commit
    }
}
