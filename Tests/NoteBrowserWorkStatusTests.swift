import Foundation
import QuillNoteUI

/// The Note Browser's work, as the shared work status (#697): the same
/// stages it showed before, now with cloud chunk progress as a percentage.
@main
struct NoteBrowserWorkStatusTests {
    static func main() {
        testFirstTranscription()
        testRetry()
        testOneBar()
        testCleanupProgressOnlyMovesForward()
        testSummary()
        print("NoteBrowserWorkStatusTests passed")
    }

    private static let running = CloudTranscriptionDisplayProgress(
        completedChunkCount: 1, totalChunkCount: 4, activeAttempt: 1
    )
    private static let betweenAttempts = CloudTranscriptionDisplayProgress(
        completedChunkCount: 1, totalChunkCount: 4, activeAttempt: nil
    )
    private static let quarter = NoteWorkProgress(completed: 1, total: 4)

    private static func testFirstTranscription() {
        func status(
            postProcessing: Bool = false,
            cloud: Bool = false,
            progress: CloudTranscriptionDisplayProgress? = nil
        ) -> NoteWorkStatus {
            NoteBrowserWorkStatus.firstTranscription(
                isPostProcessing: postProcessing,
                isCloudTranscribing: cloud,
                cloudProgress: progress
            )
        }
        precondition(status() == .transcribing(nil), "local: no progress")
        // Local AI reports chunk progress too; it is never "resuming".
        precondition(status(progress: running) == .transcribing(quarter))
        precondition(status(progress: betweenAttempts) == .transcribing(quarter))
        precondition(status(cloud: true, progress: running) == .transcribing(quarter))
        precondition(status(cloud: true, progress: betweenAttempts) == .resumingCloudTranscription(quarter))
        // A file sent in one request (an imported m4a, or audio under the
        // upload ceiling) reports no chunk progress: it is transcribing, not
        // resuming. A launch resume always seeds its saved chunk counts.
        precondition(status(cloud: true) == .transcribing(nil), "one-request upload")
        precondition(
            status(cloud: true).presentation { $0 }.title == "Transcribing...",
            "a one-request upload never reads as resuming"
        )
        // A new job is planned with no chunk done yet: starting, not resuming.
        let planned = CloudTranscriptionDisplayProgress(completedChunkCount: 0, totalChunkCount: 4, activeAttempt: nil)
        precondition(status(cloud: true, progress: planned) == .transcribing(NoteWorkProgress(completed: 0, total: 4)))
        // A job with no chunks yet has nothing to measure.
        let empty = CloudTranscriptionDisplayProgress(completedChunkCount: 0, totalChunkCount: 0, activeAttempt: 1)
        precondition(status(cloud: true, progress: empty) == .transcribing(nil))
        precondition(status(postProcessing: true, cloud: true, progress: running) == .postProcessing(nil), "cleanup off: no cleanup bar")
        // Every chunk uploaded, transcript not saved yet: not "Resuming".
        let allIn = CloudTranscriptionDisplayProgress(completedChunkCount: 4, totalChunkCount: 4, activeAttempt: nil)
        precondition(status(cloud: true, progress: allIn) == .transcribing(NoteWorkProgress(completed: 4, total: 4)))
        // A chunked job still planning shows its bar at 0% from the start (#697).
        precondition(status(cloud: true, progress: .preparing) == .transcribing(.starting))
        precondition(status(cloud: true, progress: .preparing).presentation { $0 }.percentText == "0%")

        let title = status(cloud: true, progress: running).presentation { $0 }.title
        precondition(title == "Transcribing...", title)
    }

    private static func testRetry() {
        func status(
            recovering: Bool = false,
            postProcessing: Bool = false,
            audioOnly: Bool = false,
            progress: CloudTranscriptionDisplayProgress? = nil
        ) -> NoteWorkStatus {
            NoteBrowserWorkStatus.retry(
                isRecovering: recovering,
                isPostProcessing: postProcessing,
                isAudioOnly: audioOnly,
                cloudProgress: progress
            )
        }
        precondition(status() == .retranscribing(nil))
        precondition(status(progress: running) == .retranscribing(quarter))
        // Progress is coming: the bar is there before the first count (#697).
        precondition(status(progress: .preparing) == .retranscribing(.starting))
        precondition(status(audioOnly: true, progress: .preparing) == .transcribing(.starting))
        // No progress coming (one cloud request, a local engine): no bar.
        precondition(status().presentation { $0 }.percentText == nil)
        precondition(status(audioOnly: true) == .transcribing(nil), "an audio-only note was never transcribed")
        precondition(status(postProcessing: true, progress: running) == .postProcessing(nil))
        precondition(status(recovering: true, postProcessing: true) == .recovering)
    }

