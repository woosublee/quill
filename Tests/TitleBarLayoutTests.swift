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
        assert(TitleBarLayout.extraHeight(titleBarHeight: 52) == 0)
    }

    /// macOS 27's unified title bar.
    private static func testTallerTitleBarAddsTheDifference() {
        assert(TitleBarLayout.extraHeight(titleBarHeight: 66) == 14)
    }

    /// Full screen or a title bar without a toolbar.
    private static func testShorterTitleBarAddsNothing() {
        assert(TitleBarLayout.extraHeight(titleBarHeight: 28) == 0)
        assert(TitleBarLayout.extraHeight(titleBarHeight: 0) == 0)
    }
}
