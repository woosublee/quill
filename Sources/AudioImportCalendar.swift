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

    /// Only for a shown day that overlaps the recording: an overnight event
    /// listed on the next day is not suggested for yesterday's recording.
    static func recommendation(
        in events: [CalendarEvent],
        recording: AudioFileRecordingTime?,
        day: Date,
        calendar: Calendar = .current
    ) -> CalendarEvent? {
        guard let recording else { return nil }
        let shown = dayInterval(containing: day, calendar: calendar)
        guard recording.start < shown.end, recording.end > shown.start else { return nil }
        return CalendarEventMatcher.bestMatch(
            recordingStartedAt: recording.start,
            recordingEndedAt: recording.end,
            events: events
        )
    }
}

enum ImportCalendarTitle {
    /// Same form as applying a calendar suggestion after recording. Without a
    /// recording time the date is the day the person chose in the sheet.
    static func title(for event: CalendarEvent, recording: AudioFileRecordingTime?, chosenDay: Date) -> String {
        NoteTitleResolver.calendarAppliedTitle(
            suggestedTitle: event.title.trimmingCharacters(in: .whitespacesAndNewlines),
            recordingStartedAt: recording?.start ?? chosenDay
        )
    }
}

extension CalendarEvent {
    /// Google event IDs are unique only within a calendar, so selection uses
    /// provider, calendar, and event together.
    var selectionKey: String {
        "\(provider.rawValue)|\(calendarID)|\(id)"
    }
}

enum ImportCalendarSelection {
    /// The event key to keep selected after the list reloads. `nil` is
    /// "No event". A Google event picked by hand survives a failed Google
    /// read instead of snapping to the recommendation.
    static func next(
        current: String?,
        userChose: Bool,
        events: [CalendarEvent],
        recommendedKey: String?,
        googleFailed: Bool
    ) -> String? {
        guard userChose else { return recommendedKey }
        guard let current else { return nil }
        if events.contains(where: { $0.selectionKey == current }) { return current }
        if googleFailed, current.hasPrefix("\(CalendarProvider.google.rawValue)|") { return current }
        return recommendedKey
    }
}

enum PipelineHistoryOrdering {
    /// Index that keeps a newest-first list ordered. A new note goes above
    /// one with the same time, like the old insert-at-top behavior.
    static func insertionIndex(for timestamp: Date, in timestamps: [Date]) -> Int {
        timestamps.firstIndex { $0 <= timestamp } ?? timestamps.count
    }
}
