import Foundation

/// Builds the JSON the MCP `list_notes` and `get_note` tools return.
/// Pure functions: the note's display title, its summary text and filesystem
/// access are passed in so this stays unit-testable.
enum NotePayload {
    private static let resourceDomain = "resource.calendar.google.com"
    static let defaultListLimit = 20
    static let maxListLimit = 50
    private static let previewLength = 120

    /// When the note was recorded: the recording start, or when the
    /// transcript was made for notes that don't know their start.
    static func noteDate(_ item: PipelineHistoryItem) -> Date {
        item.recordingStartedAt ?? item.timestamp
    }

    /// Where the display title comes from, in the order
    /// NoteTitleResolver.displayTitle picks it: a title the person typed,
    /// the applied calendar event title, or one made from the transcript.
    static func titleSource(_ item: PipelineHistoryItem) -> String {
        if nonEmpty(item.customTitle) != nil { return "custom" }
        if item.calendarMatch?.appliedTitle != nil { return "calendar" }
        return "automatic"
    }

    // MARK: - get_note

    /// The note's meeting summary as Markdown, and whether the transcript
    /// changed after it was made (the app shows such a summary as stale).
    struct Summary {
        let markdown: String
        let isStale: Bool
    }

    static func make(
        item: PipelineHistoryItem,
        title: String,
        summary: Summary?,
        audioDirectory: URL,
        fileExists: (URL) -> Bool,
        formatter: ISO8601DateFormatter
    ) -> [String: Any] {
        [
            "id": item.id.uuidString,
            "title": title,
            "title_source": titleSource(item),
            "timestamps": timestampsPayload(item, formatter: formatter),
            "calendar": calendarPayload(item, formatter: formatter),
            "audio": audioPayload(item, audioDirectory: audioDirectory, fileExists: fileExists),
            "summary": summary.map { ["markdown": $0.markdown, "is_stale": $0.isStale] as [String: Any] } ?? NSNull(),
            "transcript": item.postProcessedTranscript,
            "raw_transcript": item.rawTranscript,
            "context": item.contextSummary,
        ]
    }

    // MARK: - list_notes

    struct ListFilter {
        var query: String?
        var since: Date?
        var until: Date?
        var limit: Int
        var offset: Int

        /// Reads the tool arguments. `since` and `until` take a date
        /// (YYYY-MM-DD, a whole day in `timeZone`) or an ISO 8601 date-time;
        /// a bad value is an error rather than silently ignored.
        init(arguments: [String: Any], timeZone: TimeZone) throws {
            let query = (arguments["query"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.query = query?.isEmpty == false ? query : nil
            self.since = try Self.date(arguments["since"], name: "since", endOfDay: false, timeZone: timeZone)
            self.until = try Self.date(arguments["until"], name: "until", endOfDay: true, timeZone: timeZone)
            let limit = arguments["limit"] as? Int ?? NotePayload.defaultListLimit
            self.limit = max(1, min(limit, NotePayload.maxListLimit))
            self.offset = max(0, arguments["offset"] as? Int ?? 0)
        }

        private static func date(
            _ value: Any?,
            name: String,
            endOfDay: Bool,
            timeZone: TimeZone
        ) throws -> Date? {
            guard let raw = value as? String else {
                if value == nil { return nil }
                throw ListFilterError.invalidDate(name)
            }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return nil }

            let dayFormatter = DateFormatter()
            dayFormatter.calendar = Calendar(identifier: .gregorian)
            dayFormatter.locale = Locale(identifier: "en_US_POSIX")
            dayFormatter.timeZone = timeZone
            dayFormatter.dateFormat = "yyyy-MM-dd"
            dayFormatter.isLenient = false
            if let day = dayFormatter.date(from: text) {
                guard endOfDay else { return day }
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = timeZone
                return calendar.date(byAdding: .day, value: 1, to: day)?.addingTimeInterval(-0.001)
            }

            // A date-time without an offset is local time.
            let localFormatter = DateFormatter()
            localFormatter.calendar = Calendar(identifier: .gregorian)
            localFormatter.locale = Locale(identifier: "en_US_POSIX")
            localFormatter.timeZone = timeZone
            localFormatter.isLenient = false
            for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm"] {
                localFormatter.dateFormat = format
                if let date = localFormatter.date(from: text) { return date }
            }

            let dateTimeFormatter = ISO8601DateFormatter()
            dateTimeFormatter.formatOptions = [.withInternetDateTime]
            if let date = dateTimeFormatter.date(from: text) { return date }
            dateTimeFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = dateTimeFormatter.date(from: text) { return date }
            throw ListFilterError.invalidDate(name)
        }
    }

