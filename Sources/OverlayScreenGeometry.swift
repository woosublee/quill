import AppKit
import CoreGraphics

struct OverlayScreenGeometry {
    struct NotchSideGeometry {
        let frame: NSRect
        let leftContentFrame: CGRect
        let rightContentFrame: CGRect
    }

    let screenFrame: CGRect
    let visibleFrame: CGRect
    let safeAreaInsets: NSEdgeInsets
    let auxiliaryTopLeftArea: CGRect?
    let auxiliaryTopRightArea: CGRect?

    init(screen: NSScreen) {
        self.init(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaInsets: screen.safeAreaInsets,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea
        )
    }

    init(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaInsets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
        auxiliaryTopLeftArea: CGRect? = nil,
        auxiliaryTopRightArea: CGRect? = nil
    ) {
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
        self.safeAreaInsets = safeAreaInsets
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
    }

    var hasTopSafeArea: Bool {
        safeAreaInsets.top > 0
    }

    var hasNotchGeometry: Bool {
        guard hasTopSafeArea,
              let leftArea = auxiliaryTopLeftArea,
              let rightArea = auxiliaryTopRightArea else { return false }
        return rightArea.minX > leftArea.maxX
    }

    var notchWidth: CGFloat? {
        guard hasNotchGeometry,
              let leftArea = auxiliaryTopLeftArea,
              let rightArea = auxiliaryTopRightArea else { return nil }
        return rightArea.minX - leftArea.maxX
    }

    var notchOverlap: CGFloat {
        max(0, screenFrame.maxY - visibleFrame.maxY)
    }

    /// Floor for the top overlay strip on a display that has no menu bar
    /// (e.g. a secondary display). Keeps the strip tall enough for its content.
    static let minMenuBarStripHeight: CGFloat = 24

    /// Height of the menu-bar strip on a display without a notch. The recording
    /// pill and the meeting-reminder overlay's top strip both use this value so
    /// they stay vertically aligned when shown together.
    var menuBarStripHeight: CGFloat {
        notchOverlap > 0 ? notchOverlap : Self.minMenuBarStripHeight
    }

    func centeredTopFrame(width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    func notchSideGeometry(
        regionWidth: CGFloat,
        panelHeight: CGFloat,
        horizontalInset: CGFloat
    ) -> NotchSideGeometry? {
        guard hasNotchGeometry,
              let leftArea = auxiliaryTopLeftArea,
              let rightArea = auxiliaryTopRightArea else { return nil }

        let availableSideWidth = min(leftArea.width, rightArea.width)
        let contentWidth = min(regionWidth, max(0, availableSideWidth - horizontalInset * 2))
        guard contentWidth >= 64 else { return nil }

        let panelMinX = leftArea.maxX - contentWidth
        let panelMaxX = rightArea.minX + contentWidth
        let frame = NSRect(
            x: panelMinX,
            y: screenFrame.maxY - panelHeight,
            width: panelMaxX - panelMinX,
            height: panelHeight
        )

        let leftFrame = CGRect(
            x: 0,
            y: 0,
            width: contentWidth,
            height: panelHeight
        )
        let rightFrame = CGRect(
            x: frame.width - contentWidth,
            y: 0,
            width: contentWidth,
            height: panelHeight
        )

        return NotchSideGeometry(frame: frame, leftContentFrame: leftFrame, rightContentFrame: rightFrame)
    }
}
