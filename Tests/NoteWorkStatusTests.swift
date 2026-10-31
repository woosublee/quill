import Foundation
import QuillNoteUI

/// The shared work-status table (#697): each state's title, indicator,
/// detail and progress, the progress arithmetic, and the toolbar labels that
/// read from the same table.
@main
struct NoteWorkStatusTests {
    static func main() {
        testProgressArithmetic()
        testOneBarForTranscriptionAndCleanup()
        testEveryStateReadsFromTheTable()
        testTitleNeverCountsChunks()
        testReasonOnlyForWaitingAndPaused()
        testPausedHasNoSpinner()
        testAllTitleKeysCoversEveryState()
        testToolbarProgressLabelsMatchTheStatus()
        testToolbarActionLabels()
        testFractionProgress()
        testIPhoneOnlyStates()
        testWaitingToPostProcessToolbar()
        print("NoteWorkStatusTests passed")
    }

    /// Returns the key itself, so titles read as keys.
    private static func present(_ status: NoteWorkStatus) -> NoteWorkStatus.Presentation {
        status.presentation { $0 }
    }

    private static func progress(_ completed: Int, of total: Int) -> NoteWorkProgress {
        guard let progress = NoteWorkProgress(completed: completed, total: total) else {
            preconditionFailure("\(completed) of \(total) has progress")
        }
        return progress
    }

    /// One bar for the whole job (#697 owner decision): cleanup with a
    /// cloud model takes 80–100%, with an on-device one 60–100%, and with
    /// cleanup off transcription fills it. Never 100% while running.
    private static func testOneBarForTranscriptionAndCleanup() {
        func percent(_ value: NoteWorkProgress?) -> Int? { value?.percent }
        let half = progress(1, of: 2)
        precondition(percent(.combined(transcription: half, cleanup: .off)) == 50)
        precondition(percent(.combined(transcription: half, cleanup: .cloud)) == 40)
        precondition(percent(.combined(transcription: half, cleanup: .onDevice)) == 30)
        precondition(percent(.combined(transcription: .starting, cleanup: .cloud)) == 0, "0% from the start")
        precondition(NoteWorkProgress.combined(transcription: nil, cleanup: .cloud) == nil, "one request: no bar")
        // Transcription done: it reaches the boundary, never past it.
        precondition(percent(.combined(transcription: progress(4, of: 4), cleanup: .cloud)) == 80)
        precondition(percent(.combined(transcription: progress(4, of: 4), cleanup: .onDevice)) == 60)
        // Cleanup picks up at the boundary and holds there until a chunk is done.
        precondition(NoteWorkProgress.combined(cleanupProgress: nil, stage: .cloud) == nil, "Edit Mode: no cleanup bar")
        precondition(percent(.combined(cleanupProgress: progress(0, of: 3), stage: .cloud)) == 80)
        precondition(percent(.combined(cleanupProgress: progress(0, of: 1), stage: .onDevice)) == 60)
        precondition(percent(.combined(cleanupProgress: progress(1, of: 4), stage: .cloud)) == 85)
        precondition(percent(.combined(cleanupProgress: progress(2, of: 4), stage: .onDevice)) == 80)
        precondition(percent(.combined(cleanupProgress: progress(4, of: 4), stage: .cloud)) == 99, "never 100% while running")
        precondition(NoteWorkProgress.combined(cleanupProgress: progress(1, of: 2), stage: .off) == nil)
        // The bar never goes back when cleanup starts.
        for stage in [NoteCleanupStage.cloud, .onDevice] {
            let end = NoteWorkProgress.combined(transcription: progress(9, of: 9), cleanup: stage)!.fraction
            let start = NoteWorkProgress.combined(cleanupProgress: progress(0, of: 2), stage: stage)!.fraction
            precondition(start >= end, "\(stage)")
        }
        let status = NoteWorkStatus.postProcessing(.combined(cleanupProgress: progress(1, of: 4), stage: .cloud))
        let presentation = status.presentation { $0 }
        precondition(presentation.title == "Post-processing..." && presentation.percentText == "85%")
    }

