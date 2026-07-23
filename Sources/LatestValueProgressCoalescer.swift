import Foundation

final class LatestValueProgressCoalescer<Value: Sendable>: @unchecked Sendable {
    typealias Schedule = @Sendable (
        _ delay: TimeInterval,
        _ operation: @escaping @Sendable () -> Void
    ) -> Void

    private enum PendingValue {
        case none
        case value(Value)
    }

    private enum ScheduledDelivery: Sendable {
        case first(Value)
        case pending
    }

    static var mainQueueSchedule: Schedule {
        { delay, operation in
            if delay <= 0 {
                DispatchQueue.main.async(execute: operation)
            } else {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + delay,
                    execute: operation
                )
            }
        }
    }

    private let interval: TimeInterval
    private let schedule: Schedule
    private let deliver: @Sendable (Value) -> Void
    private let lock = NSLock()
    private var pendingValue: PendingValue = .none
    private var isScheduled = false
    private var hasSubmitted = false
    private var isInvalidated = false

    init(
        interval: TimeInterval = 0.1,
        schedule: @escaping Schedule = LatestValueProgressCoalescer<Value>.mainQueueSchedule,
        deliver: @escaping @Sendable (Value) -> Void
    ) {
        self.interval = max(0, interval)
        self.schedule = schedule
        self.deliver = deliver
    }

    func submit(_ value: Value) {
        let scheduled: (delay: TimeInterval, delivery: ScheduledDelivery)? = lock.withLock {
            guard !isInvalidated else { return nil }
            if !hasSubmitted {
                hasSubmitted = true
                isScheduled = true
                return (0, .first(value))
            }
            pendingValue = .value(value)
            guard !isScheduled else { return nil }
            isScheduled = true
            return (interval, .pending)
        }
        guard let scheduled else { return }
        schedule(scheduled.delay) { [weak self] in
            self?.runScheduledDelivery(scheduled.delivery)
        }
    }

    func invalidate() {
        lock.withLock {
            isInvalidated = true
            pendingValue = .none
            isScheduled = false
        }
    }

    private func runScheduledDelivery(_ scheduledDelivery: ScheduledDelivery) {
        let value: Value? = lock.withLock {
            guard !isInvalidated else { return nil }
            isScheduled = false
            switch scheduledDelivery {
            case .first(let value):
                return value
            case .pending:
                guard case .value(let value) = pendingValue else { return nil }
                pendingValue = .none
                return value
            }
        }
        guard let value else { return }
        deliver(value)
        schedulePendingValueIfNeeded()
    }

    private func schedulePendingValueIfNeeded() {
        let shouldSchedule = lock.withLock {
            guard !isInvalidated,
                  case .value = pendingValue,
                  !isScheduled else {
                return false
            }
            isScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        schedule(interval) { [weak self] in
            self?.runScheduledDelivery(.pending)
        }
    }
}
