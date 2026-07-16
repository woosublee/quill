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
    static func detailTimestamp(for item: PipelineHistoryItem, locale: Locale = .current) -> String {
        guard let startedAt = item.recordingStartedAt,
              let endedAt = item.recordingEndedAt,
              endedAt >= startedAt else {
            return normalized(dateTimeStyle(locale: locale).format(item.timestamp))
        }

        let start = normalized(dateTimeStyle(locale: locale).format(startedAt))
        let end = normalized(timeStyle(locale: locale).format(endedAt))
        guard Calendar.current.isDate(startedAt, inSameDayAs: endedAt) else {
            return "\(start)\(intervalSeparator(for: locale, start: startedAt, end: endedAt))\(normalized(dateTimeStyle(locale: locale).format(endedAt)))"
        }
        return "\(start)\(intervalSeparator(for: locale, start: startedAt, end: endedAt))\(end)"
    }

    static func rowTimestamp(for item: PipelineHistoryItem, locale: Locale = .current) -> String {
        let timestamp = item.recordingStartedAt ?? item.timestamp
        return normalized(rowTimestampStyle(locale: locale).format(timestamp))
    }

    private static func dateTimeStyle(locale: Locale) -> Date.FormatStyle {
        Date.FormatStyle(date: .long, time: .shortened).locale(locale)
    }

    private static func rowTimestampStyle(locale: Locale) -> Date.FormatStyle {
        Date.FormatStyle().month(.wide).day().hour().minute().locale(locale)
    }

    private static func timeStyle(locale: Locale) -> Date.FormatStyle {
        Date.FormatStyle().hour().minute().locale(locale)
    }

    private static func intervalSeparator(for locale: Locale, start: Date, end: Date) -> String {
        let interval = Date.IntervalFormatStyle(date: .long, time: .shortened)
            .locale(locale)
            .format(start..<end)
        return interval.contains("~") ? "~" : " – "
    }

    private static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
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
