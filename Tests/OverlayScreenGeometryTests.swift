import AppKit
import CoreGraphics

@main
struct OverlayScreenGeometryTests {
    static func main() {
        testCenteredTopFrameUsesUpdatedScreenFrame()
        testNotchSideGeometryMatchesExistingRecordingExpectations()
        testNotchOverlapUsesVisibleFrameGap()
        testNoNotchGeometryWithoutAuxiliaryAreas()
        testNotchWidthUsesAuxiliaryAreas()
        print("OverlayScreenGeometryTests passed")
    }

    private static func testCenteredTopFrameUsesUpdatedScreenFrame() {
        let oldGeometry = OverlayScreenGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944)
        )
        let updatedGeometry = OverlayScreenGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1079)
        )

        let oldFrame = oldGeometry.centeredTopFrame(width: 92, height: 76)
        let updatedFrame = updatedGeometry.centeredTopFrame(width: 92, height: 76)

        assert(oldFrame.origin.x == 710)
        assert(oldFrame.origin.y == 906)
        assert(updatedFrame.origin.x == 818)
        assert(updatedFrame.origin.y == 1041)
    }

    private static func testNotchSideGeometryMatchesExistingRecordingExpectations() {
        let geometry = OverlayScreenGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            safeAreaInsets: NSEdgeInsets(top: 38, left: 0, bottom: 0, right: 0),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 682, height: 38),
            auxiliaryTopRightArea: CGRect(x: 830, y: 944, width: 682, height: 38)
        )

        let notchSideGeometry = geometry.notchSideGeometry(
            regionWidth: 92,
            panelHeight: 38,
            horizontalInset: 8
        )

        assert(notchSideGeometry != nil)
        assert(notchSideGeometry?.frame.maxX == 922)
        assert(notchSideGeometry?.frame.minX == 590)
        assert(notchSideGeometry?.frame.height == 38)
        assert(notchSideGeometry?.leftContentFrame.origin.x == 0)
        assert(notchSideGeometry?.leftContentFrame.origin.y == 0)
        assert(notchSideGeometry?.rightContentFrame.maxX == notchSideGeometry?.frame.width)
        assert(notchSideGeometry?.rightContentFrame.origin.y == 0)
    }

    private static func testNotchOverlapUsesVisibleFrameGap() {
        let geometry = OverlayScreenGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944)
        )

        assert(geometry.notchOverlap == 38)
    }

    private static func testNoNotchGeometryWithoutAuxiliaryAreas() {
        let geometry = OverlayScreenGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
            safeAreaInsets: NSEdgeInsets(top: 25, left: 0, bottom: 0, right: 0)
        )

        assert(geometry.hasTopSafeArea)
        assert(!geometry.hasNotchGeometry)
        assert(geometry.notchWidth == nil)
        assert(geometry.notchSideGeometry(regionWidth: 92, panelHeight: 38, horizontalInset: 8) == nil)
    }

    private static func testNotchWidthUsesAuxiliaryAreas() {
        let geometry = OverlayScreenGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            safeAreaInsets: NSEdgeInsets(top: 38, left: 0, bottom: 0, right: 0),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 682, height: 38),
            auxiliaryTopRightArea: CGRect(x: 830, y: 944, width: 682, height: 38)
        )

        assert(geometry.hasNotchGeometry)
        assert(geometry.notchWidth == 148)
    }
}
