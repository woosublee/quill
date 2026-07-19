import Foundation

enum SingleSourceRecordingJournalControllerError: Error, Equatable {
    case controllerClosed
}

final class SingleSourceRecordingJournalController {
    private static let lifecycleQueueKey = DispatchSpecificKey<UInt8>()

    private enum State {
        case recording
        case promoted(URL)
        case recoverable
        case discarded
    }

    let recordingID: UUID
    let sink: any NormalizedPCM16Sink

    private let store: RecordingJournalStore
    private let writer: RecordingPCMJournalWriter
    private let finalizer: RecordingArtifactFinalizer
    private let lifecycleQueue = DispatchQueue(
        label: "com.woosublee.quill.recording-journal.single-source-lifecycle"
    )
    private var checkpointTimer: DispatchSourceTimer?
    private var state: State = .recording
    private var didReportCheckpointFailure = false

    convenience init(
        request: RecordingJournalCreateRequest,
        store: RecordingJournalStore
    ) throws {
        try self.init(
            request: request,
            store: store,
            makeWriter: { try RecordingPCMJournalWriter(session: $0, store: $1) }
        )
    }

    init(
        request: RecordingJournalCreateRequest,
        store: RecordingJournalStore,
        makeWriter: (
            RecordingJournalSession,
            RecordingJournalStore
        ) throws -> RecordingPCMJournalWriter
    ) throws {
        let session = try store.createSingleSource(request)
        let writer: RecordingPCMJournalWriter
        do {
            writer = try makeWriter(session, store)
        } catch {
            try? store.markDiscarded(
                recordingID: request.recordingID
            )
            try? store.discardInflightRecording(
                recordingID: request.recordingID
            )
            throw error
        }
        self.recordingID = request.recordingID
        self.store = store
        self.writer = writer
        self.sink = writer
        self.finalizer = RecordingArtifactFinalizer(store: store)
        self.lifecycleQueue.setSpecific(
            key: Self.lifecycleQueueKey,
            value: 1
        )
    }

    deinit {
        let cancelTimer = {
            self.cancelCheckpointTimerLocked()
        }
        if DispatchQueue.getSpecific(key: Self.lifecycleQueueKey) != nil {
            cancelTimer()
        } else {
            lifecycleQueue.sync(execute: cancelTimer)
        }
    }

    func startCheckpointing(
        every interval: TimeInterval = 7,
        onFirstFailure: @escaping (Error) -> Void
    ) {
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            guard case .recording = self.state,
                  self.checkpointTimer == nil else {
                return
            }

            let timer = DispatchSource.makeTimerSource(queue: self.lifecycleQueue)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                do {
                    _ = try self.writer.checkpoint()
                } catch {
                    guard !self.didReportCheckpointFailure else { return }
                    self.didReportCheckpointFailure = true
                    onFirstFailure(error)
                }
            }
            timer.resume()
            self.checkpointTimer = timer
        }
    }

    func checkpoint() throws {
        try lifecycleQueue.sync {
            guard case .recording = state else {
                throw SingleSourceRecordingJournalControllerError.controllerClosed
            }
            _ = try writer.checkpoint()
        }
    }

    func finish() throws -> URL {
        try lifecycleQueue.sync {
            switch state {
            case .promoted(let url):
                return url
            case .recording:
                cancelCheckpointTimerLocked()
                do {
                    _ = try store.transition(
                        recordingID: recordingID,
                        to: .stopping
                    )
                    _ = try writer.drainAndClose()
                    let artifact = try finalizer.finalizeSingleSource(
                        recordingID: recordingID
                    )
                    let promotion = try finalizer.promote(artifact)
                    _ = try store.transition(
                        recordingID: recordingID,
                        to: .promoted,
                        promotion: promotion
                    )
                    state = .promoted(artifact.destinationURL)
                    return artifact.destinationURL
                } catch {
                    try? preserveAfterFinishFailureLocked()
                    throw error
                }
            case .recoverable, .discarded:
                throw SingleSourceRecordingJournalControllerError.controllerClosed
            }
        }
    }

    func preserveForRecovery() throws {
        try lifecycleQueue.sync {
            switch state {
            case .recoverable, .promoted:
                return
            case .discarded:
                throw SingleSourceRecordingJournalControllerError.controllerClosed
            case .recording:
                cancelCheckpointTimerLocked()
                _ = try writer.drainAndClose()
                _ = try store.transition(
                    recordingID: recordingID,
                    to: .recoverable
                )
                state = .recoverable
            }
        }
    }

    func discard() throws {
        try lifecycleQueue.sync {
            switch state {
            case .discarded:
                return
            case .promoted:
                throw SingleSourceRecordingJournalControllerError.controllerClosed
            case .recording:
                cancelCheckpointTimerLocked()
                _ = try? writer.drainAndClose()
                try discardJournalLocked()
            case .recoverable:
                try discardJournalLocked()
            }
        }
    }

    private func discardJournalLocked() throws {
        try store.markDiscarded(recordingID: recordingID)
        try store.discardInflightRecording(recordingID: recordingID)
        state = .discarded
    }

    private func preserveAfterFinishFailureLocked() throws {
        let manifest = try store.loadManifest(recordingID: recordingID)
        switch manifest.state {
        case .recording:
            _ = try? writer.drainAndClose()
            _ = try store.transition(
                recordingID: recordingID,
                to: .recoverable
            )
            state = .recoverable
        case .stopping:
            _ = try? writer.drainAndClose()
            _ = try store.transition(
                recordingID: recordingID,
                to: .recoverable
            )
            state = .recoverable
        case .recoverable:
            state = .recoverable
        case .promoted, .historyStored, .finalized:
            state = .promoted(store.permanentURL(recordingID: recordingID))
        }
    }

    private func cancelCheckpointTimerLocked() {
        checkpointTimer?.setEventHandler {}
        checkpointTimer?.cancel()
        checkpointTimer = nil
    }
}
