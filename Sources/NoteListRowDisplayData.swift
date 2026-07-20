import Foundation

enum TranscriptStatus: Equatable {
    case done, recording, transcribing, recovered, fail
}

struct CloudTranscriptionDisplayProgress: Equatable, Sendable {
    let completedChunkCount: Int
    let totalChunkCount: Int
    let activeAttempt: Int?
}

func transcriptStatus(for item: PipelineHistoryItem, retrying: Set<UUID>) -> TranscriptStatus {
    if retrying.contains(item.id) { return .transcribing }
    switch item.machineStatus {
    case .liveRecording:
        return .recording
    case .importing, .cloudTranscribing:
        return .transcribing
    case .recovered:
        return .recovered
    case .failed:
        return .fail
    case .completed:
        return item.postProcessingStatus
            == PipelineHistoryItem.transcriptionRecoveryPlaceholderStatus
            ? .transcribing
            : .done
    }
}

enum NoteTimestampFormatter {
    static func detailTimestamp(for item: PipelineHistoryItem, locale: Locale = .current) -> String {
        guard let startedAt = item.recordingStartedAt,
              let endedAt = item.recordingEndedAt,
              endedAt >= startedAt else {
            return normalized(dateTimeStyle(locale: locale).format(item.timestamp))
        }

        return normalized(
            Date.IntervalFormatStyle(date: .long, time: .shortened)
                .locale(locale)
                .format(startedAt..<endedAt)
        )
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

    private static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{2009}", with: " ")
    }
}

struct NoteListRowDisplayData: Equatable {
    let id: UUID
    let status: TranscriptStatus
    let rowDate: String
    let displayTitle: String
    let preview: String

    init(
        item: PipelineHistoryItem,
        retryingIDs: Set<UUID>,
        cloudProgress: CloudTranscriptionDisplayProgress? = nil,
        locale: Locale = .current,
        localizationLanguage: String = preferredLocalizedStringLanguage(),
        localizationBundle: Bundle = .main,
        localization: (
            _ key: String,
            _ arguments: [CVarArg]
        ) -> String = { key, arguments in
            String(
                format: localizedCatalogString(key),
                locale: .current,
                arguments: arguments
            )
        }
    ) {
        let status = transcriptStatus(for: item, retrying: retryingIDs)
        let trimmedCustomTitle = item.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let customTitle = trimmedCustomTitle?.isEmpty == true ? nil : trimmedCustomTitle
        let content = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = NoteTitleResolver.displayTitle(
            for: item,
            isTranscribing: status == .transcribing,
            language: localizationLanguage,
            bundle: localizationBundle
        )

        self.id = item.id
        self.status = status
        self.rowDate = NoteTimestampFormatter.rowTimestamp(for: item, locale: locale)
        self.displayTitle = displayTitle
        self.preview = Self.preview(
            for: item,
            status: status,
            content: content,
            customTitle: customTitle,
            displayTitle: displayTitle,
            cloudProgress: cloudProgress,
            localizationLanguage: localizationLanguage,
            localizationBundle: localizationBundle,
            localization: localization
        )
    }

    private static func preview(
        for item: PipelineHistoryItem,
        status: TranscriptStatus,
        content: String,
        customTitle: String?,
        displayTitle: String,
        cloudProgress: CloudTranscriptionDisplayProgress?,
        localizationLanguage: String,
        localizationBundle: Bundle,
        localization: (
            _ key: String,
            _ arguments: [CVarArg]
        ) -> String
    ) -> String {
        if status == .fail {
            return item.userIssuePresentation(
                language: localizationLanguage,
                bundle: localizationBundle
            )?.body ?? localizedCatalogString(
                "Quill could not complete this transcription.",
                language: localizationLanguage,
                bundle: localizationBundle
            )
        }
        if status == .recovered {
            return item.recoveredRecordingContext?.localizedDescription() ?? ""
        }
        if status == .transcribing {
            guard item.machineStatus == .cloudTranscribing,
                  let cloudProgress else {
                return ""
            }
            guard cloudProgress.activeAttempt != nil else {
                return localization("Resuming cloud transcription…", [])
            }
            let activeChunkNumber = min(
                cloudProgress.completedChunkCount + 1,
                cloudProgress.totalChunkCount
            )
            return localization(
                "Transcribing %d of %d…",
                [activeChunkNumber, cloudProgress.totalChunkCount]
            )
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
