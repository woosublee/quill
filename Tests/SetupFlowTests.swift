import Foundation
import UserNotifications

@main
struct SetupFlowTests {
    static func main() {
        testLocalOnlySkipButtonTitleIsShort()
        testLocalOnlySkipStateUsesAppleSpeech()
        testLocalOnlySkipStateClearsCloudCredentials()
        testNotificationAuthorizationGrantedStates()
        testNotificationActionTitles()
        print("SetupFlowTests passed")
    }

    private static func testLocalOnlySkipButtonTitleIsShort() {
        assert(SetupFlow.localOnlySkipButtonTitle == "Skip")
    }

    private static func testLocalOnlySkipStateUsesAppleSpeech() {
        let state = SetupFlow.localOnlySkipState()

        assert(state.useLocalTranscription)
        assert(state.localTranscriptionModelID == "apple-speech")
        assert(state.disablePostProcessing)
        assert(state.disableContextCapture)
        assert(!state.realtimeStreamingEnabled)
        assert(!state.isCommandModeEnabled)
    }

    private static func testLocalOnlySkipStateClearsCloudCredentials() {
        let state = SetupFlow.localOnlySkipState()

        assert(state.apiKey.isEmpty)
        assert(state.transcriptionAPIKey.isEmpty)
        assert(state.transcriptionAPIURL.isEmpty)
    }

    private static func testNotificationAuthorizationGrantedStates() {
        assert(SetupFlow.isNotificationAuthorizationGranted(.authorized))
        assert(SetupFlow.isNotificationAuthorizationGranted(.provisional))
        assert(!SetupFlow.isNotificationAuthorizationGranted(.notDetermined))
        assert(!SetupFlow.isNotificationAuthorizationGranted(.denied))
    }

    private static func testNotificationActionTitles() {
        assert(SetupFlow.notificationPermissionActionTitle(for: .notDetermined) == "Grant Access")
        assert(SetupFlow.notificationPermissionActionTitle(for: .denied) == "Open Settings")
        assert(SetupFlow.notificationPermissionActionTitle(for: .authorized) == "Grant Access")
    }
}
