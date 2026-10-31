import QuillNoteUI

/// A running cleanup's chunk progress, kept with the shared forward-only
/// rule (`NoteCleanupProgress.advanced(to:)`, #697).
typealias PostProcessingDisplayProgress = NoteCleanupProgress

/// The Mac's note work, as the shared work status (#697). The Note Browser
/// shows it alone in an empty note, in the capsule over the note's text,
/// and beside a tab's name. The Mac never sends the iPhone's waiting,
/// cancelling, or paused states.
enum NoteBrowserWorkStatus {
    /// A note's first transcription, shown alone while the note has no text:
    /// "Post-processing…" once the transcript is being cleaned up, chunk
    /// progress, or "Transcribing…". "Resuming cloud transcription…" only
    /// for a chunked cloud job that already has chunks done. Transcription
    /// and cleanup share one bar, split by `cleanup` (#697).
    static func firstTranscription(
        isPostProcessing: Bool,
        isCloudTranscribing: Bool,
        cloudProgress: CloudTranscriptionDisplayProgress?,
        cleanupProgress: PostProcessingDisplayProgress? = nil,
        cleanupReportsProgress: Bool = true,
        cleanup: NoteCleanupStage = .off
    ) -> NoteWorkStatus {
        let stage = cleanup
        if isPostProcessing {
            return postProcessing(cleanupProgress, reportsProgress: cleanupReportsProgress, stage: stage)
        }
        let progress = NoteWorkProgress.combined(transcription: workProgress(cloudProgress), cleanup: stage)
        // Local AI reports chunks too; only cloud jobs can be resuming.
        guard isCloudTranscribing else { return .transcribing(progress) }
        // Every chunk is in and the transcript is being saved: still
        // transcribing, not resuming.
        if let cloudProgress, cloudProgress.totalChunkCount > 0,
           cloudProgress.completedChunkCount >= cloudProgress.totalChunkCount {
            return .transcribing(progress)
        }
        // A job that hasn't finished a chunk yet is starting, not resuming.
        if let cloudProgress, cloudProgress.completedChunkCount == 0, progress != nil {
            return .transcribing(progress)
        }
        // No chunk progress at all: a file sent in one request (an imported
        // audio file, or audio under the upload ceiling) never reports any.
        // That is a new transcription, not a resume: a resume at launch
        // always starts from its saved chunk counts.
        guard let cloudProgress else { return .transcribing(nil) }
        // A planned job with chunks already done, before its next upload.
        guard cloudProgress.activeAttempt != nil else {
            return .resumingCloudTranscription(progress)
        }
        return .transcribing(progress)
    }

    /// Transcribing a note again from the Note Browser, over its text:
    /// "Recovering…" while a recording is recovered again, then
    /// "Retranscribing…" ("Transcribing…" for an audio-only note that was
    /// never transcribed), then "Post-processing…" once the new transcript
    /// is being cleaned up, on the same bar as first transcription.
    static func retry(
        isRecovering: Bool,
        isPostProcessing: Bool,
        isAudioOnly: Bool,
        cloudProgress: CloudTranscriptionDisplayProgress?,
        cleanupProgress: PostProcessingDisplayProgress? = nil,
        cleanupReportsProgress: Bool = true,
        cleanup: NoteCleanupStage = .off
    ) -> NoteWorkStatus {
        let stage = cleanup
        if isRecovering { return .recovering }
        if isPostProcessing {
            return postProcessing(cleanupProgress, reportsProgress: cleanupReportsProgress, stage: stage)
        }
        let progress = NoteWorkProgress.combined(transcription: workProgress(cloudProgress), cleanup: stage)
        return isAudioOnly ? .transcribing(progress) : .retranscribing(progress)
    }

    /// Cleanup continues the bar from the transcription's share, held at
    /// that boundary until its first chunk count arrives; Edit Mode reports
    /// none and keeps the spinner.
    private static func postProcessing(
        _ progress: PostProcessingDisplayProgress?,
        reportsProgress: Bool,
        stage: NoteCleanupStage
    ) -> NoteWorkStatus {
        let chunks = progress?.workProgress
        return .postProcessing(.combined(cleanupProgress: chunks, stage: stage, reportsProgress: reportsProgress))
    }

    static func summary(hasSummary: Bool) -> NoteWorkStatus {
        hasSummary ? .regeneratingSummary : .creatingSummary
    }

    /// Nil when the work won't report progress (one cloud request, or a
    /// local engine without chunks); 0% while a chunked job is still
    /// planning, so its bar is there from the start.
    private static func workProgress(_ progress: CloudTranscriptionDisplayProgress?) -> NoteWorkProgress? {
        guard let progress else { return nil }
        if progress == .preparing { return .starting }
        return NoteWorkProgress(completed: progress.completedChunkCount, total: progress.totalChunkCount)
    }
}
