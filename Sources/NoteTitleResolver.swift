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

    /// The calendar title to suggest applying, or nil when there is nothing
    /// to suggest or applying it would not change the note's current
    /// effective title. Returns both the raw suggestion and the value
    /// Apply would set so callers don't recompute the applied form.
    static func suggestedCalendarTitle(
        for item: PipelineHistoryItem
    ) -> (suggested: String, applied: String)? {
        guard item.customTitle == nil,
              item.calendarMatch?.titleState == .suggested,
              let suggestedTitle = item.calendarMatch?.suggestedTitle else {
            return nil
        }
        let appliedTitle = calendarAppliedTitle(
            suggestedTitle: suggestedTitle,
            recordingStartedAt: item.timestamp
        )
        guard displayTitle(for: item) != appliedTitle else {
            return nil
        }
        return (suggested: suggestedTitle, applied: appliedTitle)
    }

    static func displayTitle(
        for item: PipelineHistoryItem,
        isTranscribing: Bool = false,
        isPostProcessing: Bool = false,
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
            isPostProcessing: isPostProcessing,
            language: language,
            bundle: bundle
        )
    }

    static func automaticTitle(
        for item: PipelineHistoryItem,
        isTranscribing: Bool = false,
        isPostProcessing: Bool = false,
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> String {
        let content = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty {
            if isTranscribing {
                return localizedCatalogString(
                    isPostProcessing ? "Post-processing..." : "Transcribing...",
                    language: language,
                    bundle: bundle
                )
            }
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
            if item.postProcessingStatus == "live-recording" {
                return localizedCatalogString("Recording...", language: language, bundle: bundle)
            }
            if item.postProcessingStatus == PipelineHistoryItem.transcriptionRecoveryPlaceholderStatus || item.postProcessingStatus == "importing" {
                return localizedCatalogString("Transcribing...", language: language, bundle: bundle)
            }
            return "(No content)"
        }
        let firstLine = content.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? content
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= 60 ? trimmed : String(trimmed.prefix(60))
    }
}
