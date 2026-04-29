import Foundation
import CoreGraphics

@main
struct RecordingOverlayGeometryTests {
    static func main() {
        testNotchSideContentStartsAtTopOfVisiblePill()
        testTranscribingWidthFallsBackToCenteredWidthAfterNotchSideRecording()
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
        assert(geometry?.leftContentFrame.origin.y == 0)
        assert(geometry?.rightContentFrame.origin.y == 0)
        assert(geometry?.frame.height == 38)
    }

    private static func testTranscribingWidthFallsBackToCenteredWidthAfterNotchSideRecording() {
        let lockedWidth = RecordingOverlayGeometry.lockedTranscribingWidth(
            currentPanelWidth: 348,
            centeredOverlayWidth: 148,
            wasNotchSideRecordingLayout: true
        )

        assert(lockedWidth == 148)
    }
}
