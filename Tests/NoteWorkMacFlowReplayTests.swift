import Foundation
import QuillNoteUI

/// Preparation for #768 step 3 (the Mac onto `NoteWorkBoard`). Each Mac
/// flow is replayed twice, step by step:
/// - the published values `AppState` holds at that moment today, read
///   through `NoteBrowserWorkStatus` (what the Note Browser shows now), and
/// - the `NoteWorkEvent` the planned event map (#768) sends at that moment,
///   read through the shared `NoteWork.status`.
/// Both columns are written by hand from today's `AppState` and
/// `TranscriptionRetryWorkflow`; this checks the shared rules and the
/// planned map, not the wiring. Step 3 must send exactly these events.
/// Rules the map needs, found here:
/// - A retry never sends `.cloudTranscriptionResuming`, even when a saved
///   cloud job resumes: the Note Browser reads a retry as
///   "Retranscribing…" whatever its chunk state.
/// - A first transcription sends `.cloudTranscriptionResuming` for planned
///   progress with chunks done and no active attempt, at launch or in the
///   same session (a compatible checkpoint), and `.transcriptionProgressed`
///   otherwise.
/// - Work that will report progress starts with `reportsProgress: true`
///   (the Mac publishes `.preparing`, a 0% bar).
/// - With cleanup off, transcription ends with `.transcriptionEnded`.
@main
struct NoteWorkMacFlowReplayTests {
    /// One moment of a flow: what `AppState` publishes, and the event that
    /// moment sends.
    private struct Step {
        let label: String
        let event: NoteWorkEvent
        /// Sent in the same change as `event`, before the Note Browser reads
        /// again (one publish on the board).
        var andThen: [NoteWorkEvent] = []
        var isRecovering = false
        var isPostProcessing = false
        var isCloudTranscribing = false
        var cloudProgress: CloudTranscriptionDisplayProgress?
        var cleanupProgress: NoteCleanupProgress?
        var cleanupReportsProgress = true
        /// The work stopped: the Note Browser shows no status.
        var showsNothing = false
        /// The step only happens with cleanup on.
        var needsCleanup = false
    }

    private enum Flow {
        /// Shown alone while the note has no text yet.
        case firstTranscription
        /// Shown over the note's text (`retry`).
        case retry(isAudioOnly: Bool)
    }

    static func main() {
        for stage in [NoteCleanupStage.off, .cloud, .onDevice] {
            replayFirstLocalTranscription(stage)
            replayFirstCloudOneRequest(stage)
            replayFirstCloudChunked(stage)
            replayCloudResumeAtLaunch(stage)
            replayRetranscription(stage)
            replayAudioOnlyTranscribeFromBrowser(stage)
            replayRecoveringThenRetranscribing(stage)
            replayEditModeCleanup(stage)
            replayCleanupRetryAlone(stage)
            replayFirstLocalAIWithProgress(stage)
            replayFirstCloudCheckpointInSession(stage)
            replayCloudRetranscriptionResumedAtLaunch(stage)
            replayChunkedRetranscriptionFromStart(stage)
            replayRecoverThenChunkedRetranscription(stage)
            replayFailureAndCancel(stage)
        }
        print("NoteWorkMacFlowReplayTests passed")
    }

    // MARK: Flows

    private static func replayFirstLocalTranscription(_ stage: NoteCleanupStage) {
        replay("first local", .firstTranscription, stage: stage, [
            Step(label: "started", event: .transcriptionStarted(.first, reportsProgress: false)),
            Step(
                label: "cleanup takes over",
                event: .transcriptionFinished(cleanupFollows: true),
                isPostProcessing: true,
                needsCleanup: true
            ),
            Step(
                label: "cleanup 1 of 3",
                event: .cleanupProgressed(NoteCleanupProgress(completedChunkCount: 1, totalChunkCount: 3)),
                isPostProcessing: true,
                cleanupProgress: NoteCleanupProgress(completedChunkCount: 1, totalChunkCount: 3),
                needsCleanup: true
            ),
            Step(
                label: "cleanup 2 of 3",
                event: .cleanupProgressed(NoteCleanupProgress(completedChunkCount: 2, totalChunkCount: 3)),
                isPostProcessing: true,
                cleanupProgress: NoteCleanupProgress(completedChunkCount: 2, totalChunkCount: 3),
                needsCleanup: true
            ),
        ])
    }