    private static func testProgressArithmetic() {
        precondition(NoteWorkProgress(completed: 0, total: 0) == nil, "no total, no progress")
        precondition(NoteWorkProgress(completed: 3, total: -1) == nil)

        let start = progress(0, of: 4)
        precondition(start.fraction == 0 && start.percent == 0)
        let middle = progress(1, of: 4)
        precondition(middle.percent == 25)
        // Rounded down: 2 of 3 is 66%, not 67%.
        precondition(progress(2, of: 3).percent == 66)
        // Exact ratios aren't lost to floating point: 0.58 * 100 is 57.999….
        precondition(progress(29, of: 50).percent == 58, "29 of 50")
        precondition(NoteWorkProgress(fraction: 0.29)?.percent == 29, "an iPhone fraction")
        for total in 1...200 {
            for completed in 0..<total {
                let percent = progress(completed, of: total).percent
                precondition(percent == completed * 100 / total, "\(completed) of \(total)")
            }
        }
        precondition(NoteWorkProgress(fraction: 0.999)?.percent == 99, "never 100% while running")
        // Progress known to come shows 0% from the start (#697).
        precondition(NoteWorkProgress.starting.fraction == 0 && NoteWorkProgress.starting.percent == 0)
        precondition(
            NoteWorkStatus.Presentation(indicator: .spinner, title: "", detail: nil, progress: .starting).percentText == "0%"
        )
        // The last chunk is still saving: never 100% while work runs.
        let done = progress(4, of: 4)
        precondition(done.fraction == 0.99 && done.percent == 99)
        // Out-of-range counts are clamped.
        precondition(progress(9, of: 4) == done)
        precondition(progress(-2, of: 4) == start)
        precondition(NoteWorkStatus.Presentation(indicator: .spinner, title: "", detail: nil, progress: middle).percentText == "25%")
        precondition(NoteWorkStatus.Presentation(indicator: .spinner, title: "", detail: nil, progress: nil).percentText == nil)
    }

    /// The whole table: title key, indicator, and progress for each state.
    private static func testEveryStateReadsFromTheTable() {
        let half = progress(2, of: 4)
        let rows: [(NoteWorkStatus, String, NoteWorkStatus.Indicator, NoteWorkProgress?)] = [
            (.waitingToTranscribe(reason: nil), "Waiting to transcribe...", .spinner, nil),
            (.transcribing(nil), "Transcribing...", .spinner, nil),
            (.transcribing(half), "Transcribing...", .spinner, half),
            (.resumingCloudTranscription(nil), "Resuming cloud transcription…", .spinner, nil),
            (.resumingCloudTranscription(half), "Resuming cloud transcription…", .spinner, half),
            (.retranscribing(nil), "Retranscribing...", .spinner, nil),
            (.retranscribing(half), "Retranscribing...", .spinner, half),
            (.cancellingTranscription(reason: nil), "Cancelling transcription...", .spinner, nil),
            (.transcriptionPaused(reason: nil), "Transcription paused", .hidden, nil),
            (.waitingToPostProcess(reason: nil), "Waiting to post-process", .spinner, nil),
            // #697 decision 3: post-processing shows a spinner on both apps.
            (.postProcessing(nil), "Post-processing...", .spinner, nil),
            (.postProcessing(half), "Post-processing...", .spinner, half),
            (.recovering, "Recovering…", .spinner, nil),
            (.creatingSummary, "Creating summary…", .spinner, nil),
            (.regeneratingSummary, "Regenerating summary…", .spinner, nil),
            (.retranscriptionPaused(reason: nil), "Retranscription paused", .hidden, nil),
            (.restartingTranscription(modelName: "Synthetic Model", nil), "Transcribing with %@...", .spinner, nil),
            (.restartingTranscription(modelName: "Synthetic Model", half), "Transcribing with %@...", .spinner, half),
            (.preparingTranscript(reason: nil), "Preparing transcript", .spinner, nil),
        ]
        for (status, key, indicator, expectedProgress) in rows {
            precondition(status.titleKey == key, "\(status) title")
            let presentation = present(status)
            precondition(presentation.indicator == indicator, "\(status) indicator")
            precondition(presentation.progress == expectedProgress, "\(status) progress")
            precondition(presentation.detail == nil, "\(status) has no detail without a reason")
            precondition(status.isSummaryWork == (status == .creatingSummary || status == .regeneratingSummary))
        }
    }

