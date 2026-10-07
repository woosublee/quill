import AVFoundation
import Foundation

/// The span an imported file was recorded over, from the creation date
/// recorders write into the file. Filesystem dates are not used: copying or
/// downloading a file changes them.
struct AudioFileRecordingTime: Equatable {
    let start: Date
    let end: Date

    static func make(creationDate: Date?, duration: TimeInterval) -> AudioFileRecordingTime? {
        guard let creationDate, duration.isFinite, duration > 0 else { return nil }
        return AudioFileRecordingTime(start: creationDate, end: creationDate.addingTimeInterval(duration))
    }

    /// Reads metadata only; the audio is not decoded.
    static func read(from url: URL) async -> AudioFileRecordingTime? {
        let asset = AVURLAsset(url: url)
        guard let item = try? await asset.load(.creationDate),
              let date = try? await item.load(.dateValue),
              let duration = try? await asset.load(.duration) else {
            return nil
        }
        return make(creationDate: date, duration: duration.seconds)
    }
}

enum CalendarDayEvents {
    static func dayInterval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    static func meetingCandidates(_ events: [CalendarEvent]) -> [CalendarEvent] {
        events.filter(\.isMeetingCandidate).sorted {
            $0.start != $1.start ? $0.start < $1.start : $0.title < $1.title
        }
    }

    static func recommendation(in events: [CalendarEvent], recording: AudioFileRecordingTime?) -> CalendarEvent? {
        guard let recording else { return nil }
        return CalendarEventMatcher.bestMatch(
            recordingStartedAt: recording.start,
            recordingEndedAt: recording.end,
            events: events
        )
    }
}

enum ImportCalendarTitle {
    /// Same form as applying a calendar suggestion after recording.
    static func title(for event: CalendarEvent, recording: AudioFileRecordingTime?) -> String {
        NoteTitleResolver.calendarAppliedTitle(
            suggestedTitle: event.title.trimmingCharacters(in: .whitespacesAndNewlines),
            recordingStartedAt: recording?.start ?? event.start
        )
    }
}

enum PipelineHistoryOrdering {
    /// Index that keeps a newest-first list ordered. A new note goes above
    /// one with the same time, like the old insert-at-top behavior.
    static func insertionIndex(for timestamp: Date, in timestamps: [Date]) -> Int {
        timestamps.firstIndex { $0 <= timestamp } ?? timestamps.count
    }
}