    private static func replayFirstCloudOneRequest(_ stage: NoteCleanupStage) {
        // An imported file, or audio under the upload ceiling: one request,
        // no chunk progress, never "resuming".
        replay("first cloud, one request", .firstTranscription, stage: stage, [
            Step(
                label: "started",
                event: .transcriptionStarted(.first, reportsProgress: false),
                isCloudTranscribing: true
            ),
        ])
    }

    private static func replayFirstCloudChunked(_ stage: NoteCleanupStage) {
        let plan = progress(0, of: 4)
        let first = progress(0, of: 4, attempt: 1)
        let second = progress(1, of: 4, attempt: 1)
        let allIn = progress(4, of: 4)
        replay("first cloud, chunked", .firstTranscription, stage: stage, [
            Step(
                label: "preparing",
                event: .transcriptionStarted(.first),
                isCloudTranscribing: true,
                cloudProgress: .preparing
            ),
            Step(
                label: "planned 0 of 4",
                event: .transcriptionProgressed(workProgress(plan)!),
                isCloudTranscribing: true,
                cloudProgress: plan
            ),
            Step(
                label: "uploading chunk 1",
                event: .transcriptionProgressed(workProgress(first)!),
                isCloudTranscribing: true,
                cloudProgress: first
            ),
            Step(
                label: "uploading chunk 2",
                event: .transcriptionProgressed(workProgress(second)!),
                isCloudTranscribing: true,
                cloudProgress: second
            ),
            Step(
                label: "every chunk in, saving",
                event: .transcriptionProgressed(workProgress(allIn)!),
                isCloudTranscribing: true,
                cloudProgress: allIn
            ),
            Step(
                label: "cleanup takes over",
                event: .transcriptionFinished(cleanupFollows: true),
                isPostProcessing: true,
                needsCleanup: true
            ),
        ])
    }

    private static func replayCloudResumeAtLaunch(_ stage: NoteCleanupStage) {
        let saved = progress(2, of: 4)
        let uploading = progress(2, of: 4, attempt: 1)
        let next = progress(3, of: 4, attempt: 1)
        replay("cloud resume at launch", .firstTranscription, stage: stage, [
            Step(
                label: "resuming with 2 of 4 done",
                event: .cloudTranscriptionResuming(workProgress(saved)),
                isCloudTranscribing: true,
                cloudProgress: saved
            ),
            Step(
                label: "uploading chunk 3",
                event: .transcriptionProgressed(workProgress(uploading)!),
                isCloudTranscribing: true,
                cloudProgress: uploading
            ),
            Step(
                label: "uploading chunk 4",
                event: .transcriptionProgressed(workProgress(next)!),
                isCloudTranscribing: true,
                cloudProgress: next
            ),
        ])
    }

    private static func replayRetranscription(_ stage: NoteCleanupStage) {
        let chunk = progress(1, of: 2, attempt: 1)
        replay("retranscription", .retry(isAudioOnly: false), stage: stage, [
            // Since #800 a job that reports progress publishes .preparing
            // from the start.
            Step(
                label: "started",
                event: .transcriptionStarted(.retranscription),
                cloudProgress: .preparing
            ),
            Step(
                label: "chunk progress",
                event: .transcriptionProgressed(workProgress(chunk)!),
                cloudProgress: chunk
            ),
            Step(
                label: "cleanup takes over",
                event: .transcriptionFinished(cleanupFollows: true),
                isPostProcessing: true,
                needsCleanup: true
            ),
            Step(
                label: "cleanup 1 of 2",
                event: .cleanupProgressed(NoteCleanupProgress(completedChunkCount: 1, totalChunkCount: 2)),
                isPostProcessing: true,
                cleanupProgress: NoteCleanupProgress(completedChunkCount: 1, totalChunkCount: 2),
                needsCleanup: true
            ),
        ])
    }

    private static func replayAudioOnlyTranscribeFromBrowser(_ stage: NoteCleanupStage) {
        // An audio-only note transcribed from the Note Browser reads
        // "Transcribing...", not "Retranscribing...".
        replay("audio-only transcribe", .retry(isAudioOnly: true), stage: stage, [
            Step(label: "started", event: .transcriptionStarted(.first, reportsProgress: false)),
            Step(
                label: "cleanup takes over",
                event: .transcriptionFinished(cleanupFollows: true),
                isPostProcessing: true,
                needsCleanup: true
            ),
        ])
    }