    enum ListFilterError: Error, Equatable {
        case invalidDate(String)

        var message: String {
            switch self {
            case .invalidDate(let name):
                return "Error: '\(name)' must be a date (YYYY-MM-DD) or an ISO 8601 date-time such as 2026-10-13T09:00:00."
            }
        }
    }

    /// The notes that pass the filter, newest first, skipping `offset`
    /// matches. `matches` is the Note Browser's search for a non-empty
    /// query; `title` and `hasSummary` are only asked for returned notes.
    static func list(
        _ items: [PipelineHistoryItem],
        filter: ListFilter,
        matches: (PipelineHistoryItem, String) -> Bool,
        title: (PipelineHistoryItem) -> String,
        hasSummary: (PipelineHistoryItem) -> Bool,
        formatter: ISO8601DateFormatter
    ) -> [String: Any] {
        var notes: [[String: Any]] = []
        var skipped = 0
        var hasMore = false
        // Ties break on id so pages stay in the same order between calls.
        let sorted = items.sorted {
            let (left, right) = (noteDate($0), noteDate($1))
            return left != right ? left > right : $0.id.uuidString < $1.id.uuidString
        }
        for item in sorted {
            let date = noteDate(item)
            if let since = filter.since, date < since { continue }
            if let until = filter.until, date > until { continue }
            if let query = filter.query, !matches(item, query) { continue }
            if skipped < filter.offset {
                skipped += 1
                continue
            }
            if notes.count == filter.limit {
                hasMore = true
                break
            }
            notes.append(listEntry(item, title: title(item), hasSummary: hasSummary(item), formatter: formatter))
        }
        return ["notes": notes, "has_more": hasMore]
    }

    private static func listEntry(
        _ item: PipelineHistoryItem,
        title: String,
        hasSummary: Bool,
        formatter: ISO8601DateFormatter
    ) -> [String: Any] {
        let text = item.postProcessedTranscript.isEmpty ? item.rawTranscript : item.postProcessedTranscript
        let flattened = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let preview = flattened.count > previewLength ? String(flattened.prefix(previewLength)) + "…" : flattened
        return [
            "id": item.id.uuidString,
            "title": title,
            "recorded_at": formatter.string(from: noteDate(item)),
            "calendar_event": orNull(nonEmpty(item.calendarMatch?.title)),
            "has_summary": hasSummary,
            "preview": preview,
        ]
    }

    // MARK: - Shared pieces

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func orNull(_ value: String?) -> Any { value ?? NSNull() }

    private static func iso(_ date: Date?, _ formatter: ISO8601DateFormatter) -> Any {
        guard let date else { return NSNull() }
        return formatter.string(from: date)
    }

    private static func timestampsPayload(_ item: PipelineHistoryItem, formatter: ISO8601DateFormatter) -> [String: Any] {
        [
            "recording_started_at": iso(item.recordingStartedAt, formatter),
            "recording_ended_at": iso(item.recordingEndedAt, formatter),
            "transcript_created_at": formatter.string(from: item.timestamp),
        ]
    }

    private static func calendarPayload(_ item: PipelineHistoryItem, formatter: ISO8601DateFormatter) -> Any {
        guard let match = item.calendarMatch else { return NSNull() }
        let attendees: [[String: Any]] = match.attendees.map { a in
            let isResource = (a.email?.hasSuffix(resourceDomain)) ?? false
            return [
                "display_name": orNull(a.displayName),
                "email": orNull(a.email),
                "response_status": orNull(a.responseStatus),
                "is_self": a.isSelf,
                "is_optional": a.isOptional,
                "is_resource": isResource,
            ]
        }
        return [
            "title": match.title,
            "start": formatter.string(from: match.start),
            "end": formatter.string(from: match.end),
            "attendees": attendees,
        ]
    }

    private static func audioPayload(
        _ item: PipelineHistoryItem,
        audioDirectory: URL,
        fileExists: (URL) -> Bool
    ) -> Any {
        guard let name = item.audioFileName, !name.isEmpty else { return NSNull() }
        let url = audioDirectory.appendingPathComponent(name)
        return [
            "filename": name,
            "path": url.path,
            "exists": fileExists(url),
        ]
    }
}
