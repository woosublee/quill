import QuillNoteUI

/// The Mac's note work, as the shared work status (#697). The Note Browser
/// shows it alone in an empty note, in the capsule over the note's text,
/// and beside a tab's name. The Mac never sends the iPhone's waiting,
/// cancelling, or paused states.
enum NoteBrowserWorkStatus {
    /// A note's first transcription, shown alone while the note has no text:
    /// "Post-processing…" once the transcript is being cleaned up, cloud
    /// chunk progress, or "Transcribing…".
    static func firstTranscription(
        isPostProcessing: Bool,
        isCloudTranscribing: Bool,
        cloudProgress: CloudTranscriptionDisplayProgress?
    ) -> NoteWorkStatus {
        if isPostProcessing { return .postProcessing }
        guard isCloudTranscribing else { return .transcribing(nil) }
        let progress = workProgress(cloudProgress)
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
        // Between attempts, or before the resumed job reports.
        guard cloudProgress?.activeAttempt != nil else {
            return .resumingCloudTranscription(progress)
        }
        return .transcribing(progress)
    }

    /// Transcribing a note again from the Note Browser, over its text:
    /// "Recovering…" while a recording is recovered again, then
    /// "Retranscribing…" ("Transcribing…" for an audio-only note that was
    /// never transcribed), then "Post-processing…" once the new transcript
    /// is being cleaned up. A cloud retry shows its chunk progress.
    static func retry(
        isRecovering: Bool,
        isPostProcessing: Bool,
        isAudioOnly: Bool,
        cloudProgress: CloudTranscriptionDisplayProgress?
    ) -> NoteWorkStatus {
        if isRecovering { return .recovering }
        if isPostProcessing { return .postProcessing }
        let progress = workProgress(cloudProgress)
        return isAudioOnly ? .transcribing(progress) : .retranscribing(progress)
    }

    static func summary(hasSummary: Bool) -> NoteWorkStatus {
        hasSummary ? .regeneratingSummary : .creatingSummary
    }

    private static func workProgress(_ progress: CloudTranscriptionDisplayProgress?) -> NoteWorkProgress? {
        progress.flatMap {
            NoteWorkProgress(completed: $0.completedChunkCount, total: $0.totalChunkCount)
        }
    }
}
