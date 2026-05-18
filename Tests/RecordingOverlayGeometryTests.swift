import AppKit
import CoreGraphics
import Foundation

@main
struct RecordingOverlayGeometryTests {
    static func main() throws {
        testTranscribingWidthFallsBackToCenteredWidthAfterNotchSideRecording()
        testTranscribingWidthKeepsExistingLockOnRepeatedTranscribingUpdate()
        testNotchSideLayoutPhaseEligibility()
        testRecordingOverlayUsesSharedScreenGeometry()
        try testNotchSideOverlayAvoidsContainerAudioLevelAnimation()
        try testHostingViewsUseFixedIntrinsicContentSize()
        print("RecordingOverlayGeometryTests passed")
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

    private static func testNotchSideLayoutPhaseEligibility() {
        assert(RecordingOverlayGeometry.usesNotchSideLayout(
            layout: .notchSides,
            phase: .initializing,
            hasNotchGeometry: true
        ))
        assert(RecordingOverlayGeometry.usesNotchSideLayout(
            layout: .notchSides,
            phase: .recording,
            hasNotchGeometry: true
        ))
        assert(RecordingOverlayGeometry.usesNotchSideLayout(
            layout: .notchSides,
            phase: .transcribing,
            hasNotchGeometry: true
        ))
        assert(RecordingOverlayGeometry.usesNotchSideLayout(
            layout: .notchSides,
            phase: .feedback,
            hasNotchGeometry: true
        ))
        assert(!RecordingOverlayGeometry.usesNotchSideLayout(
            layout: .notchSides,
            phase: .updateAvailable,
            hasNotchGeometry: true
        ))
        assert(!RecordingOverlayGeometry.usesNotchSideLayout(
            layout: .centered,
            phase: .recording,
            hasNotchGeometry: true
        ))
        assert(!RecordingOverlayGeometry.usesNotchSideLayout(
            layout: .notchSides,
            phase: .recording,
            hasNotchGeometry: false
        ))
    }

    private static func testRecordingOverlayUsesSharedScreenGeometry() {
        let notchGeometry = OverlayScreenGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            safeAreaInsets: NSEdgeInsets(top: 38, left: 0, bottom: 0, right: 0),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 682, height: 38),
            auxiliaryTopRightArea: CGRect(x: 830, y: 944, width: 682, height: 38)
        )

        assert(notchGeometry.hasTopSafeArea)
        assert(notchGeometry.hasNotchGeometry)
        assert(notchGeometry.notchOverlap == 38)
        assert(notchGeometry.notchWidth == 148)
        assert(notchGeometry.centeredTopFrame(width: 92, height: 76) == NSRect(x: 710, y: 906, width: 92, height: 76))
        assert(notchGeometry.notchSideGeometry(regionWidth: 92, panelHeight: 38, horizontalInset: 8)?.frame == NSRect(x: 590, y: 944, width: 332, height: 38))

        let safeAreaOnlyGeometry = OverlayScreenGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
            safeAreaInsets: NSEdgeInsets(top: 25, left: 0, bottom: 0, right: 0)
        )

        assert(safeAreaOnlyGeometry.hasTopSafeArea)
        assert(!safeAreaOnlyGeometry.hasNotchGeometry)
        assert(safeAreaOnlyGeometry.notchSideGeometry(regionWidth: 92, panelHeight: 38, horizontalInset: 8) == nil)
    }

    private static func testNotchSideOverlayAvoidsContainerAudioLevelAnimation() throws {
        let source = try String(contentsOfFile: "Sources/RecordingOverlay.swift", encoding: .utf8)
        guard let viewStart = source.range(of: "private struct NotchSideOverlayView")?.lowerBound,
              let nextView = source.range(of: "struct RecordingOverlayView", range: viewStart..<source.endIndex)?.lowerBound else {
            assertionFailure("Expected to find NotchSideOverlayView source block")
            return
        }

        let viewSource = source[viewStart..<nextView]
        assert(
            !viewSource.contains("value: state.audioLevel"),
            "NotchSideOverlayView must not animate the whole container for high-frequency audioLevel updates"
        )
    }

    private static func testHostingViewsUseFixedIntrinsicContentSize() throws {
        let sharedHostSource = try String(contentsOfFile: "Sources/FixedIntrinsicHostingView.swift", encoding: .utf8)
        let source = try String(contentsOfFile: "Sources/RecordingOverlay.swift", encoding: .utf8)
        assert(sharedHostSource.contains("final class FixedIntrinsicHostingView"))
        assert(sharedHostSource.contains("override var intrinsicContentSize"))
        assert(source.contains("FixedIntrinsicHostingView(rootView:"))
    }
}
