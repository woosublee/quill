import Foundation
import QuillNoteUI

/// Lets the person stop only a note's cleanup step from the Note Browser
/// (#699). The transcript is then kept as it is, recorded as not
/// post-processed, with no warning: the same as the iPhone's cancel.
final class PostProcessingStopSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var cancelRunningStep: (() -> Void)?
    private var progressSink: (@Sendable () -> Void)?
    private var keptProgress: NoteCleanupProgress?

    /// Called when this cleanup's progress moves (#697): the note's one bar
    /// then reads `progress`. A sink that runs later than the next report
    /// still reads the newest value, so reports that hop threads out of
    /// order can't move the bar back or make a new split out of an early 0
    /// of N.
    func onProgress(_ sink: @escaping @Sendable () -> Void) {
        lock.withLock { progressSink = sink }
    }

    /// The progress kept so far, in the order the cleanup reported it, with
    /// the shared forward-only rule (`NoteCleanupProgress.kept`).
    var progress: NoteCleanupProgress? {
        lock.withLock { keptProgress }
    }

    /// Chunks cleaned out of the chunk count. Nothing is reported once the
    /// person stopped the cleanup.
    func reportProgress(completed: Int, total: Int) {
        let sink = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !stopped, let progressSink else { return nil }
            let report = NoteCleanupProgress(completedChunkCount: completed, totalChunkCount: total)
            guard let next = NoteCleanupProgress.kept(after: keptProgress, report: report) else { return nil }
            keptProgress = next
            return progressSink
        }
        sink?()
    }

    var isStopped: Bool {
        lock.withLock { stopped }
    }

    /// Stops the step: a running request is cancelled and `run` returns nil.
    func stop() {
        let cancel = lock.withLock { () -> (() -> Void)? in
            stopped = true
            defer { cancelRunningStep = nil }
            return cancelRunningStep
        }
        cancel?()
    }

    /// Runs the cleanup step. Returns nil as soon as the person stops it,
    /// before or while it runs, without waiting for a step that is slow to
    /// notice the cancel. Cancelling the calling task still cancels the step
    /// and throws as usual.
    func run<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value? {
        let step = Task { try await operation() }
        defer { lock.withLock { cancelRunningStep = nil } }
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<Value, Error>?, Never>) in
                let finish = ResumeOnce(continuation)
                let stoppedBeforeStart = lock.withLock { () -> Bool in
                    if stopped { return true }
                    cancelRunningStep = {
                        step.cancel()
                        finish.resume(nil)
                    }
                    return false
                }
                if stoppedBeforeStart {
                    step.cancel()
                    finish.resume(nil)
                    return
                }
                Task { finish.resume(await step.result) }
            }
        } onCancel: {
            step.cancel()
        }
        guard let outcome, !isStopped else { return nil }
        return try outcome.get()
    }
}

/// Resumes a continuation once: the step's end and a stop can both try.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        let pending = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
