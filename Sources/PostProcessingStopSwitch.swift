import Foundation

/// Lets the person stop only a note's cleanup step from the Note Browser
/// (#699). The transcript is then kept as it is, recorded as not
/// post-processed, with no warning: the same as the iPhone's cancel.
final class PostProcessingStopSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var cancelRunningStep: (() -> Void)?
    private var progressSink: (@Sendable (_ completed: Int, _ total: Int) -> Void)?

    /// Where this cleanup's chunk progress goes (#697): the note's one bar.
    func onProgress(_ sink: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void) {
        lock.withLock { progressSink = sink }
    }

    /// Chunks cleaned out of the chunk count. Nothing is reported once the
    /// person stopped the cleanup.
    func reportProgress(completed: Int, total: Int) {
        let sink = lock.withLock { stopped ? nil : progressSink }
        sink?(completed, total)
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
