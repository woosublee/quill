import Foundation
import QuillNoteCore

/// Which event a note links to when a meeting reminder started its recording
/// (#622). The events are invented.
struct AppStateCalendarMatchTests {
    static func main() throws {
        try reminderSnapshotBecomesTheNotesEvent()
        try incompleteSnapshotGivesNoEvent()
        try transcribedRecordingsCarryTheReminderEvent()
        print("AppStateCalendarMatchTests passed")
    }

    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private static func snapshot(title: String? = "Synthetic planning") -> RecordingCalendarSnapshot {
        RecordingCalendarSnapshot(
            eventID: "event-1",
            calendarID: "calendar-1",
            title: title,
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            matchSource: CalendarMatchSource.calendarNotification.rawValue,
            attendeeNames: ["Alex", "Sam"],
            provider: CalendarProvider.apple.rawValue
        )
    }

    private static func reminderSnapshotBecomesTheNotesEvent() throws {
        guard let match = AppState.calendarMatch(from: snapshot()) else {
            throw TestFailure("a complete snapshot is the note's event")
        }
        try expectEqual(match.eventID, "event-1", "event")
        try expectEqual(match.calendarID, "calendar-1", "calendar")
        try expectEqual(match.title, "Synthetic planning", "title")
        try expectEqual(match.start, start, "start")
        try expectEqual(match.end, start.addingTimeInterval(1_800), "end")
        try expectEqual(match.attendees.map(\.displayName), ["Alex", "Sam"], "attendees")
        try expectEqual(match.matchSource, .calendarNotification, "match source")
        try expectEqual(match.titleState, .applied, "title state")
        try expectEqual(match.provider, .apple, "provider")
        try expectEqual(match.accountID, AppState.appleCalendarAccountID, "Apple account")
    }

    /// Without a usable snapshot, the caller falls back to overlap matching.
    private static func incompleteSnapshotGivesNoEvent() throws {
        try expectEqual(AppState.calendarMatch(from: nil) == nil, true, "no snapshot")
        try expectEqual(AppState.calendarMatch(from: snapshot(title: nil)) == nil, true, "snapshot without a title")
    }

    /// The transcribed path runs live transcription, the recorder, and the
    /// calendar services, which these tests don't stand up. So this checks
    /// that the reminder's snapshot reaches the transcription job and is read
    /// before overlap matching.
    private static func transcribedRecordingsCarryTheReminderEvent() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let compact = source.filter { !$0.isWhitespace }
        let registrations = compact.components(separatedBy: "registerTranscriptionJob(").dropFirst()
        guard registrations.contains(where: {
            $0.prefix(while: { $0 != ")" }).contains("calendarSnapshot:recordingCalendarSnapshot")
        }) else {
            throw TestFailure("stopAndTranscribe must pass the reminder snapshot to the transcription job")
        }
        guard let start = source.range(of: "private func calendarMatchForHistoryItem(jobID: UUID)"),
              let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex) else {
            throw TestFailure("calendarMatchForHistoryItem not found")
        }
        let body = source[start.upperBound..<end.lowerBound]
        guard let snapshotRead = body.range(of: "Self.calendarMatch(from: job.calendarSnapshot)"),
              let overlapRead = body.range(of: "calendarEventMatch("),
              snapshotRead.lowerBound < overlapRead.lowerBound else {
            throw TestFailure("calendarMatchForHistoryItem must prefer the job's snapshot over overlap matching")
        }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
        guard actual == expected else {
            throw TestFailure("\(label): expected \(expected), got \(actual)")
        }
    }
}
