import Combine
import Foundation

// One note's transcription work as one value (#768), the same on the Mac and
// the iPhone. Each app runs the work with its own engines and storage and
// reports what happened as `NoteWorkEvent`s; the rules for how the work moves
// on, and what it shows, live here once. Screens read one `NoteWork` per note,
// so they never combine values published at different moments (the 60% → 0%
// → 60% capsule on the iPhone, 2026-11-01).

/// The work running on one note's transcript: a transcription, a cleanup, or
/// both (the iPhone can retranscribe while an earlier cleanup still runs).
public struct NoteWork: Equatable, Sendable {
    /// Which transcription it is.
    public enum Kind: Equatable, Sendable {
        /// The note's first transcription (also a Mac audio-only note
        /// transcribed from the Note Browser).
        case first
        /// Transcribing again over the current transcript, which stays until
        /// the new one is saved.
        case retranscription
        /// The iPhone transcribing a note from the beginning with another
        /// model (a note an older model couldn't finish).
        case restart(modelName: String)
    }

    public enum Transcription: Equatable, Sendable {
        /// Queued behind other work (the iPhone).
        case waiting(Kind, reason: String?)
        /// Transcribing. The progress is the transcription's own (0...1); nil
        /// when it never reports any (one cloud request).
        case running(Kind, NoteWorkProgress?)
        /// Cloud transcription with chunks done, before its next upload (the
        /// Mac).
        case resumingCloud(NoteWorkProgress?)
        /// Stopping a first transcription (the iPhone).
        case cancelling(reason: String?)
        /// Paused (memory, heat, background, recording); it resumes or can be
        /// retried (the iPhone). `progress` is where it stopped.
        case paused(Kind, reason: String?, progress: NoteWorkProgress?)
        /// Recovering an interrupted recording again (the Mac).
        case recovering
    }

    /// Cleaning up the transcript.
    public struct Cleanup: Equatable, Sendable {
        /// Set while it waits for the cleanup model (the iPhone).
        public fileprivate(set) var waitReason: String?
        /// Where the bar's cleanup share is.
        public fileprivate(set) var progress: NoteCleanupProgress?
        /// False when the cleanup never reports chunks (the Mac's Edit Mode):
        /// the spinner without a bar.
        public fileprivate(set) var reportsProgress: Bool
        /// The attempt the progress belongs to, and where the bar was when it
        /// started. A new attempt (a fallback model, a rerun) continues from
        /// there; reports from a replaced attempt are dropped.
        fileprivate var attempt: Attempt?
        fileprivate var replacedAttempts: Set<UUID> = []

        fileprivate struct Attempt: Equatable, Sendable {
            let id: UUID
            let start: Double
        }
    }

    public private(set) var transcription: Transcription?
    public private(set) var cleanup: Cleanup?
    /// How transcription and cleanup share the one bar (the cleanup setting).
    /// Both apps re-split running work when the setting changes.
    public var stage: NoteCleanupStage

    public init(stage: NoteCleanupStage = .off) {
        self.stage = stage
    }

    /// Any work, including waiting, paused, and cancelling.
    public var isActive: Bool { transcription != nil || cleanup != nil }
    /// A cleanup runs or waits, whatever else the note shows.
    public var isPostProcessing: Bool { cleanup != nil }
}

/// What happened to a note's work. Each app sends these from where the work
/// runs; `NoteWork.apply` decides what the note shows next.
///
/// Starting events (`queued` without a transcription,
/// `cloudTranscriptionResuming` on a note without work,
/// `transcriptionStarted`, `recoveringStarted`,
/// `cleanupStarted`) begin work. The others only move work that fits them
/// on, so a late report after that work ended or moved on changes nothing.
public enum NoteWorkEvent: Equatable, Sendable {
    /// Waiting for its turn (the iPhone).
    case queued(NoteWork.Kind, reason: String?)
    /// Transcription started. `reportsProgress` false for work that never
    /// reports any (one cloud request): no bar instead of a bar stuck at 0%.
    case transcriptionStarted(NoteWork.Kind, reportsProgress: Bool = true)
    /// The transcription's own progress (0...1).
    case transcriptionProgressed(NoteWorkProgress)
    /// A Mac cloud job with chunks done waits for its next upload.
    case cloudTranscriptionResuming(NoteWorkProgress?)
    /// A first transcription is being stopped (the iPhone).
    case cancelling(reason: String?)
    /// Transcription paused (the iPhone).
    case paused(reason: String?)
    /// A paused transcription runs again, from where it stopped.
    case resumed
    case recoveringStarted
    /// The transcript is made. With `cleanupFollows`, cleanup takes over in
    /// the same change, at the bar's boundary: no moment shows the
    /// transcription without progress, or no status at all. A cleanup that
    /// already runs carries on.
    case transcriptionFinished(cleanupFollows: Bool, cleanupReportsProgress: Bool = true)
    /// The transcription stopped without a transcript to clean up: cancelled,
    /// failed, or done with cleanup off.
    case transcriptionEnded
    /// Cleanup started on its own (a retried cleanup, a resumed one). A
    /// cleanup that already runs carries on.
    case cleanupStarted(reportsProgress: Bool = true)
    /// Cleanup waits for the model, or stops waiting (nil).
    case cleanupWaiting(reason: String?)
    /// Cleanup's progress, already kept forward-only by the app (both apps
    /// keep a cleanup's progress with `NoteCleanupProgress.kept` and may send
    /// only the latest of several reports). `attempt` names the cleanup
    /// attempt (the iPhone splits again for a fallback or a rerun); nil when
    /// the app keeps one attempt (the Mac).
    case cleanupProgressed(NoteCleanupProgress, attempt: UUID? = nil)
    /// Cleanup ended: cleaned, failed, skipped, or stopped.
    case cleanupEnded
}

