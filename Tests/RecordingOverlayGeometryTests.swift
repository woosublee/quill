import Foundation
import CoreGraphics

@main
struct RecordingOverlayGeometryTests {
    static func main() throws {
        testTranscribingWidthFallsBackToCenteredWidthAfterNotchSideRecording()
        testTranscribingWidthKeepsExistingLockOnRepeatedTranscribingUpdate()
        testNotchSideLayoutPhaseEligibility()
        try testRecordingOverlayUsesSharedScreenGeometry()
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

    private static func testRecordingOverlayUsesSharedScreenGeometry() throws {
        let source = try String(contentsOfFile: "Sources/RecordingOverlay.swift", encoding: .utf8)
        assert(source.contains("private typealias NotchSideGeometry = OverlayScreenGeometry.NotchSideGeometry"))
        assert(source.contains("OverlayScreenGeometry(screen: screen)"))
        assert(source.contains("screenGeometry?.notchSideGeometry("))
        assert(source.contains("screenGeometry?.hasTopSafeArea"))
        assert(source.contains("screenGeometry.centeredTopFrame("))
        assert(!source.contains("static func notchSideGeometry("))
        assert(!source.contains("static func centeredFrame("))
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
