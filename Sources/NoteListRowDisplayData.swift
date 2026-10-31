import Foundation
import QuillNoteCore

enum TranscriptStatus: Equatable {
    case done, recording, transcribing, audioOnly, recovered, fail

    /// Notes still recording or processing are left out of multi-selection and bulk deletion.
    var isBulkSelectable: Bool {
        switch self {
        case .recording, .transcribing: return false
        case .done, .audioOnly, .recovered, .fail: return true
        }
    }
}

struct CloudTranscriptionDisplayProgress: Equatable, Sendable {
    let completedChunkCount: Int
    let totalChunkCount: Int
    let activeAttempt: Int?
}

/// `stoppedCloud` holds cloud-transcribing notes that no work is running
/// for; they show as failed so the person can retry or delete them.
func transcriptStatus(
    for item: PipelineHistoryItem,
    retrying: Set<UUID>,
    stoppedCloud: Set<UUID> = []
) -> TranscriptStatus {
    if retrying.contains(item.id) { return .transcribing }
    if stoppedCloud.contains(item.id), item.machineStatus == .cloudTranscribing {
        return .fail
    }
    switch item.machineStatus {
    case .liveRecording:
        return .recording
    case .importing, .cloudTranscribing:
        return .transcribing
    case .audioOnly:
        return .audioOnly
    case .recovered:
        return .recovered
    case .failed, .unrecovered:
        return .fail
    case .completed:
        return item.isTranscriptionPlaceholder ? .transcribing : .done
    }
}

