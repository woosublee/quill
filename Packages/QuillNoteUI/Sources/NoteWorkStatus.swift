import Foundation

// The work running on a note, and how it reads, the same on the Mac and the
// iPhone (#697). Each app maps what it knows to `NoteWorkStatus`;
// `NoteWorkStatusView` draws the result. The text is copy keys: each app
// looks them up in its own String Catalog. The keys are the Mac's.

/// How far a transcription has got, for the progress bar and its
/// percentage. The title never counts chunks: the status shows a percentage
/// only (#697).
public struct NoteWorkProgress: Equatable, Sendable {
    /// Within 0...1.
    let measured: Double

    /// Chunks done out of the chunk count. Nil when there is no total to
    /// measure against; `completed` is kept within 0...total. A `fraction`
    /// is finer progress for the bar (the iPhone counts progress inside the
    /// current chunk) and replaces the counts; one that isn't a number
    /// falls back to them.
    public init?(completed: Int, total: Int, fraction: Double? = nil) {
        guard total > 0 else { return nil }
        if let fraction, fraction.isFinite {
            self.measured = min(max(fraction, 0), 1)
        } else {
            self.measured = Double(min(max(completed, 0), total)) / Double(total)
        }
    }

    /// Work that reports only a fraction, with no chunks (an iPhone
    /// retranscription of a Mac note). Nil when it isn't a number.
    public init?(fraction: Double) {
        guard fraction.isFinite else { return nil }
        self.measured = min(max(fraction, 0), 1)
    }

    /// Work that will report progress but hasn't yet (it is still reading
    /// or planning the audio). The bar shows at 0% from the start, so the
    /// status doesn't grow when the first count arrives (#697). Work that
    /// never reports progress (one cloud request) passes nil instead and
    /// shows the title and spinner only.
    public static let starting = NoteWorkProgress(measured: 0)

    private init(measured: Double) {
        self.measured = measured
    }

    /// Never 1 while the work still runs: the last chunk is still being
    /// saved, so it stops at 99%.
    public var fraction: Double {
        min(0.99, measured)
    }

    /// Whole percent, rounded down, at most 99 while the work runs. A tiny
    /// tolerance keeps an exact ratio exact: 29 of 50 is 0.58, which times
    /// 100 is 57.999… in floating point, and must read 58%, not 57%.
    public var percent: Int {
        min(99, Int((measured * 100 + 1e-9).rounded(.down)))
    }
}

/// What cleans up the transcript after it is transcribed, which decides how
/// much of the one progress bar each step fills (#697 owner decision): a
/// cloud model's cleanup is quicker than an on-device one's.
public enum NoteCleanupStage: Equatable, Sendable {
    /// Post-processing is off: transcription fills the whole bar.
    case off
    /// A cloud model: transcription 0–80%, cleanup 80–100%.
    case cloud
    /// An on-device model: transcription 0–60%, cleanup 60–100%.
    case onDevice

    /// The part of the bar transcription fills.
    public var transcriptionShare: Double {
        switch self {
        case .off: return 1
        case .cloud: return 0.8
        case .onDevice: return 0.6
        }
    }
}

extension NoteWorkProgress {
    /// Transcription's progress as part of the one bar: nil when the
    /// transcription reports none (one cloud request), so no bar shows yet.
    public static func combined(transcription: NoteWorkProgress?, cleanup: NoteCleanupStage) -> NoteWorkProgress? {
        transcription.flatMap { NoteWorkProgress(fraction: $0.measured * cleanup.transcriptionShare) }
    }

    /// Cleanup's progress as part of the one bar, picking up where
    /// transcription stopped: 0 of N chunks is the boundary, and a single
    /// chunk holds there until it is done. Nil when cleanup reports no
    /// progress (Edit Mode) or is off.
    public static func combined(cleanupProgress progress: NoteWorkProgress?, stage: NoteCleanupStage) -> NoteWorkProgress? {
        guard stage != .off, let progress else { return nil }
        let share = stage.transcriptionShare
        return NoteWorkProgress(fraction: share + (1 - share) * progress.measured)
    }
}

