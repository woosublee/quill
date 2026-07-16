import SwiftUI
import AVFoundation
import ServiceManagement
import UserNotifications

// MARK: - Shared Helpers

private func localizedCatalogFormat(_ key: String, _ first: String, _ second: String) -> String {
    var value = localizedCatalogString(key)
    if let range = value.range(of: "%arg") { value.replaceSubrange(range, with: first) }
    if let range = value.range(of: "%arg") { value.replaceSubrange(range, with: second) }
    return value
}


private struct SettingsCard<Content: View>: View {
    let title: LocalizedStringKey
    let icon: String
    let content: Content

    init(_ title: LocalizedStringKey, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private let iso8601DayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

struct ProviderSettingsFields: View {
    @EnvironmentObject var appState: AppState
    @Binding var apiBaseURLInput: String
    @Binding var transcriptionAPIURLInput: String
    @Binding var transcriptionAPIKeyInput: String
    @FocusState private var isEditingAPIBaseURL: Bool
    @FocusState private var isEditingTranscriptionModel: Bool
    @FocusState private var isEditingRealtimeStreamingModel: Bool
    @FocusState private var isEditingPostProcessingModel: Bool
    @FocusState private var isEditingPostProcessingFallbackModel: Bool
    @FocusState private var isEditingContextModel: Bool
    @FocusState private var transcriptionAPIURLFocused: Bool
    @FocusState private var transcriptionAPIKeyFocused: Bool
    @State private var transcriptionModelDraft: String = ""
    @State private var realtimeStreamingModelDraft: String = ""
    @State private var postProcessingModelDraft: String = ""
    @State private var postProcessingFallbackModelDraft: String = ""
    @State private var contextModelDraft: String = ""

    let showsModelDescription: Bool
    let showsTranscriptionLanguage: Bool

    private func commitAPIBaseURL() {
        let trimmed = apiBaseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBaseURL = trimmed.isEmpty ? AppState.defaultAPIBaseURL : trimmed
        apiBaseURLInput = resolvedBaseURL
        appState.apiBaseURL = resolvedBaseURL
    }

    private func commitTranscriptionModel() {
        let trimmed = transcriptionModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? AppState.defaultTranscriptionModel : trimmed
        transcriptionModelDraft = resolved
        guard appState.transcriptionModel != resolved else { return }
        appState.transcriptionModel = resolved
    }

    private func commitRealtimeStreamingModel() {
        let trimmed = realtimeStreamingModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        realtimeStreamingModelDraft = trimmed
        guard appState.realtimeStreamingModel != trimmed else { return }
        appState.realtimeStreamingModel = trimmed
    }

    private func commitPostProcessingModel() {
        let trimmed = postProcessingModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? AppState.defaultPostProcessingModel : trimmed
        postProcessingModelDraft = resolved
        guard appState.postProcessingModel != resolved else { return }
        appState.postProcessingModel = resolved
    }

    private func commitPostProcessingFallbackModel() {
        let trimmed = postProcessingFallbackModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? AppState.defaultPostProcessingFallbackModel : trimmed
        postProcessingFallbackModelDraft = resolved
        guard appState.postProcessingFallbackModel != resolved else { return }
        appState.postProcessingFallbackModel = resolved
    }

    private func commitContextModel() {
        let trimmed = contextModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? AppState.defaultContextModel : trimmed
        contextModelDraft = resolved
        guard appState.contextModel != resolved else { return }
        appState.contextModel = resolved
    }

    private func commitTranscriptionAPIURL() {
        let trimmed = transcriptionAPIURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        transcriptionAPIURLInput = trimmed
        guard appState.transcriptionAPIURL != trimmed else { return }
        appState.transcriptionAPIURL = trimmed
    }

    private func commitTranscriptionAPIKey() {
        let trimmed = transcriptionAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        transcriptionAPIKeyInput = trimmed
        guard appState.transcriptionAPIKey != trimmed else { return }
        appState.transcriptionAPIKey = trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("API Base URL")
                .font(.caption.weight(.semibold))

            Text("Change this to use a different OpenAI-compatible API provider.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField(AppState.defaultAPIBaseURL, text: $apiBaseURLInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($isEditingAPIBaseURL)
                    .onSubmit {
                        commitAPIBaseURL()
                    }
                    .onChange(of: isEditingAPIBaseURL) { isEditing in
                        if !isEditing {
                            commitAPIBaseURL()
                        }
                    }

                Button("Reset to Default") {
                    apiBaseURLInput = AppState.defaultAPIBaseURL
                    appState.apiBaseURL = AppState.defaultAPIBaseURL
                }
                .font(.caption)
            }

            if showsModelDescription {
                Text("If you use another provider, enter that provider's model IDs here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ModelDropdownView(
                title: "Post-Processing Model",
                subtitle: "Used for transcript cleanup and Edit Mode transforms.",
                predefinedModels: ModelConfiguration.llmModels,
                defaultModel: AppState.defaultPostProcessingModel,
                textDraft: $postProcessingModelDraft,
                onCommit: commitPostProcessingModel,
                onReset: {
                    postProcessingModelDraft = AppState.defaultPostProcessingModel
                    appState.postProcessingModel = AppState.defaultPostProcessingModel
                }
            )

            ModelDropdownView(
                title: "Post-Processing Fallback Model",
                subtitle: "Used as the explicit retry model for transcript cleanup and Edit Mode transforms.",
                predefinedModels: ModelConfiguration.llmModels,
                defaultModel: AppState.defaultPostProcessingFallbackModel,
                textDraft: $postProcessingFallbackModelDraft,
                onCommit: commitPostProcessingFallbackModel,
                onReset: {
                    postProcessingFallbackModelDraft = AppState.defaultPostProcessingFallbackModel
                    appState.postProcessingFallbackModel = AppState.defaultPostProcessingFallbackModel
                }
            )

            ModelDropdownView(
                title: "Context Model",
                subtitle: "Used for context inference, with a text-only retry when screenshot analysis fails.",
                predefinedModels: ModelConfiguration.llmModels,
                defaultModel: AppState.defaultContextModel,
                textDraft: $contextModelDraft,
                onCommit: commitContextModel,
                onReset: {
                    contextModelDraft = AppState.defaultContextModel
                    appState.contextModel = AppState.defaultContextModel
                }
            )

            ModelDropdownView(
                title: "Transcription Model",
                subtitle: "Used for speech-to-text transcription.",
                predefinedModels: ModelConfiguration.transcriptionModels,
                defaultModel: AppState.defaultTranscriptionModel,
                textDraft: $transcriptionModelDraft,
                onCommit: commitTranscriptionModel,
                onReset: {
                    transcriptionModelDraft = AppState.defaultTranscriptionModel
                    appState.transcriptionModel = AppState.defaultTranscriptionModel
                }
            )

            if showsTranscriptionLanguage {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Transcription Language")
                        .font(.caption.weight(.semibold))
                    Picker("", selection: $appState.transcriptionLanguage) {
                        ForEach(TranscriptionLanguage.all) { option in
                            Text(option.localizedDisplayName()).tag(option)
                        }
                    }
                    .accessibilityLabel("Transcription Language")
                    .labelsHidden()
                    Text("Hint to the transcription model. Auto Detect works for most users. Pick a specific language if you see wrong-script characters appear in the output.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Transcription API URL")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 8) {
                    TextField("Uses API Base URL when empty", text: $transcriptionAPIURLInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .focused($transcriptionAPIURLFocused)
                        .onSubmit {
                            commitTranscriptionAPIURL()
                        }
                        .onChange(of: transcriptionAPIURLFocused) { isFocused in
                            if !isFocused {
                                commitTranscriptionAPIURL()
                            }
                        }
                    if !transcriptionAPIURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Clear") {
                            transcriptionAPIURLInput = ""
                            appState.transcriptionAPIURL = ""
                        }
                        .font(.caption)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Transcription API Key")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 8) {
                    SecureField("Uses API Key when empty", text: $transcriptionAPIKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .focused($transcriptionAPIKeyFocused)
                        .onSubmit {
                            commitTranscriptionAPIKey()
                        }
                        .onChange(of: transcriptionAPIKeyFocused) { isFocused in
                            if !isFocused {
                                commitTranscriptionAPIKey()
                            }
                        }
                    if !transcriptionAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Clear") {
                            transcriptionAPIKeyInput = ""
                            appState.transcriptionAPIKey = ""
                        }
                        .font(.caption)
                    }
                }
            }

            Divider()

            Toggle(
                "Stream audio while recording (realtime)",
                isOn: $appState.realtimeStreamingEnabled
            )
            Text("Streams audio through the provider's OpenAI-compatible /v1/realtime WebSocket so transcription runs while you speak.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Realtime Transcription Model")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 8) {
                    TextField("Required by some providers, e.g. gpt-4o-transcribe", text: $realtimeStreamingModelDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($isEditingRealtimeStreamingModel)
                        .onSubmit {
                            commitRealtimeStreamingModel()
                        }
                        .onChange(of: isEditingRealtimeStreamingModel) { isEditing in
                            if !isEditing {
                                commitRealtimeStreamingModel()
                            }
                        }
                    if !realtimeStreamingModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Reset") {
                            realtimeStreamingModelDraft = ""
                            appState.realtimeStreamingModel = ""
                        }
                        .font(.caption)
                    }
                }
                Text("Used only for realtime streaming. Leave empty for providers that supply a server default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            transcriptionModelDraft = appState.transcriptionModel
            realtimeStreamingModelDraft = appState.realtimeStreamingModel
            postProcessingModelDraft = appState.postProcessingModel
            postProcessingFallbackModelDraft = appState.postProcessingFallbackModel
            contextModelDraft = appState.contextModel
        }
        .onChange(of: appState.transcriptionModel) { value in
            if !isEditingTranscriptionModel {
                transcriptionModelDraft = value
            }
        }
        .onChange(of: appState.realtimeStreamingModel) { value in
            if !isEditingRealtimeStreamingModel {
                realtimeStreamingModelDraft = value
            }
        }
        .onChange(of: appState.postProcessingModel) { value in
            if !isEditingPostProcessingModel {
                postProcessingModelDraft = value
            }
        }
        .onChange(of: appState.postProcessingFallbackModel) { value in
            if !isEditingPostProcessingFallbackModel {
                postProcessingFallbackModelDraft = value
            }
        }
        .onChange(of: appState.contextModel) { value in
            if !isEditingContextModel {
                contextModelDraft = value
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.orderedCases.filter { ($0 != .debug && $0 != .runLog) || AppBuild.isDevBundle }) { tab in
                    Button {
                        appState.selectedSettingsTab = tab
                    } label: {
                        SettingsSidebarRow(title: localizedCatalogString(tab.title), icon: tab.icon)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(appState.selectedSettingsTab == tab
                                          ? Color.accentColor.opacity(0.15)
                                          : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(10)
            .frame(width: 180)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Group {
                switch appState.selectedSettingsTab {
                case .general, .none:
                    GeneralSettingsView()
                case .appearance:
                    AppearanceSettingsView()
                case .models:
                    ModelsSettingsView()
                case .shortcuts:
                    ShortcutsSettingsView()
                case .input:
                    InputSettingsView()
                case .calendar:
                    CalendarSettingsView()
                case .about:
                    AboutSettingsView()
                case .runLog where AppBuild.isDevBundle:
                    RunLogView()
                case .debug where AppBuild.isDevBundle:
                    DebugSettingsView()
                case .runLog, .debug:
                    GeneralSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDisappear {
            appState.cancelNativeWhisperInstallForSettingsClose()
        }
    }
}

private struct SettingsSidebarRow: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 16, height: 16, alignment: .center)
                .foregroundStyle(.primary)

            Text(title)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
    }
}

// localization-exclusion: developer-diagnostics-start
// MARK: - Debug Settings

struct DebugSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Debug")
                    .font(.largeTitle.bold())

                SettingsCard("Overlay", icon: "wrench.and.screwdriver") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Show the recording overlay with simulated audio levels.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button(appState.isDebugOverlayActive ? "Stop Debug Overlay" : "Debug Overlay") {
                            appState.toggleDebugOverlay()
                        }
                    }
                }

                SettingsCard("Update Overlay", icon: "arrow.down.circle") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Display the update available overlay after dictation finishes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Toggle("Show after dictation", isOn: $appState.debugShowsUpdateReminderAfterDictation)

                        Button("Show Update Overlay Now") {
                            appState.showDebugUpdateAvailableOverlay()
                        }
                    }
                }

                SettingsCard("Meeting Reminder", icon: "calendar") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Show a sample calendar reminder overlay. Turn on Debug Overlay first to preview the recording (wrapping) variant.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button("Show Meeting Reminder") {
                            appState.showDebugMeetingReminderOverlay()
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// localization-exclusion: developer-diagnostics-end

// MARK: - Appearance Settings

struct AppearanceSettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("app_appearance") private var appAppearance: String = "system"
    @AppStorage("overlay_display_id") private var overlayDisplayID = 0
    @State private var screensVersion = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("App Appearance", icon: "circle.lefthalf.filled") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Theme")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $appAppearance) {
                            Text("System Setting").tag("system")
                            Text("Light").tag("light")
                            Text("Dark").tag("dark")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: appAppearance) { value in
                            applyAppearance(value)
                        }
                    }
                }

                SettingsCard("Note Browser", icon: "note.text") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Enable Note Browser", isOn: $appState.noteBrowserEnabled)
                        Text("Click the Dock icon to open Note Browser and browse your dictation history like notes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsCard("Recording Overlay", icon: "rectangle.topthird.inset.filled") {
                    VStack(spacing: 10) {
                        OverlayLayoutOptionRow(
                            title: "Notch-side menu-bar overlay",
                            subtitle: "Shows recording status beside the camera notch when supported, without covering app tabs or toolbars.",
                            layout: .notchSides,
                            selection: $appState.recordingOverlayLayout
                        )
                        OverlayLayoutOptionRow(
                            title: "Centered drop-down pill",
                            subtitle: "Shows a single centered pill below the menu bar. More visible, but it can cover a thin strip of the active app.",
                            layout: .centered,
                            selection: $appState.recordingOverlayLayout
                        )

                        Divider()

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Waveform display")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)

                            OverlayWaveformModeOptionRow(
                                title: "Waveform only",
                                subtitle: "Show the live audio waveform while recording.",
                                mode: .waveformOnly,
                                selection: $appState.overlayWaveformDisplayMode
                            )
                            OverlayWaveformModeOptionRow(
                                title: "Show elapsed time on hover",
                                subtitle: "Show the waveform; hover it to peek the elapsed recording time.",
                                mode: .hoverTime,
                                selection: $appState.overlayWaveformDisplayMode
                            )
                            OverlayWaveformModeOptionRow(
                                title: "Show elapsed time instead of waveform",
                                subtitle: "Replace the waveform with a running elapsed-time counter.",
                                mode: .timeOnly,
                                selection: $appState.overlayWaveformDisplayMode
                            )
                        }

                        Divider()

                        overlayDisplaySection
                    }
                }
            }
            .padding(24)
        }
    }

    /// Picks which physical display the recording overlay drops down on.
    private var overlayDisplaySection: some View {
        HStack {
            Text("Show on")
                .font(.system(size: 13))
            Spacer()
            Picker("", selection: $overlayDisplayID) {
                Text("Active window (default)").tag(0)
                Text("Primary display").tag(-1)
                ForEach(connectedScreenEntries, id: \.tag) { entry in
                    Text(verbatim: entry.name).tag(entry.tag)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Show on")
            .pickerStyle(.menu)
            .frame(maxWidth: 240)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screensVersion &+= 1
        }
    }

    private var connectedScreenEntries: [(name: String, tag: Int)] {
        _ = screensVersion
        return NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            return (name: screen.localizedName, tag: Int(id))
        }
    }

    private func applyAppearance(_ value: String) {
        switch value {
        case "light":  NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":   NSApp.appearance = NSAppearance(named: .darkAqua)
        default:       NSApp.appearance = nil
        }
    }
}