// The date rules are in QuillNoteCore, shared with the iPhone app.
// These read a note's recording times.
extension NoteTimestampFormatter {
    static func detailTimestamp(
        for item: PipelineHistoryItem,
        locale: Locale = .current,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> String {
        detailTimestamp(
            recordingStartedAt: item.recordingStartedAt,
            recordingEndedAt: item.recordingEndedAt,
            fallback: item.timestamp,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        )
    }

    static func rowTimestamp(
        for item: PipelineHistoryItem,
        locale: Locale = .current,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> String {
        rowTimestamp(
            for: item.recordingStartedAt ?? item.timestamp,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        )
    }
}

/// Elapsed recording time as `mm:ss`, or `h:mm:ss` past an hour.
enum RecordingElapsedFormatter {
    static func string(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct NoteListRowDisplayData: Equatable {
    let id: UUID
    let status: TranscriptStatus
    let rowDate: String
    /// The title is the recording date, so the row's date isn't read again.
    let isNamedByDate: Bool
    let displayTitle: String
    let preview: String
    let hasMeetingSummary: Bool
    /// The recording could not be recovered, so the red dot means
    /// "Couldn't recover" rather than a failed transcription.
    let isUnrecoveredRecording: Bool
    /// Set while recording, so the row's status corner can show a running
    /// elapsed time next to the red dot.
    let recordingStartedAt: Date?

    init(
        item: PipelineHistoryItem,
        retryingIDs: Set<UUID>,
        stoppedCloudIDs: Set<UUID> = [],
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
        let status = transcriptStatus(
            for: item,
            retrying: retryingIDs,
            stoppedCloud: stoppedCloudIDs
        )
        let trimmedCustomTitle = item.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let customTitle = trimmedCustomTitle?.isEmpty == true ? nil : trimmedCustomTitle
        let content = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        // The row names the note; the stage ("Transcribing…", "Post-
        // processing…") is shown once, in the note detail, and by the row's
        // spinner. A recording or import with no title or transcript yet
        // gets a neutral name; a note being retried keeps its own name
        // (its title, or when it was recorded), never the stage.
        let hasOwnTitle = customTitle != nil || item.calendarMatch?.appliedTitle != nil
        let isUnnamed = !hasOwnTitle && content.isEmpty && !retryingIDs.contains(item.id)
        // An import transcribed by a cloud model has the cloud status, not
        // "importing", so its import mark comes from the debug status.
        let isImporting = isUnnamed && (
            item.machineStatus == .importing
                || item.debugStatus == PipelineHistoryItem.importingDebugStatus
        )
        let isNewRecording = isUnnamed && !isImporting && (
            status == .recording
                || item.isTranscriptionPlaceholder
                || item.machineStatus == .cloudTranscribing
        )
        let displayTitle: String
        if isNewRecording || isImporting {
            displayTitle = localizedCatalogString(
                isImporting ? "Imported Audio" : "New Recording",
                language: localizationLanguage,
                bundle: localizationBundle
            )
        } else {
            displayTitle = NoteTitleResolver.displayTitle(
                for: item,
                language: localizationLanguage,
                bundle: localizationBundle,
                locale: locale
            )
        }
        self.isNamedByDate = !isNewRecording && !isImporting && NoteTitleResolver.isNamedByDate(item)

        self.id = item.id
        self.status = status
        self.rowDate = NoteTimestampFormatter.rowTimestamp(for: item, locale: locale)
        self.displayTitle = displayTitle
        self.hasMeetingSummary = item.meetingSummaryJSON != nil
        self.isUnrecoveredRecording = item.unrecoveredRecordingContext != nil
        self.recordingStartedAt = status == .recording ? item.recordingStartedAt : nil
        self.preview = Self.preview(
            for: item,
            status: status,
            content: content,
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
        cloudProgress: CloudTranscriptionDisplayProgress?,
        localizationLanguage: String,
        localizationBundle: Bundle,
        localization: (
            _ key: String,
            _ arguments: [CVarArg]
        ) -> String
    ) -> String {
        if status == .audioOnly {
            return localizedCatalogString(
                "Not transcribed",
                language: localizationLanguage,
                bundle: localizationBundle
            )
        }
        if status == .fail {
            return localizedCatalogString(
                item.unrecoveredRecordingContext != nil
                    ? "Couldn't recover"
                    : "Couldn't transcribe",
                language: localizationLanguage,
                bundle: localizationBundle
            )
        }
        if status == .recovered {
            return item.recoveredRecordingContext?.localizedDescription() ?? ""
        }
        if status == .transcribing || (status == .recording && content.isEmpty) {
            // Progress lives in the note detail and the row's spinner.
            return ""
        }
        // The title is the note's own or its date, never the transcript, so
        // the preview starts at the transcript's first line.
        return String(content.prefix(100))
    }
}

/// What VoiceOver reads for a note list row: the name, the date, the state
/// in words (not only the dot's color), the Summary badge, and, while
/// selecting several notes, whether this one is checked.
enum NoteListRowAccessibility {
    enum SelectionState: Equatable {
        case checked, unchecked, unavailable
    }

    static func statusKey(
        for status: TranscriptStatus,
        isUnrecoveredRecording: Bool = false
    ) -> String {
        if status == .fail, isUnrecoveredRecording {
            return "Couldn't recover"
        }
        switch status {
        case .done: return "Transcription complete"
        case .recording: return "Recording..."
        case .transcribing: return "Transcribing..."
        case .audioOnly: return "Audio only"
        case .recovered: return "Recovered recording"
        case .fail: return "Transcription failed"
        }
    }

    /// `date` is nil when the title already is the date.
    static func label(
        title: String,
        date: String?,
        status: TranscriptStatus,
        hasSummary: Bool,
        selection: SelectionState?,
        isUnrecoveredRecording: Bool = false,
        localize: (String) -> String = { localizedCatalogString($0) }
    ) -> String {
        var parts = [title]
        if let date { parts.append(date) }
        parts.append(localize(statusKey(
            for: status,
            isUnrecoveredRecording: isUnrecoveredRecording
        )))
        if hasSummary {
            parts.append(localize("Summary"))
        }
        switch selection {
        case .checked: parts.append(localize("Selected"))
        case .unchecked: parts.append(localize("Not selected"))
        case .unavailable: parts.append(localize("Can't be selected while recording or processing"))
        case nil: break
        }
        return parts.joined(separator: ", ")
    }
}
