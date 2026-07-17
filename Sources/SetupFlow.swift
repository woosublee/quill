import UserNotifications

enum SetupFlow {
    static let localOnlySkipButtonTitle = String(localized: "Skip")

    struct LocalOnlySkipState: Equatable {
        let useLocalTranscription: Bool
        let localTranscriptionModelID: String
        let apiKey: String
        let transcriptionAPIKey: String
        let transcriptionAPIURL: String
        let disablePostProcessing: Bool
        let disableContextCapture: Bool
        let realtimeStreamingEnabled: Bool
        let isCommandModeEnabled: Bool
    }

    static func localOnlySkipState() -> LocalOnlySkipState {
        LocalOnlySkipState(
            useLocalTranscription: true,
            localTranscriptionModelID: "apple-speech",
            apiKey: "",
            transcriptionAPIKey: "",
            transcriptionAPIURL: "",
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
        status == .denied ? String(localized: "Open Settings") : String(localized: "Grant Access")
    }
}
