import Combine
import Foundation

// One note's transcription work as one value (#768), the same on the Mac and
// the iPhone. Each app runs the work with its own engines and storage and
// reports what happened as `NoteWorkEvent`s; the rules for how the work moves
// on, and what it shows, live here once. Screens read one `NoteWork` per note,
// so they never combine values published at different moments (the 60% → 0%
// → 60% capsule on the iPhone, 2026-11-01).

/// The work running on one note's transcript.
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

    public enum Phase: Equatable, Sendable {
        case idle
        /// Queued behind other work (the iPhone).
        case waitingToTranscribe(Kind, reason: String?)
        /// Transcribing. The progress is the transcription's own (0...1); nil
        /// when it never reports any (one cloud request).
        case transcribing(Kind, NoteWorkProgress?)
        /// Cloud transcription with chunks done, before its next upload (the
        /// Mac).
        case resumingCloudTranscription(NoteWorkProgress?)
        /// Stopping a first transcription (the iPhone).
        case cancellingTranscription(reason: String?)
        /// Paused (memory, heat, background, recording); it resumes or can be
        /// retried (the iPhone). `progress` is where it stopped, so it
        /// resumes from there.
        case paused(Kind, reason: String?, progress: NoteWorkProgress?)
        /// Recovering an interrupted recording again (the Mac).
        case recovering
        /// Cleaning up the transcript. `waitReason` is set while it waits for
        /// the cleanup model (the iPhone); `progress` is the cleanup's own,
        /// kept so the bar never moves back.
        case postProcessing(waitReason: String?, progress: NoteCleanupProgress?)
    }

    public private(set) var phase: Phase
    /// How transcription and cleanup share the one bar (the cleanup setting).
    /// Both apps re-split running work when the setting changes.
    public var cleanup: NoteCleanupStage
    /// False while a cleanup never reports chunks (the Mac's Edit Mode): the
    /// status keeps the spinner without a bar.
    public private(set) var cleanupReportsProgress = true

    /// One cleanup attempt: its own kept progress, and where the bar was when
    /// it started. A new attempt (a fallback model, a rerun) continues from
    /// there.
    private struct CleanupAttempt: Equatable, Sendable {
        let id: UUID
        let start: Double
        var kept: NoteCleanupProgress
    }
    private var cleanupAttempt: CleanupAttempt?
    /// Attempts that were replaced; their late reports are dropped.
    private var endedCleanupAttempts: Set<UUID> = []

    public init(cleanup: NoteCleanupStage = .off) {
        self.phase = .idle
        self.cleanup = cleanup
    }

    /// Any work, including waiting, paused, and cancelling.
    public var isActive: Bool { phase != .idle }
}

/// What happened to a note's work. Each app sends these from where the work
/// runs; `NoteWork.apply` decides what the note shows next.
///
/// Starting events (`queued`, `transcriptionStarted`, `cloudTranscriptionResuming`
/// on a note without work, `cleanupStarted`, `recoveringStarted`) begin work.
/// The others only move work that fits them on, so a late report after the
/// work ended (or moved on) changes nothing.
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
    /// The transcript is made. With `cleanupFollows`, cleanup takes over in
    /// the same change, at the bar's boundary: no moment shows the
    /// transcription without progress, or no status at all.
    case transcriptionFinished(cleanupFollows: Bool, cleanupReportsProgress: Bool = true)
    /// Cleanup started on its own (a retried cleanup, a resumed one).
    case cleanupStarted(reportsProgress: Bool = true)
    /// Cleanup waits for the model, or stops waiting (nil).
    case cleanupWaiting(reason: String?)
    /// Cleanup's chunk report. `attempt` names the cleanup attempt (the
    /// iPhone splits again for a fallback or a rerun); nil when the app keeps
    /// one attempt (the Mac).
    case cleanupProgressed(NoteCleanupProgress, attempt: UUID? = nil)
    /// A first transcription is being stopped (the iPhone).
    case cancelling(reason: String?)
    /// Transcription paused (the iPhone).
    case paused(reason: String?)
    /// A paused transcription runs again, from where it stopped.
    case resumed
    case recoveringStarted
    /// The work ended: done, cancelled, failed, or the cleanup finished.
    case ended
}