    private static func replayRecoveringThenRetranscribing(_ stage: NoteCleanupStage) {
        replay("recover again", .retry(isAudioOnly: false), stage: stage, [
            Step(label: "recovering", event: .recoveringStarted, isRecovering: true),
            Step(label: "retranscribing", event: .transcriptionStarted(.retranscription, reportsProgress: false)),
        ])
    }

    private static func replayEditModeCleanup(_ stage: NoteCleanupStage) {
        // Edit Mode's transform reports no chunks: the spinner, no bar.
        replay("edit mode", .retry(isAudioOnly: false), stage: stage, [
            Step(
                label: "transform runs",
                event: .cleanupStarted(reportsProgress: false),
                isPostProcessing: true,
                cleanupReportsProgress: false
            ),
        ])
    }

    private static func replayCleanupRetryAlone(_ stage: NoteCleanupStage) {
        // Retry Post-processing alone: cleanup with no transcription before
        // it.
        replay("retry post-processing", .retry(isAudioOnly: false), stage: stage, [
            Step(label: "started", event: .cleanupStarted(), isPostProcessing: true),
            Step(
                label: "1 of 4",
                event: .cleanupProgressed(NoteCleanupProgress(completedChunkCount: 1, totalChunkCount: 4)),
                isPostProcessing: true,
                cleanupProgress: NoteCleanupProgress(completedChunkCount: 1, totalChunkCount: 4)
            ),
        ])
    }

    private static func replayFirstLocalAIWithProgress(_ stage: NoteCleanupStage) {
        // Local AI reports chunks too, without being cloud transcription.
        let plan = progress(0, of: 3)
        let one = progress(1, of: 3, attempt: 1)
        let between = progress(2, of: 3)
        replay("first local AI", .firstTranscription, stage: stage, [
            Step(label: "preparing", event: .transcriptionStarted(.first), cloudProgress: .preparing),
            Step(label: "planned", event: .transcriptionProgressed(workProgress(plan)!), cloudProgress: plan),
            Step(label: "chunk 1", event: .transcriptionProgressed(workProgress(one)!), cloudProgress: one),
            // Between chunks with chunks done: never "resuming" off the cloud.
            Step(label: "between chunks", event: .transcriptionProgressed(workProgress(between)!), cloudProgress: between),
            Step(label: "ended, cleanup off", event: .transcriptionEnded, showsNothing: true),
        ])
    }

    private static func replayFirstCloudCheckpointInSession(_ stage: NoteCleanupStage) {
        // A first transcription started again in the same session finds a
        // compatible checkpoint: planned with chunks done, no attempt yet.
        let checkpoint = progress(2, of: 4)
        let uploading = progress(2, of: 4, attempt: 1)
        replay("first cloud, checkpoint in session", .firstTranscription, stage: stage, [
            Step(
                label: "preparing",
                event: .transcriptionStarted(.first),
                isCloudTranscribing: true,
                cloudProgress: .preparing
            ),
            Step(
                label: "planned from checkpoint",
                event: .cloudTranscriptionResuming(workProgress(checkpoint)),
                isCloudTranscribing: true,
                cloudProgress: checkpoint
            ),
            Step(
                label: "uploading",
                event: .transcriptionProgressed(workProgress(uploading)!),
                isCloudTranscribing: true,
                cloudProgress: uploading
            ),
        ])
    }

    private static func replayCloudRetranscriptionResumedAtLaunch(_ stage: NoteCleanupStage) {
        // A saved cloud retranscription of a note with text resumes at
        // launch with 2 of 4 done. The Note Browser reads it through
        // `retry`: "Retranscribing…", not "Resuming…".
        let saved = progress(2, of: 4)
        let uploading = progress(2, of: 4, attempt: 1)
        replay("cloud retranscription resumed", .retry(isAudioOnly: false), stage: stage, [
            // The start and the saved counts go in one change: sent apart,
            // the board would show 0% for a moment.
            Step(
                label: "resumed with 2 of 4",
                event: .transcriptionStarted(.retranscription),
                andThen: [.transcriptionProgressed(workProgress(saved)!)],
                cloudProgress: saved
            ),
            Step(
                label: "uploading",
                event: .transcriptionProgressed(workProgress(uploading)!),
                cloudProgress: uploading
            ),
        ])
    }

