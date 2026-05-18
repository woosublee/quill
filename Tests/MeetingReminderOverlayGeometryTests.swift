import AppKit
import CoreGraphics
import Foundation

@main
struct MeetingReminderOverlayGeometryTests {
    static func main() async throws {
        testDefaultSize()
        testUsesCompactWidthWhenScreenAllows()
        testClampsToScreenMargins()
        testIdleContextUsesDefaultVariant()
        testRecordingNotchSidesUsesNotchSideVariant()
        testProcessingKeepsNotchSideVariant()
        testRecordingCenterWithNotchUsesNotchCenterVariant()
        testRecordingCenterWithoutNotchUsesCenterVariant()
        testNotchSideWidthMatchesRecordingOverlayGeometry()
        testContextualSizesMatchFinalDesign()
        testFrameUsesSharedScreenGeometryForUpdatedFrames()
        testFrameUsesSharedNotchSideGeometryWidth()
        try testMeetingReminderUsesSharedScreenGeometry()
        try testMeetingReminderObservesScreenParameterChanges()
        try testMeetingReminderKeepsPersistentAnimationHost()
        try testMeetingReminderDefersNextReminderWhileHiding()
        try testHostingViewsUseFixedIntrinsicContentSize()
        await testPresenterFailureWhenScreenUnavailableFallsBack()
        print("MeetingReminderOverlayGeometryTests passed")
    }

    private static func testDefaultSize() {
        assert(MeetingReminderOverlayGeometry.defaultSize == CGSize(width: 336, height: 92))
    }

    private static func testUsesCompactWidthWhenScreenAllows() {
        let size = MeetingReminderOverlayGeometry.size(forScreenWidth: 1_440)
        assert(size == CGSize(width: 336, height: 92))
    }

    private static func testClampsToScreenMargins() {
        let size = MeetingReminderOverlayGeometry.size(forScreenWidth: 300)
        assert(size == CGSize(width: 280, height: 92))
    }

    private static func testIdleContextUsesDefaultVariant() {
        let variant = MeetingReminderOverlayGeometry.variant(
            for: MeetingReminderOverlayContext(phase: .idle, layout: .notchSides),
            hasNotchGeometry: true
        )
        assert(variant == .defaultReminder)
    }

    private static func testRecordingNotchSidesUsesNotchSideVariant() {
        let variant = MeetingReminderOverlayGeometry.variant(
            for: MeetingReminderOverlayContext(phase: .recording, layout: .notchSides),
            hasNotchGeometry: true
        )
        assert(variant == .notchSidesRecording)
    }

    private static func testProcessingKeepsNotchSideVariant() {
        let variant = MeetingReminderOverlayGeometry.variant(
            for: MeetingReminderOverlayContext(phase: .processing, layout: .notchSides),
            hasNotchGeometry: true
        )
        assert(variant == .notchSidesProcessing)
    }

    private static func testRecordingCenterWithNotchUsesNotchCenterVariant() {
        let variant = MeetingReminderOverlayGeometry.variant(
            for: MeetingReminderOverlayContext(phase: .recording, layout: .centerDropdownFill),
            hasNotchGeometry: true
        )
        assert(variant == .notchCenterRecording)
    }

    private static func testRecordingCenterWithoutNotchUsesCenterVariant() {
        let variant = MeetingReminderOverlayGeometry.variant(
            for: MeetingReminderOverlayContext(phase: .recording, layout: .centerDropdownFill),
            hasNotchGeometry: false
        )
        assert(variant == .centerRecording)
    }

