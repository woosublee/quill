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

    /// The title field's text after the note's title changed outside the
    /// field, such as from another Mac: the new title, or nil to leave the
    /// field alone because it already shows that title or holds an edit
    /// not saved yet.
    static func titleDraftAfterOutsideChange(
        draft: String,
        newTitle: String?,
        hasUnsavedEdit: Bool
    ) -> String? {
        // A draft with a trailing space already matches its own saved title.
        guard !hasUnsavedEdit, normalizedCustomTitle(draft) != newTitle else { return nil }
        return newTitle ?? ""
    }

    /// A typed title as it is saved: trimmed, and nil when empty.
    static func normalizedCustomTitle(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Where a note's display title comes from.
    enum DisplayTitleSource: String {
        /// A title the person typed.
        case custom
        /// The applied calendar event title.
        case calendar
        /// A title made from the note's content or state.
        case automatic
    }

    static func displayTitleSource(for item: PipelineHistoryItem) -> DisplayTitleSource {
        if item.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return .custom
        }
        return item.calendarMatch?.appliedTitle != nil ? .calendar : .automatic
    }

    static func displayTitle(
        for item: PipelineHistoryItem,
        isTranscribing: Bool = false,
        isPostProcessing: Bool = false,
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> String {
        switch displayTitleSource(for: item) {
        case .custom:
            return item.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        case .calendar:
            return item.calendarMatch?.appliedTitle ?? ""
        case .automatic:
            break
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
            // A failed note keeps a plain name; the list preview and the
            // note detail say what went wrong.
            switch item.machineStatus {
            case .failed, .unrecovered:
                return localizedCatalogString(
                    "New Recording",
                    language: language,
                    bundle: bundle
                )
            default:
                break
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