/// The work on a note. Some states only one app has: the Mac never sends the
/// waiting, cancelling, paused, preparing, or restarting ones, and the iPhone
/// never sends recovering. A `reason` is a sentence the app has already localized: why
/// the work waits or paused, which only the app knows.
public enum NoteWorkStatus: Equatable, Sendable {
    /// Queued behind other work (the iPhone).
    case waitingToTranscribe(reason: String?)
    /// A first transcription.
    case transcribing(NoteWorkProgress?)
    /// Cloud transcription between attempts, or picking up after a restart
    /// (the Mac).
    case resumingCloudTranscription(NoteWorkProgress?)
    /// Transcribing again over an existing transcript.
    case retranscribing(NoteWorkProgress?)
    /// The iPhone stopping a transcription. The reason says what is kept
    /// (the recording stays on the device).
    case cancellingTranscription(reason: String?)
    /// The iPhone paused a transcription (memory, heat, background); it
    /// resumes or can be retried.
    case transcriptionPaused(reason: String?)
    /// The iPhone paused a retranscription over an existing transcript; the
    /// current transcript stays.
    case retranscriptionPaused(reason: String?)
    /// The iPhone transcribing a note from the beginning with another model
    /// (a note an older model couldn't finish). `modelName` is shown as is.
    case restartingTranscription(modelName: String, NoteWorkProgress?)
    /// The transcript is done and is being opened (the iPhone).
    case preparingTranscript(reason: String?)
    /// The transcript is done and waits for the cleanup model (the iPhone).
    case waitingToPostProcess(reason: String?)
    /// Cleaning up the transcript. The progress is the whole job's one bar
    /// (`NoteWorkProgress.combined`), continuing from transcription.
    case postProcessing(NoteWorkProgress?)
    /// Recovering an interrupted recording again (the Mac).
    case recovering
    case creatingSummary
    case regeneratingSummary

    public enum Indicator: Equatable, Sendable {
        /// Work is running.
        case spinner
        /// Nothing runs until something changes (paused).
        case hidden
    }

    /// What the view shows: an indicator, the title, an optional detail line,
    /// and an optional progress bar with its percentage.
    public struct Presentation: Equatable, Sendable {
        public let indicator: Indicator
        public let title: String
        public let detail: String?
        public let progress: NoteWorkProgress?

        public init(indicator: Indicator, title: String, detail: String?, progress: NoteWorkProgress?) {
            self.indicator = indicator
            self.title = title
            self.detail = detail
            self.progress = progress
        }

        /// "40%". Digits and sign are the same in every language Quill ships.
        public var percentText: String? {
            progress.map { "\($0.percent)%" }
        }
    }

    /// The title's copy key.
    public var titleKey: String {
        switch self {
        case .waitingToTranscribe: return "Waiting to transcribe..."
        case .transcribing: return "Transcribing..."
        case .resumingCloudTranscription: return "Resuming cloud transcription…"
        case .retranscribing: return "Retranscribing..."
        case .cancellingTranscription: return "Cancelling transcription..."
        case .transcriptionPaused: return "Transcription paused"
        case .retranscriptionPaused: return "Retranscription paused"
        case .restartingTranscription: return "Transcribing with %@..."
        case .preparingTranscript: return "Preparing transcript"
        case .waitingToPostProcess: return "Waiting to post-process"
        case .postProcessing: return "Post-processing..."
        case .recovering: return "Recovering…"
        case .creatingSummary: return "Creating summary…"
        case .regeneratingSummary: return "Regenerating summary…"
        }
    }

    public var indicator: Indicator {
        switch self {
        case .transcriptionPaused, .retranscriptionPaused: return .hidden
        default: return .spinner
        }
    }

    public var progress: NoteWorkProgress? {
        switch self {
        case .transcribing(let progress), .resumingCloudTranscription(let progress), .retranscribing(let progress),
             .restartingTranscription(_, let progress), .postProcessing(let progress):
            return progress
        default:
            return nil
        }
    }

    public var reason: String? {
        switch self {
        case .waitingToTranscribe(let reason), .transcriptionPaused(let reason), .waitingToPostProcess(let reason),
             .cancellingTranscription(let reason),
             .retranscriptionPaused(let reason), .preparingTranscript(let reason):
            return reason.flatMap { $0.isEmpty ? nil : $0 }
        default:
            return nil
        }
    }

    /// Works on the summary rather than the transcript.
    public var isSummaryWork: Bool {
        switch self {
        case .creatingSummary, .regeneratingSummary: return true
        default: return false
        }
    }

