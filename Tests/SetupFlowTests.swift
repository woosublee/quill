import Foundation
import UserNotifications

@main
struct SetupFlowTests {
    static func main() throws {
        testProcessingStartsWithoutSelection()
        testLocalDefaultsToAppleSpeech()
        testLocalAIModelPresetMatchesNativeWhisperPermissions()
        testRecordOnlyPresetAndPermissions()
        testRecordOnlyRequiresExplicitAudioSource()
        testPermissionsFollowRecordOnlyAudioSource()
        testRecordOnlyPermissionProgress()
        testRecordOnlyDraftDoesNotChangeOtherPresets()
        try testProcessingOffersRecordOnlyAlongsideLocalAndAPI()
        try testAccessibilityPermissionIsOptional()
        testNotificationAuthorizationGrantedStates()
        testNotificationActionTitles()
        try testSetupContainsExactlyFiveScrollableSteps()
        try testSetupWindowIsResizable()
        try testSetupCompletionSharesPostSetupInitializationWithLaunch()
        try testNativeWhisperDownloadDoesNotLockProcessing()
        try testShortcutStepConfiguresHoldAndToggle()
        try testLocalAIModelCardIsKeyboardAndVoiceOverSelectable()
        try testStepChangesMoveVoiceOverToHeading()
        try testPermissionGrantsAreAnnounced()
        testSavedProgressRoundTrips()
        testResumeStopsAtTheFirstBlockedStep()
        try testSetupSavesAndRestoresProgress()
        try testConnectionsStartOffAndExistingUsersSeeThemOnce()
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

    private static func testLocalAIModelPresetMatchesNativeWhisperPermissions() {
        let preset = SetupFlow.processingPreset(
            location: .onThisMac,
            localModel: .localAIModel(id: "gemma-4-e4b-it")
        )
        assert(preset == .localAIModel(id: "gemma-4-e4b-it"))
        assert(
            SetupFlow.requiredPermissions(for: .localAIModel(id: "gemma-4-e4b-it"))
                == SetupFlow.requiredPermissions(for: .localNativeWhisper)
        )
        assert(
            SetupFlow.requiredPermissions(for: .localAIModel(id: "gemma-4-e4b-it"))
                == [.microphone]
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

    private static func testRecordOnlyRequiresExplicitAudioSource() {
        assert(!SetupFlow.hasRequiredAudioSource(for: .recordOnly, recordOnlySource: nil))
        for source in AudioRecordingSource.allCases {
            assert(SetupFlow.hasRequiredAudioSource(for: .recordOnly, recordOnlySource: source))
        }
        for preset: SetupFlow.ProcessingPreset in [.localAppleSpeech, .localNativeWhisper, .apiStandard] {
            assert(SetupFlow.hasRequiredAudioSource(for: preset, recordOnlySource: nil))
        }
    }

    private static func testPermissionsFollowRecordOnlyAudioSource() {
        let cases: [(AudioRecordingSource, Set<SetupFlow.Permission>)] = [
            (.microphone, [.microphone]),
            (.systemAudio, [.screenRecording]),
            (.microphoneAndSystemAudio, [.microphone, .screenRecording]),
        ]
        for (source, expected) in cases {
            assert(SetupFlow.requiredPermissions(for: .recordOnly, audioSource: source) == expected)
        }
    }

    private static func testRecordOnlyPermissionProgress() {
        let cases: [(AudioRecordingSource?, Set<SetupFlow.Permission>, Bool)] = [
            (nil, [], false),
            (nil, [.microphone, .screenRecording, .speechRecognition, .accessibility], false),
            (.microphone, [], false),
            (.microphone, [.screenRecording], false),
            (.microphone, [.microphone], true),
            (.systemAudio, [], false),
            (.systemAudio, [.microphone], false),
            (.systemAudio, [.screenRecording], true),
            (.microphoneAndSystemAudio, [.microphone], false),
            (.microphoneAndSystemAudio, [.screenRecording], false),
            (.microphoneAndSystemAudio, [.microphone, .screenRecording], true),
        ]
        for (source, granted, expected) in cases {
            assert(
                SetupFlow.canContinuePermissions(
                    for: .recordOnly,
                    recordOnlySource: source,
                    grantedPermissions: granted
                ) == expected
            )
        }

        var selectedSource: AudioRecordingSource? = .systemAudio
        let granted: Set<SetupFlow.Permission> = [.screenRecording]
        assert(SetupFlow.canContinuePermissions(
            for: .recordOnly, recordOnlySource: selectedSource, grantedPermissions: granted
        ))
        selectedSource = .microphoneAndSystemAudio
        assert(!SetupFlow.canContinuePermissions(
            for: .recordOnly, recordOnlySource: selectedSource, grantedPermissions: granted
        ))
        selectedSource = .systemAudio
        assert(SetupFlow.canContinuePermissions(
            for: .recordOnly, recordOnlySource: selectedSource, grantedPermissions: granted
        ))
        assert(!SetupFlow.canContinuePermissions(
            for: .recordOnly, recordOnlySource: selectedSource, grantedPermissions: []
        ))
    }

    private static func testRecordOnlyDraftDoesNotChangeOtherPresets() {
        let cases: [(SetupFlow.ProcessingPreset, Set<SetupFlow.Permission>)] = [
            (.localAppleSpeech, [.microphone, .speechRecognition]),
            (.localNativeWhisper, [.microphone]),
            (.apiStandard, [.microphone]),
        ]
        for (preset, expected) in cases {
            for source in AudioRecordingSource.allCases {
                assert(SetupFlow.requiredPermissions(for: preset, audioSource: source) == expected)
                assert(!SetupFlow.canContinuePermissions(
                    for: preset, recordOnlySource: source, grantedPermissions: [.screenRecording]
                ))
                assert(SetupFlow.canContinuePermissions(
                    for: preset, recordOnlySource: source, grantedPermissions: expected
                ))
            }
        }
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
        assert(
            !source.contains("case .recordOnly:\n                return true"),
            "Record-only must require an explicit audio source before continuing."
        )
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
        let optional = sourceBlock(
            in: permissions,
            from: "Text(\"Optional\")",
            to: "\n        .onAppear"
        )

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

        for expected in ["welcome", "processing", "permissions", "connections", "shortcut", "ready"] {
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
        assert(stepBlock.components(separatedBy: "case ").count - 1 == 6)
        // #530: Connections and Sync sits between Permissions and Shortcut.
        assert(stepBlock.contains("case permissions\n        case connections\n        case shortcut"))
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

    // Finishing setup must start the same named services as a normal
    // relaunch (MCP, hotkey monitoring, accessibility polling, update
    // checks, Calendar scheduling and health checks, and an enabled Note
    // Browser) instead of a narrower, hand-duplicated subset.
    private static func testSetupCompletionSharesPostSetupInitializationWithLaunch() throws {
        let source = try String(contentsOfFile: "Sources/AppDelegate.swift", encoding: .utf8)

        let launchBody = sourceBlock(
            in: source,
            from: "func applicationDidFinishLaunching(",
            to: "func applicationShouldTerminate("
        )
        assert(launchBody.contains("startPostSetupServices()"))
        assert(!launchBody.contains("appState.startHotkeyMonitoring()"))
        assert(!launchBody.contains("startMCPServer()"))

        // #518: after setup, a Dock click always opens the note browser.
        let reopenBody = sourceBlock(
            in: source,
            from: "func applicationShouldHandleReopen(",
            to: "\n    @MainActor"
        )
        assert(reopenBody.contains("guard appState.hasCompletedSetup else { return true }"))
        assert(reopenBody.contains("showNoteBrowserWindow()"))
        assert(!reopenBody.contains("showSettingsWindow()"))

        let completeSetupBody = sourceBlock(
            in: source,
            from: "func completeSetup()",
            to: "private func startPostSetupServices("
        )
        assert(completeSetupBody.contains("startPostSetupServices()"))
        assert(!completeSetupBody.contains("appState.startHotkeyMonitoring()"))
        assert(!completeSetupBody.contains("appState.startCalendarRecordingReminderScheduling()"))

        let sharedBody = sourceBlock(
            in: source,
            from: "private func startPostSetupServices()",
            to: "private func startMCPServer("
        )
        assert(sharedBody.contains("updateActivationPolicy()"))
        // #518: the note browser is always on, so launch opens it.
        assert(!source.contains("noteBrowserEnabled"))
        assert(sharedBody.contains("showNoteBrowserWindow()"))
        assert(sharedBody.contains("appState.startHotkeyMonitoring()"))
        assert(sharedBody.contains("appState.startAccessibilityPolling()"))
        assert(sharedBody.contains("UpdateManager.shared.startPeriodicChecks()"))
        assert(sharedBody.contains("appState.promptForAccessibilityAccess()"))
        // #528: the MCP server follows Settings › AI Tools, off by default.
        assert(sharedBody.contains("observeMCPServerSetting()"))
        assert(!sharedBody.contains("startMCPServer()"))
        assert(sharedBody.contains("appState.startCalendarRecordingReminderScheduling()"))
        assert(sharedBody.contains("appState.startGoogleCalendarHealthCheck()"))

        let mcpBody = sourceBlock(
            in: source,
            from: "private func startMCPServer() {",
            to: "\n}"
        )
        assert(mcpBody.contains("guard mcpServer == nil else { return }"))
        let observeBody = sourceBlock(
            in: source,
            from: "private func observeMCPServerSetting() {",
            to: "\n    }\n}"
        )
        assert(observeBody.contains("appState.$isMCPServerEnabled"))
        assert(observeBody.contains("self?.startMCPServer()"))
        assert(observeBody.contains("self?.stopMCPServer()"))
        let stopBody = sourceBlock(
            in: source,
            from: "private func stopMCPServer(status: MCPServerStatus = .off) {",
            to: "\n    }"
        )
        assert(stopBody.contains("mcpServer?.stop()"))
        assert(stopBody.contains("mcpServer = nil"))
        assert(stopBody.contains("appState.mcpAdditionalContext = \"\""))
        // A failed listener is let go of, so off and on starts a new one.
        assert(source.contains("self.stopMCPServer(status: .failed)"))
        let server = try String(contentsOfFile: "Sources/MCPServer.swift", encoding: .utf8)
        let serverStop = sourceBlock(in: server, from: "func stop() {", to: "\n    private func track(")
        assert(serverStop.contains("openConnections.removeAll()"))
        assert(serverStop.contains("connections.forEach { $0.cancel() }"))
        assert(server.contains("guard track(connection) else {"))
        assert(server.contains("guard !isStopped else { return false }"))
        assert(server.contains("guard let self, !self.hasStopped else {"))
        let sse = sourceBlock(in: server, from: "private func handleSSE(connection: NWConnection) {", to: "let headers = [")
        assert(sse.contains("guard !hasStopped else {"))
        // A just-released port gets a few seconds before it counts as taken.
        assert(server.contains("self?.failIfStillWaiting(listener)"))
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

        // #517: pickers list every non-custom selection, not only presets.
        let components = try String(contentsOfFile: "Sources/ShortcutComponents.swift", encoding: .utf8)
        assert(components.contains("ForEach(role.pickerBindings(selection: selection))"))
        assert(components.contains("isSelected: selection.id == binding.id"))
        let menuBar = try String(contentsOfFile: "Sources/MenuBarView.swift", encoding: .utf8)
        assert(!menuBar.contains("ForEach(ShortcutPreset.allCases)"))
        assert(menuBar.contains(".disabled(binding.conflicts(with: appState.toggleShortcut))"))
        assert(menuBar.contains(".disabled(binding.conflicts(with: appState.holdShortcut))"))

        assert(source.contains("Hold %@ to record"))
        assert(source.contains("Tap %@ to start and stop"))
    }

    /// #392: a ready Local AI model card must be a real button, not a
    /// tap-only view, and keep its mouse look via an unstyled button style.
    private static func testLocalAIModelCardIsKeyboardAndVoiceOverSelectable() throws {
        let source = try String(contentsOfFile: "Sources/SetupView.swift", encoding: .utf8)
        let card = sourceBlock(
            in: source,
            from: "private func localAITranscriptionCard(",
            to: "\n    private func localAITranscriptionCardContent("
        )
        assert(!card.contains("onTapGesture"), "Local AI card must not rely on a tap gesture for selection")
        assert(card.contains("Button {\n                    localModel = .localAIModel(id: model.id)"))
        assert(card.contains(".buttonStyle(SetupUnstyledCardButtonStyle())"))
        // The download-finished handler sits on a stable container, not a
        // Group, so it can't miss the model ID change when the card turns
        // into a button.
        assert(!card.contains("Group {"))
        assert(card.contains("VStack(spacing: 0) {"))
        assert(card.contains(".onChange(of: appState.localAITranscriptionModelID) { selectedID in"))
        assert(card.contains(".accessibilityValue(isSelected ? Text(\"Selected\") : Text(\"Not selected\"))"))

        let content = sourceBlock(
            in: source,
            from: "private func localAITranscriptionCardContent(",
            to: "\n    private func focusStepTitleForVoiceOver("
        )
        assert(!content.contains("onTapGesture"))
        assert(content.contains("Button(\"Download\")"), "Download stays a separate control")
        assert(content.contains("\"circle\")\n                .foregroundStyle(isSelected ? Color.accentColor : .secondary)\n                .accessibilityHidden(true)"))

        let style = sourceBlock(
            in: source,
            from: "private struct SetupUnstyledCardButtonStyle: ButtonStyle {",
            to: "\n}\n"
        )
        assert(style.contains("configuration.label\n"), "Card button style must render the label unchanged")
        assert(!style.contains("isPressed") && !style.contains("opacity"), "No pressed effect for mouse users")
    }

    /// #392: Back and Continue move VoiceOver to the new step heading.
    private static func testStepChangesMoveVoiceOverToHeading() throws {
        let source = try String(contentsOfFile: "Sources/SetupView.swift", encoding: .utf8)
        assert(source.contains("@AccessibilityFocusState private var isStepTitleFocused: Bool"))

        let header = sourceBlock(
            in: source,
            from: "private func stepHeader(",
            to: "\n    private func processingChoiceCard("
        )
        assert(header.contains(".accessibilityAddTraits(.isHeader)"))
        assert(header.contains(".accessibilityFocused($isStepTitleFocused)"))

        let welcome = sourceBlock(in: source, from: "var welcomeStep: some View", to: "\n    var processingStep")
        assert(welcome.contains(".accessibilityAddTraits(.isHeader)"))
        assert(welcome.contains(".accessibilityFocused($isStepTitleFocused)"))

        let stepChange = sourceBlock(
            in: source,
            from: ".onChange(of: currentStep) { step in",
            to: "\n        .onChange(of: micPermissionGranted)"
        )
        assert(stepChange.contains("focusStepTitleForVoiceOver()"))

        let focus = sourceBlock(
            in: source,
            from: "private func focusStepTitleForVoiceOver()",
            to: "\n    private func announcePermissionGranted("
        )
        assert(
            focus.contains("guard NSWorkspace.shared.isVoiceOverEnabled else { return }"),
            "Focus moves only when VoiceOver is running"
        )
    }

    /// #392: permissions granted during setup are announced without any
    /// visible change, and not twice while the permission guide is open.
    private static func testPermissionGrantsAreAnnounced() throws {
        let source = try String(contentsOfFile: "Sources/SetupView.swift", encoding: .utf8)
        for (value, message) in [
            ("micPermissionGranted", "Microphone access granted"),
            ("accessibilityGranted", "Accessibility access granted"),
            ("appState.hasSpeechRecognitionPermission", "Speech Recognition access granted"),
            ("appState.hasScreenRecordingPermission", "Screen & System Audio Recording access granted"),
            ("notificationAuthorizationGranted", "Notifications allowed")
        ] {
            assert(
                source.contains(".onChange(of: \(value)) { granted in\n            announcePermissionGranted(granted, \"\(message)\")"),
                "Missing announcement for \(value)"
            )
        }

        let announce = sourceBlock(
            in: source,
            from: "private func announcePermissionGranted(",
            to: "\n    private func handleNativeWhisperStatusChange("
        )
        assert(announce.contains("guard granted, currentStep == .permissions, !appState.isPermissionGuidePresented"))
        assert(announce.contains("notification: .announcementRequested"))
    }

    /// #516: Screen Recording relaunches Quill mid-setup; the choices
    /// survive in defaults until setup finishes.
    private static func testSavedProgressRoundTrips() {
        let suite = "SetupFlowTests.savedProgress"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        assert(SetupFlow.loadSavedProgress(from: defaults) == nil)

        let progress = SetupFlow.SavedProgress(
            step: 2,
            processingLocation: .recordOnly,
            localModel: .localAIModel(id: "synthetic-model"),
            recordOnlyAudioSourceID: AudioRecordingSource.systemAudio.id,
            savedAt: Date(timeIntervalSince1970: 1_000_000)
        )
        SetupFlow.saveProgress(progress, to: defaults)
        let loaded = SetupFlow.loadSavedProgress(from: defaults)
        assert(loaded == progress)
        assert(loaded?.recordOnlyAudioSource == .systemAudio)

        SetupFlow.clearSavedProgress(in: defaults)
        assert(SetupFlow.loadSavedProgress(from: defaults) == nil)

        defaults.set(Data("not json".utf8), forKey: SetupFlow.savedProgressKey)
        assert(SetupFlow.loadSavedProgress(from: defaults) == nil)

        let unknownSource = SetupFlow.SavedProgress(
            step: 1,
            processingLocation: .onThisMac,
            localModel: .appleSpeech,
            recordOnlyAudioSourceID: "unknown",
            savedAt: Date(timeIntervalSince1970: 1_000_000)
        )
        assert(unknownSource.recordOnlyAudioSource == nil)

        // Only a relaunch soon after the grant resumes.
        let savedAt = progress.savedAt
        assert(progress.isRecent(now: savedAt.addingTimeInterval(60)))
        assert(progress.isRecent(now: savedAt.addingTimeInterval(SetupFlow.SavedProgress.maxAge)))
        assert(!progress.isRecent(now: savedAt.addingTimeInterval(SetupFlow.SavedProgress.maxAge + 1)))
        assert(!progress.isRecent(now: savedAt.addingTimeInterval(-60)))
    }

    private static func testResumeStopsAtTheFirstBlockedStep() {
        assert(SetupFlow.resumeStep(savedStep: 3, lastStep: 4) { _ in true } == 3)
        assert(SetupFlow.resumeStep(savedStep: 3, lastStep: 4) { $0 != 1 } == 1)
        assert(SetupFlow.resumeStep(savedStep: 0, lastStep: 4) { _ in false } == 0)
        assert(SetupFlow.resumeStep(savedStep: 4, lastStep: 4) { _ in false } == 0)
        // A step past the last one, from another build, stops at the last.
        assert(SetupFlow.resumeStep(savedStep: 9, lastStep: 4) { _ in true } == 4)
    }

    private static func testSetupSavesAndRestoresProgress() throws {
        let view = try String(contentsOfFile: "Sources/SetupView.swift", encoding: .utf8)
        let onAppear = sourceBlock(in: view, from: ".onAppear {", to: ".onDisappear {")
        assert(onAppear.contains("restoreSavedProgress()"))
        // Saved only when granting Screen Recording, which relaunches Quill.
        let screenRow = sourceBlock(in: view, from: "private var screenRecordingPermissionRow: some View", to: "private func permissionRow(")
        assert(screenRow.contains("saveProgress()"))
        assert(screenRow.contains("appState.requestScreenCapturePermission()"))
        let stepChange = sourceBlock(in: view, from: ".onChange(of: currentStep) { step in", to: "focusStepTitleForVoiceOver()")
        assert(stepChange.contains("if step == .permissions {"))
        assert(stepChange.contains("saveProgress()"))
        let finish = sourceBlock(in: view, from: "private func performPrimaryAction()", to: "if currentStep == .processing, let selectedPreset")
        assert(finish.contains("SetupFlow.clearSavedProgress(in: .standard)"))
        // A resume skips the model check on Processing, so finishing checks it.
        let gate = sourceBlock(in: view, from: "private func canContinue(from step: SetupStep) -> Bool", to: "private var processingSummary")
        assert(gate.contains("return !isValidatingKey && isSelectedModelReady"))
        let restore = sourceBlock(in: view, from: "private func restoreSavedProgress()", to: "private func previousStep(")
        assert(restore.contains("guard currentStep == .welcome else { return }"))
        // Restored once, and only soon after the grant: cleared right
        // after it is read, even when it is old or unreadable.
        let clearIndex = restore.range(of: "SetupFlow.clearSavedProgress(in: .standard)")
        let recentIndex = restore.range(of: "saved.isRecent(now: Date())")
        assert(clearIndex != nil && recentIndex != nil && clearIndex!.lowerBound < recentIndex!.lowerBound)
        assert(restore.contains("return canResume(past: step)"))
        let delegate = try String(contentsOfFile: "Sources/AppDelegate.swift", encoding: .utf8)
        let setupClose = sourceBlock(in: delegate, from: "private func handleSetupWindowDidClose(", to: "@objc private func handleShowSettings()")
        assert(setupClose.contains("SetupFlow.clearSavedProgress(in: .standard)"))

        // Only choices are kept; the API key stays in Settings.
        let flow = try String(contentsOfFile: "Sources/SetupFlow.swift", encoding: .utf8)
        let saved = sourceBlock(in: flow, from: "struct SavedProgress", to: "static let savedProgressKey")
        assert(!saved.contains("apiKey"))
        assert(!saved.contains("APIKey"))
    }

    /// #530: setup offers iCloud sync and AI tools, both off; sync starts
    /// only when setup finishes; existing users get the two switches once.
    private static func testConnectionsStartOffAndExistingUsersSeeThemOnce() throws {
        let view = try String(contentsOfFile: "Sources/SetupView.swift", encoding: .utf8)
        assert(view.contains("@State private var connectionsSelection = ConnectionsChoices.Selection()"))
        let finish = sourceBlock(in: view, from: "private func performPrimaryAction()", to: "if currentStep == .processing, let selectedPreset")
        assert(finish.contains("onComplete(connectionsSelection)"))

        // Neither switch applies while choosing; both apply together.
        let choices = try String(contentsOfFile: "Sources/ConnectionsChoicesView.swift", encoding: .utf8)
        assert(choices.contains("isOn: $selection.wantsMCP"))
        assert(!choices.contains("$appState.isMCPServerEnabled"))
        assert(choices.contains("controller.unavailableReason == nil"))
        assert(choices.contains("attendee names and emails"))

        let delegate = try String(contentsOfFile: "Sources/AppDelegate.swift", encoding: .utf8)
        let launch = sourceBlock(in: delegate, from: "func applicationDidFinishLaunching(", to: "func applicationShouldTerminate(")
        assert(launch.contains("startPostSetupServices()\n            showNewSettingsIfNeeded()"))
        assert(delegate.contains("self?.completeSetup()\n            self?.applyConnectionsChoices(selection)"))
        let newSettings = sourceBlock(in: delegate, from: "private func showNewSettingsIfNeeded()", to: "private func applyConnectionsChoices(")
        assert(newSettings.contains("guard !UserDefaults.standard.bool(forKey: ConnectionsChoices.seenStorageKey)"))
        // Closing the window applies the choices, as Done does.
        assert(newSettings.contains("#selector(handleNewSettingsWindowWillClose)"))
        let close = sourceBlock(in: delegate, from: "private func handleNewSettingsWindowWillClose(", to: "private func applyConnectionsChoices(")
        assert(close.contains("applyConnectionsChoices(selection)"))
        let apply = sourceBlock(in: delegate, from: "private func applyConnectionsChoices(", to: "private func showICloudSyncTurnOnFailure(")
        assert(apply.contains("UserDefaults.standard.set(true, forKey: ConnectionsChoices.seenStorageKey)"))
        // Only a change is applied, so Settings changes made meanwhile stay.
        assert(delegate.contains("if selection.wantsMCP != selection.mcpWasOn {"))
        assert(apply.contains("applyMCPChoice(selection)"))
        // Right after launch the note store may still be loading.
        assert(apply.contains("while failure == .notReady, attempts < 10"))
        // A setup re-run closes New settings without applying it.
        let rerun = sourceBlock(in: delegate, from: "@objc func handleShowSetup()", to: "// Single wizard at a time")
        assert(rerun.contains("newSettingsModel = nil\n        newSettingsWindow?.close()"))
        let terminate = sourceBlock(in: delegate, from: "func applicationWillTerminate(", to: "appState.finalizePendingNoteDeletion()")
        assert(terminate.contains("newSettingsModel?.selection"))
        assert(!terminate.contains("seenStorageKey"))
        // A failed turn-on is said, since the choice isn't offered again.
        assert(apply.contains("self?.showICloudSyncTurnOnFailure(failure)"))
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
