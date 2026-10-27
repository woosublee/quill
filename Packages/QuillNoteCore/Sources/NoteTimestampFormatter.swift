import Foundation

/// How a note's date reads in a list row and in its detail, the same on the
/// Mac and the iPhone for a synced note. Narrow and non-breaking spaces from
/// the formatter become plain spaces.
public enum NoteTimestampFormatter {
    /// The Mac note row and the iPhone detail: full month name, day,
    /// weekday, and time.
    public static let rowTemplate = "MMMMdEEEjm"
    /// The iPhone list row: like `rowTemplate` with a short month name, so
    /// the date and length fit one line on a phone.
    public static let compactRowTemplate = "MMMdEEEjm"
    /// A note's detail header, with the year.
    public static let detailTemplate = "yMMMdEEEjm"

    public static func rowTimestamp(
        for date: Date,
        locale: Locale = .current,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> String {
        normalized(cache.string(
            from: date, role: .row, template: rowTemplate,
            locale: locale, calendar: calendar, timeZone: timeZone
        ))
    }

    public static func compactRowTimestamp(
        for date: Date,
        locale: Locale = .current,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> String {
        normalized(cache.string(
            from: date, role: .compactRow, template: compactRowTemplate,
            locale: locale, calendar: calendar, timeZone: timeZone
        ))
    }

    /// The recording's start and end as an interval, or `fallback` alone
    /// when the recording times are missing or out of order.
    public static func detailTimestamp(
        recordingStartedAt: Date?,
        recordingEndedAt: Date?,
        fallback: Date,
        locale: Locale = .current,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> String {
        guard let startedAt = recordingStartedAt,
              let endedAt = recordingEndedAt,
              endedAt >= startedAt else {
            return normalized(cache.string(
                from: fallback, role: .detail, template: detailTemplate,
                locale: locale, calendar: calendar, timeZone: timeZone
            ))
        }
        return normalized(cache.string(
            from: startedAt, to: endedAt, template: detailTemplate,
            locale: locale, calendar: calendar, timeZone: timeZone
        ))
    }

    public static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{2009}", with: " ")
    }

    private enum FormatterRole: Hashable {
        case row
        case compactRow
        case detail
        case interval
    }

    private struct FormatterKey: Hashable {
        let role: FormatterRole
        let localeIdentifier: String
        let hourCycle: Locale.HourCycle
        let calendarIdentifier: Calendar.Identifier
        let timeZoneIdentifier: String
    }

    private final class FormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private var dateFormatters: [FormatterKey: DateFormatter] = [:]
        private var intervalFormatters: [FormatterKey: DateIntervalFormatter] = [:]

        func string(
            from date: Date,
            role: FormatterRole,
            template: String,
            locale: Locale,
            calendar: Calendar,
            timeZone: TimeZone
        ) -> String {
            lock.lock()
            defer { lock.unlock() }
            let key = FormatterKey(
                role: role,
                localeIdentifier: locale.identifier,
                hourCycle: locale.hourCycle,
                calendarIdentifier: calendar.identifier,
                timeZoneIdentifier: timeZone.identifier
            )
            let formatter: DateFormatter
            if let cached = dateFormatters[key] {
                formatter = cached
            } else {
                let created = DateFormatter()
                created.locale = locale
                created.calendar = calendar
                created.timeZone = timeZone
                created.setLocalizedDateFormatFromTemplate(template)
                dateFormatters[key] = created
                formatter = created
            }
            return formatter.string(from: date)
        }

        func string(
            from start: Date,
            to end: Date,
            template: String,
            locale: Locale,
            calendar: Calendar,
            timeZone: TimeZone
        ) -> String {
            lock.lock()
            defer { lock.unlock() }
            let key = FormatterKey(
                role: .interval,
                localeIdentifier: locale.identifier,
                hourCycle: locale.hourCycle,
                calendarIdentifier: calendar.identifier,
                timeZoneIdentifier: timeZone.identifier
            )
            let formatter: DateIntervalFormatter
            if let cached = intervalFormatters[key] {
                formatter = cached
            } else {
                let created = DateIntervalFormatter()
                created.locale = locale
                created.calendar = calendar
                created.timeZone = timeZone
                created.dateTemplate = template
                intervalFormatters[key] = created
                formatter = created
            }
            return formatter.string(from: start, to: end)
        }
    }

    private static let cache = FormatterCache()
}