struct OverlayLayoutOptionRow: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let layout: RecordingOverlayLayout
    @Binding var selection: RecordingOverlayLayout

    private var isSelected: Bool {
        selection == layout
    }

    var body: some View {
        Button {
            selection = layout
        } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary)

                OverlayLayoutPreview(layout: layout)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(.plain)
        // Combine so VoiceOver reads the subtitle too, not just the title.
        .accessibilityElement(children: .combine)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

struct OverlayWaveformModeOptionRow: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let mode: OverlayWaveformDisplayMode
    @Binding var selection: OverlayWaveformDisplayMode

    private var isSelected: Bool {
        selection == mode
    }

    var body: some View {
        Button {
            selection = mode
        } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(.plain)
        // Combine so VoiceOver reads the subtitle too, not just the title.
        .accessibilityElement(children: .combine)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

struct OverlayLayoutPreview: View {
    let layout: RecordingOverlayLayout

    private let frameWidth: CGFloat = 110
    private let frameHeight: CGFloat = 56
    private let menuBarHeight: CGFloat = 8
    private let notchWidth: CGFloat = 26
    private let notchHeight: CGFloat = 8

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
                )

            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: menuBarHeight)

            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.primary.opacity(0.18))
                        .frame(height: 5)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, menuBarHeight + 4)

            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 3,
                bottomTrailingRadius: 3,
                topTrailingRadius: 0
            )
            .fill(Color.black)
            .frame(width: notchWidth, height: notchHeight)

            if layout == .notchSides {
                HStack(spacing: notchWidth) {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 3,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0
                    )
                    .fill(Color.black)
                    .frame(width: 16, height: notchHeight)

                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 3,
                        topTrailingRadius: 0
                    )
                    .fill(Color.black)
                    .frame(width: 16, height: notchHeight)
                }
            } else {
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 5,
                    bottomTrailingRadius: 5,
                    topTrailingRadius: 0
                )
                .fill(Color.black)
                .frame(width: notchWidth + 10, height: notchHeight + 12)
            }
        }
        .frame(width: frameWidth, height: frameHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Calendar Settings

struct CalendarSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined

    private var selectedCalendarCount: Int {
        appState.googleCalendarConnection.selectedCalendarIDs.count
    }

    private var calendarReminderSettingsDisabled: Bool {
        !appState.googleCalendarConnection.isConnected || selectedCalendarCount == 0
    }

    private var connectionControls: GoogleCalendarConnectionControls {
        appState.googleCalendarConnectionControls
    }

    private var calendarRecordingRemindersEnabledBinding: Binding<Bool> {
        Binding(
            get: { appState.calendarRecordingRemindersEnabled },
            set: { enabled in
                appState.calendarRecordingRemindersEnabled = enabled
                guard enabled else { return }
                handleCalendarReminderNotificationAuthorization()
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Calendar")
                    .font(.largeTitle.bold())

                SettingsCard("Google Calendar", icon: "calendar") {
                    googleCalendarSection
                }

                SettingsCard("Meeting Recording Reminders", icon: "bell.badge") {
                    calendarRecordingReminderSection
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            appState.loadStoredGoogleCalendarConnection()
            refreshNotificationAuthorizationStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshNotificationAuthorizationStatus()
        }
    }

    @ViewBuilder
    private var googleCalendarConnectionStatusLabel: some View {
        if appState.googleCalendarConnection.isConnected {
            switch appState.googleCalendarConnection.health.status {
            case .unknown:
                Label("Connected · Not checked yet", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            case .healthy:
                Label(googleCalendarHealthyStatusTitle, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .needsReconnect:
                Label("Reconnect required", systemImage: "calendar.badge.exclamationmark")
                    .foregroundStyle(.red)
            case .temporaryFailure:
                Label("Calendar refresh issue", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } else {
            Label("Not connected", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var googleCalendarHealthyStatusTitle: String {
        guard let checkedAt = appState.googleCalendarConnection.health.checkedAt else {
            return "Connected"
        }
        return "Connected · Last checked \(checkedAt.formatted(date: .omitted, time: .shortened))"
    }

    private var googleCalendarHealthMessage: String? {
        guard appState.googleCalendarConnection.isConnected else { return nil }
        let health = appState.googleCalendarConnection.health
        switch health.status {
        case .unknown, .healthy:
            return nil
        case .needsReconnect:
            return health.message ?? "Quill can’t access Google Calendar. Reconnect to restore meeting reminders and calendar-based note titles."
        case .temporaryFailure:
            return health.message ?? "Quill couldn’t refresh Google Calendar just now. Recording still works; reminders or note titles may be incomplete."
        }
    }

    private var googleCalendarReminderHealthMessage: String? {
        guard appState.googleCalendarConnection.isConnected else { return nil }
        let health = appState.googleCalendarConnection.health
        guard health.affectedFeature == .recordingReminders else { return nil }
        switch health.status {
        case .needsReconnect:
            return "Reconnect Google Calendar to keep meeting recording reminders working."
        case .temporaryFailure:
            return "Calendar reminders may be incomplete until the next successful refresh."
        case .unknown, .healthy:
            return nil
        }
    }

    private var googleCalendarHealthMessageIcon: String {
        appState.googleCalendarConnection.health.status == .needsReconnect
            ? "calendar.badge.exclamationmark"
            : "exclamationmark.triangle.fill"
    }

    private var googleCalendarHealthMessageColor: Color {
        appState.googleCalendarConnection.health.status == .needsReconnect ? .red : .orange
    }

    private func calendarRefreshIntervalTitle(_ minutes: Int) -> String {
        minutes == 60 ? "Every hour" : "Every \(minutes) minutes"
    }

    @ViewBuilder
    private func refreshActivityIndicator(isVisible: Bool) -> some View {
        if isVisible {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .allowsHitTesting(false)
                .accessibilityLabel("Refreshing")
        }
    }

    private var googleCalendarSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect your Google account to let Quill suggest note titles from matching calendar events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !appState.googleCalendarOAuthConfiguration.isConfigured {
                    Text("Google Calendar sign-in is not configured for this build.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                googleCalendarConnectionStatusLabel
                if appState.googleCalendarConnection.isConnected,
                   let email = appState.googleCalendarConnection.accountEmail,
                   !email.isEmpty {
                    Text(verbatim: email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let healthMessage = googleCalendarHealthMessage {
                Label(healthMessage, systemImage: googleCalendarHealthMessageIcon)
                    .font(.caption)
                    .foregroundStyle(googleCalendarHealthMessageColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(connectionControls.primaryActionTitle) {
                    if appState.hasPendingGoogleCalendarOAuthConnection {
                        appState.cancelGoogleCalendarConnection()
                    } else {
                        appState.connectGoogleCalendar()
                    }
                }
                .disabled(!connectionControls.allowsPrimaryAction)

                Button("Sync Now") {
                    appState.refreshGoogleCalendars()
                }
                .disabled(!connectionControls.allowsRefresh)

                Button("Disconnect") {
                    appState.disconnectGoogleCalendar()
                }
                .disabled(!connectionControls.allowsDisconnect)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                refreshActivityIndicator(isVisible: appState.isGoogleCalendarBusy)
            }

            if appState.googleCalendarConnection.isConnected {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Refresh calendars")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Refresh calendars", selection: $appState.calendarRecordingReminderRefreshIntervalMinutes) {
                            ForEach(CalendarRecordingReminderScheduler.refreshIntervalMinuteOptions, id: \.self) { minutes in
                                Text(calendarRefreshIntervalTitle(minutes)).tag(minutes)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .disabled(!appState.googleCalendarConnection.isConnected)
                    }
                    Text("Quill re-reads selected Google Calendar events on this interval to keep meeting reminders and calendar-based note titles current.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if googleCalendarHealthMessage == nil,
               let error = appState.googleCalendarConnection.lastErrorMessage,
               !error.isEmpty {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if appState.googleCalendarConnection.isConnected {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Calendars used for note title suggestions")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if appState.availableGoogleCalendars.isEmpty {
                        Text("No calendars loaded. Click Sync Now after connecting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(appState.availableGoogleCalendars.groupedForQuillDisplay(), id: \.title) { group in
                                calendarGroupSection(group)
                            }
                        }
                    }
                    Text("No calendars are selected by default. Quill only reads events from calendars you explicitly select.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var calendarRecordingReminderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(
                "Remind me before meetings to record",
                isOn: calendarRecordingRemindersEnabledBinding
            )
            .disabled(calendarReminderSettingsDisabled)

            Text("Quill schedules macOS notifications for events in your selected calendars. Clicking a reminder starts recording without toggling an active recording off.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !appState.googleCalendarConnection.isConnected {
                Label("Connect Google Calendar first.", systemImage: "calendar.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if selectedCalendarCount == 0 {
                Label("Select at least one calendar above.", systemImage: "checklist")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let reminderHealthMessage = googleCalendarReminderHealthMessage {
                Label(reminderHealthMessage, systemImage: "calendar.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(googleCalendarHealthMessageColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if notificationAuthorizationStatus == .denied {
                Label("Notifications are disabled in System Settings.", systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Reminder times")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 112), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(CalendarRecordingReminderScheduler.leadMinuteOptions, id: \.self) { minutes in
                        let isSelected = appState.calendarRecordingReminderLeadMinutes.contains(minutes)
                        Button {
                            appState.setCalendarRecordingReminderLeadTime(minutes, isSelected: !isSelected)
                        } label: {
                            Label(
                                "\(minutes) min before",
                                systemImage: isSelected ? "checkmark.circle.fill" : "circle"
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(
                            calendarReminderSettingsDisabled
                                || !appState.calendarRecordingRemindersEnabled
                                || (isSelected && appState.calendarRecordingReminderLeadMinutes.count == 1)
                        )
                    }
                }
            }
        }
    }

    private func handleCalendarReminderNotificationAuthorization() {
        Task {
            let settings = await AppNotificationManager.shared.notificationSettings()
            await MainActor.run {
                notificationAuthorizationStatus = settings.authorizationStatus
                switch settings.authorizationStatus {
                case .denied:
                    openNotificationSettings()
                case .notDetermined:
                    requestNotificationPermission()
                default:
                    break
                }
            }
        }
    }

    private func requestNotificationPermission() {
        Task {
            _ = await AppNotificationManager.shared.requestAuthorization()
            refreshNotificationAuthorizationStatus()
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
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

    private func calendarGroupSection(_ group: GoogleCalendarDisplayGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(localizedCatalogString(group.title))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.4)
                Text("\(group.calendars.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(group.calendars) { calendar in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Toggle(
                            isOn: Binding(
                                get: { appState.googleCalendarConnection.selectedCalendarIDs.contains(calendar.id) },
                                set: { appState.setGoogleCalendarSelected(calendar.id, isSelected: $0) }
                            )
                        ) {
                            Text(verbatim: calendar.displayName)
                        }
                        .toggleStyle(.checkbox)

                        Text(localizedCatalogString(calendarDisplayKind(calendar)))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
    }

    private func calendarDisplayKind(_ calendar: GoogleCalendarInfo) -> String {
        if calendar.primary { return "Primary" }
        switch calendar.accessRole {
        case "owner", "writer": return "My calendar"
        default: return "Shared"
        }
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openURL) private var openURL
    @AppStorage("show_menu_bar_icon") private var showMenuBarIcon = true
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var micPermissionGranted = false
    @State private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Quill"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("App", icon: "power") {
                    startupSection
                }
                SettingsCard("Updates", icon: "arrow.triangle.2.circlepath") {
                    updatesSection
                }
                SettingsCard("Permissions", icon: "lock.shield.fill") {
                    permissionsSection
                }
            }
            .padding(24)
        }
        .onAppear {
            appState.refreshLaunchAtLoginStatus()
            checkMicPermission()
            refreshNotificationAuthorizationStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshNotificationAuthorizationStatus()
        }
    }

    // MARK: Startup

    private var startupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Launch Quill at login", isOn: $appState.launchAtLogin)
            Toggle("Show menu bar icon", isOn: $showMenuBarIcon)

            if SMAppService.mainApp.status == .requiresApproval {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("Login item requires approval in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: Updates

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updateManager.autoCheckEnabled },
                set: { updateManager.autoCheckEnabled = $0 }
            ))

            HStack(spacing: 10) {
                Button {
                    Task {
                        await updateManager.checkForUpdates(userInitiated: true)
                    }
                } label: {
                    if updateManager.isChecking {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking...")
                        }
                    } else {
                        Text("Check for Updates Now")
                    }
                }
                .disabled(updateManager.isChecking)

                if let lastCheck = updateManager.lastCheckDate {
                    Text("Last checked: \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Updates are delivered by Sparkle and verified before installation.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if updateManager.updateAvailable || updateManager.updateStatus != .idle {
                VStack(alignment: .leading, spacing: 8) {
                    switch updateManager.updateStatus {
                    case .downloading:
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Downloading update...")
                                .font(.caption.weight(.semibold))
                        }

                    case .installing:
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Preparing update...")
                                .font(.caption.weight(.semibold))
                        }

                    case .readyToRelaunch:
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Relaunching...")
                                .font(.caption.weight(.semibold))
                        }

                    case .error(let message):
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                            Spacer()
                            Button("Check Again") {
                                Task {
                                    await updateManager.checkForUpdates(userInitiated: true)
                                }
                            }
                            .font(.caption)
                        }

                    case .idle:
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(.blue)
                            Text(updateManager.latestReleaseVersion.isEmpty
                                ? "A new version of \(appDisplayName) is available!"
                                : "\(appDisplayName) v\(updateManager.latestReleaseVersion) is available!")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Button("What's New") {
                                updateManager.showReleaseNotes()
                            }
                            .font(.caption)
                            Button("Update Now") {
                                updateManager.showUpdateAlert()
                            }
                            .font(.caption)
                        }
                    }
                }
                .padding(10)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
            }
        }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            permissionRow(
                title: "Microphone",
                icon: "mic.fill",
                granted: micPermissionGranted,
                action: {
                    appState.requestMicrophoneAccess { granted in
                        micPermissionGranted = granted
                    }
                }
            )
            permissionRow(
                title: "Accessibility",
                icon: "hand.raised.fill",
                granted: appState.hasAccessibility,
                action: { appState.openAccessibilitySettings() }
            )
            permissionRow(
                title: "Speech Recognition",
                icon: "waveform.badge.mic",
                granted: appState.hasSpeechRecognitionPermission,
                action: { appState.requestSpeechRecognitionAccess() }
            )
            permissionRow(
                title: "Screen Recording",
                icon: "camera.viewfinder",
                granted: appState.hasScreenRecordingPermission,
                action: { appState.requestScreenCapturePermission() }
            )
            permissionRow(
                title: "Notifications",
                icon: "bell.fill",
                granted: notificationAuthorizationGranted,
                actionTitle: notificationAuthorizationStatus == .denied ? "Open Settings" : "Grant Access",
                action: {
                    if notificationAuthorizationStatus == .denied {
                        openNotificationSettings()
                    } else {
                        requestNotificationPermission()
                    }
                }
            )
        }
    }

    private func permissionRow(
        title: LocalizedStringKey,
        icon: String,
        granted: Bool,
        actionTitle: LocalizedStringKey = "Grant Access",
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.blue)
            Text(title)
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Granted")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button(actionTitle) { action() }
                    .font(.caption)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }

    private var notificationAuthorizationGranted: Bool {
        notificationAuthorizationStatus == .authorized || notificationAuthorizationStatus == .provisional
    }

    private func requestNotificationPermission() {
        Task {
            _ = await AppNotificationManager.shared.requestAuthorization()
            refreshNotificationAuthorizationStatus()
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
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

    private func checkMicPermission() {
        micPermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}

// MARK: - Models Settings

struct ModelsSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var apiKeyInput: String = ""
    @State private var apiBaseURLInput: String = ""
    @State private var transcriptionAPIURLInput: String = ""
    @State private var transcriptionAPIKeyInput: String = ""
    @State private var showingLocalTranscriptionSettings = true
    @State private var isValidatingKey = false
    @State private var keyValidationError: String?
    @State private var keyValidationSuccess = false
    @State private var customVocabularyInput: String = ""
    @State private var advancedProviderSettingsExpanded = false

    @State private var customSystemPromptInput: String = ""
    @State private var customContextPromptInput: String = ""
    @State private var showDefaultSystemPrompt = false
    @State private var showDefaultContextPrompt = false
    @State private var systemTestInput: String = "Um, so I was like, thinking we should uh, refactor the authentication module, you know?"
    @State private var systemTestRunning = false
    @State private var systemTestOutput: String? = nil
    @State private var systemTestError: String? = nil
    @State private var systemTestPrompt: String? = nil
    @State private var contextTestRunning = false
    @State private var contextTestOutput: String? = nil
    @State private var contextTestError: String? = nil
    @State private var contextTestPrompt: String? = nil

    private struct OutputLanguageOption {
        let label: LocalizedStringKey
        let value: String // Persisted prompt/API value; never localize.
    }

    private static let outputLanguageOptions: [OutputLanguageOption] = [
        .init(label: "Same as spoken language", value: ""),
        .init(label: "English", value: "English"),
        .init(label: "Korean", value: "Korean"),
        .init(label: "Japanese", value: "Japanese"),
        .init(label: "Chinese", value: "Chinese"),
        .init(label: "Spanish", value: "Spanish"),
        .init(label: "French", value: "French"),
        .init(label: "German", value: "German"),
        .init(label: "Portuguese", value: "Portuguese"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("Transcription", icon: "waveform.badge.magnifyingglass") {
                    transcriptionSection
                }
                SettingsCard("Language", icon: "globe") {
                    languageSettings
                }
                SettingsCard("Custom Vocabulary", icon: "text.book.closed.fill") {
                    vocabularySection
                }
                SettingsCard("System Prompt", icon: "text.bubble.fill") {
                    systemPromptSection
                }
                SettingsCard("Instruction Guard", icon: "shield.lefthalf.filled") {
                    instructionGuardSection
                }
                SettingsCard("Context Prompt", icon: "eye.fill") {
                    contextPromptSection
                }
            }
            .padding(24)
        }
        .onAppear {
            apiKeyInput = appState.apiKey
            apiBaseURLInput = appState.apiBaseURL
            transcriptionAPIURLInput = appState.transcriptionAPIURL
            transcriptionAPIKeyInput = appState.transcriptionAPIKey
            showingLocalTranscriptionSettings = appState.useLocalTranscription
            customVocabularyInput = appState.customVocabulary
            customSystemPromptInput = appState.customSystemPrompt.isEmpty
                ? PostProcessingService.defaultSystemPrompt
                : appState.customSystemPrompt
            customContextPromptInput = appState.customContextPrompt.isEmpty
                ? AppContextService.defaultContextPrompt
                : appState.customContextPrompt
        }
        .onChange(of: appState.transcriptionAPIURL) { value in
            if transcriptionAPIURLInput != value { transcriptionAPIURLInput = value }
        }
        .onChange(of: appState.transcriptionAPIKey) { value in
            if transcriptionAPIKeyInput != value { transcriptionAPIKeyInput = value }
        }
    }

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Transcription Mode")
                    .font(.caption.weight(.semibold))

                Picker("Transcription Mode", selection: $showingLocalTranscriptionSettings) {
                    Text("Local").tag(true)
                    Text("API Provider").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: showingLocalTranscriptionSettings) { showsLocal in
                    if showsLocal {
                        appState.useLocalTranscription = true
                    } else if appState.hasTranscriptionAPIKey {
                        appState.setNoteBrowserTranscriptionMode(.apiStandard)
                    }
                }

                Text(showingLocalTranscriptionSettings
                    ? "Run speech recognition on this Mac and configure only local transcription options."
                    : "Use your configured OpenAI-compatible provider and configure only provider-specific options.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if showingLocalTranscriptionSettings {
                localTranscriptionSettings
            } else {
                apiProviderTranscriptionSettings
            }

            Divider()

            sharedTranscriptionBehaviors
        }
    }

    private var localTranscriptionSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Local Options")
                    .font(.caption.weight(.semibold))

                ModelRowView(
                    model: TranscriptionModel.find(id: "apple-speech"),
                    isSelected: appState.localTranscriptionModel.isAppleSpeech,
                    whisperBin: "",
                    onSelect: {
                        appState.localTranscriptionModel = .find(id: "apple-speech")
                        appState.useLegacyMlxWhisper = false
                    },
                    onDeleted: {}
                )

                NativeWhisperModelRowView(
                    isSelected: !appState.localTranscriptionModel.isAppleSpeech && !appState.useLegacyMlxWhisper,
                    onSelect: {
                        appState.useLocalTranscription = true
                        appState.localTranscriptionModel = .find(id: "mlx-community/whisper-large-v3-turbo")
                        appState.useLegacyMlxWhisper = false
                    }
                )
                Text("If you close Settings while the model is downloading, Quill cancels the download and removes the partial file.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Advanced Legacy mlx-whisper") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Use legacy mlx-whisper", isOn: $appState.showLegacyMlxWhisperOptions)
                    Text("Only enable this if you already manage mlx-whisper yourself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(TranscriptionModel.all.filter { !$0.isAppleSpeech }) { model in
                        ModelRowView(
                            model: model,
                            isSelected: appState.useLegacyMlxWhisper && appState.localTranscriptionModel.id == model.id,
                            whisperBin: appState.localWhisperPath.isEmpty
                                ? "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin/mlx_whisper"
                                : appState.localWhisperPath,
                            onSelect: {
                                appState.useLocalTranscription = true
                                appState.useLegacyMlxWhisper = true
                                appState.showLegacyMlxWhisperOptions = true
                                appState.localTranscriptionModel = model
                            },
                            onDeleted: {
                                appState.localTranscriptionModel = .find(id: "mlx-community/whisper-large-v3-turbo")
                                appState.useLegacyMlxWhisper = false
                            }
                        )
                        .disabled(!appState.showLegacyMlxWhisperOptions)
                        .opacity(appState.showLegacyMlxWhisperOptions ? 1 : 0.55)
                    }

                    TextField("~/.local/bin/mlx_whisper", text: $appState.localWhisperPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .disabled(!appState.showLegacyMlxWhisperOptions)
                }
                .padding(.top, 4)
            }
        }
    }

    private var apiProviderTranscriptionSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("API Provider Options")
                .font(.caption.weight(.semibold))

            Text("Quill uses the configured transcription model with your selected OpenAI-compatible provider.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                SecureField("Enter your Groq API key", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(isValidatingKey)
                    .onChange(of: apiKeyInput) { _ in
                        keyValidationError = nil
                        keyValidationSuccess = false
                    }

                Button(isValidatingKey ? "Validating..." : "Save") {
                    validateAndSaveKey()
                }
                .disabled(isValidatingKey)
            }

            if let error = keyValidationError {
                Label(error, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            } else if keyValidationSuccess {
                Label(appState.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "API key cleared" : "API key saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }

            DisclosureGroup(isExpanded: $advancedProviderSettingsExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    ProviderSettingsFields(
                        apiBaseURLInput: $apiBaseURLInput,
                        transcriptionAPIURLInput: $transcriptionAPIURLInput,
                        transcriptionAPIKeyInput: $transcriptionAPIKeyInput,
                        showsModelDescription: false,
                        showsTranscriptionLanguage: false
                    )
                }
            } label: {
                HStack {
                    Text("Advanced Provider Settings")
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { advancedProviderSettingsExpanded.toggle() }
            }
            .padding(.top, 4)
        }
    }

    private var languageSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Transcription Language", selection: $appState.transcriptionLanguage) {
                    ForEach(TranscriptionLanguage.all) { lang in
                        Text(lang.localizedDisplayName()).tag(lang)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 240, alignment: .leading)

                Text("Spoken language hint for speech recognition. Auto Detect works for most users.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Picker("Output Language", selection: $appState.outputLanguage) {
                    ForEach(Self.outputLanguageOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 280, maxWidth: 320, alignment: .leading)
                .disabled(appState.disablePostProcessing || appState.useLocalTranscription)

                Text(outputLanguageHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var outputLanguageHelpText: String {
        let key: String
        if appState.useLocalTranscription { key = "Use API Provider transcription to choose a final output language." }
        else if appState.disablePostProcessing { key = "Enable post-processing to choose a final output language." }
        else { key = "Final transcript language for post-processing." }
        return localizedCatalogString(key)
    }

    private var sharedTranscriptionBehaviors: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shared Behaviors")
                .font(.caption.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Disable Post-Processing", isOn: $appState.disablePostProcessing)
                Text("Skip LLM cleanup. Raw transcript is used as-is. No API call is made for post-processing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Preserve Exact Wording", isOn: $appState.preserveExactWording)
                    .disabled(appState.disablePostProcessing)
                Text("Skip cleanup while post-processing is enabled. Without an Output Language, the raw transcript is used. With one, only a literal translation is performed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .opacity(appState.disablePostProcessing ? 0.55 : 1)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Disable Auto Paste", isOn: $appState.disableAutoPaste)
                Text("Transcription will be copied to clipboard only. Paste manually when needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Disable Context Capture", isOn: $appState.disableContextCapture)
                Text("Skip screen recording and app context detection. Transcription will not adapt to the current app. Screen Recording permission is not required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Words and phrases to preserve during post-processing.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $customVocabularyInput)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 80, maxHeight: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .onChange(of: customVocabularyInput) { newValue in
                    appState.customVocabulary = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                }

            Text("Separate entries with commas, new lines, or semicolons.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func validateAndSaveKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        keyValidationError = nil
        keyValidationSuccess = false
        if key.isEmpty {
            appState.apiKey = ""
            keyValidationSuccess = true
            isValidatingKey = false
            return
        }

        let baseURL = apiBaseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        isValidatingKey = true

        Task {
            let valid = await TranscriptionService.validateAPIKey(
                key,
                baseURL: baseURL.isEmpty ? AppState.defaultAPIBaseURL : baseURL
            )
            await MainActor.run {
                isValidatingKey = false
                if valid {
                    appState.apiKey = key
                    if !showingLocalTranscriptionSettings {
                        appState.setNoteBrowserTranscriptionMode(.apiStandard)
                    }
                    keyValidationSuccess = true
                } else {
                    keyValidationError = "Validation failed. Please check your API key and provider settings, then try again."
                }
            }
        }
    }

    // MARK: System Prompt

    private var instructionGuardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                "Prevent dictated prompts from being executed",
                isOn: $appState.instructionExecutionGuardEnabled
            )
            .toggleStyle(.switch)

            Text("When enabled, \(AppName.displayName) retries or falls back to the literal transcript if post-processing looks like it answered the dictated text instead of cleaning it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var systemPromptSection: some View {
        let isCustom = !appState.customSystemPrompt.isEmpty
        let hasNewerDefault = isCustom
            && !appState.customSystemPromptLastModified.isEmpty
            && appState.customSystemPromptLastModified < PostProcessingService.defaultSystemPromptDate

        return VStack(alignment: .leading, spacing: 10) {
            Text("Controls how raw transcriptions are cleaned up.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if hasNewerDefault {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.blue)
                    Text("A newer default prompt is available.")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("View Default") { showDefaultSystemPrompt.toggle() }
                        .font(.caption)
                    Button("Switch to Default") {
                        customSystemPromptInput = PostProcessingService.defaultSystemPrompt
                        appState.customSystemPrompt = ""
                        appState.customSystemPromptLastModified = ""
                    }
                    .font(.caption)
                }
                .padding(10)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
            }

            if showDefaultSystemPrompt {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Default System Prompt")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Button("Hide") { showDefaultSystemPrompt = false }
                            .font(.caption)
                    }
                    Text(verbatim: PostProcessingService.defaultSystemPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
            }

            TextEditor(text: $customSystemPromptInput)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120, maxHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                .onChange(of: customSystemPromptInput) { newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    let defaultTrimmed = PostProcessingService.defaultSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed == defaultTrimmed || trimmed.isEmpty {
                        if !appState.customSystemPrompt.isEmpty {
                            appState.customSystemPrompt = ""
                            appState.customSystemPromptLastModified = ""
                        }
                    } else {
                        appState.customSystemPrompt = trimmed
                        let today = iso8601DayFormatter.string(from: Date())
                        if appState.customSystemPromptLastModified != today {
                            appState.customSystemPromptLastModified = today
                        }
                    }
                }

            HStack {
                if isCustom {
                    Label("Using custom prompt", systemImage: "pencil")
                        .font(.caption)
                        .foregroundStyle(.blue)
                } else {
                    Label("Using default", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isCustom {
                    Button("Reset to Default") {
                        customSystemPromptInput = PostProcessingService.defaultSystemPrompt
                        appState.customSystemPrompt = ""
                        appState.customSystemPromptLastModified = ""
                    }
                    .font(.caption)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Test System Prompt")
                    .font(.caption.weight(.semibold))
                Text("Enter sample text to see how the current prompt cleans it up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $systemTestInput)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 100)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))

                Button {
                    runSystemPromptTest()
                } label: {
                    HStack(spacing: 6) {
                        if systemTestRunning {
                            ProgressView().controlSize(.small)
                            Text("Running...")
                        } else {
                            Image(systemName: "play.fill")
                            Text("Test System Prompt")
                        }
                    }
                }
                .disabled(systemTestRunning || appState.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || systemTestInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if appState.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("API key required to test", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let error = systemTestError {
                    Label(error, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let output = systemTestOutput {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Result:")
                            .font(.caption.weight(.semibold))
                        Text(output.isEmpty ? "(empty — no output)" : output)
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.08))
                            .cornerRadius(6)
                    }
                }

                if let prompt = systemTestPrompt {
                    DisclosureGroup("Full prompt sent") {
                        Text(prompt)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func runSystemPromptTest() {
        systemTestRunning = true
        systemTestOutput = nil
        systemTestError = nil
        systemTestPrompt = nil

        let service = PostProcessingService(
            apiKey: appState.apiKey,
            baseURL: appState.apiBaseURL,
            preferredModel: appState.postProcessingModel,
            preferredFallbackModel: appState.postProcessingFallbackModel,
            instructionExecutionGuardEnabled: appState.instructionExecutionGuardEnabled
        )
        let input = systemTestInput
        let customPrompt = appState.customSystemPrompt
        let vocabulary = appState.customVocabulary

        let context = AppContext(
            appName: "Quill Settings",
            bundleIdentifier: "com.woosublee.quill",
            windowTitle: "System Prompt Test",
            selectedText: nil,
            currentActivity: "User is testing the system prompt in Quill settings.",
            contextSystemPrompt: nil,
            contextPrompt: nil,
            screenshotDataURL: nil,
            screenshotMimeType: nil,
            screenshotError: nil
        )

        Task {
            do {
                let result = try await service.postProcess(
                    transcript: input,
                    context: context,
                    customVocabulary: vocabulary,
                    customSystemPrompt: customPrompt
                )
                await MainActor.run {
                    systemTestOutput = result.transcript
                    systemTestPrompt = result.prompt
                    systemTestRunning = false
                }
            } catch {
                await MainActor.run {
                    systemTestError = error.localizedDescription
                    systemTestRunning = false
                }
            }
        }
    }

    // MARK: Context Prompt

    private var contextPromptSection: some View {
        let isCustom = !appState.customContextPrompt.isEmpty
        let hasNewerDefault = isCustom
            && !appState.customContextPromptLastModified.isEmpty
            && appState.customContextPromptLastModified < AppContextService.defaultContextPromptDate

        return VStack(alignment: .leading, spacing: 10) {
            Text("Controls how Quill infers your current activity from app metadata and screenshots.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if hasNewerDefault {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.blue)
                    Text("A newer default prompt is available.")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("View Default") { showDefaultContextPrompt.toggle() }
                        .font(.caption)
                    Button("Switch to Default") {
                        customContextPromptInput = AppContextService.defaultContextPrompt
                        appState.customContextPrompt = ""
                        appState.customContextPromptLastModified = ""
                    }
                    .font(.caption)
                }
                .padding(10)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
            }

            if showDefaultContextPrompt {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Default Context Prompt")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Button("Hide") { showDefaultContextPrompt = false }
                            .font(.caption)
                    }
                    Text(verbatim: AppContextService.defaultContextPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
            }

            TextEditor(text: $customContextPromptInput)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120, maxHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                .onChange(of: customContextPromptInput) { newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    let defaultTrimmed = AppContextService.defaultContextPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed == defaultTrimmed || trimmed.isEmpty {
                        if !appState.customContextPrompt.isEmpty {
                            appState.customContextPrompt = ""
                            appState.customContextPromptLastModified = ""
                        }
                    } else {
                        appState.customContextPrompt = trimmed
                        let today = iso8601DayFormatter.string(from: Date())
                        if appState.customContextPromptLastModified != today {
                            appState.customContextPromptLastModified = today
                        }
                    }
                }

            HStack {
                if isCustom {
                    Label("Using custom prompt", systemImage: "pencil")
                        .font(.caption)
                        .foregroundStyle(.blue)
                } else {
                    Label("Using default", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isCustom {
                    Button("Reset to Default") {
                        customContextPromptInput = AppContextService.defaultContextPrompt
                        appState.customContextPrompt = ""
                        appState.customContextPromptLastModified = ""
                    }
                    .font(.caption)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Screenshot Resolution")
                    .font(.caption.weight(.semibold))
                Text("Controls the maximum image dimension sent for context inference.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: $appState.contextScreenshotMaxDimension) {
                    ForEach(AppState.contextScreenshotDimensionOptions, id: \.self) { dimension in
                        Text("\(dimension) px").tag(dimension)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Screenshot Resolution")

                HStack {
                    if appState.contextScreenshotMaxDimension == AppState.defaultContextScreenshotMaxDimension {
                        Label("Using default", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Using custom value", systemImage: "pencil")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    Spacer()
                    if appState.contextScreenshotMaxDimension != AppState.defaultContextScreenshotMaxDimension {
                        Button("Reset to Default") {
                            appState.contextScreenshotMaxDimension = AppState.defaultContextScreenshotMaxDimension
                        }
                        .font(.caption)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Test Context Prompt")
                    .font(.caption.weight(.semibold))
                Text("Captures a screenshot and metadata from the frontmost app, then runs the context prompt to infer activity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    runContextPromptTest()
                } label: {
                    HStack(spacing: 6) {
                        if contextTestRunning {
                            ProgressView().controlSize(.small)
                            Text("Running...")
                        } else {
                            Image(systemName: "play.fill")
                            Text("Test Context Prompt")
                        }
                    }
                }
                .disabled(contextTestRunning || appState.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if appState.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("API key required to test", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let error = contextTestError {
                    Label(error, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let output = contextTestOutput {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Result:")
                            .font(.caption.weight(.semibold))
                        Text(output.isEmpty ? "(empty — no output)" : output)
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.08))
                            .cornerRadius(6)
                    }
                }

                if let prompt = contextTestPrompt {
                    DisclosureGroup("Full prompt sent") {
                        Text(prompt)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func runContextPromptTest() {
        contextTestRunning = true
        contextTestOutput = nil
        contextTestError = nil
        contextTestPrompt = nil

        let service = appState.makeAppContextService()

        Task {
            let context = await service.collectContext()
            await MainActor.run {
                if let prompt = context.contextPrompt {
                    contextTestOutput = context.contextSummary
                    contextTestPrompt = prompt
                } else {
                    contextTestError = "Context inference returned no result. This may be a permissions issue or the API could not be reached."
                    contextTestOutput = context.contextSummary
                }
                contextTestRunning = false
            }
        }
    }
}

// MARK: - Shortcuts Settings

struct ShortcutsSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingAddMacro = false
    @State private var editingMacro: VoiceMacro?

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Quill"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("Dictation Shortcuts", icon: "keyboard.fill") {
                    hotkeySection
                }
                SettingsCard("Audio During Dictation", icon: "speaker.slash.fill") {
                    dictationAudioSection
                }
                SettingsCard("Edit Mode", icon: "pencil") {
                    commandModeSection
                }
                SettingsCard("Clipboard", icon: "doc.on.clipboard") {
                    clipboardSection
                }
                SettingsCard("Voice Macros", icon: "music.mic") {
                    macrosSection
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $showingAddMacro, onDismiss: { editingMacro = nil }) {
            VoiceMacroEditorView(isPresented: $showingAddMacro, macro: $editingMacro)
        }
    }

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            DictationShortcutEditor { isCapturing in
                if isCapturing {
                    appState.suspendHotkeyMonitoringForShortcutCapture()
                } else {
                    appState.resumeHotkeyMonitoringAfterShortcutCapture()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Shortcut Start Delay")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(appState.shortcutStartDelayMilliseconds) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Slider(value: $appState.shortcutStartDelay, in: 0...0.5, step: 0.025)

                Text("Applies before recording starts for both hold and tap shortcuts. Stopping still happens immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dictationAudioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                "Mute audio when dictation starts",
                isOn: $appState.dictationAudioInterruptionEnabled
            )
            Text("\(appDisplayName) restores the audio state it changed when dictation ends.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var commandModeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable Edit Mode", isOn: Binding(
                get: { appState.isCommandModeEnabled },
                set: { newValue in _ = appState.setCommandModeEnabled(newValue) }
            ))

            Text("Transform highlighted text with a spoken instruction instead of dictating over it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Invocation Style", selection: Binding(
                get: { appState.commandModeStyle },
                set: { newValue in _ = appState.setCommandModeStyle(newValue) }
            )) {
                ForEach(CommandModeStyle.allCases) { style in
                    Text(localizedCatalogString(style.title)).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!appState.isCommandModeEnabled)

            Group {
                switch appState.commandModeStyle {
                case .automatic:
                    Text("If text is selected, your normal dictation shortcut transforms the selection instead of dictating over it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .manual:
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Hold the extra modifier together with your normal dictation shortcut to transform selected text.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("Extra Modifier", selection: Binding(
                            get: { appState.commandModeManualModifier },
                            set: { newValue in _ = appState.setCommandModeManualModifier(newValue) }
                        )) {
                            ForEach(CommandModeManualModifier.allCases) { modifier in
                                Text(localizedCatalogString(modifier.title)).tag(modifier)
                            }
                        }
                        .disabled(!appState.isCommandModeEnabled || appState.commandModeStyle != .manual)
                    }
                }
            }
            .opacity(appState.isCommandModeEnabled ? 1 : 0.5)

            if let validationMessage = appState.commandModeManualModifierValidationMessage {
                Label(validationMessage, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Preserve clipboard after paste", isOn: $appState.preserveClipboard)

            Text("Quill will temporarily place the transcript on your clipboard to paste it, then restore whatever was there before. If you copy something else before the restore happens, Quill leaves it alone.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.vertical, 2)

            Toggle("Keep dictations in clipboard history", isOn: $appState.keepDictationInClipboardHistory)

            Text("When on, your clipboard manager (Paste, Raycast, Maccy, etc.) records each dictation so you can find it in your recent history. When off, \(AppName.displayName) marks dictations transient and your clipboard manager skips them.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.vertical, 2)

            Toggle("Say \"press enter\" to submit after paste", isOn: $appState.isPressEnterVoiceCommandEnabled)

            Text("When the transcription ends with \"press enter\", Quill removes those words before cleanup, pastes the remaining transcript, then presses Return.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var macrosSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Bypass post-processing and immediately paste your predefined text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { showingAddMacro = true }) {
                    Text("Add Macro")
                }
            }

            if appState.voiceMacros.isEmpty {
                VStack {
                    Image(systemName: "music.mic")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 4)
                    Text("No Voice Macros Yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Click 'Add Macro' to define your first voice macro.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                VStack(spacing: 1) {
                    ForEach(Array(appState.voiceMacros.enumerated()), id: \.element.id) { index, macro in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(verbatim: macro.command)
                                    .font(.headline)
                                Spacer()
                                Button("Edit") {
                                    editingMacro = macro
                                    showingAddMacro = true
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                Button("Delete") {
                                    appState.voiceMacros.removeAll { $0.id == macro.id }
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .foregroundStyle(.red)
                            }
                            Text(verbatim: macro.payload)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                    }
                }
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.06), lineWidth: 1))
            }
        }
    }
}

// MARK: - Input Settings

struct InputSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showMutedHint = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("Microphone", icon: "mic.fill") {
                    microphoneSection
                }
                SettingsCard("Sound Volume", icon: "speaker.wave.2.fill") {
                    soundVolumeSection
                }
            }
            .padding(24)
        }
    }

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Select which audio input to use for recording.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                MicrophoneOptionRow(
                    name: "System Default",
                    isSelected: appState.selectedMicrophoneID == AudioInputDevice.defaultMicrophoneID || appState.selectedMicrophoneID.isEmpty,
                    action: { appState.selectedMicrophoneID = AudioInputDevice.defaultMicrophoneID }
                )
                MicrophoneOptionRow(
                    name: "System Audio",
                    isSelected: appState.selectedMicrophoneID == AudioInputDevice.systemAudioID,
                    action: { appState.selectedMicrophoneID = AudioInputDevice.systemAudioID }
                )
                MicrophoneOptionRow(
                    name: "System Default + System Audio",
                    isSelected: appState.selectedMicrophoneID == AudioInputDevice.systemDefaultAndSystemAudioID,
                    action: { appState.selectedMicrophoneID = AudioInputDevice.systemDefaultAndSystemAudioID }
                )
                ForEach(appState.availableMicrophones) { device in
                    MicrophoneOptionRow(
                        name: device.name,
                        isSelected: appState.selectedMicrophoneID == device.uid,
                        action: { appState.selectedMicrophoneID = device.uid }
                    )
                }
            }
        }
        .onAppear {
            appState.refreshAvailableMicrophones()
        }
    }

    private var soundVolumeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Play alert sounds", isOn: $appState.alertSoundsEnabled)

            HStack(spacing: 12) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Slider(value: $appState.soundVolume, in: 0...1, step: 0.1)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text("\(Int(appState.soundVolume * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            .disabled(!appState.alertSoundsEnabled)
            .opacity(appState.alertSoundsEnabled ? 1 : 0.5)

            HStack(spacing: 8) {
                Button("Preview") {
                    let muted = SystemAudioStatus.isDefaultOutputMuted()
                    let volume = SystemAudioStatus.defaultOutputVolume()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showMutedHint = muted || (volume ?? 1) < 0.10
                    }
                    appState.playAlertSound(named: "Tink")
                }
                .font(.caption)
                .disabled(!appState.alertSoundsEnabled)

                if showMutedHint {
                    HStack(spacing: 4) {
                        Image(systemName: "speaker.slash.fill")
                            .foregroundStyle(.orange)
                        Text("System volume is muted or very low. Unmute to hear the preview.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .transition(.opacity)
                }
            }
        }
        .onChange(of: appState.alertSoundsEnabled) { enabled in
            if !enabled { showMutedHint = false }
        }
    }
}

// MARK: - About Settings

struct AboutSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var copiedBuildInfo = false
    @State private var copiedBuildInfoResetWorkItem: DispatchWorkItem?

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Quill"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private var appBuildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    private var appReleaseTag: String {
        Bundle.main.object(forInfoDictionaryKey: "QuillBuildTag") as? String ?? "unknown"
    }

    private var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private var appArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private var buildDiagnosticsText: String {
        "\(appDisplayName) \(appVersion) (build \(appBuildNumber), \(appReleaseTag))\nmacOS \(macOSVersion) (\(appArchitecture))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)
                    Text(verbatim: appDisplayName)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("v\(appVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .padding(.bottom, 4)

                SettingsCard("Build", icon: "info.circle.fill") {
                    buildInfoSection
                }
            }
            .padding(24)
        }
    }

    private var buildInfoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Version")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(appVersion)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("Build number")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(appBuildNumber)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("Release tag")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(appReleaseTag)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(alignment: .top, spacing: 12) {
                Text(verbatim: buildDiagnosticsText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Spacer()

                Button {
                    copyBuildDiagnostics()
                } label: {
                    Label(copiedBuildInfo ? "Copied" : "Copy", systemImage: copiedBuildInfo ? "checkmark" : "doc.on.doc")
                }
                .font(.caption)
            }
        }
    }

    private func copyBuildDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(buildDiagnosticsText, forType: .string)
        copiedBuildInfo = true

        copiedBuildInfoResetWorkItem?.cancel()

        let resetWorkItem = DispatchWorkItem {
            copiedBuildInfo = false
            copiedBuildInfoResetWorkItem = nil
        }
        copiedBuildInfoResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: resetWorkItem)
    }
}

// MARK: - Microphone Option Row

struct MicrophoneOptionRow: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                Text(verbatim: name)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(12)
            .background(isSelected ? Color.blue.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// localization-exclusion: developer-diagnostics-start
// MARK: - Run Log

struct RunLogView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run Log")
                        .font(.headline)
                    Text("Stored locally. Only the \(appState.maxPipelineHistoryCount) most recent runs are kept.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Clear History") {
                    appState.clearPipelineHistory()
                }
                .disabled(appState.pipelineHistory.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            if appState.pipelineHistory.isEmpty {
                VStack {
                    Spacer()
                    Text("No runs yet. Use dictation to populate history.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(appState.pipelineHistory) { item in
                            RunLogEntryView(item: item)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }
}

// MARK: - Run Log Entry

struct RunLogEntryView: View {
    private let actionIconSize: CGFloat = 28
    let item: PipelineHistoryItem
    @EnvironmentObject var appState: AppState
    @State private var isExpanded = false
    @State private var isRetrying = false
    @State private var showContextPrompt = false
    @State private var showPostProcessingPrompt = false
    @State private var loadedTranscript: String? = nil
    @State private var copiedTranscript = false
    @State private var copiedTranscriptResetWorkItem: DispatchWorkItem?
    @State private var copiedRawTranscript = false
    @State private var copiedRawTranscriptResetWorkItem: DispatchWorkItem?
    @State private var copiedCleanedTranscript = false
    @State private var copiedCleanedTranscriptResetWorkItem: DispatchWorkItem?

    private var isError: Bool {
        item.postProcessingStatus.hasPrefix("Error:")
    }

    private var copyableTranscript: String {
        resolvedTranscriptForCopy()
    }

    @ViewBuilder
    private func actionIconButton(
        systemName: String,
        color: Color = .secondary,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: actionIconSize, height: actionIconSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed header
            HStack(spacing: 0) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: actionIconSize, height: actionIconSize)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                    if isExpanded && loadedTranscript == nil {
                        Task.detached(priority: .userInitiated) {
                            let text: String
                            if let fileName = item.transcriptFileName {
                                text = AppState.loadTranscript(from: fileName) ?? ""
                            } else {
                                // 구 항목: rawTranscript 또는 postProcessedTranscript에서 읽기
                                let t = item.rawTranscript.isEmpty ? item.postProcessedTranscript : item.rawTranscript
                                text = t
                            }
                            await MainActor.run { loadedTranscript = text }
                        }
                    }
                } label: {
                    HStack {
                        if isError {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.timestamp.formatted(date: .numeric, time: .standard))
                                .font(.subheadline.weight(.semibold))
                            HStack(spacing: 4) {
                                if item.usedLocalTranscription {
                                    Text("Local")
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.15))
                                        .foregroundStyle(.blue)
                                        .cornerRadius(4)
                                }
                                if !item.usedContextCapture {
                                    Text("No Context")
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.15))
                                        .foregroundStyle(.orange)
                                        .cornerRadius(4)
                                }
                                if !item.usedPostProcessing {
                                    Text("No LLM")
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.purple.opacity(0.15))
                                        .foregroundStyle(.purple)
                                        .cornerRadius(4)
                                }
                                if item.transcriptionLanguageCode != "auto" {
                                    Text(item.transcriptionLanguageCode)
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.15))
                                        .foregroundStyle(.green)
                                        .cornerRadius(4)
                                }
                            }
                            Text(item.postProcessedTranscript.isEmpty ? "(no transcript)" : item.postProcessedTranscript)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                HStack(spacing: 4) {
                    if isError && item.audioFileName != nil {
                        Button {
                            appState.retryTranscription(item: item)
                        } label: {
                            if isRetrying {
                                ProgressView()
                                    .controlSize(.mini)
                                    .frame(width: actionIconSize, height: actionIconSize)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .frame(width: actionIconSize, height: actionIconSize)
                                    .contentShape(Rectangle())
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isRetrying)
                        .help("Retry transcription")
                    } else {
                        Color.clear
                            .frame(width: actionIconSize, height: actionIconSize)
                    }

                    actionIconButton(systemName: "square.and.arrow.up", help: "Export run log") {
                        TestCaseExporter.exportWithSavePanel(
                            item: item,
                            audioDirURL: AppState.audioStorageDirectory()
                        )
                    }

                    actionIconButton(
                        systemName: copiedTranscript ? "checkmark" : "doc.on.doc",
                        color: copiedTranscript ? .green : .secondary,
                        help: copiedTranscript ? "Copied transcript" : "Copy transcript",
                        disabled: resolvedTranscriptForCopy().isEmpty
                    ) {
                        copyTranscriptToPasteboard()
                    }

                    actionIconButton(systemName: "trash", help: "Delete this run") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            appState.deleteHistoryEntry(id: item.id)
                        }
                    }
                }
            }
            .padding(12)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 16) {
                    // Audio player
                    if let audioFileName = item.audioFileName {
                        let audioURL = AppState.audioStorageDirectory().appendingPathComponent(audioFileName)
                        AudioPlayerView(audioURL: audioURL)
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform.slash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("No audio recorded")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Custom vocabulary
                    if !item.customVocabulary.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Custom Vocabulary")
                                .font(.caption.weight(.semibold))
                            FlowLayout(spacing: 4) {
                                ForEach(parseVocabulary(item.customVocabulary), id: \.self) { word in
                                    Text(word)
                                        .font(.caption2)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.accentColor.opacity(0.12))
                                        .cornerRadius(4)
                                }
                            }
                        }
                    }

                    // Pipeline steps
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Pipeline")
                            .font(.caption.weight(.semibold))

                        // Step 1: Context Capture (비활성화된 경우 숨김)
                        if item.usedContextCapture {
                            PipelineStepView(
                                number: 1,
                                title: "Capture Context",
                                content: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        if let dataURL = item.contextScreenshotDataURL,
                                           let image = imageFromDataURL(dataURL) {
                                            Image(nsImage: image)
                                                .resizable()
                                                .aspectRatio(contentMode: .fit)
                                                .frame(maxHeight: 120)
                                                .cornerRadius(4)
                                        }

                                        if let prompt = item.contextPrompt, !prompt.isEmpty {
                                            Button {
                                                showContextPrompt.toggle()
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Text(showContextPrompt ? "Hide Prompt" : "Show Prompt")
                                                        .font(.caption)
                                                    Image(systemName: showContextPrompt ? "chevron.up" : "chevron.down")
                                                        .font(.caption2)
                                                }
                                            }
                                            .buttonStyle(.plain)
                                            .foregroundStyle(Color.accentColor)

                                            if showContextPrompt {
                                                Text(prompt)
                                                    .font(.system(.caption2, design: .monospaced))
                                                    .padding(8)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .background(Color(nsColor: .controlBackgroundColor))
                                                    .cornerRadius(4)
                                            }
                                        }

                                        if !item.contextSummary.isEmpty {
                                            Text(item.contextSummary)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text("No context captured")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            )
                        }

                        // Step 2: Transcribe Audio
                        PipelineStepView(
                            number: item.usedContextCapture ? 2 : 1,
                            title: item.usedLocalTranscription ? "Transcribe Audio (Local)" : "Transcribe Audio",
                            content: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.usedLocalTranscription
                                         ? "mlx-whisper (\(item.transcriptionLanguageCode))"
                                         : "Groq whisper-large-v3")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let text = loadedTranscript, !text.isEmpty {
                                        TextEditor(text: .constant(text))
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                            .padding(8)
                                            .padding(.trailing, 24)
                                            .frame(minHeight: 150, maxHeight: 300)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color(nsColor: .controlBackgroundColor))
                                            .cornerRadius(4)
                                            .overlay(alignment: .topTrailing) {
                                                Button {
                                                    copyRawTranscriptToPasteboard()
                                                } label: {
                                                    Image(systemName: copiedRawTranscript ? "checkmark" : "doc.on.doc")
                                                        .font(.caption)
                                                        .foregroundStyle(copiedRawTranscript ? .green : .secondary)
                                                        .padding(6)
                                                        .contentShape(Rectangle())
                                                }
                                                .buttonStyle(.plain)
                                                .help(copiedRawTranscript ? "Copied literal transcript" : "Copy literal transcript")
                                            }
                                    } else if loadedTranscript == nil {
                                        Text("Loading...")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("(empty transcript)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        )

                        // Step 3: Post-Process (비활성화된 경우 숨김)
                        if item.usedPostProcessing {
                            PipelineStepView(
                                number: item.usedContextCapture ? 3 : 2,
                                title: "Post-Process",
                                content: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(item.postProcessingStatus)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)

                                        if let prompt = item.postProcessingPrompt, !prompt.isEmpty {
                                            Button {
                                                showPostProcessingPrompt.toggle()
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Text(showPostProcessingPrompt ? "Hide Prompt" : "Show Prompt")
                                                        .font(.caption)
                                                    Image(systemName: showPostProcessingPrompt ? "chevron.up" : "chevron.down")
                                                        .font(.caption2)
                                                }
                                            }
                                            .buttonStyle(.plain)
                                            .foregroundStyle(Color.accentColor)

                                            if showPostProcessingPrompt {
                                                Text(prompt)
                                                    .font(.system(.caption2, design: .monospaced))
                                                    .padding(8)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .background(Color(nsColor: .controlBackgroundColor))
                                                    .cornerRadius(4)
                                            }
                                        }

                                        if !item.postProcessedTranscript.isEmpty {
                                            TextEditor(text: .constant(item.postProcessedTranscript))
                                                .font(.system(.caption, design: .monospaced))
                                                .textSelection(.enabled)
                                                .padding(8)
                                                .padding(.trailing, 24)
                                                .frame(minHeight: 150, maxHeight: 300)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(Color(nsColor: .controlBackgroundColor))
                                                .cornerRadius(4)
                                                .overlay(alignment: .topTrailing) {
                                                    Button {
                                                        copyCleanedTranscriptToPasteboard()
                                                    } label: {
                                                        Image(systemName: copiedCleanedTranscript ? "checkmark" : "doc.on.doc")
                                                            .font(.caption)
                                                            .foregroundStyle(copiedCleanedTranscript ? .green : .secondary)
                                                            .padding(6)
                                                            .contentShape(Rectangle())
                                                    }
                                                    .buttonStyle(.plain)
                                                    .help(copiedCleanedTranscript ? "Copied cleaned transcript" : "Copy cleaned transcript")
                                                }
                                        }
                                    }
                                }
                            )
                        }
                    }

                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isError ? Color.red.opacity(0.4) : Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .onReceive(appState.$retryingItemIDs) { ids in
            isRetrying = ids.contains(item.id)
        }
    }

    private func parseVocabulary(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func resolvedTranscriptForCopy() -> String {
        if let already = loadedTranscript, !already.isEmpty {
            return already
        }
        if let fileName = item.transcriptFileName,
           let loaded = AppState.loadTranscript(from: fileName),
           !loaded.isEmpty {
            return loaded
        }
        if !item.postProcessedTranscript.isEmpty {
            return item.postProcessedTranscript
        }
        return item.rawTranscript
    }

    private func copyTranscriptToPasteboard() {
        let text = resolvedTranscriptForCopy()
        guard !text.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedTranscript = true

        copiedTranscriptResetWorkItem?.cancel()
        let resetWorkItem = DispatchWorkItem {
            copiedTranscript = false
            copiedTranscriptResetWorkItem = nil
        }
        copiedTranscriptResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: resetWorkItem)
    }

    private func copyRawTranscriptToPasteboard() {
        guard !item.rawTranscript.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.rawTranscript, forType: .string)
        copiedRawTranscript = true

        copiedRawTranscriptResetWorkItem?.cancel()
        let resetWorkItem = DispatchWorkItem {
            copiedRawTranscript = false
            copiedRawTranscriptResetWorkItem = nil
        }
        copiedRawTranscriptResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: resetWorkItem)
    }

    private func copyCleanedTranscriptToPasteboard() {
        guard !item.postProcessedTranscript.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.postProcessedTranscript, forType: .string)
        copiedCleanedTranscript = true

        copiedCleanedTranscriptResetWorkItem?.cancel()
        let resetWorkItem = DispatchWorkItem {
            copiedCleanedTranscript = false
            copiedCleanedTranscriptResetWorkItem = nil
        }
        copiedCleanedTranscriptResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: resetWorkItem)
    }
}

