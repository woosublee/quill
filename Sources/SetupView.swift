import AppKit
import AVFoundation
import SwiftUI
import UserNotifications

struct SetupView: View {
    var onComplete: @MainActor () -> Void

    @EnvironmentObject private var appState: AppState

    private enum SetupStep: Int, CaseIterable {
        case welcome = 0
        case processing
        case permissions
        case shortcut
        case ready
    }

    @State private var currentStep = SetupStep.welcome
    @State private var processingLocation: SetupFlow.ProcessingLocation?
    @State private var localModel = SetupFlow.LocalModel.default
    @State private var apiKeyInput = ""
    @State private var validatedAPIKey: String?
    @State private var isValidatingKey = false
    @State private var keyValidationError: String?
    @State private var micPermissionGranted = false
    @State private var accessibilityGranted = false
    @State private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var permissionTimer: Timer?
    @State private var holdShortcutValidationMessage: String?
    @State private var isCapturingHoldShortcut = false
    @State private var toggleShortcutValidationMessage: String?
    @State private var isCapturingToggleShortcut = false

    private var isCapturingShortcut: Bool {
        isCapturingHoldShortcut || isCapturingToggleShortcut
    }

    private var selectedPreset: SetupFlow.ProcessingPreset? {
        SetupFlow.processingPreset(
            location: processingLocation,
            localModel: localModel
        )
    }

