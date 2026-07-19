import Foundation

enum SegmentedRecordingJournalControllerError: Error, Equatable {
    case controllerClosed
}

struct SegmentedRecordingJournalSegmentHandle {
    let id: UUID
    let sequence: Int
    let microphoneSink: (any NormalizedPCM16Sink)?
    let systemAudioSink: (any NormalizedPCM16Sink)?
}

final class SegmentedRecordingJournalController {
    private enum State {
        case recording
        case stopped
        case recoverable
        case discarded
    }

    private struct ActiveSource {
        let id: UUID
        let writer: RecordingPCMJournalWriter
        let sink: RecordingJournalSourceSink
    }

    private struct ActiveSegment {
        let id: UUID
        let sequence: Int
        let sourcesByKind: [RecordingJournalSourceKind: ActiveSource]

        var handle: SegmentedRecordingJournalSegmentHandle {
            SegmentedRecordingJournalSegmentHandle(
                id: id,
                sequence: sequence,
                microphoneSink: sourcesByKind[.microphone]?.sink,
                systemAudioSink: sourcesByKind[.systemAudio]?.sink
            )
        }
    }

    let recordingID: UUID

    private let store: RecordingJournalStore
    private let monotonicAnchorNanoseconds: UInt64
    private let makeWriter: (
        RecordingJournalSession,
        RecordingJournalStore
    ) throws -> RecordingPCMJournalWriter
    private let lifecycleQueue = DispatchQueue(
        label: "com.woosublee.quill.recording-journal.segmented-lifecycle"
    )
    private var segment: ActiveSegment?
    private var lastHandle: SegmentedRecordingJournalSegmentHandle
    private var checkpointTimer: DispatchSourceTimer?
    private var state: State = .recording
    private var didReportCheckpointFailure = false

    convenience init(
        request: SegmentedRecordingJournalCreateRequest,
        store: RecordingJournalStore
    ) throws {
        try self.init(
            request: request,
            store: store,
            makeWriter: RecordingPCMJournalWriter.init
        )
    }

    init(
        request: SegmentedRecordingJournalCreateRequest,
        store: RecordingJournalStore,
        makeWriter: @escaping (
            RecordingJournalSession,
            RecordingJournalStore
        ) throws -> RecordingPCMJournalWriter
    ) throws {
        let session = try store.createSegmented(request)
        let activeSegment: ActiveSegment
        do {
            activeSegment = try Self.makeActiveSegment(
                session: session,
                store: store,
                monotonicAnchorNanoseconds:
                    request.monotonicAnchorNanoseconds,
                makeWriter: makeWriter
            )
        } catch {
            if session.creationDisposition == .created {
                try? store.markDiscarded(recordingID: request.recordingID)
                try? store.discardInflightRecording(
                    recordingID: request.recordingID
                )
            }
            throw error
        }

        self.recordingID = request.recordingID
        self.store = store
        self.monotonicAnchorNanoseconds = request.monotonicAnchorNanoseconds
        self.makeWriter = makeWriter
        self.segment = activeSegment
        self.lastHandle = activeSegment.handle
    }

    deinit {
        checkpointTimer?.setEventHandler {}
        checkpointTimer?.cancel()
    }

    var activeSegment: SegmentedRecordingJournalSegmentHandle {
        lifecycleQueue.sync { lastHandle }
    }