extension NoteWork {
    /// Moves the work on.
    public mutating func apply(_ event: NoteWorkEvent) {
        switch event {
        case .queued(let kind, let reason):
            switch phase {
            case .idle, .waitingToTranscribe, .paused:
                start(.waitingToTranscribe(kind, reason: Self.reason(reason)))
            default:
                return
            }

        case .transcriptionStarted(let kind, let reportsProgress):
            start(.transcribing(kind, reportsProgress ? .starting : nil))

        case .transcriptionProgressed(let progress):
            switch phase {
            case .transcribing(let kind, let current):
                // The bar never moves back.
                if let current, progress.fraction < current.fraction { return }
                phase = .transcribing(kind, progress)
            case .resumingCloudTranscription(let current):
                if let current, progress.fraction < current.fraction { return }
                phase = .transcribing(.first, progress)
            default:
                return
            }

        case .cloudTranscriptionResuming(let progress):
            switch phase {
            case .idle:
                start(.resumingCloudTranscription(progress))
            case .transcribing(.first, let current), .resumingCloudTranscription(let current):
                if let current, let progress, progress.fraction < current.fraction { return }
                phase = .resumingCloudTranscription(progress ?? current)
            default:
                return
            }

        case .transcriptionFinished(let cleanupFollows, let cleanupReportsProgress):
            switch phase {
            case .transcribing, .resumingCloudTranscription:
                if cleanupFollows {
                    beginCleanup(reportsProgress: cleanupReportsProgress)
                } else {
                    end()
                }
            default:
                return
            }

        case .cleanupStarted(let reportsProgress):
            beginCleanup(reportsProgress: reportsProgress)

        case .cleanupWaiting(let reason):
            guard case .postProcessing(_, let progress) = phase else { return }
            phase = .postProcessing(waitReason: Self.reason(reason), progress: progress)

        case .cleanupProgressed(let report, let attempt):
            guard case .postProcessing(let waitReason, let current) = phase,
                  let next = keptCleanupProgress(current: current, report: report, attempt: attempt) else { return }
            phase = .postProcessing(waitReason: waitReason, progress: next)

        case .cancelling(let reason):
            switch phase {
            case .waitingToTranscribe, .transcribing, .resumingCloudTranscription, .paused, .cancellingTranscription:
                phase = .cancellingTranscription(reason: Self.reason(reason))
            default:
                return
            }

        case .paused(let reason):
            switch phase {
            case .transcribing(let kind, let progress), .paused(let kind, _, let progress):
                phase = .paused(kind, reason: Self.reason(reason), progress: progress)
            case .waitingToTranscribe(let kind, _):
                phase = .paused(kind, reason: Self.reason(reason), progress: nil)
            default:
                return
            }

        case .resumed:
            guard case .paused(let kind, _, let progress) = phase else { return }
            phase = .transcribing(kind, progress ?? .starting)

        case .recoveringStarted:
            start(.recovering)

        case .ended:
            end()
        }
    }

    /// New work replaces whatever the note showed.
    private mutating func start(_ next: Phase) {
        phase = next
        cleanupReportsProgress = true
        cleanupAttempt = nil
        endedCleanupAttempts = []
    }

    private mutating func end() {
        start(.idle)
    }

    /// Cleanup takes over. Already cleaning (an early "cleanup will follow"
    /// and then the request): keep its progress and wait reason.
    private mutating func beginCleanup(reportsProgress: Bool) {
        if case .postProcessing = phase {
            cleanupReportsProgress = reportsProgress
            return
        }
        start(.postProcessing(waitReason: nil, progress: nil))
        cleanupReportsProgress = reportsProgress
    }