    /// `localize` looks a copy key up in the app's String Catalog; `locale`
    /// is the app's chosen language, for a formatted title.
    public func presentation(localize: (String) -> String, locale: Locale? = nil) -> Presentation {
        let format = localize(titleKey)
        let title: String
        switch self {
        case .restartingTranscription(let modelName, _):
            title = String(format: format, locale: locale, modelName)
        default:
            title = format
        }
        return Presentation(indicator: indicator, title: title, detail: reason, progress: progress)
    }

    /// Each case without its values, so the catalog checks can list every
    /// state: a new case doesn't compile until it has a kind here.
    public enum Kind: CaseIterable, Sendable {
        case waitingToTranscribe, transcribing, resumingCloudTranscription, retranscribing
        case cancellingTranscription, transcriptionPaused, waitingToPostProcess, postProcessing
        case recovering, creatingSummary, regeneratingSummary
        case retranscriptionPaused, restartingTranscription, preparingTranscript

        /// One status per title this kind can show.
        public var examples: [NoteWorkStatus] {
            switch self {
            case .waitingToTranscribe: return [.waitingToTranscribe(reason: nil)]
            case .transcribing: return [.transcribing(nil)]
            case .resumingCloudTranscription: return [.resumingCloudTranscription(nil)]
            case .retranscribing: return [.retranscribing(nil)]
            case .cancellingTranscription: return [.cancellingTranscription(reason: nil)]
            case .transcriptionPaused: return [.transcriptionPaused(reason: nil)]
            case .waitingToPostProcess: return [.waitingToPostProcess(reason: nil)]
            case .postProcessing: return [.postProcessing(nil)]
            case .recovering: return [.recovering]
            case .creatingSummary: return [.creatingSummary]
            case .regeneratingSummary: return [.regeneratingSummary]
            case .retranscriptionPaused: return [.retranscriptionPaused(reason: nil)]
            case .restartingTranscription: return [.restartingTranscription(modelName: "Model", nil)]
            case .preparingTranscript: return [.preparingTranscript(reason: nil)]
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .waitingToTranscribe: return .waitingToTranscribe
        case .transcribing: return .transcribing
        case .resumingCloudTranscription: return .resumingCloudTranscription
        case .retranscribing: return .retranscribing
        case .cancellingTranscription: return .cancellingTranscription
        case .transcriptionPaused: return .transcriptionPaused
        case .waitingToPostProcess: return .waitingToPostProcess
        case .postProcessing: return .postProcessing
        case .recovering: return .recovering
        case .creatingSummary: return .creatingSummary
        case .regeneratingSummary: return .regeneratingSummary
        case .retranscriptionPaused: return .retranscriptionPaused
        case .restartingTranscription: return .restartingTranscription
        case .preparingTranscript: return .preparingTranscript
        }
    }

    /// Every copy key the table can produce, for each app's catalog check.
    public static var allTitleKeys: [String] {
        Kind.allCases.flatMap(\.examples).map(\.titleKey)
    }
}

// The toolbar reads from the same table, so its labels match the status
// (#697): the same keys, the same capitalisation, on both apps.

extension NoteToolbarWork {
    /// The status this work shows, without progress.
    public var status: NoteWorkStatus? {
        switch self {
        case .none: return nil
        case .waitingToTranscribe: return .waitingToTranscribe(reason: nil)
        case .transcribing: return .transcribing(nil)
        case .retranscribing: return .retranscribing(nil)
        case .cancelling: return .cancellingTranscription(reason: nil)
        case .waitingToPostProcess: return .waitingToPostProcess(reason: nil)
        case .postProcessing: return .postProcessing(nil)
        }
    }

    /// The toolbar's progress slot label: the status title.
    public var progressLabelKey: String {
        (status ?? .transcribing(nil)).titleKey
    }
}

extension NoteToolbarFirstAction {
    /// The copy key for the actions both apps word the same way, or nil for
    /// the ones each app words itself: the summary's ↻ (regenerate or
    /// retry) and model setup, which opens a different screen on each.
    public var labelKey: String? {
        switch self {
        case .transcribe: return "Transcribe audio"
        case .retry, .retranscribe: return "Retry transcription"
        case .cancelTranscription: return "Cancel Transcription"
        case .cancelRetranscription: return "Cancel Retranscription"
        case .cancelPostProcessing: return "Cancel Post-processing"
        case .cancelSummary: return "Cancel Summary"
        case .openModelSetup, .runSummary: return nil
        }
    }
}
