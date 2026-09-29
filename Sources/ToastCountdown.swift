import Foundation

/// How much of a toast's countdown bar is left (#434).
enum ToastCountdown {
    /// The remaining fraction, from 1 when it starts to 0 when time is up.
    static func remainingFraction(elapsed: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, 1 - elapsed / duration))
    }

    /// The remaining fraction in whole-second steps, for Reduce Motion.
    static func steppedRemainingFraction(elapsed: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        let remainingSeconds = max(0, duration - max(0, elapsed))
        return min(1, remainingSeconds.rounded(.up) / duration)
    }
}
