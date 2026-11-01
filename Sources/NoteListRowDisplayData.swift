import Foundation
import QuillNoteCore

/// The row status rules are in QuillNoteCore, shared with the iPhone app.
typealias TranscriptStatus = NoteListRowStatus

struct CloudTranscriptionDisplayProgress: Equatable, Sendable {
    let completedChunkCount: Int
    let totalChunkCount: Int
    let activeAttempt: Int?

    /// A chunked job still reading and planning its audio: no chunk count
    /// yet, but progress will come (#697).
    static let preparing = CloudTranscriptionDisplayProgress(
        completedChunkCount: 0, totalChunkCount: 0, activeAttempt: nil
    )
}

/// `stoppedCloud` holds cloud-transcribing notes that no work is running
/// for; they show as failed so the person can retry or delete them.
func transcriptStatus(
    for item: PipelineHistoryItem,
    retrying: Set<UUID>,
    stoppedCloud: Set<UUID> = []
) -> TranscriptStatus {
    NoteListRowStatus(
        machineStatus: item.machineStatus,
        isTranscriptionPlaceholder: item.isTranscriptionPlaceholder,
        isRetrying: retrying.contains(item.id),
        isCloudTranscriptionStopped: stoppedCloud.contains(item.id)
    )
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
    /// The row's status, dot, preview, badges, and VoiceOver state, shared
    /// with the iPhone app (QuillNoteCore).
    let rowState: NoteListRowState
    let rowDate: String
    /// The title is the recording date, so the row's date isn't read again.
    let isNamedByDate: Bool
    let displayTitle: String
    let preview: String
    /// Set while recording, so the row's status corner can show a running
    /// elapsed time next to the red dot.
    let recordingStartedAt: Date?

    var status: TranscriptStatus { rowState.status }
    /// The catalog key of the stage the preview line shows while work runs
    /// ("Recording...", "Transcribing...", "Retranscribing...",
    /// "Post-processing..."); nil once the note is settled. VoiceOver reads
    /// it as the row's state.
    var workStageKey: String? { rowState.workStageKey }
    var hasMeetingSummary: Bool { rowState.hasSummary }
    /// The recording could not be recovered, so the red dot means
    /// "Couldn't recover" rather than a failed transcription.
    var isUnrecoveredRecording: Bool { rowState.isUnrecoveredRecording }

    init(
        item: PipelineHistoryItem,
        retryingIDs: Set<UUID>,
        stoppedCloudIDs: Set<UUID> = [],
        postProcessingIDs: Set<UUID> = [],
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
        let content = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let rowState = NoteListRowState(
            machineStatus: item.machineStatus,
            isTranscriptionPlaceholder: item.isTranscriptionPlaceholder,
            hasContent: !content.isEmpty,
            hasSummary: item.meetingSummaryJSON != nil,
            isRetrying: retryingIDs.contains(item.id),
            isCloudTranscriptionStopped: stoppedCloudIDs.contains(item.id),
            isPostProcessing: postProcessingIDs.contains(item.id)
        )
        self.rowState = rowState
        // The row names the note the same way from the start, as the iPhone
        // does: its own title, or when it was recorded (#697). The preview
        // line shows the stage while work runs.
        self.displayTitle = NoteTitleResolver.listRowTitle(
            for: item,
            language: localizationLanguage,
            bundle: localizationBundle,
            locale: locale
        )
        self.isNamedByDate = NoteTitleResolver.isListRowNamedByDate(item)
        self.id = item.id
        self.rowDate = NoteTimestampFormatter.rowTimestamp(for: item, locale: locale)
        self.recordingStartedAt = rowState.status == .recording ? item.recordingStartedAt : nil
        switch rowState.preview {
        case .key(let key):
            self.preview = localizedCatalogString(
                key,
                language: localizationLanguage,
                bundle: localizationBundle
            )
        case .recoveredRecording(let context):
            self.preview = context.localizedDescription()
        case .content:
            // The title is the note's own or its date, never the transcript,
            // so the preview starts at the transcript's first line.
            self.preview = String(content.prefix(100))
        }
    }
}

/// What VoiceOver reads for a note list row: the name, the date, the state
/// in words (not only the dot's color; the work stage while work runs), the
/// Summary badge, and, while
/// selecting several notes, whether this one is checked.
enum NoteListRowAccessibility {
    enum SelectionState: Equatable {
        case checked, unchecked, unavailable
    }

    static func statusKey(
        for status: TranscriptStatus,
        isUnrecoveredRecording: Bool = false
    ) -> String {
        NoteListRowState.statusKey(for: status, isUnrecoveredRecording: isUnrecoveredRecording)
    }

    /// `date` is nil when the title already is the date.
    static func label(
        title: String,
        date: String?,
        status: TranscriptStatus,
        hasSummary: Bool,
        selection: SelectionState?,
        isUnrecoveredRecording: Bool = false,
        workStageKey: String? = nil,
        localize: (String) -> String = { localizedCatalogString($0) }
    ) -> String {
        var parts = [title]
        if let date { parts.append(date) }
        parts += NoteListRowState.accessibilityKeys(
            status: status,
            isUnrecoveredRecording: isUnrecoveredRecording,
            workStageKey: workStageKey,
            hasSummary: hasSummary
        ).map(localize)
        switch selection {
        case .checked: parts.append(localize("Selected"))
        case .unchecked: parts.append(localize("Not selected"))
        case .unavailable: parts.append(localize("Can't be selected while recording or processing"))
        case nil: break
        }
        return parts.joined(separator: ", ")
    }
}
