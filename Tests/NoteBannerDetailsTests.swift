import QuillNoteUI

/// The banner's info button (#234): empty lines are dropped, and details
/// with nothing left to show give no button at all. An action is plain
/// unless it asks to be prominent (the comparison bar's "Keep Current").
/// The Keep/Use comparison's shared layout and look sit beside it (#697).
@main
struct NoteBannerDetailsTests {
    static func main() {
        testEmptyLinesAreDropped()
        testDetailsWithNothingToShowAreEmpty()
        testActionsArePlainByDefault()
        testBannersShowNoInfoButtonForEmptyDetails()
        testComparisonLayoutFollowsTheWindow()
        testComparisonCardsKeepTheMacLook()
        print("NoteBannerDetailsTests passed")
    }

    private static func testEmptyLinesAreDropped() {
        let details = NoteBannerDetails(label: "Issue Details", lines: ["", "Try again later.", ""])
        precondition(details.lines == ["Try again later."])
        precondition(!details.isEmpty)
    }

    private static func testDetailsWithNothingToShowAreEmpty() {
        precondition(NoteBannerDetails(label: "Issue Details", lines: ["", ""]).isEmpty)
        let rowsOnly = NoteBannerDetails(
            label: "Issue Details",
            lines: [],
            rows: [NoteBannerDetails.Row(label: "Code", value: "summary-timeout")]
        )
        precondition(!rowsOnly.isEmpty)
    }

    /// Blank lines and rows with nothing in them are dropped, and details
    /// left empty give no info button (`NoteBanner` uses `shown`).
    private static func testBannersShowNoInfoButtonForEmptyDetails() {
        let blank = NoteBannerDetails(
            label: "Issue Details",
            lines: [" ", "\n"],
            rows: [NoteBannerDetails.Row(label: "Code", value: " ")]
        )
        precondition(blank.isEmpty)
        precondition(NoteBannerDetails.shown(blank) == nil)
        precondition(NoteBannerDetails.shown(nil) == nil)
        precondition(NoteBannerDetails.shown(NoteBannerDetails(label: "Issue Details", lines: ["Retry."])) != nil)
    }

    private static func testActionsArePlainByDefault() {
        precondition(!NoteBannerAction(title: "Show Summary", perform: {}).isProminent)
        precondition(NoteBannerAction(title: "Keep Current", isProminent: true, perform: {}).isProminent)
    }

    /// Decisions c1 and c5: side by side unless the window is compact,
    /// where the new side shows first.
    private static func testComparisonLayoutFollowsTheWindow() {
        precondition(NoteComparisonLayout(windowClass: .compact) == .segmented)
        precondition(NoteComparisonLayout(windowClass: .regular) == .sideBySide)
        precondition(NoteComparisonLayout(windowClass: .wide) == .sideBySide)
        precondition(NoteComparisonLayout.firstShownSide == .candidate)
    }

    /// The values both apps drew by hand before.
    private static func testComparisonCardsKeepTheMacLook() {
        precondition(NoteComparisonCardStyle.padding == 16 && NoteComparisonCardStyle.cornerRadius == 10)
        precondition(NoteComparisonCardStyle.fillOpacity(.current) == 0.035 && NoteComparisonCardStyle.fillOpacity(.candidate) == 0)
        precondition(NoteComparisonCardStyle.strokeOpacity(.current) == 0.1 && NoteComparisonCardStyle.strokeWidth(.current) == 0.5)
        precondition(NoteComparisonCardStyle.strokeOpacity(.candidate) == 0.55 && NoteComparisonCardStyle.strokeWidth(.candidate) == 1.5)
        precondition(NoteComparisonCardStyle.tagFillOpacity(.current) == 0.07 && NoteComparisonCardStyle.tagFillOpacity(.candidate) == 0.14)
        precondition(NoteComparisonCopy.transcript.tag(.candidate) == "New Transcript")
        precondition(NoteComparisonCopy.summary.tag(.current) == "Current Summary")
    }
}
