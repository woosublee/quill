import Foundation

enum TranscriptStatus: Equatable {
    case done, recording, transcribing, fail
}

func transcriptStatus(for item: PipelineHistoryItem, retrying: Set<UUID>) -> TranscriptStatus {
    if retrying.contains(item.id) { return .transcribing }
    if item.postProcessingStatus == "live-recording" { return .recording }
    if item.postProcessingStatus == "importing" { return .transcribing }
    if item.postProcessingStatus == PipelineHistoryItem.transcriptionRecoveryPlaceholderStatus { return .transcribing }
    if item.postProcessingStatus.hasPrefix("Error:") { return .fail }
    return .done
}

enum NoteTimestampFormatter {
    static func detailTimestamp(for item: PipelineHistoryItem) -> String {
        intervalTimestamp(
            for: item,
            fallbackFormatter: fullDateTimeFormatter,
            startFormatter: fullDateTimeFormatter,
            crossDateEndFormatter: fullDateTimeFormatter
        )
    }

    static func rowTimestamp(for item: PipelineHistoryItem) -> String {
        guard let startedAt = item.recordingStartedAt else {
            return rowSingleTimestampFormatter.string(from: item.timestamp)
        }
        return rowStartTimestampFormatter.string(from: startedAt)
    }

    private static func intervalTimestamp(
        for item: PipelineHistoryItem,
        fallbackFormatter: DateFormatter,
        startFormatter: DateFormatter,
        crossDateEndFormatter: DateFormatter
    ) -> String {
        guard let startedAt = item.recordingStartedAt,
              let endedAt = item.recordingEndedAt,
              endedAt >= startedAt else {
            return fallbackFormatter.string(from: item.timestamp)
        }

        let startText = startFormatter.string(from: startedAt)
        guard calendar.isDate(startedAt, inSameDayAs: endedAt) else {
            return "\(startText) - \(crossDateEndFormatter.string(from: endedAt))"
        }

        if periodFormatter.string(from: startedAt) == periodFormatter.string(from: endedAt) {
            return "\(startText) - \(timeFormatter.string(from: endedAt))"
        }
        return "\(startText) - \(periodTimeFormatter.string(from: endedAt))"
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ko_KR")
        return calendar
    }()

    private static let fullDateTimeFormatter = makeFormatter("yyyy년 M월 d일 a h:mm")
    private static let rowSingleTimestampFormatter = makeFormatter("M월 d일 · HH:mm")
    private static let rowStartTimestampFormatter = makeFormatter("M월 d일 a h:mm")
    private static let periodTimeFormatter = makeFormatter("a h:mm")
    private static let timeFormatter = makeFormatter("h:mm")
    private static let periodFormatter = makeFormatter("a")

    private static func makeFormatter(_ dateFormat: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = dateFormat
        return formatter
    }
}

struct NoteListRowDisplayData: Equatable {
    let id: UUID
    let status: TranscriptStatus
    let rowDate: String
    let displayTitle: String
    let preview: String

    init(item: PipelineHistoryItem, retryingIDs: Set<UUID>) {
        let status = transcriptStatus(for: item, retrying: retryingIDs)
        let trimmedCustomTitle = item.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let customTitle = trimmedCustomTitle?.isEmpty == true ? nil : trimmedCustomTitle
        let content = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = NoteTitleResolver.displayTitle(
            for: item,
            isTranscribing: status == .transcribing
        )

        self.id = item.id
        self.status = status
        self.rowDate = NoteTimestampFormatter.rowTimestamp(for: item)
        self.displayTitle = displayTitle
        self.preview = Self.preview(
            for: item,
            status: status,
            content: content,
            customTitle: customTitle,
            displayTitle: displayTitle
        )
    }

    private static func preview(
        for item: PipelineHistoryItem,
        status: TranscriptStatus,
        content: String,
        customTitle: String?,
        displayTitle: String
    ) -> String {
        if status == .fail {
            return String(item.postProcessingStatus.dropFirst("Error:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if status == .transcribing {
            return ""
        }
        if customTitle != nil || item.calendarMatch?.appliedTitle != nil {
            return String(content.prefix(100))
        }
        if content.hasPrefix(displayTitle) {
            let rest = content.dropFirst(displayTitle.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return String(rest.prefix(100))
        }
        return String(content.prefix(100))
    }
}
