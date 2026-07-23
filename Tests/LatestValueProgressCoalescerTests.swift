import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct LatestValueProgressCoalescerTests {
    static func main() throws {
        try testFirstValueSchedulesImmediately()
        try testBurstKeepsOnlyLatestPendingValue()
        try testInvalidateDropsScheduledDelivery()
        try testFreshCoalescerStartsIndependently()
        print("LatestValueProgressCoalescerTests passed")
    }

    private static func testFirstValueSchedulesImmediately() throws {
        let scheduler = ManualProgressScheduler()
        let deliveries = LockedValues<Int>()
        let coalescer = LatestValueProgressCoalescer<Int>(
            interval: 0.1,
            schedule: scheduler.schedule,
            deliver: { value in deliveries.append(value) }
        )

        coalescer.submit(1)

        try expect(scheduler.scheduledCount == 1, "first value schedules once")
        try expect(scheduler.delays == [0], "first value schedules without delay")
        scheduler.runNext()
        try expect(deliveries.values == [1], "first value delivered")
    }

    private static func testBurstKeepsOnlyLatestPendingValue() throws {
        let scheduler = ManualProgressScheduler()
        let deliveries = LockedValues<Int>()
        let coalescer = LatestValueProgressCoalescer<Int>(
            interval: 0.1,
            schedule: scheduler.schedule,
            deliver: { value in deliveries.append(value) }
        )

        coalescer.submit(1)
        for value in 2...10_000 {
            coalescer.submit(value)
        }

        try expect(scheduler.scheduledCount == 1, "burst keeps one immediate delivery")
        try expect(scheduler.delays == [0], "first delivery has no delay")
        scheduler.runNext()
        try expect(deliveries.values == [1], "first submitted value delivered first")
        try expect(scheduler.scheduledCount == 1, "latest pending value schedules once")
        try expect(scheduler.delays == [0.1], "pending value uses configured cadence")
        scheduler.runNext()
        try expect(deliveries.values == [1, 10_000], "only latest burst value delivered")
    }

    private static func testInvalidateDropsScheduledDelivery() throws {
        let scheduler = ManualProgressScheduler()
        let deliveries = LockedValues<Int>()
        let coalescer = LatestValueProgressCoalescer<Int>(
            interval: 0.1,
            schedule: scheduler.schedule,
            deliver: { value in deliveries.append(value) }
        )

        coalescer.submit(1)
        coalescer.invalidate()
        scheduler.runAll()

        try expect(deliveries.values.isEmpty, "invalidated delivery suppressed")
    }

    private static func testFreshCoalescerStartsIndependently() throws {
        let scheduler = ManualProgressScheduler()
        let deliveries = LockedValues<Int>()
        let first = LatestValueProgressCoalescer<Int>(
            interval: 0.1,
            schedule: scheduler.schedule,
            deliver: { value in deliveries.append(value) }
        )
        first.submit(1)
        first.invalidate()

        let second = LatestValueProgressCoalescer<Int>(
            interval: 0.1,
            schedule: scheduler.schedule,
            deliver: { value in deliveries.append(value) }
        )
        second.submit(2)
        scheduler.runAll()

        try expect(deliveries.values == [2], "new coalescer ignores old generation")
    }
}

private final class ManualProgressScheduler: @unchecked Sendable {
    typealias Operation = @Sendable () -> Void

    private let lock = NSLock()
    private var scheduled: [(delay: TimeInterval, operation: Operation)] = []

    var schedule: LatestValueProgressCoalescer<Int>.Schedule {
        { [weak self] delay, operation in
            guard let self else { return }
            self.lock.withLock {
                self.scheduled.append((delay, operation))
            }
        }
    }

    var scheduledCount: Int {
        lock.withLock { scheduled.count }
    }

    var delays: [TimeInterval] {
        lock.withLock { scheduled.map(\.delay) }
    }

    func runNext() {
        let operation = lock.withLock {
            scheduled.isEmpty ? nil : scheduled.removeFirst().operation
        }
        operation?()
    }

    func runAll() {
        while scheduledCount > 0 {
            runNext()
        }
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.withLock { storage }
    }

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }
}

private struct TestFailure: Error {
    let message: String
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw TestFailure(message: message)
    }
}
