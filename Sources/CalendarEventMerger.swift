import Foundation

/// Combines events from several calendar sources. The same meeting often
/// arrives twice when a Google account is both connected directly and added
/// to the Mac Calendar app; the first group (Google) wins so its richer
/// attendee data is kept.
enum CalendarEventMerger {
    static func merge(_ groups: [[CalendarEvent]]) -> [CalendarEvent] {
        var seen = Set<Key>()
        var merged: [CalendarEvent] = []
        for group in groups {
            for event in group where seen.insert(Key(event)).inserted {
                merged.append(event)
            }
        }
        let order = Dictionary(uniqueKeysWithValues: CalendarProvider.allCases.enumerated().map { ($1, $0) })
        return merged.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.provider != rhs.provider {
                return order[lhs.provider, default: 0] < order[rhs.provider, default: 0]
            }
            if lhs.calendarID != rhs.calendarID { return lhs.calendarID < rhs.calendarID }
            return lhs.id < rhs.id
        }
    }

    private struct Key: Hashable {
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool

        init(_ event: CalendarEvent) {
            title = event.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            start = event.start
            end = event.end
            isAllDay = event.isAllDay
        }
    }
}