    private static func testNotchSideWidthMatchesRecordingOverlayGeometry() {
        let geometry = OverlayScreenGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            safeAreaInsets: NSEdgeInsets(top: 38, left: 0, bottom: 0, right: 0),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 682, height: 38),
            auxiliaryTopRightArea: CGRect(x: 830, y: 944, width: 682, height: 38)
        )
        let recordingGeometry = geometry.notchSideGeometry(
            regionWidth: 92,
            panelHeight: 92,
            horizontalInset: 8
        )

        assert(recordingGeometry != nil)
        let reminderWidth = MeetingReminderOverlayGeometry.notchSideWidth(for: geometry)

        assert(reminderWidth == recordingGeometry?.frame.width)
        assert(MeetingReminderOverlayGeometry.size(for: .notchSidesRecording, screenWidth: 1512, notchSideWidth: reminderWidth) == CGSize(width: reminderWidth!, height: 92))
        assert(MeetingReminderOverlayGeometry.size(for: .notchSidesProcessing, screenWidth: 1512, notchSideWidth: reminderWidth) == CGSize(width: reminderWidth!, height: 92))
    }

    private static func testContextualSizesMatchFinalDesign() {
        assert(MeetingReminderOverlayGeometry.size(for: .defaultReminder, screenWidth: 1_440, notchSideWidth: nil) == CGSize(width: 336, height: 92))
        assert(MeetingReminderOverlayGeometry.size(for: .defaultReminder, screenWidth: 1_440, notchSideWidth: 404) == CGSize(width: 404, height: 92))
        assert(MeetingReminderOverlayGeometry.size(for: .notchSidesRecording, screenWidth: 1_440, notchSideWidth: 330) == CGSize(width: 330, height: 92))
        assert(MeetingReminderOverlayGeometry.size(for: .notchSidesProcessing, screenWidth: 1_440, notchSideWidth: 330) == CGSize(width: 330, height: 92))
        assert(MeetingReminderOverlayGeometry.size(for: .notchCenterRecording, screenWidth: 1_440, notchSideWidth: nil) == CGSize(width: 360, height: 112))
        assert(MeetingReminderOverlayGeometry.size(for: .notchCenterProcessing, screenWidth: 1_440, notchSideWidth: nil) == CGSize(width: 360, height: 112))
        assert(MeetingReminderOverlayGeometry.size(for: .notchCenterRecording, screenWidth: 2_056, notchSideWidth: 404) == CGSize(width: 404, height: 112))
        assert(MeetingReminderOverlayGeometry.size(for: .notchCenterProcessing, screenWidth: 2_056, notchSideWidth: 404) == CGSize(width: 404, height: 112))
        assert(MeetingReminderOverlayGeometry.size(for: .centerRecording, screenWidth: 1_440, notchSideWidth: nil) == CGSize(width: 336, height: 92))
        assert(MeetingReminderOverlayGeometry.size(for: .centerProcessing, screenWidth: 1_440, notchSideWidth: nil) == CGSize(width: 336, height: 92))
    }

    private static func testFrameUsesSharedScreenGeometryForUpdatedFrames() {
        let context = MeetingReminderOverlayContext(phase: .idle, layout: .centerDropdownFill)
        let oldGeometry = OverlayScreenGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944)
        )
        let updatedGeometry = OverlayScreenGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1079)
        )

        let oldFrame = MeetingReminderOverlayGeometry.frame(for: oldGeometry, context: context)
        let updatedFrame = MeetingReminderOverlayGeometry.frame(for: updatedGeometry, context: context)

        assert(oldFrame.origin.x == 588)
        assert(oldFrame.origin.y == 890)
        assert(updatedFrame.origin.x == 696)
        assert(updatedFrame.origin.y == 1025)
    }

    private static func testFrameUsesSharedNotchSideGeometryWidth() {
        let context = MeetingReminderOverlayContext(phase: .recording, layout: .notchSides)
        let geometry = OverlayScreenGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            safeAreaInsets: NSEdgeInsets(top: 38, left: 0, bottom: 0, right: 0),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 600, height: 38),
            auxiliaryTopRightArea: CGRect(x: 830, y: 944, width: 682, height: 38)
        )

        let frame = MeetingReminderOverlayGeometry.frame(for: geometry, context: context)

        assert(frame.width == 414)
        assert(frame.origin.x == 508)
        assert(frame.origin.y == 890)
    }

    private static func testMeetingReminderUsesSharedScreenGeometry() throws {
        let source = try String(contentsOfFile: "Sources/MeetingReminderOverlay.swift", encoding: .utf8)
        assert(source.contains("OverlayScreenGeometry(screen: screen)"))
        assert(source.contains("static func frame(for geometry: OverlayScreenGeometry"))
        assert(source.contains("geometry.centeredTopFrame("))
        assert(source.contains("centerOverlayWidth: MeetingReminderOverlayGeometry.centerRecordingOverlayWidth(for: geometry)"))
    }

    private static func testMeetingReminderObservesScreenParameterChanges() throws {
        let source = try String(contentsOfFile: "Sources/MeetingReminderOverlay.swift", encoding: .utf8)
        assert(source.contains("private var screenParametersObserver: NSObjectProtocol?"))
        assert(source.contains("NSApplication.didChangeScreenParametersNotification"))
        assert(source.contains("handleScreenParametersChanged()"))
        assert(source.contains("refreshVisibleReminder(animated: false)"))
        assert(source.contains("NotificationCenter.default.removeObserver(screenParametersObserver)"))
    }

    private static func testMeetingReminderKeepsPersistentAnimationHost() throws {
        let source = try String(contentsOfFile: "Sources/MeetingReminderOverlay.swift", encoding: .utf8)
        assert(source.contains("private var contentContainer: FixedHostingContainer<AnyView>?"))
        assert(source.contains("if let panel, let viewModel, let contentContainer"))
        assert(source.contains("viewModel.update(displayData: displayData, frameSize: frame.size, animated: animated)"))
        assert(source.contains("contentContainer.setFixedContentSize(frame.size)"))
        assert(source.contains(".frame(width: viewModel.frameSize.width, height: viewModel.frameSize.height)"))
        assert(source.contains("transaction.disablesAnimations = true"))
        assert(source.contains("makeContentContainer("))
        assert(source.contains("resetPresentationHost()"))
        assert(source.contains("panel.contentView = nil"))
        assert(source.contains("viewModel = nil"))
        assert(source.contains("contentContainer = nil"))
        assert(source.contains("refreshVisibleReminder(animated: false)"))
    }

    private static func testMeetingReminderDefersNextReminderWhileHiding() throws {
        let source = try String(contentsOfFile: "Sources/MeetingReminderOverlay.swift", encoding: .utf8)
        assert(source.contains("private var isHidingVisibleReminder = false"))
        assert(source.contains("guard !isHidingVisibleReminder, visibleReminder == nil, !queue.isEmpty else { return true }"))
        assert(source.contains("isHidingVisibleReminder = true"))
        assert(source.contains("isHidingVisibleReminder = false"))
        assert(source.contains("resetPresentationHost()"))
        assert(source.contains("_ = showNextIfNeeded()"))
    }

    private static func testHostingViewsUseFixedIntrinsicContentSize() throws {
        let sharedHostSource = try String(contentsOfFile: "Sources/FixedIntrinsicHostingView.swift", encoding: .utf8)
        let source = try String(contentsOfFile: "Sources/MeetingReminderOverlay.swift", encoding: .utf8)
        assert(sharedHostSource.contains("final class FixedIntrinsicHostingView"))
        assert(sharedHostSource.contains("override var intrinsicContentSize"))
        assert(sharedHostSource.contains("sizingOptions = []"), "Fixed hosting views must opt out of window sizing")
        assert(sharedHostSource.contains("required dynamic init?(coder: NSCoder) {\n        return nil\n    }"), "Fixed hosting views must not support storyboard/XIB initialization")
        assert(sharedHostSource.contains("fatalError(\"init(rootView:) is not supported on FixedIntrinsicHostingView. Use init(rootView:size:) instead.\")"), "Fixed hosting views must require an explicit fixed size")
        assert(source.contains("FixedHostingContainer("), "Meeting reminders must host SwiftUI inside a plain NSView container")
        assert(source.contains(".frame(width: viewModel.frameSize.width, height: viewModel.frameSize.height)"), "Meeting reminders must give SwiftUI a fixed panel-sized root frame")
        assert(source.contains("centerOverlayWidth: MeetingReminderOverlayGeometry.centerRecordingOverlayWidth(for: geometry)"), "Center reminder layout must reserve the actual center recording overlay width")
        assert(!source.contains("panel.contentView = hostingView"), "Meeting reminders must not install NSHostingView directly as the panel content view")
    }

    @MainActor
    private static func testPresenterFailureWhenScreenUnavailableFallsBack() async {
        let manager = MeetingReminderOverlayManager(
            contextProvider: { MeetingReminderOverlayContext(phase: .idle, layout: .centerDropdownFill) },
            screenProvider: { nil }
        )
        let event = GoogleCalendarEvent(
            id: "meeting",
            calendarID: "calendar",
            title: "Meeting",
            start: Date(timeIntervalSince1970: 2_000),
            end: Date(timeIntervalSince1970: 2_500),
            isAllDay: false,
            attendees: []
        )
        let schedule = CalendarRecordingReminderSchedule(
            identifier: CalendarRecordingReminderScheduler.notificationIdentifier(for: event, leadMinutes: 10),
            fireDate: Date(timeIntervalSince1970: 1_400),
            event: event,
            delivery: .immediate
        )
        var didMarkPresented = false

        let didPresent = await manager.presentCalendarRecordingReminder(schedule) { _ in
            didMarkPresented = true
        }

        assert(!didPresent)
        assert(!didMarkPresented)
    }
}
