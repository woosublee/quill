import Combine
import Foundation
import QuillNoteUI

/// The shared note work state (#768): both apps' flows replayed as events,
/// checking every status a note shows on the way.
@main
struct NoteWorkTests {
    static func main() {
        testRetranscriptionHandsOverToCleanupWithoutAGap()
        testCloudRetranscriptionOnTheMac()
        testFirstTranscriptionWithoutCleanup()
        testLateReportsChangeNothing()
        testWaitingForTheCleanupModel()
        testANewCleanupAttemptContinuesTheBar()
        testCleanupWithoutChunkProgress()
        testPausedCancellingAndRestart()
        testCloudResumeAndRecovery()
        testToolbarWork()
        testLateEventsDontReviveEndedWork()
        testResumeContinuesFromWhereItPaused()
        testSplitAgainInsideOneAttemptKeepsMoving()
        testEmptyReasonsAreNoReason()
        MainActor.assumeIsolated { testBoardPublishesOneValuePerNote() }
        print("NoteWorkTests passed")
    }

    private static func p(_ completed: Int, _ total: Int) -> NoteWorkProgress {
        NoteWorkProgress(completed: completed, total: total)!
    }

    private static func present(_ work: NoteWork) -> NoteWorkStatus.Presentation? {
        work.status?.presentation { $0 }
    }

    private static func percent(_ work: NoteWork) -> Int? {
        work.status?.progress?.percent
    }

    /// Replays `events` and returns the status after each one.
    private static func replay(_ work: inout NoteWork, _ events: [NoteWorkEvent]) -> [NoteWorkStatus?] {
        events.map { event in
            work.apply(event)
            return work.status
        }
    }

    /// 2026-11-01 device log: the iPhone capsule went 60% → 0% → 60% when
    /// cleanup took over from a retranscription, because the screen read the
    /// two from different objects. With one value the hand-over is one change.
    private static func testRetranscriptionHandsOverToCleanupWithoutAGap() {
        var work = NoteWork(cleanup: .onDevice)
        let statuses = replay(&work, [
            .transcriptionStarted(.retranscription),
            .transcriptionProgressed(p(0, 1)),
            .transcriptionProgressed(p(1, 1)),
            .transcriptionFinished(cleanupFollows: true),
            .cleanupProgressed(NoteCleanupProgress(completedChunkCount: 0, totalChunkCount: 3), attempt: Self.attemptA),
            .cleanupProgressed(NoteCleanupProgress(completedChunkCount: 1, totalChunkCount: 3), attempt: Self.attemptA),
            .cleanupProgressed(NoteCleanupProgress(completedChunkCount: 3, totalChunkCount: 3), attempt: Self.attemptA),
        ])
        precondition(statuses.allSatisfy { $0 != nil }, "a status on every step: \(statuses)")
        let percents = statuses.compactMap { $0?.progress?.percent }
        precondition(percents == [0, 0, 60, 60, 60, 73, 99], "\(percents)")
        precondition(percents == percents.sorted(), "the bar never moves back: \(percents)")
        precondition(statuses[2]?.kind == .retranscribing)
        precondition(statuses[3]?.kind == .postProcessing, "cleanup takes over in the same change")
        precondition(work.toolbarWork == .postProcessing)
        work.apply(.ended)
        precondition(work.status == nil && !work.isActive)
    }

    /// The Mac's cloud retranscription: chunk counts only, cloud cleanup.
    private static func testCloudRetranscriptionOnTheMac() {
        var work = NoteWork(cleanup: .cloud)
        work.apply(.transcriptionStarted(.retranscription))
        work.apply(.transcriptionProgressed(p(2, 4)))
        precondition(present(work)?.title == "Retranscribing...")
        precondition(percent(work) == 40)
        work.apply(.transcriptionFinished(cleanupFollows: true))
        precondition(present(work)?.title == "Post-processing...")
        precondition(percent(work) == 80, "cleanup starts at the transcription's share")
    }

    private static func testFirstTranscriptionWithoutCleanup() {
        var work = NoteWork()
        work.apply(.transcriptionStarted(.first))
        precondition(present(work)?.title == "Transcribing...")
        precondition(percent(work) == 0, "the bar shows at 0% from the start")
        work.apply(.transcriptionProgressed(p(1, 2)))
        precondition(percent(work) == 50, "cleanup off: transcription fills the whole bar")
        work.apply(.transcriptionFinished(cleanupFollows: false))
        precondition(work.status == nil)
        // One cloud request reports no progress: no bar instead of 0%.
        var single = NoteWork()
        single.apply(.transcriptionStarted(.first, reportsProgress: false))
        precondition(single.status == .transcribing(nil))
    }

