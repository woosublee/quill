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
        testLocalJobShowsOneContinuousBar()
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
        precondition(first(.cloud, post: true) == 80, "no chunk count yet: held at the boundary, not hidden")
        precondition(first(.onDevice, post: true) == 60, "an on-device model still loading: held at 60%")
        let editMode = NoteBrowserWorkStatus.firstTranscription(
            isPostProcessing: true, isCloudTranscribing: false, cloudProgress: nil,
            cleanupReportsProgress: false, cleanup: .cloud
        )
        precondition(editMode == .postProcessing(nil), "Edit Mode never reports: spinner only")
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

    /// Local AI transcription then on-device cleanup, as the owner saw it
    /// (#697): every step from the start to the end shows the bar, and it
    /// never moves back: no gap before the first transcription count, none
    /// between transcription and cleanup's first chunk count.
    private static func testLocalJobShowsOneContinuousBar() {
        func p(_ c: Int, _ t: Int) -> CloudTranscriptionDisplayProgress {
            CloudTranscriptionDisplayProgress(completedChunkCount: c, totalChunkCount: t, activeAttempt: nil)
        }
        func c(_ done: Int, _ total: Int) -> PostProcessingDisplayProgress {
            PostProcessingDisplayProgress(completedChunkCount: done, totalChunkCount: total)
        }
        let transcription: [CloudTranscriptionDisplayProgress?] = [.preparing, p(0, 3), p(1, 3), p(3, 3)]
        let cleanup: [PostProcessingDisplayProgress?] = [nil, c(0, 2), c(1, 2), c(2, 2)]
        for retry in [false, true] {
            var steps: [NoteWorkStatus] = []
            for progress in transcription {
                steps.append(retry
                    ? NoteBrowserWorkStatus.retry(
                        isRecovering: false, isPostProcessing: false, isAudioOnly: false,
                        cloudProgress: progress, cleanup: .onDevice
                    )
                    : NoteBrowserWorkStatus.firstTranscription(
                        isPostProcessing: false, isCloudTranscribing: false,
                        cloudProgress: progress, cleanup: .onDevice
                    ))
            }
            for progress in cleanup {
                steps.append(retry
                    ? NoteBrowserWorkStatus.retry(
                        isRecovering: false, isPostProcessing: true, isAudioOnly: false,
                        cloudProgress: p(3, 3), cleanupProgress: progress, cleanup: .onDevice
                    )
                    : NoteBrowserWorkStatus.firstTranscription(
                        isPostProcessing: true, isCloudTranscribing: false,
                        cloudProgress: p(3, 3), cleanupProgress: progress, cleanup: .onDevice
                    ))
            }
            let percents = steps.map { $0.progress?.percent }
            precondition(!percents.contains(nil), "the bar never disappears: \(percents)")
            let values = percents.compactMap { $0 }
            precondition(values == [0, 0, 20, 60, 60, 60, 80, 99], "one bar 0–60% then 60–100%: \(values)")
        }
    }

    /// The cleanup bar never moves back and never stalls: a fallback model
    /// splits the transcript again and continues from where the bar is, and
    /// a late report from an earlier split is dropped (the shared rule, as
    /// AppState keeps it).
    private static func testCleanupProgressOnlyMovesForward() {
        func p(_ c: Int, _ t: Int) -> PostProcessingDisplayProgress {
            PostProcessingDisplayProgress(completedChunkCount: c, totalChunkCount: t)
        }
        func percents(_ reports: [PostProcessingDisplayProgress]) -> [Int] {
            var kept: PostProcessingDisplayProgress?
            var shown: [Int] = []
            for report in reports {
                if let next = PostProcessingDisplayProgress.kept(after: kept, report: report) { kept = next }
                let status = NoteBrowserWorkStatus.firstTranscription(
                    isPostProcessing: true, isCloudTranscribing: false, cloudProgress: nil,
                    cleanupProgress: kept, cleanup: .onDevice
                )
                shown.append(status.progress!.percent)
            }
            return shown
        }
        // 3 of 4 done, the primary model fails, the fallback splits into 4
        // again: the bar continues from 75% of cleanup instead of stalling
        // until the new split passes 3 of 4.
        let fallback = percents([p(0, 4), p(1, 4), p(3, 4), p(0, 4), p(1, 4), p(2, 4)])
        precondition(fallback == [60, 70, 90, 90, 92, 95], "\(fallback)")
        // A late report from the first split (a different count) is dropped.
        let late = percents([p(0, 2), p(1, 2), p(0, 3), p(2, 2), p(1, 3)])
        precondition(late == [60, 80, 80, 80, 86], "\(late)")
        // Out of order in one split: never back.
        precondition(percents([p(0, 3), p(2, 3), p(1, 3)]) == [60, 86, 86])
        for list in [fallback, late] {
            precondition(zip(list, list.dropFirst()).allSatisfy { $0 <= $1 }, "never back")
        }
    }

    private static func testSummary() {
        precondition(NoteBrowserWorkStatus.summary(hasSummary: false) == .creatingSummary)
        precondition(NoteBrowserWorkStatus.summary(hasSummary: true) == .regeneratingSummary)
    }
}
