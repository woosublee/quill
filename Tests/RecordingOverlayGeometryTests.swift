import Foundation
import CoreGraphics

@main
struct RecordingOverlayGeometryTests {
    static func main() {
        testNotchSideContentStartsAtTopOfVisiblePill()
        testTranscribingWidthFallsBackToCenteredWidthAfterNotchSideRecording()
        testTranscribingWidthKeepsExistingLockOnRepeatedTranscribingUpdate()
        testCenteredFrameUsesUpdatedMainScreenGeometry()
        print("RecordingOverlayGeometryTests passed")
    }

    private static func testNotchSideContentStartsAtTopOfVisiblePill() {
        let geometry = RecordingOverlayGeometry.notchSideGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            leftArea: CGRect(x: 0, y: 944, width: 682, height: 38),
            rightArea: CGRect(x: 830, y: 944, width: 682, height: 38),
            regionWidth: 92,
            panelHeight: 38,
            horizontalInset: 8
        )

        assert(geometry != nil)
        assert(geometry?.frame.maxX == 922)
        assert(geometry?.frame.minX == 590)
        assert(geometry?.leftContentFrame.origin.x == 0)
        assert(geometry?.rightContentFrame.maxX == geometry?.frame.width)
        assert(geometry?.leftContentFrame.origin.y == 0)
        assert(geometry?.rightContentFrame.origin.y == 0)
        assert(geometry?.frame.height == 38)
    }

    private static func testTranscribingWidthFallsBackToCenteredWidthAfterNotchSideRecording() {
        let lockedWidth = RecordingOverlayGeometry.lockedTranscribingWidth(
            existingLockedWidth: nil,
            currentPanelWidth: 348,
            centeredTranscribingWidth: 148,
            wasNotchSideRecordingLayout: true
        )

        assert(lockedWidth == 148)
    }

    private static func testTranscribingWidthKeepsExistingLockOnRepeatedTranscribingUpdate() {
        let lockedWidth = RecordingOverlayGeometry.lockedTranscribingWidth(
            existingLockedWidth: 148,
            currentPanelWidth: 332,
            centeredTranscribingWidth: 148,
            wasNotchSideRecordingLayout: false
        )

        assert(lockedWidth == 148)
    }

    private static func testCenteredFrameUsesUpdatedMainScreenGeometry() {
        let oldFrame = RecordingOverlayGeometry.centeredFrame(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            width: 92,
            height: 76
        )
        let updatedFrame = RecordingOverlayGeometry.centeredFrame(
            screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            width: 92,
            height: 76
        )

        assert(oldFrame.origin.x == 710)
        assert(updatedFrame.origin.x == 818)
        assert(updatedFrame.origin.y == 1041)
    }
}