    private static func replayChunkedRetranscriptionFromStart(_ stage: NoteCleanupStage) {
        let plan = progress(0, of: 2)
        let one = progress(1, of: 2, attempt: 1)
        replay("chunked retranscription", .retry(isAudioOnly: false), stage: stage, [
            Step(label: "preparing", event: .transcriptionStarted(.retranscription), cloudProgress: .preparing),
            Step(label: "planned", event: .transcriptionProgressed(workProgress(plan)!), cloudProgress: plan),
            Step(label: "chunk 1", event: .transcriptionProgressed(workProgress(one)!), cloudProgress: one),
            Step(
                label: "cleanup takes over",
                event: .transcriptionFinished(cleanupFollows: true),
                isPostProcessing: true,
                needsCleanup: true
            ),
            Step(label: "cleanup ended", event: .cleanupEnded, showsNothing: true, needsCleanup: true),
        ])
    }

    private static func replayRecoverThenChunkedRetranscription(_ stage: NoteCleanupStage) {
        replay("recover, then chunked retranscription", .retry(isAudioOnly: false), stage: stage, [
            Step(label: "recovering", event: .recoveringStarted, isRecovering: true),
            Step(label: "preparing", event: .transcriptionStarted(.retranscription), cloudProgress: .preparing),
        ])
    }

    private static func replayFailureAndCancel(_ stage: NoteCleanupStage) {
        replay("retry fails", .retry(isAudioOnly: false), stage: stage, [
            Step(label: "preparing", event: .transcriptionStarted(.retranscription), cloudProgress: .preparing),
            Step(label: "failed", event: .transcriptionEnded, showsNothing: true),
        ])
        replay("cleanup cancelled", .firstTranscription, stage: stage, [
            Step(label: "started", event: .transcriptionStarted(.first, reportsProgress: false)),
            Step(
                label: "cleanup takes over",
                event: .transcriptionFinished(cleanupFollows: true),
                isPostProcessing: true,
                needsCleanup: true
            ),
            // #699: stopping cleanup keeps the raw transcript; the work ends.
            Step(label: "cleanup stopped", event: .cleanupEnded, showsNothing: true, needsCleanup: true),
        ])
    }

    // MARK: Replay

    private static func replay(_ name: String, _ flow: Flow, stage: NoteCleanupStage, _ steps: [Step]) {
        var work = NoteWork(stage: stage)
        for step in steps {
            // With cleanup off there is no cleanup: the transcription ends
            // instead of handing over.
            if step.needsCleanup, stage == .off {
                if case .transcriptionFinished = step.event {
                    work.apply(.transcriptionEnded)
                    precondition(work.status == nil, "\(name) / \(step.label) / off: the work ends")
                }
                continue
            }
            work.apply(step.event)
            for event in step.andThen { work.apply(event) }
            if step.showsNothing {
                precondition(work.status == nil, "\(name) / \(step.label) / \(stage): board still shows \(String(describing: work.status))")
                continue
            }
            let today: NoteWorkStatus
            switch flow {
            case .firstTranscription:
                today = NoteBrowserWorkStatus.firstTranscription(
                    isPostProcessing: step.isPostProcessing,
                    isCloudTranscribing: step.isCloudTranscribing,
                    cloudProgress: step.cloudProgress,
                    cleanupProgress: step.cleanupProgress,
                    cleanupReportsProgress: step.cleanupReportsProgress,
                    cleanup: stage
                )
            case .retry(let isAudioOnly):
                today = NoteBrowserWorkStatus.retry(
                    isRecovering: step.isRecovering,
                    isPostProcessing: step.isPostProcessing,
                    isAudioOnly: isAudioOnly,
                    cloudProgress: step.cloudProgress,
                    cleanupProgress: step.cleanupProgress,
                    cleanupReportsProgress: step.cleanupReportsProgress,
                    cleanup: stage
                )
            }
            precondition(
                work.status == today,
                "\(name) / \(step.label) / \(stage): board \(String(describing: work.status)), Note Browser \(today)"
            )
        }
    }

    private static func progress(_ done: Int, of total: Int, attempt: Int? = nil) -> CloudTranscriptionDisplayProgress {
        CloudTranscriptionDisplayProgress(completedChunkCount: done, totalChunkCount: total, activeAttempt: attempt)
    }

    /// The progress the event map sends for a published chunk count. It is
    /// the Note Browser's reading (`NoteBrowserWorkStatus.workProgress`, which
    /// is private), written here as the event map's own rule.
    private static func workProgress(_ progress: CloudTranscriptionDisplayProgress) -> NoteWorkProgress? {
        if progress == .preparing { return .starting }
        return NoteWorkProgress(completed: progress.completedChunkCount, total: progress.totalChunkCount)
    }
}