    /// The status shows a percentage only (#697): the title is the plain
    /// one whatever the progress, and the percent carries how far it got.
    private static func testTitleNeverCountsChunks() {
        let presentation = NoteWorkStatus.transcribing(progress(1, of: 3)).presentation { key in
            key == "Transcribing..." ? "전사 중..." : key
        }
        precondition(presentation.title == "전사 중...", presentation.title)
        precondition(presentation.percentText == "33%")
        precondition(present(.transcribing(nil)).title == "Transcribing...")
    }

    private static func testReasonOnlyForWaitingAndPaused() {
        let reason = "Cleans up after the recording ends."
        for status in [
            NoteWorkStatus.waitingToTranscribe(reason: reason),
            .transcriptionPaused(reason: reason),
            .waitingToPostProcess(reason: reason),
            .retranscriptionPaused(reason: reason),
            .preparingTranscript(reason: reason),
            .cancellingTranscription(reason: reason),
        ] {
            precondition(present(status).detail == reason, "\(status) shows its reason")
        }
        precondition(present(.waitingToPostProcess(reason: "")).detail == nil, "an empty reason shows no line")
    }

    private static func testPausedHasNoSpinner() {
        precondition(NoteWorkStatus.transcriptionPaused(reason: nil).indicator == .hidden)
        precondition(NoteWorkStatus.retranscriptionPaused(reason: nil).indicator == .hidden)
    }

    private static func testAllTitleKeysCoversEveryState() {
        let keys = Set(NoteWorkStatus.allTitleKeys)
        precondition(keys.count == 14, "\(keys.count) keys")
        precondition(NoteWorkStatus.Kind.allCases.allSatisfy { kind in kind.examples.allSatisfy { $0.kind == kind } })
        for key in [
            "Waiting to transcribe...", "Transcribing...",
            "Resuming cloud transcription…", "Retranscribing...", "Cancelling transcription...",
            "Transcription paused", "Waiting to post-process", "Post-processing...",
            "Recovering…", "Creating summary…", "Regenerating summary…",
            "Retranscription paused", "Transcribing with %@...", "Preparing transcript",
        ] {
            precondition(keys.contains(key), key)
        }
    }

    /// The toolbar's progress slot says what the status says: the iPhone
    /// used to say "Transcribing..." while post-processing.
    private static func testToolbarProgressLabelsMatchTheStatus() {
        let rows: [(NoteToolbarWork, NoteWorkStatus?, String)] = [
            (.none, nil, "Transcribing..."),
            (.waitingToTranscribe, .waitingToTranscribe(reason: nil), "Waiting to transcribe..."),
            (.transcribing, .transcribing(nil), "Transcribing..."),
            (.retranscribing, .retranscribing(nil), "Retranscribing..."),
            (.cancelling, .cancellingTranscription(reason: nil), "Cancelling transcription..."),
            (.waitingToPostProcess, .waitingToPostProcess(reason: nil), "Waiting to post-process"),
            (.postProcessing, .postProcessing(nil), "Post-processing..."),
        ]
        for (work, status, key) in rows {
            precondition(work.status == status, "\(work) status")
            precondition(work.progressLabelKey == key, "\(work) progress label")
        }
    }

