import Foundation

enum NoteTitleResolver {
    private static let calendarTitleDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The name of a settled note without a title of its own: when it was
    /// recorded. The note detail shows the same as its title placeholder,
    /// and the iPhone app names such notes the same way.
    static func dateTitle(for timestamp: Date) -> String {
        timestamp.formatted(date: .long, time: .shortened)
    }

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
        /// A title the person set: typed, or a calendar suggestion they
        /// applied (Apply saves it as their title).
        case custom
        /// The applied calendar event title.
        case calendar
        /// A title made from the note's content or state.
        case automatic
    }

    static func displayTitleSource(for item: PipelineHistoryItem) -> DisplayTitleSource {
        explicitTitle(for: item)?.source ?? .automatic
    }

    /// A typed title, else the applied calendar title; nil when the note
    /// gets an automatic title.
    private static func explicitTitle(
        for item: PipelineHistoryItem
    ) -> (source: DisplayTitleSource, title: String)? {
        if let customTitle = item.customTitle {
            let trimmed = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return (.custom, trimmed) }
        }
        if let applied = item.calendarMatch?.appliedTitle {
            return (.calendar, applied)
        }
        return nil
    }

    static func displayTitle(
        for item: PipelineHistoryItem,
        isTranscribing: Bool = false,
        isPostProcessing: Bool = false,
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> String {
        if let explicit = explicitTitle(for: item) {
            return explicit.title
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
        // A note still being made, or recovered, says so; once settled it is
        // named by when it was recorded. Its row preview tells the rest
        // ("Not transcribed", "Couldn't transcribe", the transcript).
        if content.isEmpty {
            if isTranscribing {
                return localizedCatalogString(
                    isPostProcessing ? "Post-processing..." : "Transcribing...",
                    language: language,
                    bundle: bundle
                )
            }
            if case .unrecovered = item.machineStatus {
                return localizedCatalogString(
                    "New Recording",
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
        }
        return dateTitle(for: item.timestamp)
    }
}