    private static func testLateReportsChangeNothing() {
        var work = NoteWork(cleanup: .onDevice)
        work.apply(.transcriptionStarted(.retranscription))
        work.apply(.transcriptionProgressed(p(2, 4)))
        // An older report arriving late doesn't move the bar back.
        work.apply(.transcriptionProgressed(p(1, 4)))
        precondition(percent(work) == 30)
        work.apply(.transcriptionFinished(cleanupFollows: true))
        let handedOver = work
        // Transcription progress after the hand-over is dropped.
        work.apply(.transcriptionProgressed(p(4, 4)))
        precondition(work == handedOver)
        // An early "cleanup will follow" and then the request keep the bar.
        work.apply(.cleanupProgressed(NoteCleanupProgress(completedChunkCount: 1, totalChunkCount: 2)))
        let cleaning = work
        work.apply(.cleanupStarted())
        precondition(work == cleaning)
        // Cleanup progress with no cleanup running is dropped.
        work.apply(.ended)
        work.apply(.cleanupProgressed(NoteCleanupProgress(completedChunkCount: 1, totalChunkCount: 2)))
        precondition(work.status == nil)
    }

    /// The iPhone waits for the on-device model: the reason replaces the bar,
    /// and the bar comes back where it was.
    private static func testWaitingForTheCleanupModel() {
        var work = NoteWork(cleanup: .onDevice)
        work.apply(.transcriptionStarted(.first))
        work.apply(.transcriptionFinished(cleanupFollows: true))
        work.apply(.cleanupProgressed(NoteCleanupProgress(completedChunkCount: 1, totalChunkCount: 2), attempt: Self.attemptA))
        precondition(percent(work) == 80)
        work.apply(.cleanupWaiting(reason: "Cleans up after the recording ends."))
        precondition(work.status == .waitingToPostProcess(reason: "Cleans up after the recording ends."))
        precondition(work.toolbarWork == .waitingToPostProcess)
        work.apply(.cleanupWaiting(reason: nil))
        precondition(percent(work) == 80)
        work.apply(.cleanupWaiting(reason: ""))
        precondition(work.status?.kind == .postProcessing, "an empty reason is no reason")
    }

    /// A fallback model or a rerun splits the transcript again: the new
    /// attempt fills what is left, and the old attempt's late reports drop.
    private static func testANewCleanupAttemptContinuesTheBar() {
        var work = NoteWork(cleanup: .onDevice)
        work.apply(.cleanupStarted())
        precondition(percent(work) == 60, "cleanup alone holds the boundary")
        work.apply(.cleanupProgressed(NoteCleanupProgress(completedChunkCount: 1, totalChunkCount: 2), attempt: Self.attemptA))
        precondition(percent(work) == 80)
        work.apply(.cleanupProgressed(NoteCleanupProgress(completedChunkCount: 0, totalChunkCount: 4), attempt: Self.attemptB))
        precondition(percent(work) == 80, "the new attempt starts where the bar is")
        work.apply(.cleanupProgressed(NoteCleanupProgress(completedChunkCount: 2, totalChunkCount: 4), attempt: Self.attemptB))
        precondition(percent(work) == 90)
        work.apply(.cleanupProgressed(NoteCleanupProgress(completedChunkCount: 2, totalChunkCount: 2), attempt: Self.attemptA))
        precondition(percent(work) == 90, "the ended attempt's late report is dropped")
    }

    /// The Mac's Edit Mode reports no chunks: the spinner without a bar,
    /// whichever way cleanup starts, and only for that cleanup.
    private static func testCleanupWithoutChunkProgress() {
        var work = NoteWork(cleanup: .cloud)
        work.apply(.cleanupStarted(reportsProgress: false))
        precondition(work.status == .postProcessing(nil))
        work.apply(.ended)
        work.apply(.transcriptionStarted(.retranscription))
        work.apply(.transcriptionFinished(cleanupFollows: true, cleanupReportsProgress: false))
        precondition(work.status == .postProcessing(nil))
        work.apply(.ended)
        work.apply(.cleanupStarted())
        precondition(percent(work) == 80, "the next cleanup reports again")
        var off = NoteWork(cleanup: .off)
        off.apply(.cleanupStarted())
        precondition(off.status == .postProcessing(nil), "no bar when cleanup is off")
    }

