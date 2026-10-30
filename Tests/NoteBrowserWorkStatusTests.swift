import Foundation
import QuillNoteUI

/// The Note Browser's work, as the shared work status (#697): the same
/// stages it showed before, now with cloud chunk progress as a percentage.
@main
struct NoteBrowserWorkStatusTests {
    static func main() {
        testFirstTranscription()
        testRetry()
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
        // Progress reported for a note that isn't cloud-transcribing is ignored.
        precondition(status(progress: running) == .transcribing(nil))
        precondition(status(cloud: true, progress: running) == .transcribing(quarter))
        precondition(status(cloud: true, progress: betweenAttempts) == .resumingCloudTranscription(quarter))
        precondition(status(cloud: true) == .resumingCloudTranscription(nil), "before the resumed job reports")
        // A new job is planned with no chunk done yet: starting, not resuming.
        let planned = CloudTranscriptionDisplayProgress(completedChunkCount: 0, totalChunkCount: 4, activeAttempt: nil)
        precondition(status(cloud: true, progress: planned) == .transcribing(NoteWorkProgress(completed: 0, total: 4)))
        // A job with no chunks yet has nothing to measure.
        let empty = CloudTranscriptionDisplayProgress(completedChunkCount: 0, totalChunkCount: 0, activeAttempt: 1)
        precondition(status(cloud: true, progress: empty) == .transcribing(nil))
        precondition(status(postProcessing: true, cloud: true, progress: running) == .postProcessing)
        // Every chunk uploaded, transcript not saved yet: not "Resuming".
        let allIn = CloudTranscriptionDisplayProgress(completedChunkCount: 4, totalChunkCount: 4, activeAttempt: nil)
        precondition(status(cloud: true, progress: allIn) == .transcribing(NoteWorkProgress(completed: 4, total: 4)))

        let title = status(cloud: true, progress: running).presentation { $0 }.title
        precondition(title == "Transcribing 2 of 4…", title)
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
        precondition(status(audioOnly: true) == .transcribing(nil), "an audio-only note was never transcribed")
        precondition(status(postProcessing: true, progress: running) == .postProcessing)
        precondition(status(recovering: true, postProcessing: true) == .recovering)
    }

    private static func testSummary() {
        precondition(NoteBrowserWorkStatus.summary(hasSummary: false) == .creatingSummary)
        precondition(NoteBrowserWorkStatus.summary(hasSummary: true) == .regeneratingSummary)
    }
}