extension NoteWork {
    /// Moves the work on.
    public mutating func apply(_ event: NoteWorkEvent) {
        switch event {
        case .queued(let kind, let reason):
            switch transcription {
            case nil, .waiting, .paused:
                transcription = .waiting(kind, reason: Self.reason(reason))
            default:
                return
            }

        case .transcriptionStarted(let kind, let reportsProgress):
            transcription = .running(kind, reportsProgress ? .starting : nil)

        case .transcriptionProgressed(let progress):
            switch transcription {
            case .running(let kind, let current):
                // The bar never moves back.
                if let current, progress.fraction < current.fraction { return }
                transcription = .running(kind, progress)
            case .resumingCloud(let current):
                if let current, progress.fraction < current.fraction { return }
                transcription = .running(.first, progress)
            default:
                return
            }

        case .cloudTranscriptionResuming(let progress):
            switch transcription {
            case nil:
                // Only a note without work starts resuming (the Mac at launch);
                // a resume arriving during the note's cleanup is late.
                guard cleanup == nil else { return }
                transcription = .resumingCloud(progress)
            case .running(.first, let current), .resumingCloud(let current):
                if let current, let progress, progress.fraction < current.fraction { return }
                transcription = .resumingCloud(progress ?? current)
            default:
                return
            }

        case .cancelling(let reason):
            guard transcription != nil, transcription != .recovering else { return }
            transcription = .cancelling(reason: Self.reason(reason))

        case .paused(let reason):
            switch transcription {
            case .running(let kind, let progress), .paused(let kind, _, let progress):
                transcription = .paused(kind, reason: Self.reason(reason), progress: progress)
            case .waiting(let kind, _):
                transcription = .paused(kind, reason: Self.reason(reason), progress: nil)
            default:
                return
            }

        case .resumed:
            guard case .paused(let kind, _, let progress) = transcription else { return }
            transcription = .running(kind, progress ?? .starting)

        case .recoveringStarted:
            transcription = .recovering

        case .transcriptionFinished(let cleanupFollows, let cleanupReportsProgress):
            switch transcription {
            case .running, .resumingCloud:
                transcription = nil
                if cleanupFollows { beginCleanup(reportsProgress: cleanupReportsProgress) }
            default:
                return
            }

        case .transcriptionEnded:
            transcription = nil

        case .cleanupStarted(let reportsProgress):
            beginCleanup(reportsProgress: reportsProgress)

        case .cleanupWaiting(let reason):
            cleanup?.waitReason = Self.reason(reason)

        case .cleanupProgressed(let report, let attempt):
            // The attempt is recorded even when the bar doesn't move, so a
            // replaced attempt's late report is dropped from the first report
            // of the new one.
            cleanup?.place(report, attempt: attempt)

        case .cleanupEnded:
            cleanup = nil
        }
    }

    private mutating func beginCleanup(reportsProgress: Bool) {
        if cleanup == nil {
            cleanup = Cleanup(reportsProgress: reportsProgress)
        } else {
            cleanup?.reportsProgress = reportsProgress
        }
    }