    /// An empty reason is no reason.
    private static func reason(_ reason: String?) -> String? {
        reason.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The cleanup progress after `report`, or nil when the bar doesn't move.
    /// Within one attempt (or without attempts) the shared forward-only rule
    /// (`NoteCleanupProgress.kept`), so a split again inside the attempt keeps
    /// moving and a late report from an earlier split is dropped. A new
    /// attempt fills what is left from where the bar is. Reports from a
    /// replaced attempt are dropped.
    private mutating func keptCleanupProgress(
        current: NoteCleanupProgress?, report: NoteCleanupProgress, attempt: UUID?
    ) -> NoteCleanupProgress? {
        guard let attempt else { return NoteCleanupProgress.kept(after: current, report: report) }
        guard !endedCleanupAttempts.contains(attempt) else { return nil }
        var running: CleanupAttempt
        if let existing = cleanupAttempt, existing.id == attempt {
            guard let kept = NoteCleanupProgress.kept(after: existing.kept, report: report) else { return nil }
            running = existing
            running.kept = kept
        } else {
            guard let kept = NoteCleanupProgress.kept(after: nil, report: report) else { return nil }
            if let replaced = cleanupAttempt { endedCleanupAttempts.insert(replaced.id) }
            running = CleanupAttempt(id: attempt, start: current?.fraction ?? 0, kept: kept)
        }
        cleanupAttempt = running
        let shown = NoteCleanupProgress(
            completedChunkCount: running.kept.completedChunkCount,
            totalChunkCount: running.kept.totalChunkCount,
            base: running.start + (1 - running.start) * running.kept.base
        )
        if let current, shown.fraction < current.fraction { return nil }
        return shown == current ? nil : shown
    }
}

extension NoteWork {
    /// What the note shows for this work, from the shared table. Nil when no
    /// work runs.
    public var status: NoteWorkStatus? {
        switch phase {
        case .idle:
            return nil
        case .waitingToTranscribe(_, let reason):
            return .waitingToTranscribe(reason: reason)
        case .transcribing(let kind, let progress):
            let bar = NoteWorkProgress.combined(transcription: progress, cleanup: cleanup)
            switch kind {
            case .first: return .transcribing(bar)
            case .retranscription: return .retranscribing(bar)
            case .restart(let modelName): return .restartingTranscription(modelName: modelName, bar)
            }
        case .resumingCloudTranscription(let progress):
            return .resumingCloudTranscription(NoteWorkProgress.combined(transcription: progress, cleanup: cleanup))
        case .cancellingTranscription(let reason):
            return .cancellingTranscription(reason: reason)
        case .paused(let kind, let reason, _):
            return kind == .retranscription
                ? .retranscriptionPaused(reason: reason)
                : .transcriptionPaused(reason: reason)
        case .recovering:
            return .recovering
        case .postProcessing(let waitReason, let progress):
            if let waitReason { return .waitingToPostProcess(reason: waitReason) }
            return .postProcessing(NoteWorkProgress.combined(
                cleanupProgress: progress?.workProgress, stage: cleanup, reportsProgress: cleanupReportsProgress
            ))
        }
    }

    /// The toolbar's work for this note, read from the same phase as the
    /// status.
    public var toolbarWork: NoteToolbarWork {
        switch phase {
        case .idle, .paused, .recovering: return .none
        case .waitingToTranscribe: return .waitingToTranscribe
        case .transcribing(.first, _), .resumingCloudTranscription: return .transcribing
        case .transcribing: return .retranscribing
        case .cancellingTranscription: return .cancelling
        case .postProcessing(let waitReason, _): return waitReason == nil ? .postProcessing : .waitingToPostProcess
        }
    }
}

/// Every note's work, as one published value per note: the only source the
/// note screens, list rows, and toolbar read, on both apps.
@MainActor
public final class NoteWorkBoard: ObservableObject {
    @Published public private(set) var works: [String: NoteWork] = [:]
    /// The cleanup setting applies to every note's bar. A change is
    /// published once for all notes.
    public private(set) var cleanup: NoteCleanupStage = .off

    public init() {}

    public func work(for noteID: String) -> NoteWork {
        works[noteID] ?? NoteWork(cleanup: cleanup)
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

    public func setCleanup(_ stage: NoteCleanupStage) {
        guard stage != cleanup else { return }
        cleanup = stage
        guard !works.isEmpty else { return }
        works = works.mapValues { work in
            var work = work
            work.cleanup = stage
            return work
        }
    }

    /// The note is gone.
    public func forget(_ noteID: String) {
        works[noteID] = nil
    }
}
