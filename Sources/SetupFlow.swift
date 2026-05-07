import UserNotifications

enum SetupFlow {
    static let localOnlySkipButtonTitle = "Skip"

    struct LocalOnlySkipState: Equatable {
        let useLocalTranscription: Bool
        let localTranscriptionModelID: String
        let disablePostProcessing: Bool
        let disableContextCapture: Bool
        let realtimeStreamingEnabled: Bool
        let isCommandModeEnabled: Bool
    }

    static func localOnlySkipState() -> LocalOnlySkipState {
        LocalOnlySkipState(
            useLocalTranscription: true,
            localTranscriptionModelID: TranscriptionModel.default.id,
            disablePostProcessing: true,
            disableContextCapture: true,
            realtimeStreamingEnabled: false,
            isCommandModeEnabled: false
        )
    }

    static func isNotificationAuthorizationGranted(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional
    }

    static func notificationPermissionActionTitle(for status: UNAuthorizationStatus) -> String {
        status == .denied ? "Open Settings" : "Grant Access"
    }
}
