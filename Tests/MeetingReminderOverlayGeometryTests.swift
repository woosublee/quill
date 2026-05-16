import CoreGraphics
import Foundation

@main
struct MeetingReminderOverlayGeometryTests {
    static func main() async {
        testDefaultSize()
        testUsesCompactWidthWhenScreenAllows()
        testClampsToScreenMargins()
        testIdleContextUsesDefaultVariant()
        testRecordingNotchSidesUsesNotchSideVariant()
        testProcessingKeepsNotchSideVariant()
        testRecordingCenterWithNotchUsesNotchCenterVariant()
        testRecordingCenterWithoutNotchUsesCenterVariant()
        testContextualSizesMatchFinalDesign()
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

    private static func testContextualSizesMatchFinalDesign() {
        assert(MeetingReminderOverlayGeometry.size(for: .defaultReminder, screenWidth: 1_440, notchSideWidth: nil) == CGSize(width: 336, height: 92))
        assert(MeetingReminderOverlayGeometry.size(for: .notchSidesRecording, screenWidth: 1_440, notchSideWidth: 330) == CGSize(width: 330, height: 92))
        assert(MeetingReminderOverlayGeometry.size(for: .notchSidesProcessing, screenWidth: 1_440, notchSideWidth: 330) == CGSize(width: 330, height: 92))
        assert(MeetingReminderOverlayGeometry.size(for: .notchCenterRecording, screenWidth: 1_440, notchSideWidth: nil) == CGSize(width: 388, height: 112))
        assert(MeetingReminderOverlayGeometry.size(for: .notchCenterProcessing, screenWidth: 1_440, notchSideWidth: nil) == CGSize(width: 388, height: 112))
        assert(MeetingReminderOverlayGeometry.size(for: .centerRecording, screenWidth: 1_440, notchSideWidth: nil) == CGSize(width: 336, height: 92))
        assert(MeetingReminderOverlayGeometry.size(for: .centerProcessing, screenWidth: 1_440, notchSideWidth: nil) == CGSize(width: 336, height: 92))
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
