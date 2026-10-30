import Foundation
import QuillNoteCore

enum NoteTitleResolver {
    private static let calendarTitleDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The name of a settled note without a title of its own: when its
    /// recording started (else when it was saved), as the list row's date
    /// reads it. The note detail shows the same as its title placeholder,
    /// and the iPhone app names such notes the same way.
    static func dateTitle(for item: PipelineHistoryItem, locale: Locale = .current) -> String {
        dateTitle(for: item.recordingStartedAt ?? item.timestamp, locale: locale)
    }

    static func dateTitle(for date: Date, locale: Locale = .current) -> String {
        NoteTimestampFormatter.dateTitle(for: date, locale: locale)
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
        // A whitespace-only title counts as none, as it does everywhere else.
        // An untitled note is named by its date, which never reads like the
        // applied form, so applying always changes the title.
        guard normalizedCustomTitle(item.customTitle ?? "") == nil,
              item.calendarMatch?.titleState == .suggested,
              let suggestedTitle = item.calendarMatch?.suggestedTitle else {
            return nil
        }
        let appliedTitle = calendarAppliedTitle(
            suggestedTitle: suggestedTitle,
            recordingStartedAt: item.timestamp
        )
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
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        if let explicit = explicitTitle(for: item) {
            return explicit.title
        }
        return automaticTitle(
            for: item,
            isTranscribing: isTranscribing,
            isPostProcessing: isPostProcessing,
            language: language,
            bundle: bundle,
            locale: locale
        )
    }

    static func automaticTitle(
        for item: PipelineHistoryItem,
        isTranscribing: Bool = false,
        isPostProcessing: Bool = false,
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        stateTitle(
            for: item,
            isTranscribing: isTranscribing,
            isPostProcessing: isPostProcessing,
            language: language,
            bundle: bundle
        ) ?? dateTitle(for: item, locale: locale)
    }

    /// True when the note is named by its date: no title of its own, and
    /// settled. Its row then doesn't read the date twice.
    static func isNamedByDate(_ item: PipelineHistoryItem) -> Bool {
        explicitTitle(for: item) == nil
            && stateTitle(for: item, language: "en", bundle: .main) == nil
    }

    /// The title for AI tools (MCP): a title of its own, else the
    /// transcript's first line, so a tool can tell notes apart by name;
    /// else the name the app shows.
    static func toolTitle(for item: PipelineHistoryItem) -> String {
        if let explicit = explicitTitle(for: item) {
            return explicit.title
        }
        let content = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return toolTitleWithoutContent(for: item) }
        let firstLine = content.components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? content
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= 60 ? trimmed : String(trimmed.prefix(60))
    }

    /// The names tools got before untitled notes were named by date.
    private static func toolTitleWithoutContent(for item: PipelineHistoryItem) -> String {
        let language = preferredLocalizedStringLanguage()
        switch item.machineStatus {
        case .audioOnly:
            return localizedCatalogString("Audio recording", language: language, bundle: .main)
        case .failed, .unrecovered:
            return localizedCatalogString("New Recording", language: language, bundle: .main)
        default:
            return stateTitle(for: item, language: language, bundle: .main) ?? "(No content)"
        }
    }

    /// The name of a note still being made, or recovered; nil once it is
    /// settled and named by when it was recorded. Its row preview tells the
    /// rest ("Not transcribed", "Couldn't transcribe", the transcript).
    private static func stateTitle(
        for item: PipelineHistoryItem,
        isTranscribing: Bool = false,
        isPostProcessing: Bool = false,
        language: String,
        bundle: Bundle
    ) -> String? {
        let content = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.isEmpty else { return nil }
        if isTranscribing {
            return localizedCatalogString(
                isPostProcessing ? "Post-processing..." : "Transcribing...",
                language: language,
                bundle: bundle
            )
        }
        // Settled before its recovery name counts, as before.
        switch item.machineStatus {
        case .audioOnly, .failed, .unrecovered:
            return nil
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
        if item.isTranscriptionPlaceholder || item.machineStatus == .importing {
            return localizedCatalogString("Transcribing...", language: language, bundle: bundle)
        }
        return nil
    }
}
