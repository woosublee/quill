import Foundation
import QuillNoteUI

/// The shared work-status table (#697): each state's title, indicator,
/// detail and progress, the progress arithmetic, and the toolbar labels that
/// read from the same table.
@main
struct NoteWorkStatusTests {
    static func main() {
        testProgressArithmetic()
        testEveryStateReadsFromTheTable()
        testChunkTitleTakesCurrentAndTotal()
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

    private static func testProgressArithmetic() {
        precondition(NoteWorkProgress(completed: 0, total: 0) == nil, "no total, no progress")
        precondition(NoteWorkProgress(completed: 3, total: -1) == nil)

        let start = progress(0, of: 4)
        precondition(start.fraction == 0 && start.percent == 0 && start.current == 1)
        let middle = progress(1, of: 4)
        precondition(middle.percent == 25 && middle.current == 2)
        // Rounded down: 2 of 3 is 66%, not 67%.
        precondition(progress(2, of: 3).percent == 66)
        // The last chunk is still saving: never 100% while work runs.
        let done = progress(4, of: 4)
        precondition(done.fraction == 0.99 && done.percent == 99 && done.current == 4)
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
            (.transcribing(half), "Transcribing %d of %d…", .spinner, half),
            (.resumingCloudTranscription(nil), "Resuming cloud transcription…", .spinner, nil),
            (.resumingCloudTranscription(half), "Resuming cloud transcription…", .spinner, half),
            (.retranscribing(nil), "Retranscribing...", .spinner, nil),
            (.retranscribing(half), "Retranscribing...", .spinner, half),
            (.cancellingTranscription, "Cancelling transcription...", .spinner, nil),
            (.transcriptionPaused(reason: nil), "Transcription paused", .hidden, nil),
            (.waitingToPostProcess(reason: nil), "Waiting to post-process", .spinner, nil),
            // #697 decision 3: post-processing shows a spinner on both apps.
            (.postProcessing, "Post-processing...", .spinner, nil),
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

    private static func testChunkTitleTakesCurrentAndTotal() {
        let presentation = NoteWorkStatus.transcribing(progress(1, of: 3)).presentation { key in
            key == "Transcribing %d of %d…" ? "%d/%d 청크 전사 중…" : key
        }
        precondition(presentation.title == "2/3 청크 전사 중…", presentation.title)
        let korean = NoteWorkStatus.transcribing(progress(1, of: 3)).presentation(localize: { $0 }, locale: Locale(identifier: "ko"))
        precondition(korean.title == "Transcribing 2 of 3…", korean.title)
        precondition(presentation.percentText == "33%")
    }

    private static func testReasonOnlyForWaitingAndPaused() {
        let reason = "Cleans up after the recording ends."
        for status in [
            NoteWorkStatus.waitingToTranscribe(reason: reason),
            .transcriptionPaused(reason: reason),
            .waitingToPostProcess(reason: reason),
            .retranscriptionPaused(reason: reason),
            .preparingTranscript(reason: reason),
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
        precondition(keys.count == 15, "\(keys.count) keys")
        precondition(NoteWorkStatus.Kind.allCases.allSatisfy { kind in kind.examples.allSatisfy { $0.kind == kind } })
        for key in [
            "Waiting to transcribe...", "Transcribing...", "Transcribing %d of %d…",
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
            (.cancelling, .cancellingTranscription, "Cancelling transcription..."),
            (.waitingToPostProcess, .waitingToPostProcess(reason: nil), "Waiting to post-process"),
            (.postProcessing, .postProcessing, "Post-processing..."),
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

    /// A finer fraction drives the bar; chunk counts, when given, still name
    /// the title. Fraction-only progress names no chunks.
    private static func testFractionProgress() {
        guard let fine = NoteWorkProgress(completed: 1, total: 4, fraction: 0.375) else {
            preconditionFailure("chunks with a fraction have progress")
        }
        precondition(fine.countsChunks && fine.current == 2 && fine.total == 4)
        precondition(fine.fraction == 0.375 && fine.percent == 37)
        precondition(fine != progress(1, of: 4), "the fraction is part of the value")
        precondition(NoteWorkProgress(completed: 1, total: 4, fraction: .nan) == progress(1, of: 4), "a NaN fraction falls back to the counts")
        precondition(NoteWorkProgress(completed: 1, total: 0, fraction: 0.5) == nil)
        precondition(NoteWorkProgress(completed: 4, total: 4, fraction: 1)?.percent == 99, "never 100% while work runs")

        guard let only = NoteWorkProgress(fraction: 0.5) else { preconditionFailure("a fraction has progress") }
        precondition(!only.countsChunks && only.percent == 50 && only.current == 0)
        precondition(NoteWorkProgress(fraction: 1.5)?.percent == 99)
        precondition(NoteWorkProgress(fraction: -1)?.percent == 0)
        precondition(NoteWorkProgress(fraction: .infinity) == nil)
        // Without chunk counts the title doesn't say "N of M".
        precondition(NoteWorkStatus.transcribing(only).titleKey == "Transcribing...")
        precondition(present(.transcribing(only)).title == "Transcribing...")
        precondition(present(.transcribing(only)).percentText == "50%")
        precondition(present(.transcribing(fine)).title == "Transcribing 2 of 4…")
        // Chunk-count progress (all the Mac sends) reads exactly as before.
        precondition(progress(2, of: 3).countsChunks && progress(2, of: 3).fraction == 2.0 / 3.0)
    }

    /// The iPhone-only states the Mac never sends.
    private static func testIPhoneOnlyStates() {
        let restart = NoteWorkStatus.restartingTranscription(modelName: "Synthetic Model", progress(1, of: 2))
            .presentation { key in key == "Transcribing with %@..." ? "%@로 전사 중..." : key }
        precondition(restart.title == "Synthetic Model로 전사 중...", restart.title)
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
