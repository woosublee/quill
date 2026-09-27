import AppKit
import CoreGraphics
import Foundation

@main
struct RecordingOverlayGeometryTests {
    static func main() throws {
        testTranscribingWidthFallsBackToCenteredWidthAfterNotchSideRecording()
        testTranscribingWidthKeepsExistingLockOnRepeatedTranscribingUpdate()
        testNotchSideLayoutPhaseEligibility()
        testTransientNoticeStacksBelowPersistentDegradedNotice()
        testNoticeAnchorUsesTargetFrameWhileOverlayAnimates()
        testLocalizedNoticeWidthUsesMeasuredText()
        testDegradedNoticeKeepsWiderAnchorWidth()
        testNSScreenNumberBridgesThroughNSNumber()
        testRecordingOverlayUsesSharedScreenGeometry()
        try testNotchSideOverlayAvoidsContainerAudioLevelAnimation()
        try testHostingViewsUseFixedIntrinsicContentSize()
        testOverlayAccessibilityAnnouncementMessages()
        try testOverlayAccessibilitySourceContract()
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
            phase: .feedback,
            hasNotchGeometry: true,
            hasErrorMessage: true
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

    private static func testTransientNoticeStacksBelowPersistentDegradedNotice() {
        let overlay = NSRect(x: 700, y: 900, width: 150, height: 38)
        let degraded = RecordingNoticeStackGeometry.anchoredFrame(
            below: overlay,
            width: 260,
            height: 34,
            gap: 6
        )
        let transientAnchor = RecordingNoticeStackGeometry.lowestVisibleFrame([
            overlay,
            degraded
        ])
        let transient = RecordingNoticeStackGeometry.anchoredFrame(
            below: transientAnchor!,
            width: 300,
            height: 30,
            gap: 6
        )

        assert(transient.maxY <= degraded.minY - 6)
        assert(transient.midX == degraded.midX)
    }

    private static func testNoticeAnchorUsesTargetFrameWhileOverlayAnimates() {
        let hiddenPresentationFrame = NSRect(
            x: 700,
            y: 982,
            width: 150,
            height: 38
        )
        let targetRecordingFrame = NSRect(
            x: 700,
            y: 906,
            width: 150,
            height: 76
        )

        assert(
            RecordingNoticeStackGeometry.overlayAnchorFrame(
                visibleFrame: hiddenPresentationFrame,
                targetFrame: targetRecordingFrame
            ) == targetRecordingFrame
        )
        assert(
            RecordingNoticeStackGeometry.overlayAnchorFrame(
                visibleFrame: hiddenPresentationFrame,
                targetFrame: .zero
            ) == hiddenPresentationFrame
        )
        assert(
            RecordingNoticeStackGeometry.overlayAnchorFrame(
                visibleFrame: nil,
                targetFrame: targetRecordingFrame
            ) == nil
        )
    }

    private static func testLocalizedNoticeWidthUsesMeasuredText() {
        let message = "시스템 오디오 없음 — 마이크만으로 녹음 중"
        let width = RecordingNoticeStackGeometry.fittedNoticeWidth(
            message: message,
            horizontalChromeWidth: 66,
            minimumWidth: 200,
            maximumWidth: 1_000
        )
        let characterCountEstimate = CGFloat(message.count) * 6.8 + 66
        let measuredTextWidth = (message as NSString).size(
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium)
            ]
        ).width