// MARK: - Pipeline Step View

struct PipelineStepView<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
}

// MARK: - Audio Player

class AudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.onFinish?()
        }
    }
}

struct AudioPlayerView: View {
    let audioURL: URL
    @State private var player: AVAudioPlayer?
    @State private var delegate = AudioPlayerDelegate()
    @State private var isPlaying = false
    @State private var duration: TimeInterval = 0
    @State private var elapsed: TimeInterval = 0
    @State private var progressTimer: Timer?

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(elapsed / duration, 1.0)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.body)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
            }
            .buttonStyle(.plain)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(0, geo.size.width * progress), height: 4)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 28)

            Text("\(formatDuration(elapsed)) / \(formatDuration(duration))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .onAppear {
            loadDuration()
        }
        .onDisappear {
            stopPlayback()
        }
    }

    private func loadDuration() {
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return }
        Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: audioURL)
            let seconds: Double
            if let cmDuration = try? await asset.load(.duration) {
                seconds = CMTimeGetSeconds(cmDuration)
            } else {
                seconds = 0
            }
            await MainActor.run { duration = seconds }
        }
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            guard FileManager.default.fileExists(atPath: audioURL.path) else { return }
            do {
                let p = try AVAudioPlayer(contentsOf: audioURL)
                delegate.onFinish = {
                    self.stopPlayback()
                }
                p.delegate = delegate
                p.play()
                player = p
                isPlaying = true
                elapsed = 0
                startProgressTimer()
            } catch {}
        }
    }

    private func stopPlayback() {
        progressTimer?.invalidate()
        progressTimer = nil
        player?.stop()
        player = nil
        isPlaying = false
        elapsed = 0
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if let p = player, p.isPlaying {
                elapsed = p.currentTime
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layoutSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layoutSubviews(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            guard index < result.positions.count else { break }
            let pos = result.positions[index]
            subview.place(at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y), proposal: .unspecified)
        }
    }

    private func layoutSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = y + rowHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}

