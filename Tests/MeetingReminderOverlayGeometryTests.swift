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
        let recordingGeometry = RecordingOverlayGeometry.notchSideGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            leftArea: CGRect(x: 0, y: 944, width: 682, height: 38),
            rightArea: CGRect(x: 830, y: 944, width: 682, height: 38),
            regionWidth: 92,
            panelHeight: 38,
            horizontalInset: 8
        )

        assert(recordingGeometry != nil)
        let reminderWidth = MeetingReminderOverlayGeometry.notchSideWidth(
            leftAreaWidth: 682,
            rightAreaWidth: 682,
            screenWidth: 1512
        )

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

    private static func testHostingViewsUseFixedIntrinsicContentSize() throws {
        let sharedHostSource = try String(contentsOfFile: "Sources/FixedIntrinsicHostingView.swift", encoding: .utf8)
        let source = try String(contentsOfFile: "Sources/MeetingReminderOverlay.swift", encoding: .utf8)
        assert(sharedHostSource.contains("final class FixedIntrinsicHostingView"))
        assert(sharedHostSource.contains("override var intrinsicContentSize"))
        assert(sharedHostSource.contains("sizingOptions = []"), "Fixed hosting views must opt out of window sizing")
        assert(source.contains("FixedHostingContainer("), "Meeting reminders must host SwiftUI inside a plain NSView container")
        assert(source.contains("rootView: AnyView(rootView.frame("), "Meeting reminders must give SwiftUI a fixed panel-sized root frame")
        assert(source.contains("centerOverlayWidth: MeetingReminderOverlayGeometry.centerRecordingOverlayWidth(for: screen)"), "Center reminder layout must reserve the actual center recording overlay width")
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
