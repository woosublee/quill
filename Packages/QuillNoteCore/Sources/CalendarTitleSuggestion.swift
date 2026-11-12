import Foundation

/// A note's calendar title suggestion, alike on the Mac and the iPhone
/// (#832): the "Calendar suggested title … Apply" row above the note.
public enum CalendarTitleSuggestion {
    /// The title Apply sets: the recording's date, then the event's title
    /// ("2026-11-12 Weekly sync").
    public static func appliedTitle(suggestedTitle: String, date: Date) -> String {
        "\(dateFormatter.string(from: date)) \(suggestedTitle)"
    }

    /// The suggestion to show, with what Apply sets, or nil.
    ///
    /// It shows even when the note has a title of its own (#832), unless
    /// that title already is the event's title or its applied form, the
    /// event's title is the note's title (`titleState == .applied`, a
    /// recording started from a meeting reminder), or the person closed it
    /// or pressed Apply (both record a dismissal, so the event stays
    /// suggested and clearing the title goes back to the date title).
    /// - Parameters:
    ///   - customTitle: the title the person typed or applied, if any.
    ///   - date: the date Apply puts in front of the title.
    ///   - isDismissed: the person closed this suggestion
    ///     (`NoteNoticeDismissals.Notice.calendarTitleSuggestion`).
    public static func suggestion(
        calendarMatch: CalendarEventMatch?,
        customTitle: String?,
        date: Date,
        isDismissed: Bool
    ) -> (suggested: String, applied: String)? {
        guard !isDismissed,
              let calendarMatch, calendarMatch.titleState == .suggested,
              let suggested = calendarMatch.suggestedTitle else { return nil }
        let applied = appliedTitle(suggestedTitle: suggested, date: date)
        if let current = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           current == applied || current == suggested {
            return nil
        }
        return (suggested, applied)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// Which notes look for their calendar event again, after the recording
/// stopped (#832). A refresh looks only for recent notes with no event.
/// Opening a note checks it whatever it has: a note with no event looks for
/// one, and a note whose event was deleted gets the event now at that time.
///
/// It runs whenever a calendar is connected, apart from meeting reminders.
/// Each app decides when to look (launching, coming forward, a calendar
/// change, and opening a note) and reads its own calendars; which notes a
/// lookup covers and how often is decided here.
public enum CalendarMatchLookup {
    /// How far back a refresh matches notes: an event added after
    /// the meeting is usually added within days.
    public static let recentWindow: TimeInterval = 14 * 24 * 60 * 60

    /// Opening the same note again within this doesn't look again, so
    /// clicking back and forth through notes doesn't repeat the request.
    public static let noteOpenInterval: TimeInterval = 5 * 60

    /// How often launching, coming forward, or choosing calendars looks
    /// again for recent notes. A calendar change on the device looks at once.
    public static let refreshInterval: TimeInterval = 15 * 60

    /// How often a calendar change on the device looks again: changes come
    /// in bursts while calendars sync.
    public static let calendarChangeInterval: TimeInterval = 60

    /// The span to read for these recordings: from the earliest start to
    /// the latest end, or nil when there is none.
    public static func lookupRange(for recordings: [(start: Date, end: Date)]) -> DateInterval? {
        guard let start = recordings.map(\.start).min(),
              let end = recordings.map(\.end).max(), end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// The note has no event yet and has a recording time to match. A note
    /// without one (an imported file with no recording time) is skipped.
    public static func needsLookup(
        calendarMatch: CalendarEventMatch?,
        recordingStartedAt: Date?,
        recordingEndedAt: Date?
    ) -> Bool {
        guard calendarMatch == nil,
              let recordingStartedAt, let recordingEndedAt else { return false }
        return recordingEndedAt > recordingStartedAt
    }

    /// The span a calendar refresh reads for recent notes, ending `now`.
    public static func recentRange(now: Date) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-recentWindow), end: now)
    }

    /// A refresh matches the note: it needs a lookup and was recorded within
    /// the recent window.
    public static func isRecentCandidate(
        calendarMatch: CalendarEventMatch?,
        recordingStartedAt: Date?,
        recordingEndedAt: Date?,
        now: Date
    ) -> Bool {
        guard needsLookup(
            calendarMatch: calendarMatch,
            recordingStartedAt: recordingStartedAt,
            recordingEndedAt: recordingEndedAt
        ), let recordingStartedAt else { return false }
        return recentRange(now: now).contains(recordingStartedAt)
    }

    /// Opening the note checks its event: it has a recording time, and it
    /// wasn't checked on opening within `noteOpenInterval`.
    public static func shouldCheckOnOpen(
        recordingStartedAt: Date?,
        recordingEndedAt: Date?,
        lastCheckedAt: Date?,
        now: Date
    ) -> Bool {
        guard let recordingStartedAt, let recordingEndedAt,
              recordingEndedAt > recordingStartedAt else { return false }
        guard let lastCheckedAt else { return true }
        return now.timeIntervalSince(lastCheckedAt) >= noteOpenInterval
    }

    /// The event to suggest after checking a note's recording time, or nil
    /// to leave the note as it is.
    ///
    /// - With no event saved, the best match.
    /// - With an event saved that is still there, nothing.
    /// - With a suggested event saved that is gone, the best other match;
    ///   with none, nothing, so the saved event stays.
    /// - An event the person chose (on import) or recorded from (a meeting
    ///   reminder) is never replaced.
    ///
    /// An event is gone only when its calendar was read in full
    /// (`readCalendarIDs`): a calendar that failed or isn't chosen any more
    /// says nothing about it. The same meeting in another calendar, which
    /// merging shows once, counts as still there.
    public static func eventToSuggest(
        saved: CalendarEventMatch?,
        events: [CalendarEvent],
        readCalendarIDs: Set<String>,
        recordingStartedAt: Date,
        recordingEndedAt: Date
    ) -> CalendarEvent? {
        if let saved {
            guard saved.matchSource == .overlapSuggestion,
                  readCalendarIDs.contains(saved.calendarID),
                  !events.contains(where: {
                      ($0.calendarID == saved.calendarID && $0.id == saved.eventID)
                          || ($0.title == saved.title && $0.start == saved.start && $0.end == saved.end)
                  }) else {
                return nil
            }
        }
        return CalendarEventMatcher.bestMatch(
            recordingStartedAt: recordingStartedAt,
            recordingEndedAt: recordingEndedAt,
            events: events
        )
    }
}
