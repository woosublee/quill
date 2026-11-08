import Foundation

/// How a note's audio time reads, the same on the Mac and the iPhone (#697):
/// `m:ss`, or `h:mm:ss` from an hour. The player's elapsed and total time
/// and the download bar use it.
public enum NoteAudioDuration {
    /// About 31,700 years: past any real recording, well inside `Int`.
    public static let maximumSeconds: TimeInterval = 1e12

    /// Partial seconds are dropped. A time that isn't a finite number, or is
    /// below zero, reads as `0:00`; one too large to be real is held at
    /// `maximumSeconds` rather than trapping.
    public static func text(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(min(seconds, maximumSeconds).rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}
