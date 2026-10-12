import Foundation

@main
struct TitleBarLayoutTests {
    static func main() {
        testDesignedTitleBarAddsNothing()
        testTallerTitleBarAddsTheDifference()
        testShorterTitleBarAddsNothing()
        print("TitleBarLayoutTests passed")
    }

    private static func testDesignedTitleBarAddsNothing() {
        precondition(TitleBarLayout.extraHeight(titleBarHeight: 52) == 0)
    }

    /// macOS 27's unified title bar.
    private static func testTallerTitleBarAddsTheDifference() {
        precondition(TitleBarLayout.extraHeight(titleBarHeight: 66) == 14)
    }

    /// Full screen or a title bar without a toolbar.
    private static func testShorterTitleBarAddsNothing() {
        precondition(TitleBarLayout.extraHeight(titleBarHeight: 28) == 0)
        precondition(TitleBarLayout.extraHeight(titleBarHeight: 0) == 0)
    }
}
