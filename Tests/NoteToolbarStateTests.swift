import AppKit
import Foundation
import SwiftUI
import QuillNoteUI

/// The #690 note toolbar table (QuillNoteUI), the same for both apps. Every
/// row of the table, on both tabs, is checked here.
@main
struct NoteToolbarStateTests {
    static func main() {
        testDone()
        testTranscriptionWork()
        testCancelling()
        testPostProcessing()
        testWorkWithoutCancelPath()
        testMakingSummary()
        testFailedOrAudioOnly()
        testModelSetupOpensSettings()
        testCreateSummaryWaitsForAllWork()
        testSummaryActionBlockedWhileComparingOrEditing()
        testHiddenOnlyForRecordingComparingAndKeyboard()
        testEveryCombinationKeepsTheFixedSlots()
        testEachMacButtonHasItsOwnCursorViewForItsHelpTag()
        MainActor.assumeIsolated { testEachMacButtonGetsAnAppKitView() }
        print("NoteToolbarStateTests passed")
    }

    private typealias State = NoteToolbarState

    /// A done note with a transcript and a summary.
    private static func done(_ tab: NoteToolbarTab) -> NoteToolbarInput {
        NoteToolbarInput(
            tab: tab,
            canCancelWork: true,
            transcriptAction: .retranscribe,
            hasSummaryTab: true,
            canRunSummary: true,
            hasTranscriptToCopy: true,
            hasSummaryToCopy: true,
            hasFilesToSave: true
        )
    }

    private static func testDone() {
        precondition(State.make(done(.transcript)) == State(
            firstSlot: .button(.retranscribe, isEnabled: true),
            isCopyEnabled: true, isSaveEnabled: true, createSummary: .none, isDeleteEnabled: true
        ))
        precondition(State.make(done(.summary)) == State(
            firstSlot: .button(.runSummary, isEnabled: true),
            isCopyEnabled: true, isSaveEnabled: true, createSummary: .none, isDeleteEnabled: true
        ))
        // Without a summary, ✨ sits after Save on the transcript tab.
        var noSummary = done(.transcript)
        noSummary.hasSummaryTab = false
        noSummary.canCreateSummary = true
        precondition(State.make(noSummary).createSummary == .button(isEnabled: true))
    }

    /// Waiting to transcribe, transcribing, retranscribing: ✕ Cancel only
    /// on the transcript tab; ↻ off, Copy on, Save and Delete off on the
    /// summary tab.
    private static func testTranscriptionWork() {
        let cases: [(NoteToolbarWork, NoteToolbarFirstAction)] = [
            (.waitingToTranscribe, .cancelTranscription),
            (.transcribing, .cancelTranscription),
            (.retranscribing, .cancelRetranscription),
        ]
        for (work, cancel) in cases {
            var transcript = done(.transcript)
            transcript.work = work
            precondition(State.make(transcript) == State(
                firstSlot: .button(cancel, isEnabled: true),
                isCopyEnabled: false, isSaveEnabled: false, createSummary: .none, isDeleteEnabled: false
            ), "\(work) transcript tab")
            var summary = done(.summary)
            summary.work = work
            precondition(State.make(summary) == State(
                firstSlot: .button(.runSummary, isEnabled: false),
                isCopyEnabled: true, isSaveEnabled: false, createSummary: .none, isDeleteEnabled: false
            ), "\(work) summary tab")
        }
    }

    private static func testCancelling() {
        var transcript = done(.transcript)
        transcript.work = .cancelling
        precondition(State.make(transcript) == State(
            firstSlot: .progress,
            isCopyEnabled: false, isSaveEnabled: false, createSummary: .none, isDeleteEnabled: false
        ))
        var summary = done(.summary)
        summary.work = .cancelling
        precondition(State.make(summary).firstSlot == .button(.runSummary, isEnabled: false))
        precondition(State.make(summary).isCopyEnabled)
    }

    private static func testPostProcessing() {
        var transcript = done(.transcript)
        transcript.work = .postProcessing
        precondition(State.make(transcript) == State(
            firstSlot: .button(.cancelPostProcessing, isEnabled: true),
            isCopyEnabled: false, isSaveEnabled: false, createSummary: .none, isDeleteEnabled: false
        ))
        var summary = done(.summary)
        summary.work = .postProcessing
        precondition(State.make(summary) == State(
            firstSlot: .button(.runSummary, isEnabled: false),
            isCopyEnabled: true, isSaveEnabled: false, createSummary: .none, isDeleteEnabled: false
        ))
    }

    /// An app that can't stop the work from the toolbar shows progress in
    /// the first slot instead of a ✕ that would do nothing.
    private static func testWorkWithoutCancelPath() {
        for work in [NoteToolbarWork.waitingToTranscribe, .transcribing, .retranscribing, .postProcessing] {
            var input = done(.transcript)
            input.work = work
            input.canCancelWork = false
            precondition(State.make(input).firstSlot == .progress, "\(work)")
        }
    }

