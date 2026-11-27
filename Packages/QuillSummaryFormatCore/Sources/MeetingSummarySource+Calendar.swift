import Foundation
import QuillNoteCore

public extension MeetingSummaryCalendarContext {
    /// A note's matched event as a summary reads it: the title, the times,
    /// and each attendee's name, or their email when the name is blank.
    init(match: CalendarEventMatch) {
        self.init(
            title: match.title,
            start: match.start,
            end: match.end,
            attendees: match.attendees.compactMap {
                Self.attendeeLabel(displayName: $0.displayName, email: $0.email)
            }
        )
    }
}

public extension MeetingSummarySource {
    /// What a note's summary is made from: its transcript and, when it has
    /// one, its matched event. Both apps build a note's summary source here.
    init(
        transcript: String,
        calendarMatch: CalendarEventMatch?,
        languageContext: MeetingSummaryLanguageContext
    ) {
        self.init(
            transcript: transcript,
            calendar: calendarMatch.map(MeetingSummaryCalendarContext.init(match:)),
            languageContext: languageContext
        )
    }

    /// The source without a language, for comparing fingerprints only, as in
    /// whether a saved summary is stale.
    static func availability(transcript: String, calendarMatch: CalendarEventMatch?) -> MeetingSummarySource {
        MeetingSummarySource(
            transcript: transcript,
            calendarMatch: calendarMatch,
            languageContext: MeetingSummaryLanguageContext(
                requestedOutputLanguage: "",
                appliedLanguageCode: "",
                resolutionSource: .unavailable
            )
        )
    }
}
