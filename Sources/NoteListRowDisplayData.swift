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
        self.rowDate = Self.rowDateFormatter.string(from: item.timestamp)
        self.displayTitle = displayTitle
        self.preview = Self.preview(
            for: item,
            status: status,
            content: content,
            customTitle: customTitle,
            displayTitle: displayTitle
        )
    }

    private static let rowDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 · HH:mm"
        return formatter
    }()

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