    /// Making a summary: the summary tab's ↻ becomes ✕ Cancel with Copy,
    /// Save, and Delete off; the transcript tab keeps Copy and turns its ↻,
    /// Save, and Delete off, with no ✨.
    private static func testMakingSummary() {
        var summary = done(.summary)
        summary.isMakingSummary = true
        precondition(State.make(summary) == State(
            firstSlot: .button(.cancelSummary, isEnabled: true),
            isCopyEnabled: false, isSaveEnabled: false, createSummary: .none, isDeleteEnabled: false
        ))
        var transcript = done(.transcript)
        transcript.isMakingSummary = true
        transcript.hasSummaryTab = false
        transcript.canCreateSummary = true
        precondition(State.make(transcript) == State(
            firstSlot: .button(.retranscribe, isEnabled: false),
            isCopyEnabled: true, isSaveEnabled: false, createSummary: .none, isDeleteEnabled: false
        ))
    }

    /// Transcription failed, or audio only: Transcribe, Copy off, Save
    /// (audio) and Delete on, no ✨. A summary tab, if any, is as in Done.
    private static func testFailedOrAudioOnly() {
        let failed = NoteToolbarInput(
            tab: .transcript,
            canCancelWork: true,
            transcriptAction: .transcribe,
            hasFilesToSave: true
        )
        precondition(State.make(failed) == State(
            firstSlot: .button(.transcribe, isEnabled: true),
            isCopyEnabled: false, isSaveEnabled: true, createSummary: .none, isDeleteEnabled: true
        ))
        // No ✨ there, even when the app would offer one (2026-10-28 decision):
        // it shows dimmed only while a transcription runs, and turns on after.
        var offered = failed
        offered.canCreateSummary = false
        precondition(State.make(offered).createSummary == .none)
        offered.canCreateSummary = true
        precondition(State.make(offered).createSummary == .none)
        offered.work = .transcribing
        precondition(State.make(offered).createSummary == .button(isEnabled: false))
        var withSummary = done(.summary)
        withSummary.transcriptAction = .transcribe
        precondition(State.make(withSummary) == State.make(done(.summary)))
    }

    /// No transcription model yet (the iPhone's ⚙︎): the first slot opens
    /// model setup. ✨ follows what the app says about the transcript, and
    /// running work or a summary tab still wins.
    private static func testModelSetupOpensSettings() {
        var untranscribed = NoteToolbarInput(tab: .transcript, transcriptAction: .openModelSetup, hasFilesToSave: true)
        precondition(State.make(untranscribed) == State(
            firstSlot: .button(.openModelSetup, isEnabled: true),
            isCopyEnabled: false, isSaveEnabled: true, createSummary: .none, isDeleteEnabled: true
        ), "nothing to summarize: no ✨")
        precondition(!NoteToolbarFirstAction.openModelSetup.isCancel)

        var transcribed = untranscribed
        transcribed.hasTranscriptToCopy = true
        transcribed.canCreateSummary = true
        precondition(State.make(transcribed).createSummary == .button(isEnabled: true), "a transcript keeps ✨")
        precondition(State.make(transcribed).isCopyEnabled)

        untranscribed.isMakingSummary = true
        precondition(
            State.make(untranscribed).firstSlot == .button(.openModelSetup, isEnabled: true),
            "opening Settings starts no work, so it stays on during a summary"
        )

        var withSummaryTab = transcribed
        withSummaryTab.hasSummaryTab = true
        precondition(State.make(withSummaryTab).createSummary == .none, "a summary tab makes it there")

        var working = transcribed
        working.work = .transcribing
        working.canCancelWork = true
        precondition(State.make(working).firstSlot == .button(.cancelTranscription, isEnabled: true), "Cancel wins")
    }

    /// A note without a summary keeps ✨ dimmed in its slot until
    /// transcription and post-processing have both finished, even when
    /// there's nothing to summarize yet.
    private static func testCreateSummaryWaitsForAllWork() {
        for work in [NoteToolbarWork.waitingToTranscribe, .transcribing, .retranscribing, .cancelling, .postProcessing] {
            for canCreate in [Bool?.none, true, false] {
                let input = NoteToolbarInput(
                    tab: .transcript, work: work, canCancelWork: true, canCreateSummary: canCreate
                )
                precondition(State.make(input).createSummary == .button(isEnabled: false), "\(work) \(String(describing: canCreate))")
            }
        }
        let finished = NoteToolbarInput(tab: .transcript, canCreateSummary: true)
        precondition(State.make(finished).createSummary == .button(isEnabled: true))
        let unavailable = NoteToolbarInput(tab: .transcript, canCreateSummary: false)
        precondition(State.make(unavailable).createSummary == .button(isEnabled: false))
        let nothingToSummarize = NoteToolbarInput(tab: .transcript, canCreateSummary: nil)
        precondition(State.make(nothingToSummarize).createSummary == .none)
    }

