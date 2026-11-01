import QuillNoteUI

/// The banner's info button (#234): empty lines are dropped, and details
/// with nothing left to show give no button at all. An action is plain
/// unless it asks to be prominent (the comparison bar's "Keep Current").
@main
struct NoteBannerDetailsTests {
    static func main() {
        testEmptyLinesAreDropped()
        testDetailsWithNothingToShowAreEmpty()
        testActionsArePlainByDefault()
        testBannersShowNoInfoButtonForEmptyDetails()
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
}