    private static func testPausedCancellingAndRestart() {
        var work = NoteWork()
        work.apply(.transcriptionStarted(.retranscription))
        work.apply(.paused(reason: "Paused because this iPhone is too warm."))
        precondition(work.status == .retranscriptionPaused(reason: "Paused because this iPhone is too warm."))
        precondition(present(work)?.indicator == .hidden)
        precondition(work.toolbarWork == .none)

        var first = NoteWork()
        first.apply(.queued(.first, reason: nil))
        precondition(first.status == .waitingToTranscribe(reason: nil))
        precondition(first.toolbarWork == .waitingToTranscribe)
        first.apply(.transcriptionStarted(.first))
        first.apply(.paused(reason: nil))
        precondition(first.status == .transcriptionPaused(reason: nil))
        first.apply(.transcriptionStarted(.first))
        first.apply(.cancelling(reason: "Your recording stays on this iPhone."))
        precondition(first.status == .cancellingTranscription(reason: "Your recording stays on this iPhone."))
        precondition(first.toolbarWork == .cancelling)

        var restart = NoteWork(cleanup: .onDevice)
        restart.apply(.transcriptionStarted(.restart(modelName: "Synthetic Model")))
        precondition(restart.status == .restartingTranscription(modelName: "Synthetic Model", .starting))
        precondition(restart.toolbarWork == .retranscribing)
        restart.apply(.paused(reason: nil))
        precondition(restart.status == .transcriptionPaused(reason: nil), "a restart pauses as a transcription")
    }

    private static func testCloudResumeAndRecovery() {
        var work = NoteWork()
        work.apply(.cloudTranscriptionResuming(p(1, 4)))
        precondition(work.status == .resumingCloudTranscription(p(1, 4)))
        precondition(work.toolbarWork == .transcribing)
        work.apply(.transcriptionProgressed(p(2, 4)))
        precondition(work.status?.kind == .transcribing, "the next upload is a transcription again")

        var recovering = NoteWork()
        recovering.apply(.recoveringStarted)
        precondition(recovering.status == .recovering && recovering.toolbarWork == .none)
    }

    private static func testToolbarWork() {
        var work = NoteWork()
        precondition(work.toolbarWork == .none)
        work.apply(.transcriptionStarted(.first))
        precondition(work.toolbarWork == .transcribing)
        work.apply(.transcriptionStarted(.retranscription))
        precondition(work.toolbarWork == .retranscribing)
        work.apply(.transcriptionFinished(cleanupFollows: true))
        precondition(work.toolbarWork == .postProcessing)
    }

    @MainActor
    private static func testBoardPublishesOneValuePerNote() {
        let board = NoteWorkBoard()
        board.setCleanup(.onDevice)
        var published = 0
        let subscription = board.$works.dropFirst().sink { _ in published += 1 }
        board.send(.transcriptionStarted(.retranscription), for: "note-a")
        board.send(.transcriptionProgressed(p(1, 1)), for: "note-a")
        let before = published
        board.send(.transcriptionFinished(cleanupFollows: true), for: "note-a")
        precondition(published == before + 1, "the hand-over is one published change")
        precondition(board.work(for: "note-a").status?.kind == .postProcessing)
        precondition(board.work(for: "note-a").status?.progress?.percent == 60)
        // Repeating a report that changes nothing publishes nothing.
        let quiet = published
        board.send(.cleanupStarted(), for: "note-a")
        precondition(published == quiet)
        // The cleanup setting reaches running work.
        let beforeSetting = published
        board.send(.transcriptionStarted(.first), for: "note-c")
        board.setCleanup(.cloud)
        precondition(published == beforeSetting + 2, "a setting change is published once for all notes")
        precondition(board.work(for: "note-a").status?.progress?.percent == 80)
        precondition(board.work(for: "note-c").cleanup == .cloud)
        board.send(.ended, for: "note-c")
        board.send(.ended, for: "note-a")
        precondition(board.works["note-a"] == nil && board.work(for: "note-a").status == nil)
        // A note that never ran publishes nothing when it ends.
        let idle = published
        board.send(.ended, for: "note-b")
        precondition(published == idle)
        board.send(.recoveringStarted, for: "note-b")
        board.forget("note-b")
        precondition(board.works.isEmpty)
        subscription.cancel()
    }

