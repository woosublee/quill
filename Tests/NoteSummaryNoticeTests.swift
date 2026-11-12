import Foundation
import QuillNoteSyncCore

/// The saved summary's notices, shared by the Mac and the iPhone (#697).
/// The order, images, tints, copy keys, raw values (part of the Mac's saved
/// dismissal keys), and synced dismissals are pinned to what both apps
/// showed before the table moved here.
@main
struct NoteSummaryNoticeTests {
    static func main() {
        testCalendarTitleSuggestionDismissal()
        precondition(NoteSummaryNotice.allCases.map(\.rawValue) == [
            "unchanged", "failure", "stale", "unverifiedEvidence", "featureDisabled", "modelUnavailable"
        ])

        let all = NoteSummaryNotice.notices(
            hasSummary: true, showsUnchanged: true, hasCurrentFailure: true,
            isStale: true, isUnverifiedEvidence: true, setting: .featureDisabled
        )
        precondition(all == [.unchanged, .failure, .stale, .unverifiedEvidence, .featureDisabled])
        let model = NoteSummaryNotice.notices(
            hasSummary: true, showsUnchanged: false, hasCurrentFailure: false,
            isStale: false, isUnverifiedEvidence: false, setting: .modelUnavailable
        )
        precondition(model == [.modelUnavailable])
        let none = NoteSummaryNotice.notices(
            hasSummary: false, showsUnchanged: true, hasCurrentFailure: true,
            isStale: true, isUnverifiedEvidence: true, setting: .featureDisabled
        )
        precondition(none.isEmpty, "no saved summary, no notices")
        // Decision s2: "View Models" on the setting notices, on both apps.
        for notice in NoteSummaryNotice.allCases {
            let expected: NoteSummaryNotice.Action? = [.featureDisabled, .modelUnavailable].contains(notice) ? .openModels : nil
            precondition(notice.action == expected, "\(notice)")
        }
        precondition(NoteSummaryNotice.Action.openModels.titleKey == "View Models")
        precondition(NoteSummaryNotice.notices(
            hasSummary: true, showsUnchanged: false, hasCurrentFailure: false,
            isStale: false, isUnverifiedEvidence: false, setting: .ready
        ).isEmpty)

        let images = NoteSummaryNotice.allCases.map(\.systemImage)
        precondition(images == [
            "info.circle", "exclamationmark.triangle.fill", "exclamationmark.triangle.fill",
            "exclamationmark.triangle.fill", "pause.circle", "exclamationmark.circle"
        ])
        precondition(NoteSummaryNotice.allCases.map(\.tint) == [
            .secondary, .warning, .warning, .warning, .secondary, .secondary
        ])

        precondition(NoteSummaryNotice.failure.titleKey == nil && NoteSummaryNotice.failure.detailKey == nil)
        precondition(NoteSummaryNotice.unchanged.titleKey == "The new summary is the same as the current one.")
        precondition(NoteSummaryNotice.unchanged.detailKey == "The summary text didn't change.")
        precondition(NoteSummaryNotice.stale.titleKey == "Transcript changed after this summary was generated.")
        precondition(NoteSummaryNotice.stale.detailKey == "Regenerate to align the draft with the current transcript.")
        precondition(NoteSummaryNotice.unverifiedEvidence.titleKey == "Some evidence could not be verified.")
        precondition(NoteSummaryNotice.unverifiedEvidence.detailKey == "Review the summary before sharing it.")
        precondition(NoteSummaryNotice.featureDisabled.titleKey == "Meeting Summary is off")
        precondition(NoteSummaryNotice.featureDisabled.detailKey
            == "This saved summary is still available. Turn the feature on to regenerate it.")
        precondition(NoteSummaryNotice.modelUnavailable.titleKey == "Summary model is unavailable.")
        precondition(NoteSummaryNotice.modelUnavailable.detailKey
            == "This saved summary remains available for review and copying.")

        let attempt = Date(timeIntervalSince1970: 1_800_000_000)
        let made = Date(timeIntervalSince1970: 1_800_000_500)
        func synced(_ notice: NoteSummaryNotice) -> NoteNoticeDismissals.Notice? {
            notice.syncedDismissal(failedAttemptAt: attempt, sourceFingerprint: "abc", summaryGeneratedAt: made)
        }
        precondition(synced(.unchanged) == nil, "the same-summary notice syncs as its own marker")
        precondition(synced(.failure) == .summaryFailure(attemptAt: attempt))
        precondition(synced(.stale) == .summaryStale(sourceFingerprint: "abc"))
        precondition(synced(.unverifiedEvidence) == .summaryUnverifiedEvidence(generatedAt: made))
        precondition(synced(.featureDisabled) == .summaryFeatureDisabled(generatedAt: made))
        precondition(synced(.modelUnavailable) == .summaryModelUnavailable(generatedAt: made))
        for notice in NoteSummaryNotice.allCases {
            precondition(
                notice.syncedDismissal(failedAttemptAt: nil, sourceFingerprint: nil, summaryGeneratedAt: nil) == nil,
                "no condition, no synced dismissal"
            )
        }
        print("NoteSummaryNoticeTests passed")
    }

    // #832: closing a calendar suggestion syncs for that event and title,
    // so another event, or the same one renamed, suggests again.
    private static func testCalendarTitleSuggestionDismissal() {
        let notice = NoteNoticeDismissals.Notice.calendarTitleSuggestion(
            calendarID: "calendar", eventID: "event", title: "Weekly sync"
        )
        precondition(notice.key == "calendar.titleSuggestion")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        guard let dismissed = NoteNoticeDismissals().dismissing(notice, at: at) else {
            preconditionFailure("closing the suggestion records it")
        }
        precondition(dismissed.isDismissed(notice))
        precondition(!dismissed.isDismissed(.calendarTitleSuggestion(
            calendarID: "calendar", eventID: "other", title: "Weekly sync"
        )), "another event suggests again")
        precondition(!dismissed.isDismissed(.calendarTitleSuggestion(
            calendarID: "calendar", eventID: "event", title: "Weekly sync (moved)"
        )), "a renamed event suggests again")
        let decoded = NoteNoticeDismissals.decode(dismissed.value)
        precondition(decoded.isDismissed(notice), "the dismissal survives its synced value")
    }
}