    func startCheckpointing(
        every interval: TimeInterval = 7,
        callbackQueue: DispatchQueue = .main,
        onFirstFailure: @escaping (Error) -> Void
    ) {
        lifecycleQueue.async { [weak self] in
            guard let self,
                  case .recording = self.state,
                  self.checkpointTimer == nil else {
                return
            }
            let timer = DispatchSource.makeTimerSource(queue: self.lifecycleQueue)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                do {
                    try self.checkpointLocked()
                } catch {
                    guard !self.didReportCheckpointFailure else { return }
                    self.didReportCheckpointFailure = true
                    callbackQueue.async { onFirstFailure(error) }
                }
            }
            timer.resume()
            self.checkpointTimer = timer
        }
    }

    func checkpoint() throws {
        try lifecycleQueue.sync {
            guard case .recording = state else {
                throw SegmentedRecordingJournalControllerError.controllerClosed
            }
            try checkpointLocked()
        }
    }

    func switchSegment(
        segmentID: UUID,
        sources: [RecordingJournalSegmentSourceRequest]
    ) throws -> SegmentedRecordingJournalSegmentHandle {
        try lifecycleQueue.sync {
            guard case .recording = state, let currentSegment = segment else {
                throw SegmentedRecordingJournalControllerError.controllerClosed
            }
            try drainAndCommitLocked(currentSegment)
            segment = nil

            let session = try store.appendSegment(
                recordingID: recordingID,
                segmentID: segmentID,
                sequence: currentSegment.sequence + 1,
                sources: sources
            )
            do {
                let next = try Self.makeActiveSegment(
                    session: session,
                    store: store,
                    monotonicAnchorNanoseconds: monotonicAnchorNanoseconds,
                    makeWriter: makeWriter
                )
                segment = next
                lastHandle = next.handle
                return next.handle
            } catch {
                lastHandle = SegmentedRecordingJournalSegmentHandle(
                    id: session.segmentID,
                    sequence: session.sequence,
                    microphoneSink: nil,
                    systemAudioSink: nil
                )
                throw error
            }
        }
    }

    func stopAndClose() throws {
        try lifecycleQueue.sync {
            switch state {
            case .stopped:
                return
            case .recoverable, .discarded:
                throw SegmentedRecordingJournalControllerError.controllerClosed
            case .recording:
                cancelCheckpointTimerLocked()
                if let segment {
                    try drainAndCommitLocked(segment)
                    self.segment = nil
                }
                _ = try store.transition(
                    recordingID: recordingID,
                    to: .stopping
                )
                state = .stopped
            }
        }
    }

    func preserveForRecovery() throws {
        try lifecycleQueue.sync {
            switch state {
            case .recoverable, .stopped:
                return
            case .discarded:
                throw SegmentedRecordingJournalControllerError.controllerClosed
            case .recording:
                cancelCheckpointTimerLocked()
                do {
                    if let segment {
                        try drainAndCommitLocked(segment)
                        self.segment = nil
                    }
                    _ = try store.transition(
                        recordingID: recordingID,
                        to: .recoverable
                    )
                    state = .recoverable
                } catch {
                    try? preserveAfterCloseFailureLocked()
                    throw error
                }
            }
        }
    }

    func discard() throws {
        try lifecycleQueue.sync {
            switch state {
            case .discarded:
                return
            case .stopped:
                throw SegmentedRecordingJournalControllerError.controllerClosed
            case .recording:
                cancelCheckpointTimerLocked()
                if let segment {
                    for source in segment.sourcesByKind.values {
                        _ = try? source.writer.drainAndCloseSnapshot()
                    }
                    self.segment = nil
                }
                try discardJournalLocked()
            case .recoverable:
                try discardJournalLocked()
            }
        }
    }

    private static func makeActiveSegment(
        session: RecordingJournalSegmentSession,
        store: RecordingJournalStore,
        monotonicAnchorNanoseconds: UInt64,
        makeWriter: (
            RecordingJournalSession,
            RecordingJournalStore
        ) throws -> RecordingPCMJournalWriter
    ) throws -> ActiveSegment {
        var sourcesByKind: [RecordingJournalSourceKind: ActiveSource] = [:]
        do {
            for source in session.sources {
                let writer = try makeWriter(source.session, store)
                sourcesByKind[source.kind] = ActiveSource(
                    id: source.session.sourceID,
                    writer: writer,
                    sink: RecordingJournalSourceSink(
                        writer: writer,
                        monotonicAnchorNanoseconds: monotonicAnchorNanoseconds
                    )
                )
            }
        } catch {
            for source in sourcesByKind.values {
                _ = try? source.writer.drainAndCloseSnapshot()
            }
            throw error
        }
        return ActiveSegment(
            id: session.segmentID,
            sequence: session.sequence,
            sourcesByKind: sourcesByKind
        )
    }

    private func checkpointLocked() throws {
        guard let segment else { return }
        var commits: [UUID: RecordingJournalSourceCommit] = [:]
        for source in segment.sourcesByKind.values {
            commits[source.id] = try source.writer.checkpointSnapshot()
        }
        guard !commits.isEmpty else { return }
        _ = try store.recordCheckpoints(
            recordingID: recordingID,
            commitsBySourceID: commits
        )
    }

    private func drainAndCommitLocked(_ segment: ActiveSegment) throws {
        var commits: [UUID: RecordingJournalSourceCommit] = [:]
        var firstError: Error?
        for source in segment.sourcesByKind.values {
            do {
                commits[source.id] = try source.writer.drainAndCloseSnapshot()
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        guard !commits.isEmpty else { return }
        _ = try store.recordCheckpoints(
            recordingID: recordingID,
            commitsBySourceID: commits
        )
    }

    private func discardJournalLocked() throws {
        try store.markDiscarded(recordingID: recordingID)
        try store.discardInflightRecording(recordingID: recordingID)
        state = .discarded
    }

    private func preserveAfterCloseFailureLocked() throws {
        let manifest = try store.loadManifest(recordingID: recordingID)
        switch manifest.state {
        case .recording, .stopping:
            _ = try store.transition(
                recordingID: recordingID,
                to: .recoverable
            )
            state = .recoverable
        case .recoverable:
            state = .recoverable
        case .promoted, .historyStored, .finalized:
            throw SegmentedRecordingJournalControllerError.controllerClosed
        }
    }

    private func cancelCheckpointTimerLocked() {
        checkpointTimer?.setEventHandler {}
        checkpointTimer?.cancel()
        checkpointTimer = nil
    }
}
