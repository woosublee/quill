import Foundation

enum NoteTitleResolver {
    private static let calendarTitleDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func calendarAppliedTitle(suggestedTitle: String, recordingStartedAt: Date) -> String {
        "\(calendarTitleDateFormatter.string(from: recordingStartedAt)) \(suggestedTitle)"
    }

    static func displayTitle(
        for item: PipelineHistoryItem,
        isTranscribing: Bool = false,
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> String {
        if let customTitle = item.customTitle {
            let trimmed = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let applied = item.calendarMatch?.appliedTitle {
            return applied
        }
        return automaticTitle(
            for: item,
            isTranscribing: isTranscribing,
            language: language,
            bundle: bundle
        )
    }

    static func automaticTitle(
        for item: PipelineHistoryItem,
        isTranscribing: Bool = false,
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> String {
        let content = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty {
            if isTranscribing { return "Transcribing..." }
            if item.machineStatus == .audioOnly {
                return localizedCatalogString(
                    "Audio recording",
                    language: language,
                    bundle: bundle
                )
            }
            if case .failed = item.machineStatus {
                return item.userIssuePresentation(
                    language: language,
                    bundle: bundle
                )?.title ?? localizedCatalogString(
                    "Transcription failed",
                    language: language,
                    bundle: bundle
                )
            }
            if let context = item.recoveredRecordingContext {
                return localizedCatalogString(
                    context.titleLocalizationKey,
                    language: language,
                    bundle: bundle
                )
            }
            if item.postProcessingStatus == "live-recording" { return "Recording..." }
            if item.postProcessingStatus == PipelineHistoryItem.transcriptionRecoveryPlaceholderStatus || item.postProcessingStatus == "importing" { return "Transcribing..." }
            return "(No content)"
        }
        let firstLine = content.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? content
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= 60 ? trimmed : String(trimmed.prefix(60))
    }
}