    private static func testSummaryActionBlockedWhileComparingOrEditing() {
        var blocked = done(.summary)
        blocked.isSummaryActionBlocked = true
        precondition(State.make(blocked).firstSlot == .button(.runSummary, isEnabled: false))
        blocked.canRunSummary = true
        blocked.isSummaryActionBlocked = false
        precondition(State.make(blocked).firstSlot == .button(.runSummary, isEnabled: true))
        var unavailable = done(.summary)
        unavailable.canRunSummary = false
        precondition(State.make(unavailable).firstSlot == .button(.runSummary, isEnabled: false))
    }

    private static func testHiddenOnlyForRecordingComparingAndKeyboard() {
        precondition(!State.isHidden(isRecording: false, isComparingCandidates: false))
        precondition(State.isHidden(isRecording: true, isComparingCandidates: false))
        precondition(State.isHidden(isRecording: false, isComparingCandidates: true))
        precondition(State.isHidden(isRecording: false, isComparingCandidates: false, isEditingWithKeyboard: true))
    }

    /// Whatever the input, Save and Delete are off during any work, Copy
    /// follows the open tab's content, and only the transcript tab has ✨.
    private static func testEveryCombinationKeepsTheFixedSlots() {
        let works: [NoteToolbarWork] = [.none, .waitingToTranscribe, .transcribing, .retranscribing, .cancelling, .postProcessing]
        for tab in [NoteToolbarTab.transcript, .summary] {
            for work in works {
                for making in [false, true] {
                    for hasSummaryTab in [false, true] {
                        let input = NoteToolbarInput(
                            tab: tab, work: work, canCancelWork: true, transcriptAction: .retry,
                            hasSummaryTab: hasSummaryTab, isMakingSummary: making, canRunSummary: true,
                            canCreateSummary: true, hasTranscriptToCopy: true, hasSummaryToCopy: true,
                            hasFilesToSave: true
                        )
                        let state = State.make(input)
                        let anyWork = work != .none || making
                        precondition(state.isSaveEnabled == !anyWork)
                        precondition(state.isDeleteEnabled == !anyWork)
                        switch tab {
                        case .transcript:
                            precondition(state.isCopyEnabled == (work == .none))
                        case .summary:
                            precondition(state.isCopyEnabled == !making)
                            precondition(state.createSummary == .none)
                            precondition(state.firstSlot != .none)
                        }
                    }
                }
            }
        }
    }

    /// A Mac toolbar button floating over the transcript's text view shows
    /// its help tag only with an AppKit view of its own behind it, as each
    /// button had before the toolbar was shared (#698).
    private static func testEachMacButtonHasItsOwnCursorViewForItsHelpTag() {
        let url = URL(fileURLWithPath: "Packages/QuillNoteUI/Sources/NoteFloatingToolbar.swift")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("NoteFloatingToolbar.swift not found; run from the repository root")
        }
        guard let start = source.range(of: "struct NoteToolbarIconButton"),
              let end = source.range(of: "struct NoteToolbarHint", range: start.upperBound..<source.endIndex)
        else { preconditionFailure("NoteToolbarIconButton not found") }
        let button = String(source[start.upperBound..<end.lowerBound])
        guard let help = button.range(of: ".help(label)"),
              let cursor = button.range(of: ".overrideCursor(.arrow)", range: help.upperBound..<button.endIndex)
        else { preconditionFailure("each toolbar button needs .overrideCursor(.arrow) with its .help (#698)") }
        let between = button[help.upperBound..<cursor.lowerBound]
        precondition(!between.contains("}\n}"), "the cursor view must stay on the button")
        precondition(button[cursor.upperBound...].contains("#endif"), "the cursor view is Mac only")
    }

    /// Every drawn button gets its own `CursorNSView`, besides any on the
    /// whole toolbar.
    @MainActor
    private static func testEachMacButtonGetsAnAppKitView() {
        var input = done(.transcript)
        input.hasSummaryTab = false
        input.canCreateSummary = true
        let state = State.make(input)
        // ↻, Copy, Save, ✨, Delete.
        let buttonCount = 5
        let toolbar = NoteFloatingToolbar(
            state: state,
            labels: NoteToolbarLabels(
                firstAction: { _ in "Retranscribe" },
                progress: "Working",
                copy: "Copy",
                copyUnavailable: "Nothing to copy",
                save: "Save",
                createSummary: "Create summary",
                delete: "Delete"
            ),
            actions: NoteToolbarActions(
                firstAction: { _ in }, copy: {}, save: {}, createSummary: {}, delete: {}
            ),
            opaqueBackground: .white
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: toolbar)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        func cursorViews(in view: NSView) -> [CursorNSView] {
            (view as? CursorNSView).map { [$0] } ?? view.subviews.flatMap(cursorViews(in:))
        }
        let views = cursorViews(in: host)
        precondition(views.count == buttonCount, "expected a cursor view per button, found \(views.count)")
        precondition(views.allSatisfy { $0.cursor == .arrow })
        precondition(views.allSatisfy { !$0.frame.isEmpty })
        window.close()
    }
}
