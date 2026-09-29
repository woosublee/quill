import Foundation

// #434: the delete-cancel toast's countdown bar.
@main
struct ToastCountdownTests {
    static func main() {
        precondition(ToastCountdown.remainingFraction(elapsed: 0, duration: 5) == 1)
        precondition(ToastCountdown.remainingFraction(elapsed: 2.5, duration: 5) == 0.5)
        precondition(ToastCountdown.remainingFraction(elapsed: 5, duration: 5) == 0)
        precondition(ToastCountdown.remainingFraction(elapsed: 9, duration: 5) == 0, "never below empty")
        precondition(ToastCountdown.remainingFraction(elapsed: -1, duration: 5) == 1, "never above full")
        precondition(ToastCountdown.remainingFraction(elapsed: 1, duration: 0) == 0)

        // Reduce Motion: whole-second steps.
        precondition(ToastCountdown.steppedRemainingFraction(elapsed: 0, duration: 5) == 1)
        precondition(ToastCountdown.steppedRemainingFraction(elapsed: 0.4, duration: 5) == 1)
        precondition(ToastCountdown.steppedRemainingFraction(elapsed: 1, duration: 5) == 0.8)
        precondition(ToastCountdown.steppedRemainingFraction(elapsed: 4.2, duration: 5) == 0.2)
        precondition(ToastCountdown.steppedRemainingFraction(elapsed: 5, duration: 5) == 0)
        print("ToastCountdownTests passed")
    }
}
