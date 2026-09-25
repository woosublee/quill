import Foundation
import os

/// Combines live transcription segments when the audio input is switched
/// mid-recording, so each input segment gets its own live transcriber.
enum LiveTranscriptSegments {
    static let separator = "\n"

    static func joined(_ parts: [String]) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }

    /// Returns nil when any audio was not live transcribed or a segment failed,
    /// so the caller falls back to transcribing the recorded file.
    static func finalTranscript(segments: [String?], isIncomplete: Bool) -> String? {
        guard !isIncomplete else { return nil }
        var texts: [String] = []
        for segment in segments {
            guard let segment else { return nil }
            texts.append(segment)
        }
        return joined(texts)
    }
}

/// Feeds one live transcriber segment's partial results to the live note at a
/// bounded cadence, and keeps the latest partial for when the segment ends.
final class LiveTranscriptSegmentFeed: @unchecked Sendable {
    private let latestPartial = OSAllocatedUnfairLock(initialState: "")
    private let coalescer: LatestValueProgressCoalescer<String>

    init(
        interval: TimeInterval,
        schedule: @escaping LatestValueProgressCoalescer<String>.Schedule = LatestValueProgressCoalescer<String>.mainQueueSchedule,
        deliver: @escaping @Sendable (String) -> Void
    ) {
        coalescer = LatestValueProgressCoalescer<String>(
            interval: interval,
            schedule: schedule,
            deliver: deliver
        )
    }

    func submit(_ text: String) {
        latestPartial.withLock { $0 = text }
        coalescer.submit(text)
    }

    /// Stops further deliveries and returns the latest partial, delivered or not.
    func finish() -> String {
        coalescer.invalidate()
        return latestPartial.withLock { $0 }
    }
}
