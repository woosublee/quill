import Foundation

struct RecordingMonotonicClock {
    static func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}
