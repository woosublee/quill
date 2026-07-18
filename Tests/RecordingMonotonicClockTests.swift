import Foundation

@main
struct RecordingMonotonicClockTests {
    static func main() {
        let first = RecordingMonotonicClock.nowNanoseconds()
        let second = RecordingMonotonicClock.nowNanoseconds()

        precondition(second >= first, "recording monotonic clock must not move backward")
        print("RecordingMonotonicClockTests passed")
    }
}