    /// One bar through transcription and cleanup (#697 owner decision).
    private static func testOneBar() {
        let half = CloudTranscriptionDisplayProgress(completedChunkCount: 2, totalChunkCount: 4, activeAttempt: 1)
        func first(_ cleanup: NoteCleanupStage, post: Bool = false, chunks: PostProcessingDisplayProgress? = nil) -> Int? {
            NoteBrowserWorkStatus.firstTranscription(
                isPostProcessing: post, isCloudTranscribing: true, cloudProgress: post ? nil : half,
                cleanupProgress: chunks, cleanup: cleanup
            ).progress?.percent
        }
        precondition(first(.off) == 50 && first(.cloud) == 40 && first(.onDevice) == 30)
        precondition(first(.cloud, post: true) == nil, "no chunk count yet (Edit Mode): spinner only")
        let zero = PostProcessingDisplayProgress(completedChunkCount: 0, totalChunkCount: 3)
        precondition(first(.cloud, post: true, chunks: zero) == 80, "cleanup starts at the boundary")
        precondition(first(.onDevice, post: true, chunks: zero) == 60)
        let oneOfFour = PostProcessingDisplayProgress(completedChunkCount: 1, totalChunkCount: 4)
        precondition(first(.cloud, post: true, chunks: oneOfFour) == 85)
        let single = PostProcessingDisplayProgress(completedChunkCount: 0, totalChunkCount: 1)
        precondition(first(.onDevice, post: true, chunks: single) == 60, "one chunk holds at the boundary")
        let done = PostProcessingDisplayProgress(completedChunkCount: 1, totalChunkCount: 1)
        precondition(first(.cloud, post: true, chunks: done) == 99, "never 100% while running")
        let title = NoteBrowserWorkStatus.firstTranscription(
            isPostProcessing: true, isCloudTranscribing: true, cloudProgress: nil, cleanup: .cloud
        ).presentation { $0 }.title
        precondition(title == "Post-processing...", title)

        let retry = NoteBrowserWorkStatus.retry(
            isRecovering: false, isPostProcessing: false, isAudioOnly: false,
            cloudProgress: .preparing, cleanup: .cloud
        )
        precondition(retry == .retranscribing(.starting), "0% from the start, on the shared bar")
        let retryCleanup = NoteBrowserWorkStatus.retry(
            isRecovering: false, isPostProcessing: true, isAudioOnly: false,
            cloudProgress: nil, cleanupProgress: oneOfFour, cleanup: .onDevice
        )
        precondition(retryCleanup.progress?.percent == 70)
    }

    /// The cleanup bar never moves back: a fallback starts at 0 of N again,
    /// and out-of-order reports are dropped.
    private static func testCleanupProgressOnlyMovesForward() {
        func p(_ c: Int, _ t: Int) -> PostProcessingDisplayProgress {
            PostProcessingDisplayProgress(completedChunkCount: c, totalChunkCount: t)
        }
        precondition(p(1, 4).isAhead(of: p(0, 4)))
        precondition(!p(0, 3).isAhead(of: p(3, 4)), "a fallback's 0 of N doesn't pull the bar back")
        precondition(!p(2, 3).isAhead(of: p(3, 3)), "a late report doesn't")
        precondition(p(2, 3).isAhead(of: p(1, 2)))
        precondition(!p(1, 2).isAhead(of: p(2, 4)), "the same share isn't ahead")
    }

    private static func testSummary() {
        precondition(NoteBrowserWorkStatus.summary(hasSummary: false) == .creatingSummary)
        precondition(NoteBrowserWorkStatus.summary(hasSummary: true) == .regeneratingSummary)
    }
}
