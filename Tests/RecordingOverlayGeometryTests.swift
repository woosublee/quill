import AppKit
import CoreGraphics
import Foundation
import SwiftUI

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
        testMotionHelperWithInjectedReduceMotion()
        testContrastHelperWithInjectedIncreaseContrast()
        try testOverlaysRespectReduceMotionSourceContract()
        testRecordingNoticeSeverityIconRule()
        testQuietDetectorShowsOnceAfterSilentWindow()
        testQuietDetectorStaysHiddenWhenSoundArrivesFirst()
        testQuietDetectorKeepsOriginalStartAcrossResume()
        testStarvationDetectorFlagsMissingBuffers()
        testStarvationDetectorSuspensionRestartsGraceWindow()
        testStarvationDetectorTreatsCounterResetAsProgress()
        testInputHintStatePrefersInputLostOverQuiet()
        testInputHintClassificationAndAnnouncement()
        try testInputHintStringsAreLocalized()
        try testRecordingNoticeSeveritySourceContract()
        try testRecordingInputHintAppStateSourceContract()
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

    /// #395: Reduce Motion is injected, never read from the live system setting.
    private static func testMotionHelperWithInjectedReduceMotion() {
        let base = Animation.spring(response: 0.28, dampingFraction: 0.8)
        precondition(QuillMotion.animation(base, reduceMotion: false) == base)
        precondition(QuillMotion.animation(base, reduceMotion: true) == nil)
        precondition(QuillMotion.animation(nil, reduceMotion: false) == nil)

        precondition(QuillMotion.animatesPanel(true, reduceMotion: false))
        precondition(!QuillMotion.animatesPanel(true, reduceMotion: true))
        precondition(!QuillMotion.animatesPanel(false, reduceMotion: false))
        precondition(!QuillMotion.animatesPanel(false, reduceMotion: true))
    }

    /// #395: with Increase Contrast off every value is unchanged; on, faint
    /// values strengthen and keep their order.
    private static func testContrastHelperWithInjectedIncreaseContrast() {
        for value in [0.0, 0.04, 0.35, 0.5, 0.55, 0.7, 0.85, 1.0] {
            precondition(QuillContrast.opacity(value, increased: false) == value)
            precondition(QuillContrast.fillOpacity(value, increased: false) == value)
            precondition(QuillContrast.opacity(value, increased: true) >= value)
            precondition(QuillContrast.fillOpacity(value, increased: true) >= value)
        }
        precondition(abs(QuillContrast.opacity(0.35, increased: true) - 0.675) < 0.0001)
        precondition(abs(QuillContrast.opacity(0.5, increased: true) - 0.75) < 0.0001)
        precondition(abs(QuillContrast.opacity(0.7, increased: true) - 0.85) < 0.0001)
        precondition(QuillContrast.opacity(1.0, increased: true) == 1.0)
        precondition(
            QuillContrast.opacity(0.5, increased: true) < QuillContrast.opacity(0.7, increased: true),
            "Inactive tags stay fainter than active tags"
        )
        precondition(abs(QuillContrast.fillOpacity(0.08, increased: true) - 0.16) < 0.0001)
        precondition(QuillContrast.fillOpacity(0.8, increased: true) == 1.0)

        precondition(QuillContrast.emphasis(.tertiary, increased: false) == .tertiary)
        precondition(QuillContrast.emphasis(.quaternary, increased: false) == .quaternary)
        precondition(QuillContrast.emphasis(.tertiary, increased: true) == .secondary)
        precondition(QuillContrast.emphasis(.quaternary, increased: true) == .secondary)
    }

    /// #395: each moving part of the recording and reminder overlays reads
    /// Reduce Motion, and the default animations are still present.
    private static func testOverlaysRespectReduceMotionSourceContract() throws {
        let source = try String(contentsOfFile: "Sources/RecordingOverlay.swift", encoding: .utf8)
        let reminder = try String(contentsOfFile: "Sources/MeetingReminderOverlay.swift", encoding: .utf8)

        func view(_ start: String, _ end: String) -> Substring {
            guard let lower = source.range(of: start)?.lowerBound,
                  let upper = source.range(of: end, range: lower..<source.endIndex)?.lowerBound else {
                preconditionFailure("Expected source block \(start)")
            }
            return source[lower..<upper]
        }

        let waveform = view("struct WaveformView: View", "struct CompactWaveformView")
        precondition(waveform.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"))
        precondition(waveform.contains("if showsActivityPulse && !reduceMotion {"))
        precondition(waveform.contains("TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false))"))

        let processing = view("struct ProcessingWaveformView: View", "private struct ProcessingPill")
        precondition(processing.contains("if reduceMotion {\n            ReducedMotionProcessingIndicator()"))
        precondition(processing.contains("Image(systemName: \"hourglass\")"))

        let indicator = view("struct ProcessingIndicatorView: View", "struct InitializingDotsView")
        precondition(indicator.contains("if showsExtendedSpinner && !reduceMotion {"))
        precondition(indicator.contains(".repeatForever(autoreverses: false)"))

        let dots = view("struct InitializingDotsView: View", "private struct NotchExtensionBackground")
        precondition(dots.contains("reduceMotion ? 0.6 : (activeDot == index ? 0.9 : 0.25)"))

        let notch = view("private struct NotchSideOverlayView", "struct RecordingOverlayView")
        let pill = view("struct RecordingOverlayView: View", "struct InputSwitchMenu")
        for block in [notch, pill] {
            precondition(block.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"))
            precondition(block.contains(".animation(phaseAnimation, value: state.phase)"))
            precondition(block.contains(
                "QuillMotion.animation(.spring(response: 0.28, dampingFraction: 0.8), reduceMotion: reduceMotion)"
            ))
            precondition(!block.contains(" .animation(.spring("))
        }

        // Panel slide-in and resize skip their motion under Reduce Motion.
        precondition(source.contains(
            "guard QuillMotion.animatesPanel(true, reduceMotion: QuillMotion.systemReduceMotion) else {"
        ))
        precondition(source.contains(
            "guard QuillMotion.animatesPanel(animated, reduceMotion: QuillMotion.systemReduceMotion) else {"
        ))
        let reminderPanelGuards = reminder.components(
            separatedBy: "guard QuillMotion.animatesPanel(animated, reduceMotion: QuillMotion.systemReduceMotion) else {"
        ).count - 1
        precondition(reminderPanelGuards == 2, "Reminder slide-in and resize both skip motion")
        precondition(reminder.contains("let hiddenFrame = QuillMotion.systemReduceMotion\n            ? currentFrame"))
        precondition(reminder.contains(
            "if QuillMotion.animatesPanel(animated, reduceMotion: QuillMotion.systemReduceMotion) {"
        ))
        precondition(reminder.contains(
            "QuillMotion.animation(meetingReminderContentTransitionAnimation, reduceMotion: reduceMotion)"
        ))
    }

    // MARK: - #214 microphone hints and notice severity

    private static func testRecordingNoticeSeverityIconRule() {
        assert(RecordingNoticeSeverity.info.symbolName == "info.circle.fill")
        assert(RecordingNoticeSeverity.warning.symbolName == "exclamationmark.triangle.fill")
        assert(RecordingNoticeSeverity.error.symbolName == "exclamationmark.circle.fill")
        // Each level has its own shape, so meaning never relies on color alone.
        let symbols = Set(RecordingNoticeSeverity.allCases.map(\.symbolName))
        assert(symbols.count == RecordingNoticeSeverity.allCases.count)
    }

    private static func testQuietDetectorShowsOnceAfterSilentWindow() {
        var detector = RecordingQuietInputDetector()
        detector.begin(at: 100)
        detector.observeLevel(0)
        // Exactly at the threshold still counts as silence.
        detector.observeLevel(RecordingQuietInputDetector.nearSilentLevel)
        assert(!detector.evaluate(at: 109.9))
        assert(detector.evaluate(at: 110))
        assert(detector.isShowing && detector.hasShown)

        // Sound hides it immediately.
        detector.observeLevel(0.2)
        assert(!detector.isShowing)
        // At most once per recording: silence again never re-shows it.
        detector.observeLevel(0)
        assert(!detector.evaluate(at: 200))
    }

    private static func testQuietDetectorStaysHiddenWhenSoundArrivesFirst() {
        var detector = RecordingQuietInputDetector()
        detector.begin(at: 0)
        detector.observeLevel(0.06)
        assert(!detector.evaluate(at: 30))
        assert(!detector.hasShown)

        var unstarted = RecordingQuietInputDetector()
        assert(!unstarted.evaluate(at: 1_000), "no hint before the recording begins")
    }

    private static func testQuietDetectorKeepsOriginalStartAcrossResume() {
        var detector = RecordingQuietInputDetector()
        detector.begin(at: 0)
        // Switching to another microphone gives the new input a fresh window,
        // so the hint doesn't appear a moment after the switch.
        detector.begin(at: 8)
        assert(!detector.evaluate(at: 10))
        assert(detector.evaluate(at: 18))
        // Once shown, it stays at most once per recording.
        detector.observeLevel(0.5)
        detector.begin(at: 30)
        assert(!detector.evaluate(at: 45))
    }

    private static func testStarvationDetectorFlagsMissingBuffers() {
        var detector = AudioBufferStarvationDetector()
        detector.rearm(at: 0)
        assert(!detector.observe(bufferCount: 40, isSuspended: false, at: 1))
        assert(!detector.observe(bufferCount: 80, isSuspended: false, at: 2))
        // Buffers stop at t=2.
        assert(!detector.observe(bufferCount: 80, isSuspended: false, at: 6.9))
        assert(detector.observe(bufferCount: 80, isSuspended: false, at: 7))
        assert(detector.observe(bufferCount: 80, isSuspended: false, at: 30), "stays visible while starved")
        // Buffers resume: the warning clears at once.
        assert(!detector.observe(bufferCount: 81, isSuspended: false, at: 31))

        // A path that never delivers after (re)arming also starves.
        var silent = AudioBufferStarvationDetector()
        silent.rearm(at: 0)
        assert(!silent.observe(bufferCount: 12, isSuspended: false, at: 1))
        assert(silent.observe(bufferCount: 12, isSuspended: false, at: 5))
    }

    private static func testStarvationDetectorSuspensionRestartsGraceWindow() {
        var detector = AudioBufferStarvationDetector()
        detector.rearm(at: 0)
        _ = detector.observe(bufferCount: 10, isSuspended: false, at: 1)
        // Capture interrupted (or input switching) for a long time: no warning.
        assert(!detector.observe(bufferCount: 10, isSuspended: true, at: 4))
        assert(!detector.observe(bufferCount: 10, isSuspended: true, at: 60))
        // After the interruption ends a fresh 5 s grace window applies.
        assert(!detector.observe(bufferCount: 10, isSuspended: false, at: 61))
        assert(!detector.observe(bufferCount: 10, isSuspended: false, at: 64.9))
        assert(detector.observe(bufferCount: 10, isSuspended: false, at: 65))
        // Suspending while starved hides the warning.
        assert(!detector.observe(bufferCount: 10, isSuspended: true, at: 66))
        assert(!detector.isStarved)

        // Rearming (wake from sleep) also restarts the window.
        var woke = AudioBufferStarvationDetector()
        woke.rearm(at: 0)
        _ = woke.observe(bufferCount: 3, isSuspended: false, at: 1)
        woke.rearm(at: 4)
        assert(!woke.observe(bufferCount: 3, isSuspended: false, at: 8))
        assert(woke.observe(bufferCount: 3, isSuspended: false, at: 9))
    }

    private static func testStarvationDetectorTreatsCounterResetAsProgress() {
        var detector = AudioBufferStarvationDetector()
        detector.rearm(at: 0)
        _ = detector.observe(bufferCount: 500, isSuspended: false, at: 1)
        // A restarted capture session resets its counter to a smaller value.
        assert(!detector.observe(bufferCount: 3, isSuspended: false, at: 5.5))
        assert(!detector.observe(bufferCount: 3, isSuspended: false, at: 10.4))
        assert(detector.observe(bufferCount: 3, isSuspended: false, at: 10.5))
    }

    private static func testInputHintStatePrefersInputLostOverQuiet() {
        var state = RecordingInputHintState(sessionID: UUID())
        state.resume(at: 0)
        assert(state.tick(now: 1, bufferCount: 1, isCaptureSuspended: false) == nil)
        // Buffers keep flowing but only silence arrives.
        var count = 1
        for second in 2...9 {
            count += 50
            assert(state.tick(now: TimeInterval(second), bufferCount: count, isCaptureSuspended: false) == nil)
        }
        assert(state.tick(now: 10, bufferCount: count + 50, isCaptureSuspended: false) == .quiet)
        count += 50
        // Buffers stop: the warning replaces the quiet hint.
        assert(state.tick(now: 15, bufferCount: count, isCaptureSuspended: false) == .inputLost)
        // Buffers resume with speech: everything clears.
        assert(state.tick(now: 16, bufferCount: count + 1, isCaptureSuspended: false) == .quiet)
        assert(state.observeLevel(0.3) == nil)
        assert(state.tick(now: 30, bufferCount: count + 2, isCaptureSuspended: false) == nil)

        // Resume after an input switch rearms starvation only.
        state.resume(at: 40)
        assert(state.tick(now: 44, bufferCount: 0, isCaptureSuspended: false) == nil)
        assert(state.tick(now: 45, bufferCount: 0, isCaptureSuspended: false) == .inputLost)
        state.rearmStarvation(at: 46)
        assert(state.currentHint == nil)
    }

    private static func testInputHintClassificationAndAnnouncement() {
        assert(RecordingInputHint.quiet.severity == .info)
        assert(RecordingInputHint.inputLost.severity == .warning)
        // The quiet hint is never spoken: the microphone may be live and the
        // phrase could end up in the recording.
        assert(!RecordingInputHint.quiet.isAnnouncedToVoiceOver)
        assert(RecordingInputHint.inputLost.isAnnouncedToVoiceOver)
        assert(RecordingQuietInputDetector.quietDuration == 10)
        assert(AudioBufferStarvationDetector.starvationTimeout == 5)
        assert(RecordingQuietInputDetector.nearSilentLevel > 0)
        assert(RecordingQuietInputDetector.nearSilentLevel < 0.054, "first smoothed speech buffer must exceed the threshold")
    }

    private static func testInputHintStringsAreLocalized() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "Resources/Localization/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = catalog?["strings"] as? [String: Any] ?? [:]
        let expectedKorean = [
            RecordingInputHint.quiet.messageKey: "말하고 계신가요? 마이크에서 소리가 들리지 않습니다.",
            RecordingInputHint.inputLost.messageKey: "마이크 입력이 끊겼습니다. 연결을 확인하세요."
        ]
        for (key, korean) in expectedKorean {
            let entry = strings[key] as? [String: Any]
            let localizations = entry?["localizations"] as? [String: Any]
            let ko = (localizations?["ko"] as? [String: Any])?["stringUnit"] as? [String: Any]
            let en = (localizations?["en"] as? [String: Any])?["stringUnit"] as? [String: Any]
            assert(ko?["value"] as? String == korean, "Missing ko for \(key)")
            assert(en?["value"] as? String == key, "Missing en for \(key)")
        }
    }

    private static func testRecordingNoticeSeveritySourceContract() throws {
        let source = try String(contentsOfFile: "Sources/RecordingOverlay.swift", encoding: .utf8)
        let appState = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)

        // Both notice views draw their icon from the shared severity rule.
        for viewName in ["struct RecordingNoticeToastView", "struct DegradedCaptureNoticeView"] {
            guard let start = source.range(of: viewName)?.lowerBound,
                  let end = source.range(of: "var body: some View", range: start..<source.endIndex)?.upperBound,
                  let bodyEnd = source.range(of: ".font(.system(size: 12, weight: .medium))", range: end..<source.endIndex)?.lowerBound else {
                assertionFailure("Expected \(viewName) source block")
                return
            }
            let block = source[start..<bodyEnd]
            assert(block.contains("let severity: RecordingNoticeSeverity"))
            assert(block.contains("Image(systemName: severity.symbolName)"))
            assert(block.contains("severity.tint(increasedContrast: colorSchemeContrast == .increased)"))
            assert(!block.contains("Color.red"), "\(viewName) must not hard-code the error color")
        }
        assert(source.contains("func showRecordingNotice(\n        _ message: String,\n        severity: RecordingNoticeSeverity,"))
        assert(source.contains("DegradedCaptureNoticeView(\n                message: request.message,\n                severity: .warning\n"))
        // The pill error and failure mark stay red.
        assert(source.contains("Image(systemName: \"exclamationmark.circle.fill\")\n                .font(.system(size: 13, weight: .bold))\n                .foregroundStyle(Color.red.opacity(0.92))"))
        assert(source.contains(".background(Circle().fill(Color.red.opacity(0.92)))"))

        // Every mid-recording notice call site states its severity.
        let callCount = appState.components(separatedBy: "overlayManager.showRecordingNotice(").count - 1
        let severityCount = appState.components(separatedBy: "overlayManager.showRecordingNotice(").dropFirst()
            .filter { $0.prefix(260).contains("severity: .") }.count
        assert(callCount == 4 && severityCount == callCount)
        assert(appState.contains("recordingInputAccessNotice(for: newInputID),\n                severity: .warning,"))
        assert(appState.contains("\"Failed to switch audio input. Saving the recorded audio.\"),\n            severity: .error,"))
        assert(appState.contains("message,\n            severity: .error,\n            reminderFrame"), "storage failure stops the recording")
        assert(appState.contains("providerDetail: error.localizedDescription\n        )\n        overlayManager.showRecordingNotice(\n            message,\n            severity: .warning,"))
    }

    private static func testRecordingInputHintAppStateSourceContract() throws {
        let source = try String(contentsOfFile: "Sources/RecordingOverlay.swift", encoding: .utf8)
        let appState = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let recorder = try String(contentsOfFile: "Sources/AudioRecorder.swift", encoding: .utf8)

        // The hint has its own persistent panel that never auto-dismisses and
        // never falls back to the pill error toast.
        guard let showStart = source.range(of: "func showRecordingHint(")?.lowerBound,
              let showEnd = source.range(of: "func hideRecordingHint()", range: showStart..<source.endIndex)?.lowerBound else {
            assertionFailure("Expected showRecordingHint")
            return
        }
        let show = source[showStart..<showEnd]
        assert(!show.contains("asyncAfter"))
        assert(!show.contains("showError("))
        assert(show.contains("if isNewPresentation, announce"))
        assert(source.contains("private var recordingHintWindow: NSPanel?"))
        assert(source.contains("visibleRecordingHintFrame"))
        assert(source.contains("recordingHintWindow?.orderOut(nil)"))

        // Hints only inform: the monitor never stops or cancels the recording.
        guard let monitorStart = appState.range(of: "// MARK: - Microphone hints (#214)")?.lowerBound,
              let monitorEnd = appState.range(of: "private func activeRecorderAudioLevelPublisher", range: monitorStart..<appState.endIndex)?.lowerBound else {
            assertionFailure("Expected microphone hint section")
            return
        }
        let monitor = appState[monitorStart..<monitorEnd]
        for forbidden in ["stopAndTranscribe", "cancelRecording", "handleRecordingFailure", "stopRecording", "cancelActiveAudioRecorder"] {
            assert(!monitor.contains(forbidden), "hint monitor must not call \(forbidden)")
        }
        assert(monitor.contains("ProcessInfo.processInfo.systemUptime"))
        assert(monitor.contains("NSWorkspace.didWakeNotification"))
        assert(monitor.contains("activeInputSwitchToken != nil"))
        assert(monitor.contains("audioRecorder.isCaptureSessionInterrupted"))
        assert(monitor.contains("guard !AudioInputDevice.isSystemAudio(inputID)"))
        assert(monitor.contains("currentMissingSource == .microphone"))
        // Resumed after each successful start or input switch; paused
        // everywhere the live level feed is torn down.
        assert(appState.components(separatedBy: "self.resumeRecordingInputHints(").count - 1 == 3)
        let levelTeardowns = appState.components(separatedBy: "audioLevelCancellable = nil\n").dropFirst()
        assert(!levelTeardowns.isEmpty)
        for teardown in levelTeardowns {
            assert(teardown.drop(while: { $0 == " " }).hasPrefix("pauseRecordingInputHints()"))
        }

        // The recorder exposes lock-backed liveness without blocking the session queue.
        assert(recorder.contains("var capturedBufferCount: Int {\n        _bufferCount.withLock { $0 }"))
        assert(recorder.contains("private let sessionInterruptedLock = OSAllocatedUnfairLock(initialState: false)"))
        assert(recorder.contains("var isCaptureSessionInterrupted: Bool {"))
    }
}
