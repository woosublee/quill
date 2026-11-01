import Foundation

/// The state a note list row shows, the same on both apps.
public enum NoteListRowStatus: Equatable, Sendable {
    case done, recording, transcribing, audioOnly, recovered, fail

    /// Notes still recording or processing are left out of multi-selection
    /// and bulk deletion.
    public var isBulkSelectable: Bool {
        switch self {
        case .recording, .transcribing: return false
        case .done, .audioOnly, .recovered, .fail: return true
        }
    }

    /// A note's row status from its synced post-processing status and the
    /// work running for it. `isRetrying` wins over everything: the note is
    /// being transcribed again. `isCloudTranscriptionStopped` marks a
    /// cloud-transcribing note that no work is running for; it shows as
    /// failed so it can be retried or deleted.
    public init(
        machineStatus: NoteMachineStatus,
        isTranscriptionPlaceholder: Bool,
        isRetrying: Bool = false,
        isCloudTranscriptionStopped: Bool = false
    ) {
        if isRetrying {
            self = .transcribing
            return
        }
        switch machineStatus {
        case .liveRecording:
            self = .recording
        case .importing:
            self = .transcribing
        case .cloudTranscribing:
            self = isCloudTranscriptionStopped ? .fail : .transcribing
        case .audioOnly:
            self = .audioOnly
        case .recovered:
            self = .recovered
        case .failed, .unrecovered:
            self = .fail
        case .completed:
            self = isTranscriptionPlaceholder ? .transcribing : .done
        }
    }
}

/// What the row's status corner draws. Each app picks its own colors and
/// symbols for these.
public enum NoteListRowDotRole: Equatable, Sendable {
    /// A green dot: transcribed, or audio only.
    case done
    /// A red dot with the running time.
    case recording
    /// A spinner.
    case processing
    /// The recovered recording symbol (`arrow.clockwise.circle`).
    case recovered
    /// A red dot; a warning symbol under Differentiate Without Color.
    case failure
}

/// What the row's preview line shows.
public enum NoteListRowPreview: Equatable, Sendable {
    /// The note's own text (its transcript's first line, or live text).
    case content
    /// A catalog key each app translates.
    case key(String)
    /// The recovered recording's description, which each app writes from
    /// the context.
    case recoveredRecording(RecoveredRecordingContext)
}

/// A note list row's status, dot, preview, badges, and VoiceOver state, read
/// from the note's `NoteMachineStatus` and the work running for it
/// (woosublee/quill#697). Both apps build their rows from this, so one note
/// reads the same on the Mac and the iPhone. Keys are catalog keys; each app
/// translates them with its own String Catalog.
public struct NoteListRowState: Equatable, Sendable {
    public static let audioOnlyBadgeKey = "Audio only"
    public static let summaryBadgeKey = "Summary"

    public let status: NoteListRowStatus
    /// The recording could not be recovered, so the failure reads
    /// "Couldn't recover" rather than a failed transcription.
    public let isUnrecoveredRecording: Bool
    /// The catalog key of the stage the preview line shows while work runs
    /// ("Recording...", "Transcribing...", "Retranscribing...",
    /// "Post-processing..."); nil once the note is settled. VoiceOver reads
    /// it as the row's state.
    public let workStageKey: String?
    public let hasSummary: Bool
    private let recoveredContext: RecoveredRecordingContext?

    /// `hasContent` says whether the note has transcript (or live) text;
    /// a recording with live text shows that text instead of its stage.
    public init(
        machineStatus: NoteMachineStatus,
        isTranscriptionPlaceholder: Bool,
        hasContent: Bool,
        hasSummary: Bool = false,
        isRetrying: Bool = false,
        isCloudTranscriptionStopped: Bool = false,
        isPostProcessing: Bool = false
    ) {
        let status = NoteListRowStatus(
            machineStatus: machineStatus,
            isTranscriptionPlaceholder: isTranscriptionPlaceholder,
            isRetrying: isRetrying,
            isCloudTranscriptionStopped: isCloudTranscriptionStopped
        )
        self.status = status
        self.hasSummary = hasSummary
        if case .unrecovered = machineStatus {
            isUnrecoveredRecording = true
        } else {
            isUnrecoveredRecording = false
        }
        if case .recovered(let context) = machineStatus {
            recoveredContext = context
        } else {
            recoveredContext = nil
        }
        workStageKey = Self.workStageKey(
            status: status,
            machineStatus: machineStatus,
            hasContent: hasContent,
            isRetrying: isRetrying,
            isPostProcessing: isPostProcessing
        )
    }

    /// The stage a working note's preview line shows, named like the note
    /// detail's progress: recording with no live text yet, transcribing
    /// (again, for a note that had been transcribed or failed), then
    /// post-processing. A recording with live text shows that text instead.
    public static func workStageKey(
        status: NoteListRowStatus,
        machineStatus: NoteMachineStatus,
        hasContent: Bool,
        isRetrying: Bool,
        isPostProcessing: Bool
    ) -> String? {
        switch status {
        case .recording:
            return hasContent ? nil : "Recording..."
        case .transcribing:
            if isPostProcessing { return "Post-processing..." }
            if isRetrying, machineStatus != .audioOnly { return "Retranscribing..." }
            return "Transcribing..."
        case .done, .audioOnly, .recovered, .fail:
            return nil
        }
    }

    public var dotRole: NoteListRowDotRole {
        switch status {
        case .done, .audioOnly: return .done
        case .recording: return .recording
        case .transcribing: return .processing
        case .recovered: return .recovered
        case .fail: return .failure
        }
    }

    public var preview: NoteListRowPreview {
        switch status {
        case .audioOnly:
            return .key("Not transcribed")
        case .fail:
            return .key(isUnrecoveredRecording ? "Couldn't recover" : "Couldn't transcribe")
        case .recovered:
            return .recoveredRecording(
                recoveredContext
                    ?? RecoveredRecordingContext(mode: .complete, interruptionReason: nil)
            )
        case .done, .recording, .transcribing:
            // Chunk progress stays in the note detail.
            return workStageKey.map(NoteListRowPreview.key) ?? .content
        }
    }

    /// The badges after the row's date, in order.
    public var badgeKeys: [String] {
        var keys: [String] = []
        if showsAudioOnlyBadge { keys.append(Self.audioOnlyBadgeKey) }
        if hasSummary { keys.append(Self.summaryBadgeKey) }
        return keys
    }

    public var showsAudioOnlyBadge: Bool { status == .audioOnly }

    /// The state in words (not only the dot's color).
    public var statusKey: String {
        Self.statusKey(for: status, isUnrecoveredRecording: isUnrecoveredRecording)
    }

    public static func statusKey(
        for status: NoteListRowStatus,
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

    /// What VoiceOver reads after the row's name and date: the work stage
    /// while work runs, else the state, then each badge the state didn't
    /// already say.
    public var accessibilityKeys: [String] {
        Self.accessibilityKeys(
            status: status,
            isUnrecoveredRecording: isUnrecoveredRecording,
            workStageKey: workStageKey,
            hasSummary: hasSummary
        )
    }

    public static func accessibilityKeys(
        status: NoteListRowStatus,
        isUnrecoveredRecording: Bool = false,
        workStageKey: String? = nil,
        hasSummary: Bool
    ) -> [String] {
        let state = workStageKey
            ?? statusKey(for: status, isUnrecoveredRecording: isUnrecoveredRecording)
        var keys = [state]
        if status == .audioOnly, state != audioOnlyBadgeKey { keys.append(audioOnlyBadgeKey) }
        if hasSummary { keys.append(summaryBadgeKey) }
        return keys
    }
}
