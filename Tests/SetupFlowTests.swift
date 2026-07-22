import Foundation
import UserNotifications

@main
struct SetupFlowTests {
    static func main() throws {
        testProcessingStartsWithoutSelection()
        testLocalDefaultsToAppleSpeech()
        testRecordOnlyPresetAndPermissions()
        try testProcessingOffersRecordOnlyAlongsideLocalAndAPI()
        try testAccessibilityPermissionIsOptional()
        testNotificationAuthorizationGrantedStates()
        testNotificationActionTitles()
        try testSetupContainsExactlyFiveScrollableSteps()
        try testSetupWindowIsResizable()
        try testNativeWhisperDownloadDoesNotLockProcessing()
        try testShortcutStepConfiguresHoldAndToggle()
        print("SetupFlowTests passed")
    }

    private static func testProcessingStartsWithoutSelection() {
        assert(
            SetupFlow.processingPreset(
                location: nil,
                localModel: .appleSpeech
            ) == nil
        )
    }

    private static func testLocalDefaultsToAppleSpeech() {
        assert(SetupFlow.LocalModel.default == .appleSpeech)
        assert(
            SetupFlow.processingPreset(
                location: .onThisMac,
                localModel: .default
            ) == .localAppleSpeech
        )
        assert(
            SetupFlow.processingPreset(
                location: .onThisMac,
                localModel: .nativeWhisper
            ) == .localNativeWhisper
        )
        assert(
            SetupFlow.processingPreset(
                location: .apiProvider,
                localModel: .appleSpeech
            ) == .apiStandard
        )
    }

    private static func testRecordOnlyPresetAndPermissions() {
        assert(
            SetupFlow.processingPreset(
                location: .recordOnly,
                localModel: .appleSpeech
            ) == .recordOnly
        )
        assert(
            SetupFlow.requiredPermissions(for: .recordOnly) == [.microphone]
        )
        assert(
            SetupFlow.requiredPermissions(for: .localAppleSpeech)
                == [.microphone, .speechRecognition]
        )
        assert(
            SetupFlow.requiredPermissions(for: .localNativeWhisper)
                == [.microphone]
        )
        assert(
            SetupFlow.requiredPermissions(for: .apiStandard)
                == [.microphone]
        )
    }

    private static func testProcessingOffersRecordOnlyAlongsideLocalAndAPI() throws {
        let source = try String(contentsOfFile: "Sources/SetupView.swift", encoding: .utf8)
        let processing = sourceBlock(
            in: source,
            from: "var processingStep: some View",
            to: "\n    private var localProcessingDetails"
        )

        assert(processing.contains("location: .recordOnly"))
        assert(processing.contains("title: \"Record only\""))
        assert(processing.contains("location: .onThisMac"))
        assert(processing.contains("location: .apiProvider"))
        assert(source.contains("case .recordOnly:\n                return true"))
    }

    private static func testAccessibilityPermissionIsOptional() throws {
        let source = try String(contentsOfFile: "Sources/SetupView.swift", encoding: .utf8)
        let permissions = sourceBlock(
            in: source,
            from: "var permissionsStep: some View",
            to: "\n    var shortcutStep: some View"
        )
        let required = sourceBlock(
            in: permissions,
            from: "Text(\"Required\")",
            to: "Text(\"Optional\")"
        )
        let optional = String(permissions.dropFirst(required.count))

        assert(!required.contains("title: \"Accessibility\""))
        assert(optional.contains("title: \"Accessibility\""))
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
    }

