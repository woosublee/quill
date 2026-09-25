import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var updateManager = UpdateManager.shared

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var recentHistoryItems: [PipelineHistoryItem] {
        Array(appState.pipelineHistory.filter { !transcriptText(for: $0).isEmpty }.prefix(10))
    }

    private func transcriptText(for item: PipelineHistoryItem) -> String {
        let cleaned = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            return cleaned
        }
        return item.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcriptFull(for item: PipelineHistoryItem) -> String {
        if !item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return item.postProcessedTranscript
        }
        return item.rawTranscript
    }

    private func transcriptSnippet(for item: PipelineHistoryItem) -> String {
        let text = transcriptText(for: item)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return String(localized: "(no transcript)") }
        return text.count > 48 ? String(text.prefix(48)) + "..." : text
    }

    private func copyTranscriptToPasteboard(_ transcript: String) {
        guard !transcript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
    }

    private func openRunLog() {
        appState.selectedSettingsTab = .runLog
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }

    private var recordingButtonTitle: String {
        if appState.isRecording {
            return String(localized: "Stop Recording")
        }
        return appState.transcriptionEnabled
            ? String(localized: "Start Dictating")
            : String(localized: "Start Recording")
    }

    var body: some View {
        VStack(spacing: 4) {
            Text("\(AppName.displayName) v\(appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)

            Divider()

            if !appState.hasScreenRecordingPermission {
                Button {
                    appState.requestScreenCapturePermission()
                } label: {
                    Label("Screen Recording Permission Needed", systemImage: "camera.viewfinder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.orange)

                Divider()
            }

            // Accessibility warning
            if appState.requiresAccessibility, !appState.hasAccessibility {
                Button {
                    appState.openAccessibilitySettings()
                } label: {
                    Label("Accessibility Required", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.red)

                Divider()
            }

            // Status
            if appState.isRecording {
                Label("Recording...", systemImage: "record.circle")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            } else if appState.isTranscribing {
                Label(appState.transcribingStatusTitle, systemImage: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            } else {
                Text(appState.shortcutStatusText)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }

            Divider()

            // Manual toggle
            Button(recordingButtonTitle) {
                appState.toggleRecording()
            }
            .disabled(
                appState.isTranscribing
                    || appState.isHistoryUnavailable
                    || appState.isHistoryRecoveryOperationInProgress
            )

            if let hotkeyError = appState.hotkeyMonitoringErrorMessage {
                Divider()
                Text(hotkeyError)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .lineLimit(3)
            }

            if appState.isHistoryUnavailable,
               let warning = appState.historyPersistenceWarning {
                let presentation = warning.presentation()
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        presentation.title,
                        systemImage: "externaldrive.badge.exclamationmark"
                    )
                    .font(.caption.weight(.semibold))
                    Text(presentation.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HistoryUnavailableRecoveryActions()
                        .controlSize(.small)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            } else if !appState.historyRecoverySnapshots.isEmpty {
                Divider()
                Button("Recovery…") {
                    appState.openHistoryRecoverySettings()
                }
            } else if let warning = appState.historyPersistenceWarning {
                Divider()
                Label(
                    warning.presentation().compactMessage,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .font(.caption)
                .padding(.horizontal, 16)
                .lineLimit(3)
            }

            if let error = appState.errorMessage {
                Divider()
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .lineLimit(3)
            }

            Divider()

            if !appState.lastTranscript.isEmpty && !appState.isRecording && !appState.isTranscribing {
                Button(appState.copyAgainShortcut.isDisabled
                    ? String(localized: "Paste Again")
                    : localizedCatalogFormat("Paste Again  (%@)", appState.copyAgainShortcut.displayName)) {
                    appState.copyLastTranscriptToPasteboard()
                }

                let truncatedTranscript = appState.lastTranscript.count > 35
                    ? String(appState.lastTranscript.prefix(35)) + "…"
                    : appState.lastTranscript
                Text("\u{201C}\(truncatedTranscript)\u{201D}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .lineLimit(4)
                    .frame(maxWidth: 280, alignment: .leading)
            }

            Menu("History") {
                if recentHistoryItems.isEmpty {
                    Text("No transcripts yet")
                } else {
                    ForEach(recentHistoryItems) { item in
                        let transcript = transcriptText(for: item)
                        Button {
                            copyTranscriptToPasteboard(transcriptFull(for: item))
                        } label: {
                            Text(transcriptSnippet(for: item))
                        }
                        .disabled(transcript.isEmpty)
                    }

                    if AppBuild.isDevBundle {
                        Divider()
                    }
                }

                if AppBuild.isDevBundle {
                    Button("Open Run Log") {
                        openRunLog()
                    }
                }
            }

            Divider()

            Button("Paste Custom Word to Vocabulary") {
                if appState.pasteWordToVocabulary() != nil {
                    VocabularyNotificationManager.shared.flashCheckmark()
                }
            }

            Divider()

            Menu("Hold Shortcut") {
                Button {
                    _ = appState.setShortcut(.disabled, for: .hold)
                } label: {
                    if appState.holdShortcut.isDisabled {
                        Text("✓ Disabled")
                    } else {
                        Text("  Disabled")
                    }
                }

                ForEach(ShortcutPreset.allCases) { preset in
                    Button {
                        _ = appState.setShortcut(preset.binding, for: .hold)
                    } label: {
                        if appState.holdShortcut == preset.binding {
                            Text("✓ \(preset.title)")
                        } else {
                            Text("  \(preset.title)")
                        }
                    }
                    .disabled(preset.binding == appState.toggleShortcut)
                }

                if let savedCustomShortcut = appState.savedCustomShortcut(for: .hold) {
                    Divider()
                    Button {
                        _ = appState.setShortcut(savedCustomShortcut, for: .hold)
                    } label: {
                        if appState.holdShortcut == savedCustomShortcut {
                            Text("✓ Custom: \(savedCustomShortcut.displayName)")
                        } else {
                            Text("  Custom: \(savedCustomShortcut.displayName)")
                        }
                    }
                }

                Divider()
                Button("Customize…") {
                    appState.selectedSettingsTab = .shortcuts
                    NotificationCenter.default.post(name: .showSettings, object: nil)
                }
            }

            Menu("Toggle Shortcut") {
                Button {
                    _ = appState.setShortcut(.disabled, for: .toggle)
                } label: {
                    if appState.toggleShortcut.isDisabled {
                        Text("✓ Disabled")
                    } else {
                        Text("  Disabled")
                    }
                }

                ForEach(ShortcutPreset.allCases) { preset in
                    Button {
                        _ = appState.setShortcut(preset.binding, for: .toggle)
                    } label: {
                        if appState.toggleShortcut == preset.binding {
                            Text("✓ \(preset.title)")
                        } else {
                            Text("  \(preset.title)")
                        }
                    }
                    .disabled(preset.binding == appState.holdShortcut)
                }

                if let savedCustomShortcut = appState.savedCustomShortcut(for: .toggle) {
                    Divider()
                    Button {
                        _ = appState.setShortcut(savedCustomShortcut, for: .toggle)
                    } label: {
                        if appState.toggleShortcut == savedCustomShortcut {
                            Text("✓ Custom: \(savedCustomShortcut.displayName)")
                        } else {
                            Text("  Custom: \(savedCustomShortcut.displayName)")
                        }
                    }
                }

                Divider()
                Button("Customize…") {
                    appState.selectedSettingsTab = .shortcuts
                    NotificationCenter.default.post(name: .showSettings, object: nil)
                }
            }

            Menu("Paste Again Shortcut") {
                Button {
                    _ = appState.setShortcut(.disabled, for: .copyAgain)
                } label: {
                    if appState.copyAgainShortcut.isDisabled {
                        Text("✓ Disabled")
                    } else {
                        Text("  Disabled")
                    }
                }

                ForEach(ShortcutPreset.allCases) { preset in
                    Button {
                        _ = appState.setShortcut(preset.binding, for: .copyAgain)
                    } label: {
                        if appState.copyAgainShortcut == preset.binding {
                            Text("✓ \(preset.title)")
                        } else {
                            Text("  \(preset.title)")
                        }
                    }
                    .disabled(preset.binding == appState.holdShortcut || preset.binding == appState.toggleShortcut)
                }

                if let savedCustomShortcut = appState.savedCustomShortcut(for: .copyAgain) {
                    Divider()
                    Button {
                        _ = appState.setShortcut(savedCustomShortcut, for: .copyAgain)
                    } label: {
                        if appState.copyAgainShortcut == savedCustomShortcut {
                            Text("✓ Custom: \(savedCustomShortcut.displayName)")
                        } else {
                            Text("  Custom: \(savedCustomShortcut.displayName)")
                        }
                    }
                }

                Divider()
                Button("Customize…") {
                    appState.selectedSettingsTab = .shortcuts
                    NotificationCenter.default.post(name: .showSettings, object: nil)
                }
            }

            Menu("Audio Input") {
                Menu("Audio Source") {
                    ForEach(AudioRecordingSource.allCases) { source in
                        Button {
                            appState.selectAudioSource(source)
                        } label: {
                            let prefix = appState.selectedAudioSource == source
                                ? "✓ "
                                : "  "
                            Text(verbatim: prefix + localizedCatalogString(source.titleKey))
                        }
                        .disabled(!appState.isAudioSourceSelectable(source))
                    }
                }

                Menu("Microphone") {
                    let systemDefaultName = appState.systemDefaultMicrophoneDisplayName()
                    Button {
                        appState.selectMicrophoneDevice(AudioInputDevice.defaultMicrophoneID)
                    } label: {
                        let prefix = appState.selectedMicrophoneDeviceID == AudioInputDevice.defaultMicrophoneID
                            ? "✓ "
                            : "  "
                        Text(verbatim: prefix + systemDefaultName)
                    }
                    ForEach(appState.availableMicrophones) { device in
                        Button {
                            appState.selectMicrophoneDevice(device.uid)
                        } label: {
                            if appState.selectedMicrophoneDeviceID == device.uid {
                                Text("✓ \(device.name)")
                            } else {
                                Text("  \(device.name)")
                            }
                        }
                    }
                }
                .disabled(appState.isRecording)
            }

            Button("Re-run Setup...") {
                NotificationCenter.default.post(name: .showSetup, object: nil)
            }

            Button("Settings") {
                NotificationCenter.default.post(name: .showSettings, object: nil)
            }
            .keyboardShortcut(",", modifiers: .command)

            Button {
                Task {
                    await updateManager.checkForUpdates(userInitiated: true)
                }
            } label: {
                HStack(spacing: 6) {
                    if updateManager.isChecking {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(updateManager.isChecking ? String(localized: "Checking for Updates...") : String(localized: "Check for Updates"))
                }
            }
            .disabled(updateManager.isChecking)

            if updateManager.updateAvailable || updateManager.updateStatus != .idle {
                Divider()

                switch updateManager.updateStatus {
                case .downloading:
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Downloading update...")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)

                case .installing, .readyToRelaunch:
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Preparing update...")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)

                case .error(let message):
                    Button {
                        updateManager.showUpdateAlert()
                    } label: {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.red)

                case .idle:
                    Button {
                        updateManager.showUpdateAlert()
                    } label: {
                        Label("Update available", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                }
            }

            Divider()

            Button(localizedCatalogFormat("Quit %@", AppName.displayName)) {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(4)
    }
}