// localization-exclusion: developer-diagnostics-end

// MARK: - Voice Macro Editor

struct VoiceMacroEditorView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @Binding var macro: VoiceMacro?

    @State private var command: String = ""
    @State private var payload: String = ""

    var body: some View {
        VStack(spacing: 20) {
            Text(macro == nil ? "Add Macro" : "Edit Macro")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Voice Command (What you say)")
                    .font(.caption.weight(.semibold))
                TextField("e.g. debugging prompt", text: $command)
                    .textFieldStyle(.roundedBorder)

                Text("Text (What gets pasted)")
                    .font(.caption.weight(.semibold))
                    .padding(.top, 8)
                TextEditor(text: $payload)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 150)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                    macro = nil
                }
                Spacer()
                Button("Save") {
                    let newMacro = VoiceMacro(
                        id: macro?.id ?? UUID(),
                        command: command.trimmingCharacters(in: .whitespacesAndNewlines),
                        payload: payload
                    )
                    if let existingIndex = appState.voiceMacros.firstIndex(where: { $0.id == newMacro.id }) {
                        appState.voiceMacros[existingIndex] = newMacro
                    } else {
                        appState.voiceMacros.append(newMacro)
                    }
                    isPresented = false
                    macro = nil
                }
                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || payload.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            if let m = macro {
                command = m.command
                payload = m.payload
            }
        }
    }
}

