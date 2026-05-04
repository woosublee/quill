import Foundation

enum CalendarEventMatcher {
    static func bestMatch(recordingStartedAt: Date?, recordingEndedAt: Date?, events: [GoogleCalendarEvent]) -> GoogleCalendarEvent? {
        guard let recordingStartedAt, let recordingEndedAt, recordingEndedAt > recordingStartedAt else {
            return nil
        }
        return events
            .filter { !$0.isAllDay && $0.hasUsableTitle && $0.end > $0.start }
            .compactMap { event -> Candidate? in
                let overlapStart = max(recordingStartedAt, event.start)
                let overlapEnd = min(recordingEndedAt, event.end)
                let overlap = overlapEnd.timeIntervalSince(overlapStart)
                guard overlap > 0 else { return nil }
                return Candidate(event: event, overlap: overlap, startDistance: abs(event.start.timeIntervalSince(recordingStartedAt)))
            }
            .sorted { lhs, rhs in
                if lhs.overlap != rhs.overlap {
                    return lhs.overlap > rhs.overlap
                }
                if lhs.startDistance != rhs.startDistance {
                    return lhs.startDistance < rhs.startDistance
                }
                if lhs.event.start != rhs.event.start {
                    return lhs.event.start < rhs.event.start
                }
                if lhs.event.calendarID != rhs.event.calendarID {
                    return lhs.event.calendarID < rhs.event.calendarID
                }
                return lhs.event.id < rhs.event.id
            }
            .first?
            .event
    }

    private struct Candidate {
        let event: GoogleCalendarEvent
        let overlap: TimeInterval
        let startDistance: TimeInterval
    }
}
