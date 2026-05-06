import Foundation
import UserNotifications

final class AppNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotificationManager()

    private let notificationCenter: UNUserNotificationCenter
    private var calendarReminderHandler: (() -> Void)?

    private override init() {
        notificationCenter = .current()
        super.init()
    }

    func install() {
        notificationCenter.delegate = self
    }

    func setCalendarReminderHandler(_ handler: @escaping () -> Void) {
        calendarReminderHandler = handler
    }

    func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            notificationCenter.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            notificationCenter.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    func canShowAlerts() async -> Bool {
        let settings = await notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await notificationCenter.add(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func pendingNotificationRequestIdentifiers() async -> [String] {
        await withCheckedContinuation { continuation in
            notificationCenter.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests.map(\.identifier))
            }
        }
    }

    func deliveredNotificationRequestIdentifiers() async -> [String] {
        await withCheckedContinuation { continuation in
            notificationCenter.getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications.map(\.request.identifier))
            }
        }
    }

    func sendImmediateNotification(title: String, body: String, sound: UNNotificationSound?) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        await sendImmediateNotification(request)
    }

    func sendImmediateNotification(_ request: UNNotificationRequest) async {
        guard await canShowAlerts() else { return }
        try? await add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if CalendarRecordingReminderScheduler.isCalendarReminderIdentifier(notification.request.identifier) {
            return [.banner, .sound]
        }
        return notification.request.content.sound == nil ? [.banner] : [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard CalendarRecordingReminderScheduler.isCalendarReminderIdentifier(response.notification.request.identifier) else {
            return
        }
        await MainActor.run {
            calendarReminderHandler?()
        }
    }
}
