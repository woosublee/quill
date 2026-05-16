import CoreGraphics

@main
struct MeetingReminderOverlayGeometryTests {
    static func main() {
        testDefaultSize()
        testUsesCompactWidthWhenScreenAllows()
        testClampsToScreenMargins()
        print("MeetingReminderOverlayGeometryTests passed")
    }

    private static func testDefaultSize() {
        assert(MeetingReminderOverlayGeometry.defaultSize == CGSize(width: 368, height: 112))
    }

    private static func testUsesCompactWidthWhenScreenAllows() {
        let size = MeetingReminderOverlayGeometry.size(forScreenWidth: 1_440)
        assert(size == CGSize(width: 368, height: 112))
    }

    private static func testClampsToScreenMargins() {
        let size = MeetingReminderOverlayGeometry.size(forScreenWidth: 340)
        assert(size == CGSize(width: 308, height: 112))
    }
}
