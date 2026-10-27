import Foundation

/// Which event a note links to when a meeting reminder started its recording
/// (#622). The events are invented.
struct AppStateCalendarMatchTests {
    static func main() throws {
        try reminderSnapshotBecomesTheNotesEvent()
        try incompleteSnapshotFallsBackToOverlap()
        try transcribedRecordingsCarryTheReminderEvent()
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

    private static func incompleteSnapshotFallsBackToOverlap() throws {
        try expectEqual(AppState.calendarMatch(from: nil) == nil, true, "no snapshot")
        try expectEqual(AppState.calendarMatch(from: snapshot(title: nil)) == nil, true, "snapshot without a title")
    }

    /// The transcribed path runs live transcription, the recorder, and the
    /// calendar services, which these tests don't stand up. So this checks
    /// that the reminder's snapshot reaches the transcription job and is read
    /// before overlap matching.
    private static func transcribedRecordingsCarryTheReminderEvent() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        guard source.contains("isImportedAudio: false,\n            calendarSnapshot: recordingCalendarSnapshot\n") else {
            throw TestFailure("stopAndTranscribe must pass the reminder snapshot to the transcription job")
        }
        guard let historyMatch = source.range(of: "private func calendarMatchForHistoryItem(jobID: UUID)"),
              let snapshotRead = source.range(
                  of: "Self.calendarMatch(from: job.calendarSnapshot)",
                  range: historyMatch.upperBound..<source.endIndex
              ),
              let overlapRead = source.range(
                  of: "calendarEventMatch(",
                  range: historyMatch.upperBound..<source.endIndex
              ),
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