    /// The Mac's wording and capitalisation, for both apps.
    private static func testToolbarActionLabels() {
        let rows: [(NoteToolbarFirstAction, String?)] = [
            (.transcribe, "Transcribe audio"),
            (.retry, "Retry transcription"),
            (.retranscribe, "Retry transcription"),
            (.cancelTranscription, "Cancel Transcription"),
            (.cancelRetranscription, "Cancel Retranscription"),
            (.cancelPostProcessing, "Cancel Post-processing"),
            (.cancelSummary, "Cancel Summary"),
            (.openModelSetup, nil),
            (.runSummary, nil),
        ]
        for (action, key) in rows {
            precondition(action.labelKey == key, "\(action) label")
        }
    }

    /// A finer fraction drives the bar in place of the chunk counts.
    /// Fraction-only progress has no chunks.
    private static func testFractionProgress() {
        guard let fine = NoteWorkProgress(completed: 1, total: 4, fraction: 0.375) else {
            preconditionFailure("chunks with a fraction have progress")
        }
        precondition(fine.fraction == 0.375 && fine.percent == 37)
        precondition(fine != progress(1, of: 4), "the fraction is part of the value")
        precondition(NoteWorkProgress(completed: 1, total: 4, fraction: .nan) == progress(1, of: 4), "a NaN fraction falls back to the counts")
        precondition(NoteWorkProgress(completed: 1, total: 0, fraction: 0.5) == nil)
        precondition(NoteWorkProgress(completed: 4, total: 4, fraction: 1)?.percent == 99, "never 100% while work runs")
        // No title names a chunk, so the fraction isn't held to one.
        precondition(NoteWorkProgress(completed: 3, total: 4, fraction: 0.1)?.fraction == 0.1)
        precondition(NoteWorkProgress(completed: 0, total: 4, fraction: 0.9)?.fraction == 0.9)
        precondition(NoteWorkProgress(completed: 1, total: 4, fraction: -1)?.fraction == 0)
        precondition(NoteWorkProgress(completed: 1, total: 4, fraction: nil) == progress(1, of: 4))

        guard let only = NoteWorkProgress(fraction: 0.5) else { preconditionFailure("a fraction has progress") }
        precondition(only.percent == 50)
        precondition(NoteWorkProgress(fraction: 1.5)?.percent == 99)
        precondition(NoteWorkProgress(fraction: -1)?.percent == 0)
        precondition(NoteWorkProgress(fraction: .infinity) == nil)
        precondition(NoteWorkStatus.transcribing(only).titleKey == "Transcribing...")
        precondition(present(.transcribing(only)).title == "Transcribing...")
        precondition(present(.transcribing(only)).percentText == "50%")
        precondition(present(.transcribing(fine)).title == "Transcribing...")
        precondition(present(.transcribing(fine)).percentText == "37%")
        // Chunk-count progress (all the Mac sends) fills the bar as before.
        precondition(progress(2, of: 3).fraction == 2.0 / 3.0)
    }

    /// The iPhone-only states the Mac never sends.
    private static func testIPhoneOnlyStates() {
        let restart = NoteWorkStatus.restartingTranscription(modelName: "Synthetic Model", progress(1, of: 2))
            .presentation { key in key == "Transcribing with %@..." ? "%@ 모델로 전사 중..." : key }
        precondition(restart.title == "Synthetic Model 모델로 전사 중...", restart.title)
        precondition(restart.percentText == "50%")
        precondition(present(.preparingTranscript(reason: "Synthetic detail")).detail == "Synthetic detail")
        precondition(!NoteWorkStatus.preparingTranscript(reason: nil).isSummaryWork)
    }

    /// Waiting for the cleanup model is cancelled like post-processing.
    private static func testWaitingToPostProcessToolbar() {
        for work in [NoteToolbarWork.waitingToPostProcess, .postProcessing] {
            let state = NoteToolbarState.make(NoteToolbarInput(tab: .transcript, work: work, canCancelWork: true))
            precondition(state.firstSlot == .button(.cancelPostProcessing, isEnabled: true), "\(work) cancels the cleanup")
            let blocked = NoteToolbarState.make(NoteToolbarInput(tab: .transcript, work: work, canCancelWork: false))
            precondition(blocked.firstSlot == .progress, "\(work) without a cancel path shows progress")
        }
    }
}
