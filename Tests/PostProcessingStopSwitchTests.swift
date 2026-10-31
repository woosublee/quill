import Foundation
import QuillNoteUI

/// #699: Cancel Post-processing stops only the cleanup step.
@main
struct PostProcessingStopSwitchTests {
    static func main() async throws {
        try await testStopBeforeTheStepSkipsIt()
        try await testStopWhileRunningCancelsTheRequest()
        try await testUnstoppedStepReturnsItsResult()
        try await testUnstoppedStepFailureStillThrows()
        try await testCallerCancelStillThrows()
        try await testStopDoesNotWaitForASlowStep()
        testProgressReachesTheSinkUntilStopped()
        print("PostProcessingStopSwitchTests passed")
    }

    private struct SyntheticFailure: Error {}

    /// The cleanup's chunk progress feeds the note's one bar (#697) until
    /// the person stops it, kept in report order with the shared
    /// forward-only rule, so a sink that runs late still reads the newest
    /// value.
    private static func testProgressReachesTheSinkUntilStopped() {
        final class Log: @unchecked Sendable {
            let lock = NSLock()
            var calls = 0
        }
        let log = Log()
        let stopSwitch = PostProcessingStopSwitch()
        stopSwitch.reportProgress(completed: 0, total: 3)
        precondition(stopSwitch.progress == nil, "nothing kept before a sink")
        stopSwitch.onProgress {
            log.lock.withLock { log.calls += 1 }
        }
        stopSwitch.reportProgress(completed: 0, total: 3)
        stopSwitch.reportProgress(completed: 1, total: 3)
        stopSwitch.reportProgress(completed: 1, total: 3)
        precondition(log.lock.withLock { log.calls } == 2, "a report that doesn't move the bar isn't sent")
        precondition(stopSwitch.progress == NoteCleanupProgress(completedChunkCount: 1, totalChunkCount: 3))
        // A fallback model splits again: it continues from a third.
        stopSwitch.reportProgress(completed: 0, total: 2)
        stopSwitch.reportProgress(completed: 1, total: 2)
        let kept = stopSwitch.progress!
        precondition(abs(kept.fraction - (1.0 / 3 + 2.0 / 3 / 2)) < 1e-9, "\(kept.fraction)")
        stopSwitch.stop()
        stopSwitch.reportProgress(completed: 2, total: 2)
        precondition(stopSwitch.progress == kept, "progress after a stop is dropped")
    }

    private static func testStopBeforeTheStepSkipsIt() async throws {
        let stopSwitch = PostProcessingStopSwitch()
        stopSwitch.stop()
        let result = try await stopSwitch.run { () async throws -> String in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "cleaned"
        }
        precondition(result == nil, "a stopped step returns nothing")
    }

    private static func testStopWhileRunningCancelsTheRequest() async throws {
        let stopSwitch = PostProcessingStopSwitch()
        let stopper = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            stopSwitch.stop()
        }
        let started = Date()
        // The request stops with an error; the person's stop wins over it.
        let result = try await stopSwitch.run { () async throws -> String in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "cleaned"
        }
        _ = await stopper.value
        precondition(result == nil, "stopped mid-request returns nothing")
        precondition(Date().timeIntervalSince(started) < 2, "the request was cancelled")
        precondition(stopSwitch.isStopped)
    }

    private static func testUnstoppedStepReturnsItsResult() async throws {
        let result = try await PostProcessingStopSwitch().run { "cleaned" }
        precondition(result == "cleaned")
    }

    private static func testUnstoppedStepFailureStillThrows() async throws {
        do {
            _ = try await PostProcessingStopSwitch().run { () async throws -> String in
                throw SyntheticFailure()
            }
            preconditionFailure("a failure without a stop must throw")
        } catch is SyntheticFailure {}
    }

    private static func testCallerCancelStillThrows() async throws {
        let stopSwitch = PostProcessingStopSwitch()
        let caller = Task {
            try await stopSwitch.run { () async throws -> String in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "cleaned"
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        caller.cancel()
        switch await caller.result {
        case .failure(let error):
            precondition(error is CancellationError, "the job's own cancel throws")
        case .success:
            preconditionFailure("the job's own cancel isn't a stop")
        }
    }

    /// A step that ignores cancellation (a busy local model) doesn't keep
    /// the note waiting once the person stops it.
    private static func testStopDoesNotWaitForASlowStep() async throws {
        let stopSwitch = PostProcessingStopSwitch()
        let stopper = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            stopSwitch.stop()
        }
        let started = Date()
        let result = try await stopSwitch.run { () async -> String in
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    continuation.resume()
                }
            }
            return "cleaned"
        }
        _ = await stopper.value
        precondition(result == nil)
        precondition(Date().timeIntervalSince(started) < 2, "the stop returns at once")
    }
}