        assert(width == ceil(measuredTextWidth + 66))
        assert(width > characterCountEstimate)
    }

    private static func testDegradedNoticeKeepsWiderAnchorWidth() {
        let anchorWidth: CGFloat = 335
        let width = RecordingNoticeStackGeometry.degradedCaptureNoticeWidth(
            message: "마이크 없음 — 시스템 오디오만으로 녹음 중",
            anchorWidth: anchorWidth,
            maximumWidth: 1_000
        )

        assert(width == anchorWidth)
    }

    private static func testNSScreenNumberBridgesThroughNSNumber() {
        let deviceDescription: [NSDeviceDescriptionKey: Any] = [
            NSDeviceDescriptionKey("NSScreenNumber"): NSNumber(value: UInt32(42))
        ]

        assert(deviceDescription.displayID == 42)
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

    private static func testOverlayAccessibilityAnnouncementMessages() {
        let bundle = Bundle(path: FileManager.default.currentDirectoryPath)!
        func message(_ announcement: OverlayAccessibilityAnnouncement) -> String {
            announcement.message(language: "en", bundle: bundle)
        }

        assert(message(.transcribing) == "Transcribing...")
        assert(message(.done) == "Done")
        assert(message(.failed) == "Recording failed")

        // Errors are announced in full, even past the pill's truncation length.
        let longError = "Synthetic provider error " + String(repeating: "detail ", count: 40) + "end"
        assert(longError.count > 120)
        assert(message(.error(longError)) == longError)
        assert(message(.error("  Synthetic error\n")) == "Synthetic error")
        assert(message(.meetingStarting(title: " Synthetic Weekly Sync ")) == "Meeting starting: Synthetic Weekly Sync")

        assert(OverlayAccessibilityAnnouncement.error("x").priority == .high)
        assert(OverlayAccessibilityAnnouncement.failed.priority == .high)
        assert(OverlayAccessibilityAnnouncement.meetingStarting(title: "x").priority == .high)
        assert(OverlayAccessibilityAnnouncement.done.priority == .medium)
    }

    private static func testOverlayAccessibilitySourceContract() throws {
        let source = try String(contentsOfFile: "Sources/RecordingOverlay.swift", encoding: .utf8)
        let appState = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)

        // Announcements only run while VoiceOver is on and use the shared
        // announcement notification.
        assert(source.contains("guard NSWorkspace.shared.isVoiceOverEnabled else { return }"))
        assert(source.contains("notification: .announcementRequested"))

        // Phase changes and errors are announced; errors use the full message,
        // not the truncated copy shown in the pill.
        // Nothing is spoken when recording starts; it could be recorded.
        assert(!source.contains("case recordingStarted"))
        assert(source.contains("OverlayAccessibilityAnnouncer.announce(.transcribing)"))
        assert(source.contains("OverlayAccessibilityAnnouncer.announce(.failed)"))
        assert(source.contains("OverlayAccessibilityAnnouncer.announce(.error(message))"))
        assert(!source.contains("OverlayAccessibilityAnnouncer.announce(.error(truncated))"))
        assert(source.contains("OverlayAccessibilityAnnouncer.announce(.error(request.message))"))
        assert(appState.contains("OverlayAccessibilityAnnouncer.announce(.done)"))
        // Never announce transcript text.
        assert(!appState.contains("OverlayAccessibilityAnnouncer.announce(.error(completion"))
        assert(!appState.contains("OverlayAccessibilityAnnouncer.announce(.error(lastTranscript"))

        // On-screen timing and truncation stay unchanged.
        assert(source.contains("DispatchQueue.main.asyncAfter(deadline: .now() + 6.0)"))
        assert(source.contains("let truncated = Self.truncatedToastMessage(message)"))

        // Both Stop buttons are labeled; the failure mark is labeled.
        let stopLabelCount = source.components(separatedBy: ".accessibilityLabel(\"Stop recording\")").count - 1
        assert(stopLabelCount == 2, "Standard and notch Stop buttons must both be labeled")
        guard let failureStart = source.range(of: "struct FailureIndicatorView")?.lowerBound,
              let failureEnd = source.range(of: "struct ErrorOverlayView", range: failureStart..<source.endIndex)?.lowerBound else {
            assertionFailure("Expected FailureIndicatorView source block")
            return
        }
        assert(source[failureStart..<failureEnd].contains(".accessibilityLabel(\"Recording failed\")"))

        // Degraded notice dismiss stays hover-only visually, but is always
        // exposed to accessibility with a dismiss action.
        guard let noticeStart = source.range(of: "struct DegradedCaptureNoticeView")?.lowerBound,
              let noticeEnd = source.range(of: "private struct DegradedCaptureNoticeHoverCatcher", range: noticeStart..<source.endIndex)?.lowerBound else {
            assertionFailure("Expected DegradedCaptureNoticeView source block")
            return
        }
        let notice = source[noticeStart..<noticeEnd]
        assert(notice.contains(".opacity(isHovering ? 1 : 0)"))
        assert(notice.contains(".allowsHitTesting(isHovering)"))
        assert(!notice.contains(".accessibilityHidden(!isHovering)"))
        assert(notice.contains(".accessibilityLabel(\"Dismiss\")"))
        assert(notice.contains(".accessibilityAction(named: Text(\"Dismiss\"), onDismiss)"))

        // The input switcher is a pop-up button that opens the same menu.
        guard let catcherStart = source.range(of: "private struct InputMenuClickCatcher")?.lowerBound,
              let catcherEnd = source.range(of: "struct CommandModeIndicator", range: catcherStart..<source.endIndex)?.lowerBound else {
            assertionFailure("Expected InputMenuClickCatcher source block")
            return
        }
        let catcher = source[catcherStart..<catcherEnd]
        assert(catcher.contains(".popUpButton"))
        assert(catcher.contains("localizedCatalogString(\"Audio input\")"))
        assert(catcher.contains("override func accessibilityValue() -> Any?"))
        assert(catcher.contains("override func accessibilityPerformPress() -> Bool {\n            showInputMenu()"))
        assert(catcher.contains("override func accessibilityPerformShowMenu() -> Bool {\n            showInputMenu()"))
        assert(catcher.contains("override func mouseDown(with event: NSEvent) {\n            showInputMenu()"))
    }
}
