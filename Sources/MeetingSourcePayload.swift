import Foundation

/// Builds the structured JSON payload returned by the MCP `get_meeting_source` tool.
/// Pure function: filesystem access is injected via `fileExists` so it is unit-testable.
enum MeetingSourcePayload {
    private static let resourceDomain = "resource.calendar.google.com"

    static func make(
        item: PipelineHistoryItem,
        audioDirectory: URL,
        fileExists: (URL) -> Bool,
        formatter: ISO8601DateFormatter
    ) -> [String: Any] {
        [
            "id": item.id.uuidString,
            "title": titlePayload(item),
            "timestamps": timestampsPayload(item, formatter: formatter),
            "calendar": calendarPayload(item, formatter: formatter),
            "audio": audioPayload(item, audioDirectory: audioDirectory, fileExists: fileExists),
            "transcript": item.postProcessedTranscript,
            "raw_transcript": item.rawTranscript,
            "context": item.contextSummary,
        ]
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func orNull(_ value: String?) -> Any { value ?? NSNull() }

    private static func titlePayload(_ item: PipelineHistoryItem) -> [String: Any] {
        let custom = nonEmpty(item.customTitle)
        let calendar = nonEmpty(item.calendarMatch?.title)
        return [
            "custom": orNull(custom),
            "calendar": orNull(calendar),
            "resolved": orNull(custom ?? calendar),
        ]
    }

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
            let isResource = (a.email?.contains(resourceDomain)) ?? false
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