    private var trimmedAPIKey: String {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isAPIKeyValidated: Bool {
        !trimmedAPIKey.isEmpty && validatedAPIKey == trimmedAPIKey
    }

    private var notificationAuthorizationGranted: Bool {
        SetupFlow.isNotificationAuthorizationGranted(notificationAuthorizationStatus)
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView {
                    currentStepView
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                        .frame(
                            minHeight: currentStep == .welcome ? max(0, geometry.size.height - 64) : 0,
                            alignment: .top
                        )
                        .padding(.horizontal, 32)
                        .padding(.vertical, 32)
                }
            }

            Divider()

            ZStack {
                stepIndicator

                HStack {
                    if currentStep != .welcome {
                        Button("Back") {
                            keyValidationError = nil
                            withAnimation(.easeInOut(duration: 0.2)) {
                                currentStep = previousStep(currentStep)
                            }
                        }
                        .disabled(isValidatingKey)
                    }

                    Spacer()

                    Button(primaryButtonTitle) {
                        performPrimaryAction()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinueFromCurrentStep)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 560, minHeight: 600)
        .onAppear {
            apiKeyInput = appState.apiKey
            appState.refreshNativeWhisperInstallStatus()
            refreshPermissionStatuses()
        }
        .onDisappear {
            permissionTimer?.invalidate()
            appState.resumeHotkeyMonitoringAfterShortcutCapture()
        }
        .onChange(of: currentStep) { step in
            if step == .permissions {
                startPermissionPolling()
            } else {
                permissionTimer?.invalidate()
            }
        }
        .onChange(of: isCapturingShortcut) { isCapturing in
            if isCapturing {
                appState.suspendHotkeyMonitoringForShortcutCapture()
            } else {
                appState.resumeHotkeyMonitoringAfterShortcutCapture()
            }
        }
        .onChange(of: appState.nativeWhisperInstallStatus) { status in
            handleNativeWhisperStatusChange(status)
        }
        .onChange(of: appState.isInstallingNativeWhisper) { isInstalling in
            if !isInstalling {
                handleNativeWhisperStatusChange(appState.nativeWhisperInstallStatus)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatuses()
        }
    }

    @ViewBuilder
    private var currentStepView: some View {
        switch currentStep {
        case .welcome:
            welcomeStep
        case .processing:
            processingStep
        case .permissions:
            permissionsStep
        case .shortcut:
            shortcutStep
        case .ready:
            readyStep
        }
    }

    var welcomeStep: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 20)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text("Meet Quill")
                    .font(.system(size: 34, weight: .bold, design: .rounded))

                Text("Turn speech and meetings into notes — from anywhere on your Mac.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var processingStep: some View {
        VStack(spacing: 24) {
            stepHeader(
                icon: "waveform.and.magnifyingglass",
                title: "Choose how Quill works",
                description: "Select where your audio is processed. You can configure each feature independently later in Settings."
            )

            HStack(spacing: 12) {
                processingChoiceCard(
                    location: .onThisMac,
                    icon: "desktopcomputer",
                    title: "On this Mac",
                    detail: "Private · Works offline · No API key"
                )
                processingChoiceCard(
                    location: .apiProvider,
                    icon: "cloud.fill",
                    title: "API Provider",
                    detail: "No model download · AI features available"
                )
            }

            if processingLocation == .onThisMac {
                localProcessingDetails
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else if processingLocation == .apiProvider {
                apiProcessingDetails
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 1.0), value: processingLocation)
    }

    private var localProcessingDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcription model")
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 8) {
                Button {
                    selectAppleSpeech()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: localModel == .appleSpeech ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(localModel == .appleSpeech ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Apple Speech")
                                .font(.callout.weight(localModel == .appleSpeech ? .semibold : .regular))
                            Text("Built in · Start instantly")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    .padding(12)
                    .background(
                        localModel == .appleSpeech
                            ? Color.accentColor.opacity(0.08)
                            : Color(nsColor: .controlBackgroundColor)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                localModel == .appleSpeech
                                    ? Color.accentColor.opacity(0.3)
                                    : Color.clear,
                                lineWidth: 1
                            )
                    )
                    .cornerRadius(8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                NativeWhisperModelRowView(
                    isSelected: localModel == .nativeWhisper,
                    onSelect: {
                        localModel = .nativeWhisper
                    },
                    onDownloadStarted: {
                        processingLocation = .onThisMac
                        localModel = .appleSpeech
                    }
                )
                .environmentObject(appState)
            }

            Label(
                "Transcription runs locally. AI cleanup and context-aware output stay off until compatible local models are configured.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07))
            .cornerRadius(8)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(12)
    }

    private var apiProcessingDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("API Key")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 8) {
                SecureField("Enter your Groq API key", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(isValidatingKey)
                    .onChange(of: apiKeyInput) { _ in
                        validatedAPIKey = nil
                        keyValidationError = nil
                    }

                Button(isValidatingKey ? "Validating..." : "Validate") {
                    validateAPIKey()
                }
                .disabled(trimmedAPIKey.isEmpty || isValidatingKey)
            }

            apiValidationStatus
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(12)
    }

    @ViewBuilder
    private var apiValidationStatus: some View {
        if isValidatingKey {
            Label("Validating provider access…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if isAPIKeyValidated {
            Label(
                "API key validated. Cloud transcription and AI features are ready.",
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(.green)
        } else if let keyValidationError {
            Label(keyValidationError, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Uses Quill's default Groq configuration. Advanced providers remain in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func selectProcessingLocation(_ location: SetupFlow.ProcessingLocation) {
        processingLocation = location
        if location == .apiProvider {
            appState.cancelNativeWhisperAutoSelection()
        }
    }

    private func selectAppleSpeech() {
        localModel = .appleSpeech
        appState.cancelNativeWhisperAutoSelection()
    }

    var permissionsStep: some View {
        VStack(spacing: 24) {
            stepHeader(
                icon: "checkmark.shield.fill",
                title: "Allow Quill to work",
                description: "Required permissions unlock dictation. Optional permissions can be skipped and enabled later."
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("Required")
                    .font(.headline)

                permissionRow(
                    title: "Microphone",
                    description: "Record your voice for transcription.",
                    icon: "mic.fill",
                    granted: micPermissionGranted,
                    actionTitle: String(localized: "Grant Access"),
                    action: requestMicrophonePermission
                )

                permissionRow(
                    title: "Accessibility",
                    description: "Paste transcribed text into your apps.",
                    icon: "hand.raised.fill",
                    granted: accessibilityGranted,
                    actionTitle: String(localized: "Open Settings"),
                    action: appState.openAccessibilitySettings
                )

                if selectedPreset == .localAppleSpeech {
                    permissionRow(
                        title: "Speech Recognition",
                        description: "Required by Apple Speech for live transcription.",
                        icon: "waveform.badge.mic",
                        granted: appState.hasSpeechRecognitionPermission,
                        actionTitle: String(localized: "Grant Access"),
                        action: { appState.requestSpeechRecognitionAccess() }
                    )
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Optional")
                        .font(.headline)
                    Text("Can be enabled later")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                permissionRow(
                    title: "Screen Recording",
                    description: "Adds screen context and enables System Audio when you choose it.",
                    icon: "camera.viewfinder",
                    granted: appState.hasScreenRecordingPermission,
                    actionTitle: String(localized: "Grant Access"),
                    action: appState.requestScreenCapturePermission
                )

                permissionRow(
                    title: "Notifications",
                    description: "Shows calendar recording reminders before meetings.",
                    icon: "bell.fill",
                    granted: notificationAuthorizationGranted,
                    actionTitle: SetupFlow.notificationPermissionActionTitle(
                        for: notificationAuthorizationStatus
                    ),
                    action: handleNotificationPermissionAction
                )
            }
        }
        .onAppear {
            refreshPermissionStatuses()
            startPermissionPolling()
        }
        .onDisappear {
            permissionTimer?.invalidate()
        }
    }

    var shortcutStep: some View {
        VStack(spacing: 24) {
            stepHeader(
                icon: "keyboard.fill",
                title: "Choose your shortcut",
                description: "Choose how you want to start and stop recording. You can change these shortcuts later in Settings."
            )

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    ShortcutRoleSection(
                        role: .hold,
                        selection: appState.holdShortcut,
                        validationMessage: holdShortcutValidationMessage,
                        isCapturing: $isCapturingHoldShortcut,
                        onSelect: { binding in
                            holdShortcutValidationMessage = appState.setShortcut(binding, for: .hold)
                        }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    ShortcutRoleSection(
                        role: .toggle,
                        selection: appState.toggleShortcut,
                        validationMessage: toggleShortcutValidationMessage,
                        isCapturing: $isCapturingToggleShortcut,
                        onSelect: { binding in
                            toggleShortcutValidationMessage = appState.setShortcut(binding, for: .toggle)
                        }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if appState.holdShortcut.usesFnKey || appState.toggleShortcut.usesFnKey {
                    Text("Tip: If Fn opens Emoji picker, go to System Settings > Keyboard and change \"Press fn key to\" to \"Do Nothing\".")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
            .cornerRadius(12)

            if !appState.hasEnabledHoldShortcut && !appState.hasEnabledToggleShortcut {
                Label(
                    "Enable at least one recording shortcut to continue.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Label(
                "Paste Again, Recording Cancel, and other shortcuts remain available in Settings.",
                systemImage: "command"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    var readyStep: some View {
        VStack(spacing: 24) {
            stepHeader(
                icon: "checkmark.circle.fill",
                title: "You're ready",
                description: "Use either recording shortcut anywhere on your Mac to start your first recording."
            )

            VStack(spacing: 10) {
                summaryRow(
                    icon: "waveform",
                    title: "Processing",
                    detail: processingSummary
                )
                if appState.hasEnabledHoldShortcut {
                    summaryRow(
                        icon: "keyboard",
                        title: "Hold to Talk",
                        detail: localizedCatalogFormat(
                            "Hold %@ to record",
                            appState.holdShortcut.displayName
                        )
                    )
                }
                if appState.hasEnabledToggleShortcut {
                    summaryRow(
                        icon: "switch.2",
                        title: "Tap to Toggle",
                        detail: localizedCatalogFormat(
                            "Tap %@ to start and stop",
                            appState.toggleShortcut.displayName
                        )
                    )
                }
                summaryRow(
                    icon: "circle.dashed",
                    title: "Optional permissions",
                    detail: optionalPermissionsSummary
                )
            }
        }
    }

    private func stepHeader(
        icon: String,
        title: LocalizedStringKey,
        description: LocalizedStringKey
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)

            Text(description)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func processingChoiceCard(
        location: SetupFlow.ProcessingLocation,
        icon: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        let isSelected = processingLocation == location
        return Button {
            selectProcessingLocation(location)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    Spacer()
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }

                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .padding(16)
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .cornerRadius(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? Text("Selected") : Text("Not selected"))
    }

    private func permissionRow(
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        icon: String,
        granted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(9)
    }

    private func summaryRow(
        icon: String,
        title: LocalizedStringKey,
        detail: String
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .frame(width: 28)
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(SetupStep.allCases, id: \.rawValue) { step in
                Circle()
                    .fill(step == currentStep ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                localizedCatalogFormat(
                    "Step %d of %d",
                    currentStep.rawValue + 1,
                    SetupStep.allCases.count
                )
            )
        )
    }

    private var primaryButtonTitle: LocalizedStringKey {
        currentStep == .ready ? "Get Started" : "Continue"
    }

    private var canContinueFromCurrentStep: Bool {
        switch currentStep {
        case .welcome, .ready:
            return !isValidatingKey
        case .shortcut:
            return !isCapturingShortcut
                && (appState.hasEnabledHoldShortcut || appState.hasEnabledToggleShortcut)
        case .processing:
            guard let selectedPreset else { return false }
            switch selectedPreset {
            case .localAppleSpeech:
                return true
            case .localNativeWhisper:
                return appState.nativeWhisperInstallStatus == .ready
                    && !appState.isInstallingNativeWhisper
            case .apiStandard:
                return isAPIKeyValidated && !isValidatingKey
            }
        case .permissions:
            guard let selectedPreset else { return false }
            return SetupFlow.requiredPermissions(for: selectedPreset).allSatisfy {
                permissionGranted($0)
            }
        }
    }

    private var processingSummary: String {
        switch selectedPreset {
        case .localAppleSpeech:
            if appState.willAutoSelectNativeWhisperWhenReady {
                return localizedCatalogString(
                    "On this Mac · Apple Speech · Whisper is downloading and will become active when ready."
                )
            }
            return localizedCatalogString("On this Mac · Apple Speech")
        case .localNativeWhisper:
            return localizedCatalogFormat(
                "On this Mac · %@",
                NativeWhisperModelCatalog.recommended.displayName
            )
        case .apiStandard:
            return localizedCatalogString("API Provider · Standard")
        case nil:
            return localizedCatalogString("Choose a processing option")
        }
    }

    private var optionalPermissionsSummary: String {
        switch (appState.hasScreenRecordingPermission, notificationAuthorizationGranted) {
        case (true, true):
            return localizedCatalogString("Screen Recording and Notifications are enabled.")
        case (true, false):
            return localizedCatalogString("Screen Recording is enabled. Notifications can be added later.")
        case (false, true):
            return localizedCatalogString("Notifications are enabled. Screen Recording can be added later.")
        case (false, false):
            return localizedCatalogString("Screen Recording and Notifications can be enabled later.")
        }
    }

    private func performPrimaryAction() {
        if currentStep == .ready {
            onComplete()
            return
        }

        if currentStep == .processing, let selectedPreset {
            appState.applySetupProcessingPreset(selectedPreset)
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            currentStep = nextStep(currentStep)
        }
    }

    private func previousStep(_ step: SetupStep) -> SetupStep {
        SetupStep(rawValue: step.rawValue - 1) ?? .welcome
    }

    private func nextStep(_ step: SetupStep) -> SetupStep {
        SetupStep(rawValue: step.rawValue + 1) ?? .ready
    }

    private func validateAPIKey() {
        let key = trimmedAPIKey
        guard !key.isEmpty else { return }

        isValidatingKey = true
        validatedAPIKey = nil
        keyValidationError = nil
        let baseURL = appState.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBaseURL = baseURL.isEmpty ? AppState.defaultAPIBaseURL : baseURL

        Task {
            let valid = await TranscriptionService.validateAPIKey(
                key,
                baseURL: resolvedBaseURL
            )
            await MainActor.run {
                isValidatingKey = false
                if valid {
                    appState.apiKey = key
                    validatedAPIKey = key
                } else {
                    keyValidationError = String(
                        localized: "Validation failed. Please check your API key and try again."
                    )
                }
            }
        }
    }

    private func handleNativeWhisperStatusChange(_ status: NativeWhisperInstallStatus) {
        if status == .ready,
           case .nativeWhisper = appState.currentNoteBrowserTranscriptionChoice {
            processingLocation = .onThisMac
            localModel = .nativeWhisper
            return
        }

        if status != .ready,
           !appState.isInstallingNativeWhisper,
           localModel == .nativeWhisper {
            localModel = .appleSpeech
        }
    }

    private func permissionGranted(_ permission: SetupFlow.Permission) -> Bool {
        switch permission {
        case .microphone:
            return micPermissionGranted
        case .accessibility:
            return accessibilityGranted
        case .speechRecognition:
            return appState.hasSpeechRecognitionPermission
        }
    }

    private func refreshPermissionStatuses() {
        refreshPolledPermissionStatuses()
        refreshNotificationAuthorizationStatus()
    }

    private func refreshPolledPermissionStatuses() {
        micPermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
        appState.refreshSpeechRecognitionAuthorizationStatus()
        let screenGranted = CGPreflightScreenCaptureAccess()
        if appState.hasScreenRecordingPermission != screenGranted {
            appState.hasScreenRecordingPermission = screenGranted
        }
    }

    private func startPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            DispatchQueue.main.async {
                refreshPolledPermissionStatuses()
            }
        }
    }

    private func requestMicrophonePermission() {
        appState.requestMicrophoneAccess { granted in
            micPermissionGranted = granted
        }
    }

    private func handleNotificationPermissionAction() {
        if notificationAuthorizationStatus == .denied {
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.notifications"
            ) {
                NSWorkspace.shared.open(url)
            }
        } else {
            Task {
                _ = await AppNotificationManager.shared.requestAuthorization()
                refreshNotificationAuthorizationStatus()
            }
        }
    }

    private func refreshNotificationAuthorizationStatus() {
        Task {
            let settings = await AppNotificationManager.shared.notificationSettings()
            await MainActor.run {
                notificationAuthorizationStatus = settings.authorizationStatus
            }
        }
    }
}
