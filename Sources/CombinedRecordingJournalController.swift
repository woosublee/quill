import Foundation

enum CombinedRecordingJournalControllerError: Error, Equatable {
    case controllerClosed
}

struct CombinedRecordingJournalStopResult: Equatable {
    let microphoneSourceURL: URL
    let microphoneCommit: RecordingJournalSourceCommit
    let systemAudioSourceURL: URL
    let systemAudioCommit: RecordingJournalSourceCommit
}

final class CombinedRecordingJournalController {
    private static let lifecycleQueueKey = DispatchSpecificKey<UInt8>()

    private enum State {
        case recording
        case stopped(CombinedRecordingJournalStopResult)
        case recoverable
        case discarded
    }

    let recordingID: UUID
    let microphoneSink: any NormalizedPCM16Sink
    let systemAudioSink: any NormalizedPCM16Sink

    private let store: RecordingJournalStore
    private let microphoneWriter: RecordingPCMJournalWriter
    private let systemAudioWriter: RecordingPCMJournalWriter
    private let microphoneSourceID: UUID
    private let systemAudioSourceID: UUID
    private let microphoneSourceURL: URL
    private let systemAudioSourceURL: URL
    private let lifecycleQueue = DispatchQueue(
        label: "com.woosublee.quill.recording-journal.combined-lifecycle"
    )
    private var checkpointTimer: DispatchSourceTimer?
    private var state: State = .recording
    private var didReportCheckpointFailure = false

    convenience init(
        request: CombinedRecordingJournalCreateRequest,
        store: RecordingJournalStore
    ) throws {
        try self.init(
            request: request,
            store: store,
            makeWriter: { try RecordingPCMJournalWriter(session: $0, store: $1) }
        )
    }

    init(
        request: CombinedRecordingJournalCreateRequest,
        store: RecordingJournalStore,
        makeWriter: (
            RecordingJournalSession,
            RecordingJournalStore
        ) throws -> RecordingPCMJournalWriter
    ) throws {
        let session = try store.createCombined(request)
        let microphoneWriter: RecordingPCMJournalWriter
        let systemAudioWriter: RecordingPCMJournalWriter
        do {
            microphoneWriter = try makeWriter(
                session.microphoneSession,
                store
            )
            systemAudioWriter = try makeWriter(
                session.systemAudioSession,
                store
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
        self.microphoneWriter = microphoneWriter
        self.systemAudioWriter = systemAudioWriter
        self.microphoneSink = RecordingJournalSourceSink(
            writer: microphoneWriter,
            monotonicAnchorNanoseconds: request.monotonicAnchorNanoseconds
        )
        self.systemAudioSink = RecordingJournalSourceSink(
            writer: systemAudioWriter,
            monotonicAnchorNanoseconds: request.monotonicAnchorNanoseconds
        )
        self.microphoneSourceID = request.microphoneSourceID
        self.systemAudioSourceID = request.systemAudioSourceID
        self.microphoneSourceURL = session.microphoneSession.sourceURL
        self.systemAudioSourceURL = session.systemAudioSession.sourceURL
        lifecycleQueue.setSpecific(
            key: Self.lifecycleQueueKey,
            value: 1
        )
    }

    deinit {
        checkpointTimer?.setEventHandler {}
        checkpointTimer?.cancel()
    }

    func startCheckpointing(
        every interval: TimeInterval = 7,
        callbackQueue: DispatchQueue = .main,
        onFirstFailure: @escaping (Error) -> Void
    ) {
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            guard case .recording = self.state,
                  self.checkpointTimer == nil else {
                return
            }

            let timer = DispatchSource.makeTimerSource(
                queue: self.lifecycleQueue
            )
            timer.schedule(
                deadline: .now() + interval,
                repeating: interval
            )
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                do {
                    try self.checkpointLocked()
                } catch {
                    guard !self.didReportCheckpointFailure else {
                        return
                    }
                    self.didReportCheckpointFailure = true
                    callbackQueue.async {
                        onFirstFailure(error)
                    }
                }
            }
            timer.resume()
            self.checkpointTimer = timer
        }
    }

    func checkpoint() throws {
        try lifecycleQueue.sync {
            guard case .recording = state else {
                throw CombinedRecordingJournalControllerError.controllerClosed
            }
            try checkpointLocked()
        }
    }

    func stopAndClose() throws -> CombinedRecordingJournalStopResult {
        try lifecycleQueue.sync {
            switch state {
            case .stopped(let result):
                return result
            case .recording:
                cancelCheckpointTimerLocked()
                _ = try store.transition(
                    recordingID: recordingID,
                    to: .stopping
                )
                do {
                    let commits = try drainAndCommitLocked()
                    let result = CombinedRecordingJournalStopResult(
                        microphoneSourceURL: microphoneSourceURL,
                        microphoneCommit: commits.microphone,
                        systemAudioSourceURL: systemAudioSourceURL,
                        systemAudioCommit: commits.systemAudio
                    )
                    state = .stopped(result)
                    return result
                } catch {
                    try? preserveAfterCloseFailureLocked()
                    throw error
                }
            case .recoverable, .discarded:
                throw CombinedRecordingJournalControllerError.controllerClosed
            }
        }
    }

    func preserveForRecovery() throws {
        try lifecycleQueue.sync {
            switch state {
            case .recoverable, .stopped:
                return
            case .discarded:
                throw CombinedRecordingJournalControllerError.controllerClosed
            case .recording:
                cancelCheckpointTimerLocked()
                do {
                    _ = try drainAndCommitLocked()
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
                throw CombinedRecordingJournalControllerError.controllerClosed
            case .recording:
                cancelCheckpointTimerLocked()
                _ = try? microphoneWriter.drainAndCloseSnapshot()
                _ = try? systemAudioWriter.drainAndCloseSnapshot()
                try discardJournalLocked()
            case .recoverable:
                try discardJournalLocked()
            }
        }
    }

    private func checkpointLocked() throws {
        let microphoneCommit = try microphoneWriter.checkpointSnapshot()
        let systemAudioCommit = try systemAudioWriter.checkpointSnapshot()
        _ = try store.recordCheckpoints(
            recordingID: recordingID,
            commitsBySourceID: [
                microphoneSourceID: microphoneCommit,
                systemAudioSourceID: systemAudioCommit
            ]
        )
    }

    private func drainAndCommitLocked() throws -> (
        microphone: RecordingJournalSourceCommit,
        systemAudio: RecordingJournalSourceCommit
    ) {
        var microphoneCommit: RecordingJournalSourceCommit?
        var systemAudioCommit: RecordingJournalSourceCommit?
        var firstError: Error?

        do {
            microphoneCommit = try microphoneWriter.drainAndCloseSnapshot()
        } catch {
            firstError = error
        }
        do {
            systemAudioCommit = try systemAudioWriter.drainAndCloseSnapshot()
        } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
        guard let microphoneCommit, let systemAudioCommit else {
            throw CombinedRecordingJournalControllerError.controllerClosed
        }

        _ = try store.recordCheckpoints(
            recordingID: recordingID,
            commitsBySourceID: [
                microphoneSourceID: microphoneCommit,
                systemAudioSourceID: systemAudioCommit
            ]
        )
        return (microphoneCommit, systemAudioCommit)
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
            throw CombinedRecordingJournalControllerError.controllerClosed
        }
    }

    private func cancelCheckpointTimerLocked() {
        checkpointTimer?.setEventHandler {}
        checkpointTimer?.cancel()
        checkpointTimer = nil
    }
}