    /// An empty reason is no reason.
    private static func reason(_ reason: String?) -> String? {
        reason.flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension NoteWork.Cleanup {
    fileprivate init(reportsProgress: Bool) {
        self.reportsProgress = reportsProgress
    }

    /// Places `report` on the bar. The app already kept it forward-only
    /// within its attempt (the contract of `cleanupProgressed`), so this only
    /// places it: a new attempt fills what is left from where the bar is, a
    /// report without an attempt belongs to the current one, a replaced
    /// attempt's late report is dropped, and the bar never moves back.
    fileprivate mutating func place(_ report: NoteCleanupProgress, attempt id: UUID?) {
        guard report.totalChunkCount > 0 || report.base > 0 else { return }
        if let id {
            guard !replacedAttempts.contains(id) else { return }
            if attempt?.id != id {
                if let replaced = attempt { replacedAttempts.insert(replaced.id) }
                attempt = Attempt(id: id, start: progress?.fraction ?? 0)
            }
        }
        let start = attempt?.start ?? 0
        let shown = NoteCleanupProgress(
            completedChunkCount: report.completedChunkCount,
            totalChunkCount: report.totalChunkCount,
            base: start + (1 - start) * report.base
        )
        if let progress, shown.fraction < progress.fraction { return }
        progress = shown
    }
}

extension NoteWork {
    /// What the note shows for this work, from the shared table. A
    /// transcription shows over a cleanup that still runs (a new
    /// retranscription over an earlier cleanup, the iPhone). Nil when no work
    /// runs.
    public var status: NoteWorkStatus? {
        if let transcription { return Self.status(transcription, stage: stage) }
        guard let cleanup else { return nil }
        if let waitReason = cleanup.waitReason { return .waitingToPostProcess(reason: waitReason) }
        return .postProcessing(NoteWorkProgress.combined(
            cleanupProgress: cleanup.progress?.workProgress, stage: stage, reportsProgress: cleanup.reportsProgress
        ))
    }

    private static func status(_ transcription: Transcription, stage: NoteCleanupStage) -> NoteWorkStatus {
        switch transcription {
        case .waiting(_, let reason):
            return .waitingToTranscribe(reason: reason)
        case .running(let kind, let progress):
            let bar = NoteWorkProgress.combined(transcription: progress, cleanup: stage)
            switch kind {
            case .first: return .transcribing(bar)
            case .retranscription: return .retranscribing(bar)
            case .restart(let modelName): return .restartingTranscription(modelName: modelName, bar)
            }
        case .resumingCloud(let progress):
            return .resumingCloudTranscription(NoteWorkProgress.combined(transcription: progress, cleanup: stage))
        case .cancelling(let reason):
            return .cancellingTranscription(reason: reason)
        case .paused(let kind, let reason, _):
            return kind == .retranscription
                ? .retranscriptionPaused(reason: reason)
                : .transcriptionPaused(reason: reason)
        case .recovering:
            return .recovering
        }
    }

    /// The toolbar's work for this note, read from the same work as the
    /// status.
    public var toolbarWork: NoteToolbarWork {
        switch transcription {
        case .waiting: return .waitingToTranscribe
        case .running(.first, _), .resumingCloud: return .transcribing
        case .running: return .retranscribing
        case .cancelling: return .cancelling
        // Nothing runs for the transcription; a cleanup underneath still does.
        case .paused, .recovering, nil:
            guard let cleanup else { return .none }
            return cleanup.waitReason == nil ? .postProcessing : .waitingToPostProcess
        }
    }
}

/// Every note's work, as one published value per note: the only source the
/// note screens, list rows, and toolbar read, on both apps.
@MainActor
public final class NoteWorkBoard: ObservableObject {
    @Published public private(set) var works: [String: NoteWork] = [:]
    /// The cleanup setting, for every note's bar. A change is published once
    /// for all notes.
    public private(set) var stage: NoteCleanupStage = .off

    public init() {}

    public func work(for noteID: String) -> NoteWork {
        works[noteID] ?? NoteWork(stage: stage)
    }

    /// Applies `event` to the note's work and publishes it once, only when it
    /// changed.
    public func send(_ event: NoteWorkEvent, for noteID: String) {
        var work = work(for: noteID)
        work.apply(event)
        if work.isActive {
            if works[noteID] != work { works[noteID] = work }
        } else if works[noteID] != nil {
            works[noteID] = nil
        }
    }

    public func setStage(_ stage: NoteCleanupStage) {
        guard stage != self.stage else { return }
        self.stage = stage
        guard !works.isEmpty else { return }
        works = works.mapValues { work in
            var work = work
            work.stage = stage
            return work
        }
    }

    /// The note is gone.
    public func forget(_ noteID: String) {
        works[noteID] = nil
    }
}
