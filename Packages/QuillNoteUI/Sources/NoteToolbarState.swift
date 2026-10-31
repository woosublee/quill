import Foundation

// The note toolbar's states (#690), the same on the Mac and the iPhone.
// Each app maps what it knows about a note to `NoteToolbarInput`, and
// `NoteFloatingToolbar` draws the result. Nothing here runs work.

/// The tab the toolbar sits under.
public enum NoteToolbarTab: Equatable, Sendable {
    case transcript
    case summary
}

/// The transcription work running for the note.
public enum NoteToolbarWork: Equatable, Sendable {
    case none
    case waitingToTranscribe
    /// A first transcription.
    case transcribing
    case retranscribing
    case cancelling
    /// Cleaning up the transcript, or waiting to.
    case postProcessing

    /// Any transcription work, including cancelling and post-processing.
    public var isRunning: Bool { self != .none }
}

/// The transcript tab's own action while no work runs.
public enum NoteToolbarTranscriptAction: Equatable, Sendable {
    /// A note with audio and no transcript (failed, or audio only).
    case transcribe
    case retry
    case retranscribe
    /// No transcription model is set up yet (the iPhone's ⚙︎).
    case openModelSetup
}

/// What the first slot does when pressed.
public enum NoteToolbarFirstAction: Equatable, Sendable {
    case transcribe
    case retry
    case retranscribe
    case openModelSetup
    /// The summary tab's ↻ (regenerate, or retry after a failed attempt).
    case runSummary
    case cancelTranscription
    case cancelRetranscription
    case cancelPostProcessing
    case cancelSummary

    public var isCancel: Bool {
        switch self {
        case .cancelTranscription, .cancelRetranscription, .cancelPostProcessing, .cancelSummary: true
        case .transcribe, .retry, .retranscribe, .openModelSetup, .runSummary: false
        }
    }
}

/// What each app knows about the note, before the #690 rules apply.
public struct NoteToolbarInput: Equatable, Sendable {
    public var tab: NoteToolbarTab
    public var work: NoteToolbarWork
    /// The app can stop the running work from the toolbar. Without it, the
    /// first slot shows progress instead of ✕.
    public var canCancelWork: Bool
    /// The transcript tab's action while no work runs, or nil for none.
    public var transcriptAction: NoteToolbarTranscriptAction?
    /// The note has a summary tab (a summary, or a failed attempt).
    public var hasSummaryTab: Bool
    public var isMakingSummary: Bool
    /// The summary tab's ↻ could run now, before the work rules apply
    /// (a model is ready, the feature is on).
    public var canRunSummary: Bool
    /// The summary is being compared with a candidate or edited, so ↻
    /// would replace what the person is working on.
    public var isSummaryActionBlocked: Bool
    /// The transcript tab's ✨ when the note has no summary tab: nil when
    /// there's nothing to summarize, else whether it can run now.
    public var canCreateSummary: Bool?
    public var hasTranscriptToCopy: Bool
    public var hasSummaryToCopy: Bool
    public var hasFilesToSave: Bool
    public var canDelete: Bool

    public init(
        tab: NoteToolbarTab,
        work: NoteToolbarWork = .none,
        canCancelWork: Bool = false,
        transcriptAction: NoteToolbarTranscriptAction? = nil,
        hasSummaryTab: Bool = false,
        isMakingSummary: Bool = false,
        canRunSummary: Bool = false,
        isSummaryActionBlocked: Bool = false,
        canCreateSummary: Bool? = nil,
        hasTranscriptToCopy: Bool = false,
        hasSummaryToCopy: Bool = false,
        hasFilesToSave: Bool = false,
        canDelete: Bool = true
    ) {
        self.tab = tab
        self.work = work
        self.canCancelWork = canCancelWork
        self.transcriptAction = transcriptAction
        self.hasSummaryTab = hasSummaryTab
        self.isMakingSummary = isMakingSummary
        self.canRunSummary = canRunSummary
        self.isSummaryActionBlocked = isSummaryActionBlocked
        self.canCreateSummary = canCreateSummary
        self.hasTranscriptToCopy = hasTranscriptToCopy
        self.hasSummaryToCopy = hasSummaryToCopy
        self.hasFilesToSave = hasFilesToSave
        self.canDelete = canDelete
    }
}

/// The toolbar's slots: `[first] | Copy · Save · (✨) | Delete`. A disabled
/// button keeps its slot, dimmed; only the first slot and ✨ can be absent.
public struct NoteToolbarState: Equatable, Sendable {
    public enum FirstSlot: Equatable, Sendable {
        case none
        /// Work that can't be pressed (cancelling, or no cancel path).
        case progress
        case button(NoteToolbarFirstAction, isEnabled: Bool)
    }