    /// Review: a late report from cancelled or finished work must not
    /// bring a status back that nothing will end.
    private static func testLateEventsDontReviveEndedWork() {
        let late: [NoteWorkEvent] = [
            .paused(reason: "Synthetic reason"), .transcriptionFinished(cleanupFollows: true),
            .transcriptionProgressed(p(1, 2)), .cancelling(reason: nil), .resumed,
            .cleanupWaiting(reason: "Synthetic reason"),
            .cleanupProgressed(NoteCleanupProgress(completedChunkCount: 1, totalChunkCount: 2)),
        ]
        for event in late {
            var work = NoteWork(cleanup: .onDevice)
            work.apply(.transcriptionStarted(.first))
            work.apply(.ended)
            work.apply(event)
            precondition(!work.isActive, "\(event) revived ended work")
        }
        // Cleanup ending doesn't go back to transcription.
        var work = NoteWork(cleanup: .cloud)
        work.apply(.transcriptionStarted(.first))
        work.apply(.transcriptionFinished(cleanupFollows: true))
        work.apply(.cloudTranscriptionResuming(p(1, 4)))
        precondition(work.status?.kind == .postProcessing)
        // A stale resume doesn't move the bar back.
        var cloud = NoteWork()
        cloud.apply(.transcriptionStarted(.first))
        cloud.apply(.transcriptionProgressed(p(3, 4)))
        cloud.apply(.cloudTranscriptionResuming(p(1, 4)))
        precondition(percent(cloud) == 75)
        // A paused cleanup isn't a paused transcription.
        var cleaning = NoteWork(cleanup: .onDevice)
        cleaning.apply(.cleanupStarted())
        cleaning.apply(.paused(reason: nil))
        precondition(cleaning.status?.kind == .postProcessing)
    }

    /// Review: resuming from a pause showed 0% and then jumped back.
    private static func testResumeContinuesFromWhereItPaused() {
        var work = NoteWork(cleanup: .onDevice)
        work.apply(.transcriptionStarted(.retranscription))
        work.apply(.transcriptionProgressed(p(7, 10)))
        work.apply(.paused(reason: "Synthetic reason"))
        precondition(work.status == .retranscriptionPaused(reason: "Synthetic reason"))
        work.apply(.resumed)
        precondition(work.status?.kind == .retranscribing && percent(work) == 42)
        // A queued retranscription that pauses keeps its kind.
        var queued = NoteWork()
        queued.apply(.queued(.retranscription, reason: nil))
        queued.apply(.paused(reason: nil))
        precondition(queued.status == .retranscriptionPaused(reason: nil))
        queued.apply(.resumed)
        precondition(queued.status == .retranscribing(.starting))
    }

    /// Review: the chunk runner splits again inside one attempt (0 of N);
    /// the bar keeps moving instead of waiting for the new split to pass it.
    private static func testSplitAgainInsideOneAttemptKeepsMoving() {
        var work = NoteWork(cleanup: .off)
        work.apply(.cleanupStarted())
        work.cleanup = .onDevice
        work.apply(.cleanupProgressed(NoteCleanupProgress(completedChunkCount: 2, totalChunkCount: 4), attempt: Self.attemptA))
        precondition(percent(work) == 80)
        work.apply(.cleanupProgressed(NoteCleanupProgress(completedChunkCount: 0, totalChunkCount: 6), attempt: Self.attemptA))
        precondition(percent(work) == 80)
        work.apply(.cleanupProgressed(NoteCleanupProgress(completedChunkCount: 3, totalChunkCount: 6), attempt: Self.attemptA))
        precondition(percent(work) == 90, "the new split fills what is left")
        // A late report from the earlier split is dropped.
        work.apply(.cleanupProgressed(NoteCleanupProgress(completedChunkCount: 3, totalChunkCount: 4), attempt: Self.attemptA))
        precondition(percent(work) == 90)
    }

    private static func testEmptyReasonsAreNoReason() {
        var queued = NoteWork()
        queued.apply(.queued(.first, reason: ""))
        var none = NoteWork()
        none.apply(.queued(.first, reason: nil))
        precondition(queued == none)
        queued.apply(.cancelling(reason: ""))
        precondition(queued.status == .cancellingTranscription(reason: nil))
    }

    private static let attemptA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private static let attemptB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
}