    private static func testSetupContainsExactlyFiveScrollableSteps() throws {
        let source = try String(contentsOfFile: "Sources/SetupView.swift", encoding: .utf8)
        let stepBlock = sourceBlock(
            in: source,
            from: "private enum SetupStep",
            to: "\n\n    @State"
        )

        for expected in ["welcome", "processing", "permissions", "shortcut", "ready"] {
            assert(stepBlock.contains("case \(expected)"), "Missing setup step: \(expected)")
        }
        for removed in [
            "apiKey", "micPermission", "speechRecognition", "accessibility",
            "screenRecording", "notifications", "holdShortcut", "toggleShortcut",
            "copyAgainShortcut", "commandMode", "overlayStyle", "vocabulary",
            "launchAtLogin", "testTranscription"
        ] {
            assert(!stepBlock.contains("case \(removed)"), "Legacy setup step remains: \(removed)")
        }
        assert(stepBlock.components(separatedBy: "case ").count - 1 == 5)
        assert(source.contains("ScrollView"))
        assert(!source.contains("skipAPIKeyForLocalOnly"))
        assert(!source.contains("SetupProviderSettingsSheet"))
        assert(!source.contains("testTranscriptionStep"))
    }

    private static func testSetupWindowIsResizable() throws {
        let source = try String(contentsOfFile: "Sources/AppDelegate.swift", encoding: .utf8)
        let setupWindow = sourceBlock(
            in: source,
            from: "func showSetupWindow()",
            to: "\n\n    @MainActor\n    func completeSetup()"
        )

        assert(setupWindow.contains("width: 780, height: 720"))
        assert(setupWindow.contains(".resizable"))
        assert(setupWindow.contains("window.minSize = NSSize(width: 620, height: 600)"))
        assert(!setupWindow.contains("window.delegate = setupWindowDelegate"))
        assert(!source.contains("private final class SetupWindowDelegate"))
        assert(!source.contains("cancelNativeWhisperInstallForSetupClose()"))
    }

    private static func testNativeWhisperDownloadDoesNotLockProcessing() throws {
        let source = try String(contentsOfFile: "Sources/SetupView.swift", encoding: .utf8)
        let processing = sourceBlock(
            in: source,
            from: "var processingStep: some View",
            to: "\n    var permissionsStep: some View"
        )
        let continueGate = sourceBlock(
            in: source,
            from: "private var canContinueFromCurrentStep: Bool",
            to: "\n    private var processingSummary"
        )

        assert(!processing.contains("guard !appState.isInstallingNativeWhisper"))
        assert(!processing.contains(".disabled(appState.isInstallingNativeWhisper)"))
        assert(processing.contains("appState.cancelNativeWhisperAutoSelection()"))
        assert(processing.contains("localModel = .appleSpeech"))
        assert(continueGate.contains("case .localAppleSpeech:\n                return true"))
        assert(!continueGate.contains("return !appState.isInstallingNativeWhisper"))
        assert(source.contains("Whisper is downloading and will become active when ready."))
    }

    private static func testShortcutStepConfiguresHoldAndToggle() throws {
        let source = try String(contentsOfFile: "Sources/SetupView.swift", encoding: .utf8)
        let shortcut = sourceBlock(
            in: source,
            from: "var shortcutStep: some View",
            to: "\n    var readyStep: some View"
        )
        let gate = sourceBlock(
            in: source,
            from: "private var canContinueFromCurrentStep: Bool",
            to: "\n    private var processingSummary"
        )

        assert(shortcut.contains("role: .hold"))
        assert(shortcut.contains("role: .toggle"))
        assert(shortcut.contains("appState.setShortcut(binding, for: .hold)"))
        assert(shortcut.contains("appState.setShortcut(binding, for: .toggle)"))
        assert(shortcut.contains("Enable at least one recording shortcut to continue."))
        assert(!shortcut.contains("role: .copyAgain"))
        assert(!shortcut.contains("RecordingCancelShortcutSection"))
        assert(gate.contains("appState.hasEnabledHoldShortcut || appState.hasEnabledToggleShortcut"))

        assert(source.contains("Hold %@ to record"))
        assert(source.contains("Tap %@ to start and stop"))
    }

    private static func sourceBlock(
        in source: String,
        from startMarker: String,
        to endMarker: String
    ) -> String {
        guard let start = source.range(of: startMarker),
              let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else {
            preconditionFailure("Expected source block from \(startMarker) to \(endMarker)")
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }
}
