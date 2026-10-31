import AppKit
import Foundation
import SwiftUI
import QuillNoteUI
import QuillDesignTokens

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
    /// button had before the toolbar was shared (#698). That view, and the
    /// button's hit shape, are Mac only.
    private static func testEachMacButtonHasItsOwnCursorViewForItsHelpTag() {
        let url = URL(fileURLWithPath: "Packages/QuillNoteUI/Sources/NoteFloatingToolbar.swift")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("NoteFloatingToolbar.swift not found; run from the repository root")
        }
        guard let start = source.range(of: "struct NoteToolbarIconButton"),
              let end = source.range(of: "struct NoteToolbarHint", range: start.upperBound..<source.endIndex)
        else { preconditionFailure("NoteToolbarIconButton not found") }
        let button = String(source[start.upperBound..<end.lowerBound])
        let macBlocks = macOnlyBlocks(in: button)
        guard let help = button.range(of: ".help(label)") else { preconditionFailure("the button lost its .help") }
        precondition(macBlocks.contains { $0.contains(".help(label)") }, ".help is Mac only")
        let afterHelp = button[help.upperBound...]
        precondition(afterHelp.contains(".background(CursorView(cursor: .arrow"),
                     "each toolbar button needs its cursor view with its .help (#698)")
        precondition(macBlocks.contains { $0.contains(".background(CursorView(cursor: .arrow") },
                     "the button's cursor view must sit inside #if os(macOS)")
        precondition(macBlocks.contains { $0.contains(".contentShape(Circle())") && $0.contains(".allowsHitTesting(true)") },
                     "the button's Mac hit shape must sit inside #if os(macOS)")
    }

    /// The text of each `#if os(macOS)` branch, up to its `#else` or `#endif`.
    private static func macOnlyBlocks(in source: String) -> [String] {
        var blocks: [String] = []
        var current: [String]?
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "#if os(macOS)" {
                current = []
            } else if trimmed == "#else" || trimmed == "#endif" {
                if let block = current { blocks.append(block.joined(separator: "\n")) }
                current = nil
            } else {
                current?.append(String(line))
            }
        }
        return blocks
    }

    /// Every drawn button gets its own cursor view, besides the one the Mac
    /// puts on the whole toolbar.
    @MainActor
    private static func testEachMacButtonGetsAnAppKitView() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        var input = done(.transcript)
        input.hasSummaryTab = false
        input.canCreateSummary = true
        let state = State.make(input)
        let firstSlotButtons: Int
        switch state.firstSlot {
        case .none: firstSlotButtons = 0
        case .progress, .button: firstSlotButtons = 1
        }
        let summaryButtons = state.createSummary == .none ? 0 : 1
        // The first slot, Copy, Save, Create summary, and Delete.
        let buttonCount = firstSlotButtons + 2 + summaryButtons + 1
        precondition(buttonCount == 5, "the fixture should draw every slot")

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
        // As the Mac's note browser draws it.
        .overrideCursor(.arrow)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: toolbar)
        window.contentView = host

        func cursorViews(in view: NSView) -> [NSView] {
            let own = NSStringFromClass(type(of: view)).hasSuffix(".CursorNSView") ? [view] : []
            return own + view.subviews.flatMap(cursorViews(in:))
        }
        let buttonSize = QuillControlSize.noteToolbarButtonMac
        func buttonCursorViews() -> [NSView] {
            cursorViews(in: host).filter { $0.frame.width == buttonSize && $0.frame.height == buttonSize }
        }
        // SwiftUI can add the hosted views on a later pass; wait briefly.
        let deadline = Date().addingTimeInterval(2)
        host.layoutSubtreeIfNeeded()
        while buttonCursorViews().count < buttonCount, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            host.layoutSubtreeIfNeeded()
        }
        let found = buttonCursorViews().count
        precondition(found == buttonCount, "expected a cursor view per button, found \(found)")
        precondition(cursorViews(in: host).count == buttonCount + 1, "the toolbar-wide view is separate")
        window.close()
    }
}
