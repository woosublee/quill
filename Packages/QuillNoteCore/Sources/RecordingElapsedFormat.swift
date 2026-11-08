import Foundation

/// How a recording's running time reads in the note list row and the note
/// detail ("Recording · 3:12"), the same on both apps (#697, the owner's
/// 2026-11-08 decisions r1 and r2): `m:ss`, or `h:mm:ss` from an hour on,
/// as the iPhone's recorder bar and Live Activity read. Each app passes the
/// time recorded so far; paused time isn't counted.
public enum RecordingElapsedFormat {
    public static func string(milliseconds: Int64) -> String {
        let totalSeconds = max(0, milliseconds / 1_000)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%lld:%02lld:%02lld", hours, minutes, seconds)
        }
        return String(format: "%lld:%02lld", minutes, seconds)
    }

    /// The time between two dates, for a recording that can't pause (the
    /// Mac's).
    public static func string(from start: Date, to now: Date) -> String {
        string(milliseconds: Int64((now.timeIntervalSince(start) * 1_000).rounded(.down)))
    }
}