// MARK: - Model Row View

struct DonutProgressView: View {
    let fractionCompleted: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 3)
            Circle()
                .trim(from: 0, to: fractionCompleted)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
    }
}

struct NativeWhisperModelRowView: View {
    @EnvironmentObject var appState: AppState

    let model: NativeWhisperModel
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var showDeleteConfirmation = false
    @State private var isHoveringDownloadProgress = false
    @FocusState private var isCancelDownloadFocused: Bool

    init(
        model: NativeWhisperModel = NativeWhisperModelCatalog.recommended,
        isSelected: Bool,
        onSelect: @escaping () -> Void
    ) {
        self.model = model
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    private var isInstalled: Bool {
        appState.nativeWhisperInstallStatus == .ready
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    onSelect()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isInstalled ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: model.displayName)
                                .font(.caption.weight(isSelected ? .semibold : .regular))
                            Text(localizedCatalogFormat("%arg. About %arg.", model.localizedDescription(), ByteCountFormatter.string(fromByteCount: model.approximateBytes, countStyle: .file)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isInstalled || appState.isInstallingNativeWhisper)

                actionView
            }

            if let errorMessage = appState.nativeWhisperInstallError {
                Label(errorMessage, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .confirmationDialog(
            "Delete model?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Model", role: .destructive) {
                deleteModel()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the downloaded Local Whisper model. You can download it again later.")
        }
        .onAppear {
            appState.refreshNativeWhisperInstallStatus()
        }
    }

    @ViewBuilder
    private var actionView: some View {
        if appState.isInstallingNativeWhisper {
            downloadProgressView
        } else if appState.nativeWhisperInstallProgress.isCancelled {
            canceledDownloadView
        } else if isInstalled {
            HStack(spacing: 8) {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Button {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else {
            Button("Download") {
                appState.installNativeWhisperModel()
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var downloadProgressView: some View {
        HStack(spacing: 8) {
            Text(appState.nativeWhisperInstallProgress.displayText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 104, alignment: .trailing)

            ZStack {
                if let fractionCompleted = appState.nativeWhisperInstallProgress.fractionCompleted {
                    DonutProgressView(fractionCompleted: fractionCompleted)
                        .opacity((isHoveringDownloadProgress || isCancelDownloadFocused) ? 0.25 : 1)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .opacity((isHoveringDownloadProgress || isCancelDownloadFocused) ? 0.25 : 1)
                }
                Button {
                    appState.cancelNativeWhisperInstall()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .focused($isCancelDownloadFocused)
                .opacity((isHoveringDownloadProgress || isCancelDownloadFocused) ? 1 : 0.001)
                .accessibilityLabel("Cancel Local Whisper download")
            }
            .frame(width: 24, height: 24)
            .contentShape(Circle())
            .onHover { hovering in
                isHoveringDownloadProgress = hovering
            }
        }
    }

    private var canceledDownloadView: some View {
        HStack(spacing: 8) {
            Text(appState.nativeWhisperInstallProgress.displayText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 72, alignment: .trailing)
            Button("Download") {
                appState.installNativeWhisperModel()
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func deleteModel() {
        appState.deleteNativeWhisperModel()
    }
}

struct ModelRowView: View {
    let model: TranscriptionModel
    let isSelected: Bool
    let whisperBin: String
    let onSelect: () -> Void
    let onDeleted: () -> Void

    @State private var isInstalled: Bool = false
    @State private var isDownloading: Bool = false
    @State private var isDeleting: Bool = false
    @State private var downloadTask: TranscriptionModel.DownloadTask?
    @State private var downloadProgress = TranscriptionModel.DownloadProgress(downloadedBytes: 0, totalBytes: nil)
    @State private var downloadWasCancelled = false
    @State private var isHoveringDownloadProgress = false
    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false

    private var isBusy: Bool {
        isDownloading || isDeleting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    onSelect()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isInstalled ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: model.displayName)
                                .font(.caption.weight(isSelected ? .semibold : .regular))
                            Text(model.localizedDescription())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isInstalled || isBusy)

                modelActionView
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .confirmationDialog(
            "Delete model?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Model", role: .destructive) {
                deleteModelCache()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the downloaded local model cache. You can download it again later.")
        }
        .onAppear {
            refreshInstallState()
        }
    }

    @ViewBuilder
    private var modelActionView: some View {
        if model.isAppleSpeech {
            Label("Built-in", systemImage: "apple.logo")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if isDownloading {
            downloadProgressView
        } else if downloadProgress.isCancelled {
            canceledDownloadView
        } else if isDeleting {
            busyLabel("Deleting...")
        } else if isInstalled {
            HStack(spacing: 8) {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Button {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isBusy)
            }
        } else {
            Button("Download") {
                downloadModel()
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isBusy)
        }
    }

    private var downloadProgressView: some View {
        HStack(spacing: 8) {
            Text(downloadProgress.displayText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 104, alignment: .trailing)

            ZStack {
                if !downloadProgress.isCancelled {
                    if let fractionCompleted = downloadProgress.fractionCompleted {
                        DonutProgressView(fractionCompleted: fractionCompleted)
                            .opacity(isHoveringDownloadProgress ? 0.25 : 1)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .opacity(isHoveringDownloadProgress ? 0.25 : 1)
                    }
                    if isHoveringDownloadProgress {
                        Button {
                            cancelDownload()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Circle())
            .onHover { hovering in
                isHoveringDownloadProgress = hovering
            }
        }
    }

    private var canceledDownloadView: some View {
        HStack(spacing: 8) {
            Text(downloadProgress.displayText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 72, alignment: .trailing)
            Button("Download") {
                downloadModel()
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func busyLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            ProgressView()
                .controlSize(.mini)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshInstallState() {
        isInstalled = model.isInstalled
    }

    private func downloadModel() {
        errorMessage = nil
        downloadWasCancelled = false
        downloadProgress = model.downloadProgress()
        isDownloading = true
        downloadTask = model.download(
            whisperBin: whisperBin,
            progress: { progress in
                downloadProgress = progress
            },
            completion: { result in
                downloadTask = nil
                isDownloading = false
                refreshInstallState()
                guard !downloadWasCancelled else { return }
                if case .failure(let error) = result {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }

    private func cancelDownload() {
        downloadWasCancelled = true
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        try? model.deleteIncompleteDownloadFiles()
        downloadProgress = TranscriptionModel.DownloadProgress(
            downloadedBytes: model.downloadProgress().downloadedBytes,
            totalBytes: downloadProgress.totalBytes,
            isCancelled: true
        )
        refreshInstallState()
    }

    private func deleteModelCache() {
        errorMessage = nil
        isDeleting = true
        let selectedModel = model
        Task.detached(priority: .utility) {
            do {
                try selectedModel.deleteCache()
                await MainActor.run {
                    isDeleting = false
                    refreshInstallState()
                    onDeleted()
                }
            } catch {
                await MainActor.run {
                    isDeleting = false
                    refreshInstallState()
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
