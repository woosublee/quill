import Foundation
import QuillNoteCore
import QuillNoteSyncCore
import QuillUserIssueCore

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
        precondition(NoteTranscriptNotice.allCopyKeys.count == 5)

        // quill-universal-private#429: a failed retranscription shows after the
        // same-result notice and before the post-processing one, folds like
        // them, and hides while work runs.
        func failed(same: Bool = false, pp: NoteTranscriptNotice.PostProcessing? = nil, working: Bool = false) -> NoteTranscriptNoticeGroup {
            NoteTranscriptNoticeGroup(
                showsSameAsCurrent: same, postProcessing: pp, isDisplayedTranscriptBlank: false,
                isNothingToCleanUpDismissed: false, isWarningDismissed: false, isWorkRunning: working,
                showsRetranscriptionFailure: true
            )
        }
        precondition(failed().notices == [.retranscriptionFailed])
        precondition(failed(same: true, pp: .warning).notices == [.sameAsCurrent, .retranscriptionFailed, .warning])
        precondition(failed(working: true).notices.isEmpty)
        precondition(group().notices == [], "off by default for callers that don't pass it")
        precondition(NoteTranscriptNotice.retranscriptionFailed.systemImage == nil, "draws as a warning banner")
        precondition(NoteTranscriptNotice.retranscriptionFailed.titleKey == "Retranscription failed")
        precondition(NoteTranscriptNotice.retranscriptionFailed.detailKey == "The current transcript is unchanged.")

        // Which stored statuses are a failed retranscription: an issue marked
        // as a transcription retry over a transcript that isn't blank. An
        // unmarked error (a failed context capture on a good note) or a
        // warning (post-processing) isn't one, and a blank transcript is a
        // failed first transcription.
        let auth = QuillUserIssueRecord(code: .authenticationFailed).with(operation: .transcriptionRetry).persistedStatus
        let network = QuillUserIssueRecord(code: .networkUnavailable).with(operation: .transcriptionRetry).persistedStatus
        let unmarked = QuillUserIssueRecord(code: .authenticationFailed).persistedStatus
        let warning = QuillUserIssueRecord(code: .postProcessingFailed).persistedStatus
        precondition(NoteRetranscriptionFailure.issue(postProcessingStatus: auth, transcript: "Hello")?.code == .authenticationFailed)
        precondition(NoteRetranscriptionFailure.issue(postProcessingStatus: auth, transcript: " \n") == nil)
        precondition(NoteRetranscriptionFailure.issue(postProcessingStatus: unmarked, transcript: "Hello") == nil)
        precondition(NoteRetranscriptionFailure.issue(postProcessingStatus: warning, transcript: "Hello") == nil)
        precondition(NoteRetranscriptionFailure.issue(postProcessingStatus: "Post-processing disabled", transcript: "Hello") == nil)
        precondition(NoteRetranscriptionFailure.opensProviderSettings(QuillUserIssueRecord(code: .authenticationFailed)))
        precondition(NoteRetranscriptionFailure.opensProviderSettings(QuillUserIssueRecord(code: .quotaExceeded)))
        precondition(!NoteRetranscriptionFailure.opensProviderSettings(
            NoteRetranscriptionFailure.issue(postProcessingStatus: network, transcript: "Hello")!
        ))
        // The mark survives the stored status and doesn't change the code,
        // severity, or recovery.
        let marked = QuillUserIssueRecord(code: .authenticationFailed, context: QuillUserIssueContext(modelID: "m"))
            .with(operation: .transcriptionRetry)
        precondition(marked.code == .authenticationFailed && marked.severity == .error && marked.context.modelID == "m")
        precondition(marked.recoveryAction == .openProviderSettings)

        // Its dismissal syncs under its own key, for the status: a new
        // failure (another status) shows again.
        let dismissal = NoteNoticeDismissals.Notice.retranscriptionFailure(status: auth)
        precondition(dismissal.key == NoteNoticeDismissals.retranscriptionFailure)
        precondition(!dismissal.key.hasPrefix(NoteNoticeDismissals.postProcessingWarningPrefix))
        let dismissed = NoteNoticeDismissals().dismissing(dismissal, at: Date(timeIntervalSince1970: 1))!
        precondition(dismissed.isDismissed(dismissal))
        precondition(!dismissed.isDismissed(.retranscriptionFailure(status: network)))
        print("NoteTranscriptNoticesTests passed")
    }
}
