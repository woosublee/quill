import Foundation

// What the note toolbar's summary buttons get (#782): the transcript tab's ✨
// and the summary tab's ↻. The Mac's note screen and both iPhone note
// screens turn a note into these values here, so one note gets the same
// `NoteToolbarInput` everywhere. Each app still says, from its own summary
// availability, whether pressing the button does something now (`canRun`).

/// The transcript a summary would be made from.
public enum NoteSummaryTranscript: Equatable, Sendable {
    /// No transcript yet (audio only, still to be transcribed).
    case missing
    /// Transcribed, but there's no text to summarize (a cleared transcript,
    /// or a recording with no speech).
    case empty
    case present

    /// Only spaces or line breaks count as no text.
    public init(hasTranscript: Bool, text: String?) {
        if !hasTranscript {
            self = .missing
        } else if text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            self = .present
        } else {
            self = .empty
        }
    }
}

/// What the summary button does: a first summary (✨), a retry after a
/// failed attempt, or a new one over the saved summary (↻).
public enum NoteSummaryKind: Equatable, Sendable {
    case create
    case retry
    case regenerate

    /// A saved summary is regenerated even when the last attempt failed.
    /// (The Mac also retries after a retryable summary issue with no failed
    /// attempt, so it works out its own kind.)
    public init(hasSummary: Bool, lastAttemptFailed: Bool) {
        self = hasSummary ? .regenerate : (lastAttemptFailed ? .retry : .create)
    }
}

/// Where a summary stands right now, read from each app's own availability.
/// It decides whether ✨ and the summary tab's ↻ do something when pressed.
public enum NoteSummaryReadiness: Equatable, CaseIterable, Sendable {
    case ready
    /// Meeting Summary is off in Settings: pressing says so.
    case featureOff
    /// The on-device model is busy with a recording, a transcription, or
    /// another note's summary (the iPhone).
    case modelBusy
    /// No summary model is set up or ready.
    case noModel
    /// The cloud summary model has no API key (the iPhone).
    case noKey
    case transcribing
    case postProcessing
    /// Nothing to summarize: no transcript, or no text in it.
    case noTranscript
    /// This note's summary is being made.
    case making

    /// ✨ and ↻ stay dimmed and can't be pressed while a summary can't run:
    /// no model, no key, the model busy, transcribing, or post-processing,
    /// as on the Mac (2026-11-08 decision t2). A summary that's off can
    /// still be pressed: it opens the setting that turns it on.
    public var allowsPress: Bool {
        switch self {
        case .ready, .featureOff: true
        case .modelBusy, .noModel, .noKey, .transcribing, .postProcessing, .noTranscript, .making: false
        }
    }
}

/// The summary part of `NoteToolbarInput`.
public struct NoteToolbarSummaryInput: Equatable, Sendable {
    public private(set) var hasSummaryTab: Bool
    public private(set) var isMakingSummary: Bool
    public private(set) var canRunSummary: Bool
    public private(set) var isSummaryActionBlocked: Bool
    public private(set) var canCreateSummary: Bool?
    public private(set) var hasSummaryToCopy: Bool

    /// A note this screen can't summarize: no summary tab and no ✨ input.
    public static let none = Self(
        hasSummaryTab: false,
        isMakingSummary: false,
        canRunSummary: false,
        isSummaryActionBlocked: false,
        canCreateSummary: nil,
        hasSummaryToCopy: false
    )

    private init(
        hasSummaryTab: Bool,
        isMakingSummary: Bool,
        canRunSummary: Bool,
        isSummaryActionBlocked: Bool,
        canCreateSummary: Bool?,
        hasSummaryToCopy: Bool
    ) {
        self.hasSummaryTab = hasSummaryTab
        self.isMakingSummary = isMakingSummary
        self.canRunSummary = canRunSummary
        self.isSummaryActionBlocked = isSummaryActionBlocked
        self.canCreateSummary = canCreateSummary
        self.hasSummaryToCopy = hasSummaryToCopy
    }

    /// - Parameters:
    ///   - canRun: the button does something now, from
    ///     `NoteSummaryReadiness.allowsPress`, before the transcript and
    ///     work rules here.
    ///   - isBlocked: the summary is being compared with a candidate or
    ///     edited, so ↻ would replace what the person is working on.
    public static func make(
        kind: NoteSummaryKind,
        transcript: NoteSummaryTranscript,
        canRun: Bool,
        hasSummaryTab: Bool,
        isMakingSummary: Bool,
        isBlocked: Bool,
        hasSummaryToCopy: Bool
    ) -> Self {
        // Only a transcript with text can be summarized: a missing or empty
        // one keeps ✨ and ↻ in their slots, dimmed (2026-11-02).
        let canSummarize = transcript == .present && canRun && !isMakingSummary
        return Self(
            hasSummaryTab: hasSummaryTab,
            isMakingSummary: isMakingSummary,
            canRunSummary: canSummarize,
            isSummaryActionBlocked: isBlocked,
            // ✨ is for a first summary only; a retry or regenerate is the
            // summary tab's ↻. (While one is being made, the table shows
            // its tab instead.)
            canCreateSummary: kind == .create ? canSummarize : nil,
            hasSummaryToCopy: hasSummaryToCopy
        )
    }
}

extension NoteToolbarInput {
    /// The note's toolbar input with its summary part from `summary`.
    public init(
        tab: NoteToolbarTab,
        work: NoteToolbarWork = .none,
        canCancelWork: Bool = false,
        transcriptAction: NoteToolbarTranscriptAction? = nil,
        canRunTranscriptAction: Bool = true,
        summary: NoteToolbarSummaryInput,
        hasTranscriptToCopy: Bool,
        hasFilesToSave: Bool,
        canDelete: Bool
    ) {
        self.init(
            tab: tab,
            work: work,
            canCancelWork: canCancelWork,
            transcriptAction: transcriptAction,
            canRunTranscriptAction: canRunTranscriptAction,
            hasSummaryTab: summary.hasSummaryTab,
            isMakingSummary: summary.isMakingSummary,
            canRunSummary: summary.canRunSummary,
            isSummaryActionBlocked: summary.isSummaryActionBlocked,
            canCreateSummary: summary.canCreateSummary,
            hasTranscriptToCopy: hasTranscriptToCopy,
            hasSummaryToCopy: summary.hasSummaryToCopy,
            hasFilesToSave: hasFilesToSave,
            canDelete: canDelete
        )
    }
}