    public enum CreateSummarySlot: Equatable, Sendable {
        case none
        case button(isEnabled: Bool)
    }

    public var firstSlot: FirstSlot
    public var isCopyEnabled: Bool
    public var isSaveEnabled: Bool
    public var createSummary: CreateSummarySlot
    public var isDeleteEnabled: Bool

    public init(
        firstSlot: FirstSlot,
        isCopyEnabled: Bool,
        isSaveEnabled: Bool,
        createSummary: CreateSummarySlot,
        isDeleteEnabled: Bool
    ) {
        self.firstSlot = firstSlot
        self.isCopyEnabled = isCopyEnabled
        self.isSaveEnabled = isSaveEnabled
        self.createSummary = createSummary
        self.isDeleteEnabled = isDeleteEnabled
    }

    /// The toolbar hides only while recording (the recorder panel takes its
    /// place), while comparing candidates (the choice bar does), and on the
    /// iPhone while editing with the keyboard up.
    public static func isHidden(
        isRecording: Bool,
        isComparingCandidates: Bool,
        isEditingWithKeyboard: Bool = false
    ) -> Bool {
        isRecording || isComparingCandidates || isEditingWithKeyboard
    }

    /// The #690 table.
    public static func make(_ input: NoteToolbarInput) -> Self {
        let work = input.work
        let isAnyWork = work.isRunning || input.isMakingSummary
        // Save and Delete open the same picker from either tab: off during
        // any work.
        let isSaveEnabled = input.hasFilesToSave && !isAnyWork
        let isDeleteEnabled = input.canDelete && !isAnyWork

        switch input.tab {
        case .transcript:
            return Self(
                firstSlot: transcriptFirstSlot(input),
                // Copy is off while the open tab's content is changing.
                isCopyEnabled: input.hasTranscriptToCopy && !work.isRunning,
                isSaveEnabled: isSaveEnabled,
                createSummary: createSummarySlot(input),
                isDeleteEnabled: isDeleteEnabled
            )
        case .summary:
            let firstSlot: FirstSlot = input.isMakingSummary
                ? .button(.cancelSummary, isEnabled: true)
                : .button(
                    .runSummary,
                    isEnabled: input.canRunSummary && !work.isRunning && !input.isSummaryActionBlocked
                )
            return Self(
                firstSlot: firstSlot,
                isCopyEnabled: input.hasSummaryToCopy && !input.isMakingSummary,
                isSaveEnabled: isSaveEnabled,
                createSummary: .none,
                isDeleteEnabled: isDeleteEnabled
            )
        }
    }

    private static func transcriptFirstSlot(_ input: NoteToolbarInput) -> FirstSlot {
        let cancel: NoteToolbarFirstAction
        switch input.work {
        case .cancelling:
            return .progress
        case .waitingToTranscribe, .transcribing:
            cancel = .cancelTranscription
        case .retranscribing:
            cancel = .cancelRetranscription
        case .postProcessing:
            cancel = .cancelPostProcessing
        case .none:
            guard let action = input.transcriptAction else { return .none }
            let firstAction: NoteToolbarFirstAction = switch action {
            case .transcribe: .transcribe
            case .retry: .retry
            case .retranscribe: .retranscribe
            case .openModelSetup: .openModelSetup
            }
            // While a summary is being made, nothing but its Cancel runs.
            // Model setup only opens Settings, so it stays on.
            return .button(firstAction, isEnabled: firstAction == .openModelSetup || !input.isMakingSummary)
        }
        return input.canCancelWork ? .button(cancel, isEnabled: true) : .progress
    }

    private static func createSummarySlot(_ input: NoteToolbarInput) -> CreateSummarySlot {
        // A note with a summary tab makes it there; while one is being made,
        // the summary tab opens.
        guard !input.hasSummaryTab, !input.isMakingSummary else { return .none }
        // A note without a summary keeps ✨ in its slot, dimmed, until
        // transcription and post-processing have both finished.
        if input.work.isRunning { return .button(isEnabled: false) }
        // A note whose action is Transcribe (audio only, or a failed
        // transcription that kept no text) has nothing to summarize: no ✨,
        // on both apps (2026-10-28 decision). A failed note whose action is
        // Retry keeps ✨, dimmed while its transcript is empty, as on the Mac.
        if input.transcriptAction == .transcribe { return .none }
        return input.canCreateSummary.map { .button(isEnabled: $0) } ?? .none
    }
}
