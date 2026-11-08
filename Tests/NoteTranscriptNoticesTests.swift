import Foundation
import QuillNoteCore

/// The notices above a note's transcript, shared by the Mac and the iPhone
/// (#697): which show, how they fold behind "+1", and the owner's decisions
/// n1-n3 (one grey banner style, none while work runs, the Mac's hide rule).
@main
struct NoteTranscriptNoticesTests {
    static func main() {
        func group(
            same: Bool = false,
            pp: NoteTranscriptNotice.PostProcessing? = nil,
            blank: Bool = false,
            nothingDismissed: Bool = false,
            warningDismissed: Bool = false,
            working: Bool = false
        ) -> NoteTranscriptNoticeGroup {
            NoteTranscriptNoticeGroup(
                showsSameAsCurrent: same,
                postProcessing: pp,
                isDisplayedTranscriptBlank: blank,
                isNothingToCleanUpDismissed: nothingDismissed,
                isWarningDismissed: warningDismissed,
                isWorkRunning: working
            )
        }

        precondition(group().notices.isEmpty)
        precondition(group(pp: .nothingToCleanUp).notices == [.nothingToCleanUp])
        precondition(group(pp: .warning).notices == [.warning])

        // "Nothing to clean up" points at the original transcript.
        precondition(group(pp: .nothingToCleanUp, blank: true).notices.isEmpty)
        precondition(group(pp: .warning, blank: true).notices == [.warning], "a warning stays over a blank transcript")

        // n3: dismissed on any device, or the warning dismissed, hides it.
        precondition(group(pp: .nothingToCleanUp, nothingDismissed: true).notices.isEmpty)
        precondition(group(pp: .nothingToCleanUp, warningDismissed: true).notices.isEmpty)
        precondition(group(pp: .warning, warningDismissed: true).notices.isEmpty)
        precondition(group(pp: .warning, nothingDismissed: true).notices == [.warning])

        // n2: nothing shows while a retranscription or cleanup runs.
        precondition(group(same: true, pp: .warning, working: true).notices.isEmpty)
        precondition(group(pp: .nothingToCleanUp, working: true).notices.isEmpty)

        // "+1": the same-result notice leads and folds the rest.
        let both = group(same: true, pp: .warning)
        precondition(both.notices == [.sameAsCurrent, .warning])
        precondition(both.folds && both.hiddenCount == 1)
        precondition(both.shown(isExpanded: false) == [.sameAsCurrent])
        precondition(both.shown(isExpanded: true) == [.sameAsCurrent, .warning])
        let sameOnly = group(same: true)
        precondition(!sameOnly.folds && sameOnly.hiddenCount == nil && sameOnly.shown(isExpanded: false) == [.sameAsCurrent])
        let warningOnly = group(pp: .warning)
        precondition(!warningOnly.folds && warningOnly.shown(isExpanded: false) == [.warning], "without the lead nothing folds")

        // n1: both quiet notices are the grey info banner.
        precondition(NoteTranscriptNotice.sameAsCurrent.systemImage == "info.circle")
        precondition(NoteTranscriptNotice.nothingToCleanUp.systemImage == "info.circle")
        precondition(NoteTranscriptNotice.warning.systemImage == nil, "a warning draws as its issue's banner")
        precondition(NoteTranscriptNotice.sameAsCurrent.titleKey == "The new transcript is the same as the current one.")
        precondition(NoteTranscriptNotice.sameAsCurrent.detailKey == "The transcript text didn't change.")
        precondition(NoteTranscriptNotice.nothingToCleanUp.titleKey == "Nothing to clean up; showing the original transcript.")
        precondition(NoteTranscriptNotice.nothingToCleanUp.detailKey == nil)
        precondition(NoteTranscriptNotice.warning.titleKey == nil)
        precondition(NoteTranscriptNotice.allCopyKeys.count == 3)
        print("NoteTranscriptNoticesTests passed")
    }
}
