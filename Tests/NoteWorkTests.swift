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
        testKeptCleanupProgressIsPlacedNotKeptAgain()
        testANewCleanupAttemptContinuesTheBar()
        testCleanupWithoutChunkProgress()
        testRetranscriptionOverAnEarlierCleanup()
        testPausedCancellingAndRestart()
        testResumeContinuesFromWhereItPaused()
        testCloudResumeAndRecovery()
        testLateEventsDontReviveEndedWork()
        testEmptyReasonsAreNoReason()
        testToolbarWork()
        testANewAttemptIsRecordedFromItsFirstReport()
        testReportWithoutAttemptBelongsToTheCurrentOne()
        MainActor.assumeIsolated { testBoardPublishesOneValuePerNote() }
        print("NoteWorkTests passed")
    }

    private static func p(_ completed: Int, _ total: Int) -> NoteWorkProgress {
        NoteWorkProgress(completed: completed, total: total)!
    }

    private static func chunks(_ completed: Int, _ total: Int, base: Double = 0) -> NoteCleanupProgress {
        NoteCleanupProgress(completedChunkCount: completed, totalChunkCount: total, base: base)
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
        var work = NoteWork(stage: .onDevice)
        let statuses = replay(&work, [
            .transcriptionStarted(.retranscription),
            .transcriptionProgressed(p(0, 1)),
            .transcriptionProgressed(p(1, 1)),
            .transcriptionFinished(cleanupFollows: true),
            .cleanupProgressed(chunks(0, 3), attempt: Self.attemptA),
            .cleanupProgressed(chunks(1, 3), attempt: Self.attemptA),
            .cleanupProgressed(chunks(3, 3), attempt: Self.attemptA),
        ])
        precondition(statuses.allSatisfy { $0 != nil }, "a status on every step: \(statuses)")
        let percents = statuses.compactMap { $0?.progress?.percent }
        precondition(percents == [0, 0, 60, 60, 60, 73, 99], "\(percents)")
        precondition(statuses[2]?.kind == .retranscribing)
        precondition(statuses[3]?.kind == .postProcessing, "cleanup takes over in the same change")
        precondition(work.toolbarWork == .postProcessing && work.isPostProcessing)
        work.apply(.cleanupEnded)
        precondition(work.status == nil && !work.isActive)
    }

    /// The Mac's cloud retranscription: chunk counts only, cloud cleanup.
    private static func testCloudRetranscriptionOnTheMac() {
        var work = NoteWork(stage: .cloud)
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
        precondition(work.status == nil && !work.isActive)
        // One cloud request reports no progress: no bar instead of 0%.
        var single = NoteWork()
        single.apply(.transcriptionStarted(.first, reportsProgress: false))
        precondition(single.status == .transcribing(nil))
    }

    private static func testLateReportsChangeNothing() {
        var work = NoteWork(stage: .onDevice)
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
        work.apply(.cleanupProgressed(chunks(1, 2)))
        let cleaning = work
        work.apply(.cleanupStarted())
        precondition(work == cleaning)
        // Cleanup progress with no cleanup running is dropped.
        work.apply(.cleanupEnded)
        work.apply(.cleanupProgressed(chunks(1, 2)))
        precondition(work.status == nil)
    }

    /// The iPhone waits for the on-device model: the reason replaces the bar,
    /// and the bar comes back where it was.
    private static func testWaitingForTheCleanupModel() {
        var work = NoteWork(stage: .onDevice)
        work.apply(.transcriptionStarted(.first))
        work.apply(.transcriptionFinished(cleanupFollows: true))
        work.apply(.cleanupProgressed(chunks(1, 2), attempt: Self.attemptA))
        precondition(percent(work) == 80)
        work.apply(.cleanupWaiting(reason: "Cleans up after the recording ends."))
        precondition(work.status == .waitingToPostProcess(reason: "Cleans up after the recording ends."))
        precondition(work.toolbarWork == .waitingToPostProcess)
        work.apply(.cleanupWaiting(reason: nil))
        precondition(percent(work) == 80)
        work.apply(.cleanupWaiting(reason: ""))
        precondition(work.status?.kind == .postProcessing, "an empty reason is no reason")
    }

    /// Both apps keep a cleanup's progress forward-only before they send it
    /// (and may send only the latest of several reports). A split again
    /// inside one attempt arrives already kept (base set); it is placed, not
    /// kept again, so the bar keeps moving (step 2 finding, 2026-11-01).
    private static func testKeptCleanupProgressIsPlacedNotKeptAgain() {
        var work = NoteWork(stage: .onDevice)
        work.apply(.cleanupStarted())
        work.apply(.cleanupProgressed(chunks(0, 2), attempt: Self.attemptA))
        // The app split 1 of 2 again into 4 and kept it: 1 of 4 above 0.5.
        work.apply(.cleanupProgressed(chunks(1, 4, base: 0.5), attempt: Self.attemptA))
        precondition(work.cleanup?.progress?.fraction == 0.625)
        precondition(percent(work) == 85)
        // A report behind the bar is dropped.
        work.apply(.cleanupProgressed(chunks(1, 2), attempt: Self.attemptA))
        precondition(work.cleanup?.progress?.fraction == 0.625)
        // The Mac sends one attempt without an ID, already kept.
        var mac = NoteWork(stage: .cloud)
        mac.apply(.cleanupStarted())
        mac.apply(.cleanupProgressed(chunks(2, 4)))
        mac.apply(.cleanupProgressed(chunks(1, 6, base: 0.5)))
        precondition(mac.cleanup?.progress == chunks(1, 6, base: 0.5))
    }

    /// A fallback model or a rerun splits the transcript again: the new
    /// attempt fills what is left, and the old attempt's late reports drop.
    private static func testANewCleanupAttemptContinuesTheBar() {
        var work = NoteWork(stage: .onDevice)
        work.apply(.cleanupStarted())
        precondition(percent(work) == 60, "cleanup alone holds the boundary")
        work.apply(.cleanupProgressed(chunks(1, 2), attempt: Self.attemptA))
        precondition(percent(work) == 80)
        work.apply(.cleanupProgressed(chunks(0, 4), attempt: Self.attemptB))
        precondition(percent(work) == 80, "the new attempt starts where the bar is")
        work.apply(.cleanupProgressed(chunks(2, 4), attempt: Self.attemptB))
        precondition(percent(work) == 90)
        work.apply(.cleanupProgressed(chunks(2, 2), attempt: Self.attemptA))
        precondition(percent(work) == 90, "the replaced attempt's late report is dropped")
    }

    /// The Mac's Edit Mode reports no chunks: the spinner without a bar,
    /// whichever way cleanup starts.
    private static func testCleanupWithoutChunkProgress() {
        var work = NoteWork(stage: .cloud)
        work.apply(.cleanupStarted(reportsProgress: false))
        precondition(work.status == .postProcessing(nil))
        work.apply(.cleanupEnded)
        work.apply(.transcriptionStarted(.retranscription))
        work.apply(.transcriptionFinished(cleanupFollows: true, cleanupReportsProgress: false))
        precondition(work.status == .postProcessing(nil))
        work.apply(.cleanupEnded)
        work.apply(.cleanupStarted())
        precondition(percent(work) == 80, "the next cleanup reports again")
        var off = NoteWork(stage: .off)
        off.apply(.cleanupStarted())
        precondition(off.status == .postProcessing(nil), "no bar when cleanup is off")
    }

    /// The iPhone can retranscribe while an earlier cleanup still runs. The
    /// retranscription shows (with its Cancel); the cleanup keeps running
    /// for the rows and the summary; each ending ends only its own work.
    private static func testRetranscriptionOverAnEarlierCleanup() {
        var work = NoteWork(stage: .onDevice)
        work.apply(.cleanupStarted())
        work.apply(.cleanupProgressed(chunks(1, 2), attempt: Self.attemptA))
        work.apply(.transcriptionStarted(.retranscription))
        precondition(work.status?.kind == .retranscribing && work.toolbarWork == .retranscribing)
        precondition(work.isPostProcessing, "the earlier cleanup still runs")
        // The earlier cleanup ends: the retranscription keeps showing.
        work.apply(.cleanupEnded)
        precondition(work.status?.kind == .retranscribing && !work.isPostProcessing)
        // Or it runs on, and the new transcript joins it.
        var joined = NoteWork(stage: .onDevice)
        joined.apply(.cleanupStarted())
        joined.apply(.cleanupProgressed(chunks(1, 2), attempt: Self.attemptA))
        joined.apply(.transcriptionStarted(.retranscription))
        joined.apply(.transcriptionFinished(cleanupFollows: true))
        precondition(joined.status?.kind == .postProcessing && percent(joined) == 80)
        // A cancelled retranscription ends only the transcription.
        var cancelled = NoteWork(stage: .onDevice)
        cancelled.apply(.cleanupStarted())
        cancelled.apply(.transcriptionStarted(.retranscription))
        cancelled.apply(.transcriptionEnded)
        precondition(cancelled.status?.kind == .postProcessing)
    }

    private static func testPausedCancellingAndRestart() {
        var work = NoteWork()
        work.apply(.transcriptionStarted(.retranscription))
        work.apply(.paused(reason: "Paused because this iPhone is too warm."))
        precondition(work.status == .retranscriptionPaused(reason: "Paused because this iPhone is too warm."))
        precondition(present(work)?.indicator == .hidden)
        precondition(work.toolbarWork == .none)
        // A paused retranscription over a running cleanup: the toolbar keeps
        // the cleanup's work (review).
        var underneath = NoteWork(stage: .onDevice)
        underneath.apply(.cleanupStarted())
        underneath.apply(.transcriptionStarted(.retranscription))
        underneath.apply(.paused(reason: nil))
        precondition(underneath.status?.kind == .retranscriptionPaused)
        precondition(underneath.toolbarWork == .postProcessing)

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
        first.apply(.transcriptionEnded)
        precondition(!first.isActive)

        var restart = NoteWork(stage: .onDevice)
        restart.apply(.transcriptionStarted(.restart(modelName: "Synthetic Model")))
        precondition(restart.status == .restartingTranscription(modelName: "Synthetic Model", .starting))
        precondition(restart.toolbarWork == .retranscribing)
        restart.apply(.paused(reason: nil))
        precondition(restart.status == .transcriptionPaused(reason: nil), "a restart pauses as a transcription")
    }

    /// Review: resuming from a pause showed 0% and then jumped back.
    private static func testResumeContinuesFromWhereItPaused() {
        var work = NoteWork(stage: .onDevice)
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

    private static func testCloudResumeAndRecovery() {
        var work = NoteWork()
        work.apply(.cloudTranscriptionResuming(p(1, 4)))
        precondition(work.status == .resumingCloudTranscription(p(1, 4)))
        precondition(work.toolbarWork == .transcribing)
        work.apply(.transcriptionProgressed(p(2, 4)))
        precondition(work.status?.kind == .transcribing, "the next upload is a transcription again")
        // A stale resume doesn't move the bar back.
        work.apply(.transcriptionProgressed(p(3, 4)))
        work.apply(.cloudTranscriptionResuming(p(1, 4)))
        precondition(percent(work) == 75)

        var recovering = NoteWork()
        recovering.apply(.recoveringStarted)
        precondition(recovering.status == .recovering && recovering.toolbarWork == .none)
        recovering.apply(.cancelling(reason: nil))
        precondition(recovering.status == .recovering, "recovery isn't cancelled as a transcription")
    }

    /// Review: a late report from cancelled or finished work must not bring a
    /// status back that nothing will end.
    private static func testLateEventsDontReviveEndedWork() {
        let late: [NoteWorkEvent] = [
            .paused(reason: "Synthetic reason"), .transcriptionFinished(cleanupFollows: true),
            .transcriptionProgressed(p(1, 2)), .cancelling(reason: nil), .resumed,
            .cleanupWaiting(reason: "Synthetic reason"), .cleanupProgressed(chunks(1, 2)),
        ]
        for event in late {
            var work = NoteWork(stage: .onDevice)
            work.apply(.transcriptionStarted(.first))
            work.apply(.transcriptionEnded)
            work.apply(event)
            precondition(!work.isActive, "\(event) revived ended work")
        }
        // A pause arriving during cleanup doesn't pause a transcription.
        var work = NoteWork(stage: .cloud)
        work.apply(.transcriptionStarted(.first))
        work.apply(.transcriptionFinished(cleanupFollows: true))
        work.apply(.paused(reason: nil))
        precondition(work.status?.kind == .postProcessing, "a cleanup isn't paused as a transcription")
        work.apply(.cloudTranscriptionResuming(p(1, 4)))
        precondition(work.status?.kind == .postProcessing, "a late cloud resume doesn't cover the cleanup")
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

    /// Review: a new attempt whose first report matched the bar wasn't
    /// recorded, so the replaced attempt's late report moved the bar.
    private static func testANewAttemptIsRecordedFromItsFirstReport() {
        var work = NoteWork(stage: .onDevice)
        work.apply(.cleanupStarted())
        work.apply(.cleanupProgressed(chunks(0, 3), attempt: Self.attemptA))
        work.apply(.cleanupProgressed(chunks(0, 3), attempt: Self.attemptB))
        work.apply(.cleanupProgressed(chunks(2, 3), attempt: Self.attemptA))
        precondition(percent(work) == 60, "the replaced attempt's late report is dropped")
        work.apply(.cleanupProgressed(chunks(1, 3), attempt: Self.attemptB))
        precondition(percent(work) == 73)
    }

    /// Review: a report without an attempt after attempt reports is placed in
    /// the current attempt, not read as absolute.
    private static func testReportWithoutAttemptBelongsToTheCurrentOne() {
        var work = NoteWork(stage: .onDevice)
        work.apply(.cleanupStarted())
        work.apply(.cleanupProgressed(chunks(1, 2), attempt: Self.attemptA))
        work.apply(.cleanupProgressed(chunks(0, 4), attempt: Self.attemptB))
        work.apply(.cleanupProgressed(chunks(2, 4)))
        precondition(percent(work) == 90, "placed from attempt B's start (0.5)")
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
        board.setStage(.onDevice)
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
        // The cleanup setting reaches running work, published once for all.
        board.send(.transcriptionStarted(.first), for: "note-c")
        let beforeSetting = published
        board.setStage(.cloud)
        precondition(published == beforeSetting + 1, "a setting change is published once for all notes")
        precondition(board.work(for: "note-a").status?.progress?.percent == 80)
        precondition(board.work(for: "note-c").stage == .cloud)
        board.send(.transcriptionEnded, for: "note-c")
        board.send(.cleanupEnded, for: "note-a")
        precondition(board.works.isEmpty && board.work(for: "note-a").status == nil)
        // A note that never ran publishes nothing when it ends.
        let idle = published
        board.send(.cleanupEnded, for: "note-b")
        precondition(published == idle)
        board.send(.recoveringStarted, for: "note-b")
        board.forget("note-b")
        precondition(board.works.isEmpty)
        subscription.cancel()
    }

    private static let attemptA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private static let attemptB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
}
