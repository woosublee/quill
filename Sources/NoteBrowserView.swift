import SwiftUI
import UserNotifications
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Cursor helper

private class CursorNSView: NSView {
    var cursor: NSCursor

    init(cursor: NSCursor) {
        self.cursor = cursor
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        guard !bounds.isEmpty else { return }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .cursorUpdate, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }
}

private struct CursorView: NSViewRepresentable {
    var cursor: NSCursor = .arrow
    func makeNSView(context: Context) -> CursorNSView { CursorNSView(cursor: cursor) }
    func updateNSView(_ nsView: CursorNSView, context: Context) { nsView.cursor = cursor }
}

extension View {
    func overrideCursor(_ cursor: NSCursor) -> some View {
        self.background(CursorView(cursor: cursor))
    }
}

// MARK: - Visual effect helpers

private class GlassNSView: NSView {
    var material: NSVisualEffectView.Material
    var cornerRadius: CGFloat? = nil
    private let effectView = NSVisualEffectView()

    init(material: NSVisualEffectView.Material = .popover) {
        self.material = material
        super.init(frame: .zero)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        effectView.material = material
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = frame.height / 2
        effectView.layer?.masksToBounds = true
        addSubview(effectView)
    }

    override func layout() {
        super.layout()
        effectView.frame = bounds
        effectView.layer?.cornerRadius = cornerRadius ?? (bounds.height / 2)
    }
}

private struct GlassView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var cornerRadius: CGFloat? = nil

    func makeNSView(context: Context) -> NSView {
        let view = GlassNSView(material: material)
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let nsView = nsView as? GlassNSView {
            nsView.material = material
            nsView.cornerRadius = cornerRadius
        }
    }
}

// MARK: - Obsidian Export Manager

final class ObsidianExportManager: ObservableObject {
    static let shared = ObsidianExportManager()
    private init() {}

    @Published private(set) var processingIDs: Set<UUID> = []

    @MainActor
    func export(
        itemID: UUID,
        content: String,
        fileName: String,
        vaultPath: String,
        audioSrcURL: URL?,
        useGemini: Bool,
        geminiPrompt: String,
        timestamp: Date
    ) {
        processingIDs.insert(itemID)
        Task {
            defer {
                Task { @MainActor in self.processingIDs.remove(itemID) }
            }
            do {
                let finalContent: String
                if useGemini {
                    finalContent = try await self.runGemini(content: content, prompt: geminiPrompt)
                } else {
                    finalContent = content
                }

                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime]
                let audioFileName = audioSrcURL.map { fileName + "." + $0.pathExtension }
                let audioEmbed = audioFileName.map { "\n![[\($0)]]\n" } ?? ""

                let markdown: String
                if useGemini {
                    markdown = """
---
title: \(fileName)
date: \(iso.string(from: timestamp))
source: Quill
---

\(finalContent)

---

# 전사문
\(audioEmbed)
\(content)
"""
                } else {
                    markdown = """
---
title: \(fileName)
date: \(iso.string(from: timestamp))
source: Quill
---

# 전사문
\(audioEmbed)
\(content)
"""
                }

                let vaultURL = URL(fileURLWithPath: vaultPath)
                let mdURL = vaultURL.appendingPathComponent(fileName + ".md")
                try markdown.write(to: mdURL, atomically: true, encoding: .utf8)

                if let srcURL = audioSrcURL,
                   let audioFileName,
                   FileManager.default.fileExists(atPath: srcURL.path) {
                    let dstURL = vaultURL.appendingPathComponent(audioFileName)
                    try? FileManager.default.removeItem(at: dstURL)
                    try FileManager.default.copyItem(at: srcURL, to: dstURL)
                }

                await self.notify(title: "내보내기 완료", body: "\(fileName).md 저장됨", success: true)
            } catch {
                await self.notify(title: "내보내기 실패", body: error.localizedDescription, success: false)
            }
        }
    }

    private func notify(title: String, body: String, success: Bool) async {
        await AppNotificationManager.shared.sendImmediateNotification(
            title: title,
            body: body,
            sound: success ? .default : nil
        )
    }

    func runGemini(content: String, prompt: String) async throws -> String {
        let candidates = [
            "/Users/\(NSUserName())/.npm-global/bin/gemini",
            "/usr/local/bin/gemini",
            "/opt/homebrew/bin/gemini"
        ]
        guard let geminiPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw NSError(domain: "GeminiCLI", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "gemini CLI를 찾을 수 없습니다"])
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: geminiPath)
            process.arguments = ["--yolo", "-p", "\(prompt)\n\n---\n\(content)"]
            process.currentDirectoryURL = FileManager.default.temporaryDirectory

            var env = ProcessInfo.processInfo.environment
            let extraPaths: [String] = [
                "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
                "/Users/\(NSUserName())/.npm-global/bin",
                "/Users/\(NSUserName())/.volta/bin",
                ObsidianExportManager.nvmNodeBinPath(),
                "/usr/bin", "/bin"
            ].filter { !$0.isEmpty }
            let existingPath = env["PATH"] ?? ""
            env["PATH"] = (extraPaths + [existingPath]).filter { !$0.isEmpty }.joined(separator: ":")
            process.environment = env

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            process.terminationHandler = { _ in
                let raw = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let cleaned = raw.replacingOccurrences(of: #"\x1B\[[0-9;]*[mGKHF]"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.isEmpty {
                    let err = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "알 수 없는 오류"
                    continuation.resume(throwing: NSError(domain: "GeminiCLI", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: err.trimmingCharacters(in: .whitespacesAndNewlines)]))
                } else {
                    continuation.resume(returning: cleaned)
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    static func nvmNodeBinPath() -> String {
        let nvmDir = "/Users/\(NSUserName())/.nvm/versions/node"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir).sorted().last else { return "" }
        return "\(nvmDir)/\(versions)/bin"
    }
}

// MARK: - Audio Import

private struct PendingAudioImport: Identifiable {
    let id = UUID()
    let fileURL: URL
    let currentMode: NoteBrowserTranscriptionMode
    let hasAPIKey: Bool
    let hasLocalWhisperModel: Bool
    let fileSizeBytes: Int64?

    init(
        fileURL: URL,
        currentMode: NoteBrowserTranscriptionMode,
        hasAPIKey: Bool,
        hasLocalWhisperModel: Bool
    ) {
        self.fileURL = fileURL
        self.currentMode = currentMode
        self.hasAPIKey = hasAPIKey
        self.hasLocalWhisperModel = hasLocalWhisperModel
        let accessGranted = fileURL.startAccessingSecurityScopedResource()
        self.fileSizeBytes = accessGranted ? AppState.fileSizeBytes(for: fileURL) : nil
        if accessGranted {
            fileURL.stopAccessingSecurityScopedResource()
        }
    }

    var options: AudioImportOptions {
        AudioImportOptions(
            fileExtension: fileURL.pathExtension,
            currentMode: currentMode,
            fileSizeBytes: fileSizeBytes,
            hasAPIKey: hasAPIKey,
            hasLocalWhisperModel: hasLocalWhisperModel
        )
    }
}

private struct AudioImportSheet: View {
    let importRequest: PendingAudioImport
    let onImport: (NoteBrowserTranscriptionMode) -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var appState: AppState
    @State private var selectedMode: NoteBrowserTranscriptionMode

    init(
        importRequest: PendingAudioImport,
        onImport: @escaping (NoteBrowserTranscriptionMode) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.importRequest = importRequest
        self.onImport = onImport
        self.onCancel = onCancel
        _selectedMode = State(initialValue: importRequest.options.defaultMode ?? .apiStandard)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Import Audio File")
                    .font(.system(size: 18, weight: .semibold))
                Text(importRequest.fileURL.lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if importRequest.options.supportedModes.isEmpty {
                Text("No transcription method is available. Configure an API key or install a Local Whisper model, then try again.")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Transcription Method")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach([NoteBrowserTranscriptionMode.apiStandard, .localWhisper], id: \.self) { mode in
                    let isSupported = importRequest.options.supportedModes.contains(mode)
                    Button {
                        selectedMode = mode
                    } label: {
                        HStack {
                            Image(systemName: selectedMode == mode ? "largecircle.fill.circle" : "circle")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(appState.audioImportLabel(for: mode))
                                if mode == .apiStandard && !isSupported {
                                    Text(importRequest.options.apiUnavailableReason)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                } else if mode == .localWhisper && !isSupported {
                                    Text(appState.useLegacyMlxWhisper
                                        ? "Install a legacy mlx-whisper model to import locally"
                                        : "Install the native Local Whisper model to import locally")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!isSupported)
                    .opacity(isSupported ? 1 : 0.45)
                }
            }

            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Transcribe") { onImport(selectedMode) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(importRequest.options.supportedModes.isEmpty || !importRequest.options.supportedModes.contains(selectedMode))
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

// MARK: - Note Browser View

struct NoteBrowserView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var exportManager: ObsidianExportManager
    @State private var selectedItemID: UUID?
    @State private var searchText = ""
    @State private var knownHistoryIDs: Set<UUID> = []
    @State private var pendingAudioImport: PendingAudioImport?
    @State private var recordingPulse = false

    private var filteredHistory: [PipelineHistoryItem] {
        guard !searchText.isEmpty else { return appState.pipelineHistory }
        let q = searchText.lowercased()
        return appState.pipelineHistory.filter {
            $0.postProcessedTranscript.lowercased().contains(q) ||
            $0.contextSummary.lowercased().contains(q) ||
            ($0.customTitle ?? "").lowercased().contains(q) ||
            ($0.calendarMatch?.title ?? "").lowercased().contains(q)
        }
    }

    private func transcriptionModeMenuItem(_ title: String, mode: NoteBrowserTranscriptionMode) -> some View {
        Toggle(isOn: Binding<Bool>(
            get: { appState.currentNoteBrowserTranscriptionMode == mode },
            set: { isSelected in
                if isSelected { appState.setNoteBrowserTranscriptionMode(mode) }
            }
        )) {
            Text(title)
        }
        .disabled(!appState.isNoteBrowserTranscriptionModeAvailable(mode))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebarPanel
            detailPanel
        }
        .frame(minWidth: 800, minHeight: 520)
        .onAppear {
            let ids = Set(appState.pipelineHistory.map(\.id))
            knownHistoryIDs = ids
            if selectedItemID == nil {
                selectedItemID = appState.pipelineHistory.first?.id
            }
        }
        .sheet(item: $pendingAudioImport) { importRequest in
            AudioImportSheet(importRequest: importRequest) { mode in
                pendingAudioImport = nil
                appState.importAudioFile(importRequest.fileURL, mode: mode)
            } onCancel: {
                pendingAudioImport = nil
            }
            .environmentObject(appState)
        }
        .onReceive(appState.$pipelineHistory) { newHistory in
            let ids = newHistory.map(\.id)
            // 현재 선택이 사라진 경우 → 최신 항목 선택
            guard let current = selectedItemID, ids.contains(current) else {
                selectedItemID = ids.first
                knownHistoryIDs = Set(ids)
                return
            }
            // 진짜 새 항목이 추가된 경우에만 자동 선택 (기존 항목 수정은 무시)
            if let newest = ids.first, newest != current, !knownHistoryIDs.contains(newest) {
                selectedItemID = newest
            }
            knownHistoryIDs = Set(ids)
        }
    }

    // MARK: - Sidebar

    // Down-chevron beside the Rec button to choose the audio input for the next
    // recording (mirrors the menu bar Microphone submenu). Disabled while
    // recording — switching the live input is done from the recording overlay.
    // Starts/stops the Rec dot pulse. Stopping is wrapped in a finite animation
    // so the repeatForever context is cleanly torn down (no idle CPU), and this
    // is also called from onAppear so the pulse runs if the view opens while a
    // recording is already in progress.
    private func updateRecordingPulse(_ isRecording: Bool) {
        if isRecording {
            recordingPulse = false
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                recordingPulse = true
            }
        } else {
            withAnimation(.default) {
                recordingPulse = false
            }
        }
    }

    private var inputPickerMenu: some View {
        // Custom chevron + an AppKit NSMenu on click, so the glyph is fully ours
        // (SwiftUI Menu draws its own fixed indicator that ignores label sizing)
        // and the selected input gets a native checkmark.
        Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 11, height: 22)
            .contentShape(Rectangle())
            .padding(.leading, -2)
            .opacity(appState.isRecording ? 0.3 : 1.0)
            .overlay {
                if !appState.isRecording {
                    InputMenuCatcher(
                        sources: [
                            (AudioInputDevice.defaultMicrophoneID, "System Default"),
                            (AudioInputDevice.systemAudioID, "System Audio"),
                            (AudioInputDevice.systemDefaultAndSystemAudioID, "System Default + System Audio")
                        ],
                        mics: appState.availableMicrophones.map { ($0.uid, $0.name) },
                        selectedID: appState.selectedMicrophoneID,
                        onSelect: { appState.selectedMicrophoneID = $0 }
                    )
                }
            }
            .help("Choose audio input for the next recording")
            .overrideCursor(.arrow)
    }

    private var sidebarPanel: some View {
        VStack(spacing: 0) {
            // Title row
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("Recordings")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if !appState.pipelineHistory.isEmpty {
                        Text("\(appState.pipelineHistory.count)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    Button {
                        showAudioImportPicker()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 24, height: 24)
                            .background(Color.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Import audio file")
                    .disabled(appState.isRecording)
                    .overrideCursor(.arrow)

                    // Record button
                    Button {
                        appState.toggleRecording()
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(.white)
                                .frame(width: 6, height: 6)
                                // Pulse opacity only (via recordingPulse) so the dot blinks
                                // in place and isn't dragged by the Rec/Stop layout change.
                                .opacity(appState.isRecording ? (recordingPulse ? 0.35 : 1.0) : 1.0)
                            Text(appState.isRecording ? "Stop" : "Rec")
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                        }
                        .onChange(of: appState.isRecording) { isRecording in
                            updateRecordingPulse(isRecording)
                        }
                        .onAppear { updateRecordingPulse(appState.isRecording) }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(appState.isRecording ? Color.orange : Color.red, in: Capsule())
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .overrideCursor(.arrow)

                    inputPickerMenu
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            HStack(spacing: 8) {
                Text("Transcription")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .kerning(0.4)

                Spacer()

                Menu {
                    Section("API") {
                        transcriptionModeMenuItem("Standard", mode: .apiStandard)
                        transcriptionModeMenuItem("Realtime", mode: .apiRealtime)
                    }
                    Section("Local") {
                        transcriptionModeMenuItem("Whisper", mode: .localWhisper)
                        transcriptionModeMenuItem("Apple Live", mode: .localAppleLive)
                    }
                } label: {
                    Text(appState.noteBrowserTranscriptionModeLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(appState.isRecording || appState.isTranscribing)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                TextField("검색", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider().opacity(0.5)

            // List
            if appState.pipelineHistory.isEmpty {
                emptyListState
            } else if filteredHistory.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                    Text("검색 결과 없음")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredHistory) { item in
                            NoteListRow(
                                displayData: NoteListRowDisplayData(
                                    item: item,
                                    retryingIDs: appState.retryingItemIDs
                                ),
                                isSelected: selectedItemID == item.id
                            )
                            .onTapGesture { selectedItemID = item.id }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(width: 280)
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(width: 0.5)
        }
    }

    private func showAudioImportPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Array(AudioImportOptions.broadlySupportedExtensions)
            .sorted()
            .compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Choose"
        panel.message = "Choose an audio file. Supported formats: FLAC, MP3, MP4, MPEG, MPGA, M4A, OGG, WAV, WEBM"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            pendingAudioImport = PendingAudioImport(
                fileURL: url,
                currentMode: appState.currentNoteBrowserTranscriptionMode,
                hasAPIKey: appState.hasTranscriptionAPIKey,
                hasLocalWhisperModel: appState.hasInstalledLocalWhisperModel
            )
        }
    }

    private var emptyListState: some View {
        VStack(spacing: 12) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.04))
                    .frame(width: 64, height: 64)
                Image(systemName: "mic")
                    .font(.system(size: 26, weight: .ultraLight))
                    .foregroundStyle(.tertiary)
            }
            Text("녹음이 없습니다")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("단축키를 눌러 녹음을 시작하세요")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPanel: some View {
        if let id = selectedItemID,
           let item = appState.pipelineHistory.first(where: { $0.id == id }) {
            NoteDetailView(item: item) {
                appState.deleteHistoryEntry(id: id)
            }
            .id(id)
        } else if appState.pipelineHistory.isEmpty {
            emptyDetailNoRecordings
        } else {
            emptyDetailNoSelection
        }
    }

    private var emptyDetailNoSelection: some View {
        VStack(spacing: 12) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.04))
                    .frame(width: 80, height: 80)
                    .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1))
                Image(systemName: "doc.text")
                    .font(.system(size: 32, weight: .ultraLight))
                    .foregroundStyle(.tertiary)
            }
            Text("노트를 선택하세요")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("왼쪽 목록에서 녹음을 선택하면\n전사된 내용이 표시됩니다")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var emptyDetailNoRecordings: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.04))
                    .frame(width: 96, height: 96)
                    .overlay(Circle().stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4])))
                Image(systemName: "mic")
                    .font(.system(size: 38, weight: .ultraLight))
                    .foregroundStyle(.tertiary)
            }
            Text("녹음이 없습니다")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("단축키를 눌러 첫 번째 녹음을 시작하세요.\n전사된 내용이 여기에 나타납니다.")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Note List Row

private struct NoteListRow: View {
    let displayData: NoteListRowDisplayData
    let isSelected: Bool

    @EnvironmentObject private var exportManager: ObsidianExportManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var isExporting: Bool { exportManager.processingIDs.contains(displayData.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Content
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(displayData.rowDate)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(selectedMetaColor)
                        .textCase(.uppercase)
                        .kerning(0.4)
                    if isExporting {
                        HStack(spacing: 2) {
                            ProgressView().controlSize(.mini).scaleEffect(0.6)
                            Text("내보내는 중")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(isSelected ? selectedMetaColor : .orange)
                        }
                    }
                    Spacer()
                    statusIndicator
                }

                Text(displayData.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selectedTitleColor)
                    .lineLimit(1)

                Text(displayData.preview.isEmpty ? " " : displayData.preview)
                    .font(.system(size: 11.5))
                    .foregroundStyle(selectedPreviewColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .opacity(displayData.preview.isEmpty ? 0 : 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 80, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    isSelected
                        ? (colorScheme == .dark ? Color.white.opacity(0.07) : Color.primary.opacity(0.08))
                        : (isHovered
                            ? (colorScheme == .dark ? Color.white.opacity(0.03) : Color.primary.opacity(0.05))
                            : Color.clear)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isSelected
                                ? (colorScheme == .dark ? Color.white.opacity(0.14) : Color.primary.opacity(0.12))
                                : (colorScheme == .dark
                                    ? Color.white.opacity(isHovered ? 0.07 : 0)
                                    : Color.primary.opacity(isHovered ? 0.08 : 0)),
                            lineWidth: isSelected ? 0.6 : 0.5
                        )
                }
        }
        .shadow(color: isSelected ? .black.opacity(colorScheme == .dark ? 0.08 : 0.04) : .clear, radius: 6, x: 0, y: 1)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var selectedMetaColor: Color {
        isSelected
            ? (colorScheme == .dark ? Color.white.opacity(0.72) : Color.primary.opacity(0.55))
            : Color.secondary.opacity(0.7)
    }

    private var selectedTitleColor: Color {
        isSelected
            ? (colorScheme == .dark ? .white : .primary)
            : .primary
    }

    private var selectedPreviewColor: Color {
        isSelected
            ? (colorScheme == .dark ? Color.white.opacity(0.78) : Color.primary.opacity(0.72))
            : .secondary
    }

    private var toolbarStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.primary.opacity(0.10)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch displayData.status {
        case .done:
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
        case .recording, .transcribing:
            YellowSpinner(color: .orange)
        case .fail:
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
        }
    }

}

// MARK: - Note Detail View

private struct NoteDetailView: View {
    let item: PipelineHistoryItem
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var appState: AppState
    @State private var loadedContent: String?
    @State private var isCopied = false
    @State private var showExportSheet = false
    @State private var titleDraft = ""
    @State private var isRetrying = false
    @State private var titleDebounceTimer: Timer?
    @State private var showDeleteConfirmation = false

    private var isError: Bool { item.postProcessingStatus.hasPrefix("Error:") }
    private var isLiveRecording: Bool { item.postProcessingStatus == "live-recording" }
    private var canRetry: Bool { item.audioFileName != nil }
    private var displayContent: String { loadedContent ?? item.postProcessedTranscript }

    private var suggestedCalendarTitle: String? {
        guard item.customTitle == nil,
              item.calendarMatch?.titleState == .suggested else {
            return nil
        }
        return item.calendarMatch?.suggestedTitle
    }

    private var suggestedCalendarAppliedTitle: String? {
        guard let suggestedCalendarTitle else { return nil }
        return NoteTitleResolver.calendarAppliedTitle(
            suggestedTitle: suggestedCalendarTitle,
            recordingStartedAt: item.timestamp
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                noteHeader
                contentArea
            }
            floatingToolbar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { loadContent() }
        .onChange(of: item.postProcessedTranscript) { newValue in
            if !newValue.isEmpty {
                loadedContent = newValue
            }
        }
        .sheet(isPresented: $showExportSheet) {
            ObsidianExportSheet(
                item: item,
                content: displayContent,
                customTitle: item.customTitle,
                onDismiss: { showExportSheet = false }
            )
        }
        .onReceive(appState.$retryingItemIDs) { ids in
            isRetrying = ids.contains(item.id)
        }
        .confirmationDialog("노트를 삭제할까요?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("삭제", role: .destructive) { onDelete() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("삭제한 노트는 복구할 수 없습니다.")
        }
    }

    // MARK: Header

    private var noteHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            metadataLine

            // Title — auto-save on change
            TextField(
                item.timestamp.formatted(date: .long, time: .shortened),
                text: $titleDraft
            )
            .font(.system(size: 28, weight: .bold))
            .textFieldStyle(.plain)
            .foregroundStyle(.primary)
            .frame(minHeight: 38, alignment: .leading)
            .onChange(of: titleDraft) { newValue in
                titleDebounceTimer?.invalidate()
                let timer = Timer(timeInterval: 0.5, repeats: false) { _ in
                    Task { @MainActor in
                        appState.updateHistoryItemTitle(id: item.id, title: newValue)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                titleDebounceTimer = timer
            }
            .onAppear {
                titleDraft = item.customTitle ?? ""
            }
            .overrideCursor(.iBeam)

            if let suggestedCalendarTitle, let suggestedCalendarAppliedTitle {
                HStack(spacing: 10) {
                    Image(systemName: "calendar")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 24, height: 24)
                        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Calendar suggested title")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Text(suggestedCalendarTitle)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Apply") {
                        titleDraft = suggestedCalendarAppliedTitle
                        appState.updateHistoryItemTitle(id: item.id, title: suggestedCalendarAppliedTitle)
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(colorScheme == .dark ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.blue.opacity(0.16), lineWidth: 1)
                )
                .padding(.top, 2)
            }

            // Audio player (오디오 파일이 있을 때만 표시)
            if let audioFileName = item.audioFileName {
                let audioURL = AppState.audioStorageDirectory().appendingPathComponent(audioFileName)
                if FileManager.default.fileExists(atPath: audioURL.path) {
                    NoteAudioPlayerView(audioURL: audioURL)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 40)
        .padding(.top, 28)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.4)
        }
    }

    private var metadataLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                detailTimestampLabel
                statusBadges
                noteStateIndicator
                contextSummaryLabel
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    detailTimestampLabel
                    noteStateIndicator
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    statusBadges
                    contextSummaryLabel
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var detailTimestampLabel: some View {
        Text(NoteTimestampFormatter.detailTimestamp(for: item))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .kerning(0.5)
            .lineLimit(1)
    }

    @ViewBuilder
    private var noteStateIndicator: some View {
        if isLiveRecording {
            LiveRecordingBadge()
        } else if isError {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10, weight: .light))
                .foregroundStyle(.red.opacity(0.6))
                .help("Transcription failed")
        }
    }

    @ViewBuilder
    private var contextSummaryLabel: some View {
        if !item.contextSummary.isEmpty
            && !item.contextSummary.hasPrefix("Could not")
            && item.contextSummary != "Context capture disabled" {
            Text("·")
                .foregroundStyle(.quaternary)
                .font(.system(size: 10))
            Text(item.contextSummary)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var statusBadges: some View {
        HStack(spacing: 5) {
            metaTag(
                item.usedLocalTranscription ? "LOCAL" : "CLOUD",
                active: item.usedLocalTranscription,
                help: item.usedLocalTranscription ? "로컬 전사" : "클라우드 전사"
            )
            metaDot
            metaTag(
                item.usedContextCapture ? "CTX" : "NO CTX",
                active: item.usedContextCapture,
                help: item.usedContextCapture ? "컨텍스트 캡처 사용" : "컨텍스트 미사용"
            )
            metaDot
            metaTag(
                item.usedPostProcessing ? "LLM" : "NO LLM",
                active: item.usedPostProcessing,
                help: item.usedPostProcessing ? "LLM 후처리 사용" : "LLM 후처리 미사용"
            )
            if item.transcriptionLanguageCode != "auto" {
                metaDot
                metaTag(
                    item.transcriptionLanguageCode.uppercased(),
                    active: true,
                    help: "전사 언어"
                )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var metaDot: some View {
        Text("·")
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.quaternary)
    }

    private func metaTag(_ label: String, active: Bool, help tooltip: String) -> some View {
        Button(action: {}) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(active ? Color.secondary.opacity(0.7) : Color.secondary.opacity(0.35))
                .padding(.vertical, 3)
                .padding(.horizontal, 2)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: Content

    private var contentArea: some View {
        Group {
            if loadedContent == nil {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if displayContent.isEmpty {
                emptyContentState
            } else {
                NoteTextView(text: displayContent, bottomPadding: 36) { edited in
                    loadedContent = edited
                    appState.updateTranscript(id: item.id, text: edited)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyContentState: some View {
        VStack(spacing: 14) {
            Spacer()
            if isError {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.06))
                        .frame(width: 80, height: 80)
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30, weight: .ultraLight))
                        .foregroundStyle(.red.opacity(0.6))
                }
                Text("Transcription failed")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(item.postProcessingStatus.replacingOccurrences(of: "Error: ", with: ""))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)
            } else {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.04))
                        .frame(width: 80, height: 80)
                    Image(systemName: "doc.text")
                        .font(.system(size: 30, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                }
                Text("No content")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Floating Toolbar

    private var floatingToolbar: some View {
        HStack(spacing: 2) {
            if canRetry {
                toolbarButton(
                    action: { retryTranscription() },
                    label: {
                        Group {
                            if isRetrying {
                                ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.orange)
                            }
                        }
                    },
                    disabled: isRetrying,
                    help: "전사 재시도"
                )
                toolbarDivider
            }

            // Copy
            toolbarButton(
                action: { copyContent() },
                label: {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isCopied ? Color.accentColor : Color.primary)
                },
                disabled: displayContent.isEmpty,
                help: "내용 복사"
            )

            // Share (Obsidian export)
            toolbarButton(
                action: { showExportSheet = true },
                label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.primary)
                },
                disabled: displayContent.isEmpty,
                help: "Obsidian으로 내보내기"
            )

            toolbarDivider

            // Delete
            toolbarButton(
                action: { showDeleteConfirmation = true },
                label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.8))
                },
                disabled: false,
                help: "노트 삭제"
            )
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .background {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: Capsule())
            } else {
                Capsule().fill(.ultraThinMaterial)
            }
            #else
            Capsule().fill(.ultraThinMaterial)
            #endif
        }
        .overlay(Capsule().strokeBorder(toolbarStrokeColor, lineWidth: 0.6))
        .compositingGroup()
        .shadow(color: .black.opacity(0.085), radius: 14, x: 0, y: 4)
        .shadow(color: .white.opacity(0.05), radius: 4, x: 0, y: -1)
        .padding(.bottom, 20)
        .zIndex(100)
        .contentShape(Capsule())
        .allowsHitTesting(true)
        .overrideCursor(.arrow)
    }

    private var toolbarStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.primary.opacity(0.10)
    }

    private func toolbarButton<L: View>(
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> L,
        disabled: Bool,
        help: String
    ) -> some View {
        ToolbarIconButton(
            action: action,
            disabled: disabled,
            help: help,
            label: label
        )
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 0.5, height: 18)
            .padding(.horizontal, 4)
    }

    // MARK: Actions

    private func loadContent() {
        let postProcessed = item.postProcessedTranscript
        let raw = item.rawTranscript
        let fileName = item.transcriptFileName
        Task.detached(priority: .userInitiated) {
            let text: String
            if !postProcessed.isEmpty {
                text = postProcessed
            } else if let fileName {
                text = AppState.loadTranscript(from: fileName) ?? raw
            } else {
                text = raw
            }
            await MainActor.run { loadedContent = text }
        }
    }

    private func retryTranscription() {
        appState.retryTranscription(item: item)
    }

    private func copyContent() {
        guard !displayContent.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayContent, forType: .string)
        withAnimation { isCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { isCopied = false }
        }
    }
}

// MARK: - Note Audio Player View (wireframe design)

struct NoteAudioPlayerView: View {
    let audioURL: URL

    @Environment(\.colorScheme) private var colorScheme
    @State private var player: AVAudioPlayer?
    @State private var delegate = AudioPlayerDelegate()
    @State private var isPlaying = false
    @State private var duration: TimeInterval = 0
    @State private var elapsed: TimeInterval = 0
    @State private var progressTimer: Timer?
    @State private var volume: Double = 1
    @State private var showVolumePopover = false

    @State private var barHeights: [CGFloat] = Array(repeating: 0.15, count: 80)

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(elapsed / duration, 1.0)
    }

    private var volumeIcon: String {
        if volume <= 0.001 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.fill" }
        if volume < 0.67 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    private var toolbarStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.primary.opacity(0.10)
    }

    var body: some View {
        HStack(spacing: 14) {
            // Play / Stop button — var(--ink) bg, var(--bg) icon
            Button { togglePlayback() } label: {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.10))
                        .overlay(GlassView(material: .popover).clipShape(Circle()))
                        .overlay(Circle().strokeBorder(toolbarStrokeColor, lineWidth: 0.7))
                        .frame(width: 36, height: 36)
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .offset(x: isPlaying ? 0 : 1.5)
                }
            }
            .buttonStyle(.plain)

            // Waveform — border-radius:1px, opacity:0.45 unplayed, accent played
            GeometryReader { geo in
                let layout = AudioWaveformHeights.layout(
                    width: geo.size.width,
                    barCount: barHeights.count,
                    preferredGap: 2
                )
                let playedCount = Int(Double(layout.barCount) * progress)

                HStack(alignment: .center, spacing: layout.gap) {
                    ForEach(0..<layout.barCount, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(i < playedCount
                                  ? Color.accentColor
                                  : Color.primary.opacity(0.45))
                            .frame(width: layout.barWidth, height: geo.size.height * barHeights[i])
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                // Tap to jump, drag to scrub. minimumDistance 0 makes a plain
                // tap report through onChanged as well as a drag.
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            seek(toFraction: Double(value.location.x / geo.size.width))
                        }
                )
            }
            .frame(height: 44)

            // Time — monospaced, tabular, intrinsic width so the waveform flexes with label length.
            Text("\(formatDuration(elapsed)) / \(formatDuration(duration))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            // Volume — tap the speaker for a slider popover
            Button { showVolumePopover.toggle() } label: {
                Image(systemName: volumeIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showVolumePopover, arrowEdge: .bottom) {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Slider(value: $volume, in: 0...1)
                        .frame(width: 120)
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(height: 72)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.06), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
        }
        .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
        .shadow(color: .black.opacity(0.04), radius: 3, x: 0, y: 1)
        .onAppear {
            loadDuration()
            loadWaveform()
        }
        .onChange(of: volume) { newValue in
            player?.volume = Float(newValue)
        }
        .onDisappear { stopPlayback() }
    }

    private func loadWaveform() {
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return }
        Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: audioURL)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32
            ]
            let reader: AVAssetReader
            do { reader = try AVAssetReader(asset: asset) } catch { return }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            reader.add(output)
            guard reader.startReading() else { return }

            var samples: [Float] = []
            while let buf = output.copyNextSampleBuffer(),
                  let block = CMSampleBufferGetDataBuffer(buf) {
                let len = CMBlockBufferGetDataLength(block)
                var data = Data(count: len)
                _ = data.withUnsafeMutableBytes { ptr in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: ptr.baseAddress!)
                }
                data.withUnsafeBytes { ptr in
                    let floats = ptr.bindMemory(to: Float.self)
                    samples.append(contentsOf: floats)
                }
            }

            let resolvedHeights = AudioWaveformHeights.heights(from: samples).map(CGFloat.init)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.4)) { barHeights = resolvedHeights }
            }
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
            pausePlayback()
        } else {
            play()
        }
    }

    /// Lazily creates the player (if needed) and resumes from the current
    /// position so pause keeps its place and seeking before pressing play works.
    @discardableResult
    private func preparedPlayer() -> AVAudioPlayer? {
        if let player { return player }
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return nil }
        guard let p = try? AVAudioPlayer(contentsOf: audioURL) else { return nil }
        delegate.onFinish = { handlePlaybackFinished() }
        p.delegate = delegate
        p.volume = Float(volume)
        p.prepareToPlay()
        player = p
        return p
    }

    private func play() {
        guard let p = preparedPlayer() else { return }
        p.play()
        isPlaying = true
        startProgressTimer()
    }

    private func pausePlayback() {
        player?.pause()
        isPlaying = false
        progressTimer?.invalidate()
        progressTimer = nil
        elapsed = player?.currentTime ?? elapsed
    }

    /// Playback reached the end: stop the ticker and rewind to the start so the
    /// next press of play restarts from the beginning.
    private func handlePlaybackFinished() {
        isPlaying = false
        progressTimer?.invalidate()
        progressTimer = nil
        player?.currentTime = 0
        elapsed = 0
    }

    /// Tears the player down entirely. Used when the view goes away.
    private func stopPlayback() {
        player?.stop()
        player = nil
        isPlaying = false
        progressTimer?.invalidate()
        progressTimer = nil
        elapsed = 0
    }

    /// Moves the playhead to `fraction` (0...1) of the duration. Works whether or
    /// not playback is currently running.
    private func seek(toFraction fraction: Double) {
        // `fraction` comes from location.x / width; guard against a 0-width
        // layout (NaN/Infinity) so we never set a bad AVAudioPlayer.currentTime.
        guard fraction.isFinite, duration > 0, let p = preparedPlayer() else { return }
        let clamped = min(max(fraction, 0), 1)
        let target = clamped * duration
        p.currentTime = target
        elapsed = target
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            elapsed = player?.currentTime ?? 0
        }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        guard t.isFinite else { return "0:00" }
        let total = Int(t)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Toolbar Button Style

private struct ToolbarButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    var isHovered: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(
                        configuration.isPressed
                            ? Color.primary.opacity(0.12)
                            : (isHovered ? hoverFillColor : Color.clear)
                    )
            )
            .overlay(
                Circle()
                    .strokeBorder(hoverStrokeColor.opacity(isHovered ? 1 : 0), lineWidth: 0.5)
            )
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.12), value: isHovered)
    }

    private var hoverFillColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.primary.opacity(0.07)
    }

    private var hoverStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color.primary.opacity(0.12)
    }
}

private struct ToolbarIconButton<Label: View>: View {
    let action: () -> Void
    let disabled: Bool
    let help: String
    @ViewBuilder let label: () -> Label

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(ToolbarButtonStyle(isHovered: isHovered))
        .disabled(disabled)
        .help(help)
        .contentShape(Circle())
        .allowsHitTesting(true)
        .onHover { hovering in
            isHovered = hovering
        }
        .overrideCursor(.arrow)
    }
}

// MARK: - Obsidian Export Sheet

private struct ObsidianExportSheet: View {
    let item: PipelineHistoryItem
    let content: String
    var customTitle: String? = nil
    let onDismiss: () -> Void

    @AppStorage("obsidian_vault_path") private var vaultPath: String = ""
    @AppStorage("obsidian_gemini_prompt") private var geminiPrompt: String = "다음은 음성 전사 내용입니다. 핵심 내용을 유지하면서 읽기 쉽게 정리해주세요. 마크다운 형식으로 작성하되, 불필요한 설명 없이 정리된 내용만 출력해주세요.\n옵시디언에 다른 회의록을 참고하여 컨텍스트와 작성 포맷을 통일하여 주세요."
    @State private var titleInput: String = ""
    @State private var includeAudio: Bool = true
    @State private var useGemini: Bool = false
    @State private var showPromptEditor: Bool = false
    @State private var exportResult: String?
    @State private var isSuccess = false

    private var defaultTitleInput: String {
        guard let custom = customTitle, !custom.isEmpty else { return "" }
        return custom.replacingOccurrences(of: #"^\d{4}-\d{2}-\d{2}\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private var hasAudio: Bool {
        guard let fileName = item.audioFileName else { return false }
        return FileManager.default.fileExists(
            atPath: AppState.audioStorageDirectory().appendingPathComponent(fileName).path
        )
    }

    private var datePrefix: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: item.timestamp)
    }

    private var finalFileName: String {
        let extra = titleInput.trimmingCharacters(in: .whitespaces)
        return extra.isEmpty ? datePrefix : "\(datePrefix) \(extra)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Obsidian으로 내보내기")
                .font(.headline)
                .padding(.bottom, 20)

            fieldLabel("파일 제목")
            HStack(spacing: 6) {
                Text(datePrefix)
                    .font(.body).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                TextField("제목 추가 (선택)", text: $titleInput)
                    .textFieldStyle(.roundedBorder)
            }
            Text("저장될 파일명: \(finalFileName).md")
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.top, 4).padding(.bottom, 16)

            fieldLabel("Obsidian Vault 폴더")
            HStack(spacing: 8) {
                Text(vaultPath.isEmpty ? "폴더를 선택하세요" : vaultPath)
                    .font(.callout)
                    .foregroundStyle(vaultPath.isEmpty ? .tertiary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                Button("변경") { selectVaultFolder() }.controlSize(.small)
            }
            .padding(.bottom, 16)

            if hasAudio {
                Toggle(isOn: $includeAudio) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("오디오 파일 포함").font(.callout)
                        Text("md 파일과 같은 폴더에 복사됩니다")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox).padding(.bottom, 12)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $useGemini) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gemini로 내용 정리").font(.callout)
                        Text("내보내기 전에 Gemini CLI로 전사 내용을 정리합니다")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)

                if useGemini {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("프롬프트").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Button(showPromptEditor ? "접기" : "편집") { showPromptEditor.toggle() }
                                .font(.caption).controlSize(.mini)
                        }
                        if showPromptEditor {
                            TextEditor(text: $geminiPrompt)
                                .font(.caption)
                                .frame(height: 80)
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                        } else {
                            Text(geminiPrompt)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.leading, 20)
                }
            }
            .padding(.bottom, 16)

            if let result = exportResult {
                HStack(spacing: 6) {
                    Image(systemName: isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(isSuccess ? .green : .red)
                    Text(result).font(.caption)
                        .foregroundStyle(isSuccess ? .green : .red)
                }
                .padding(.bottom, 8)
            }

            Spacer()
            Divider().padding(.bottom, 16)

            HStack {
                Button("취소") { onDismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(useGemini ? "백그라운드로 내보내기" : "내보내기") { exportNote() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(vaultPath.isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { titleInput = defaultTitleInput }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 6)
    }

    private func selectVaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "선택"
        panel.message = "Obsidian Vault 폴더를 선택하세요"
        if panel.runModal() == .OK, let url = panel.url { vaultPath = url.path }
    }

    @MainActor
    private func exportNote() {
        guard !vaultPath.isEmpty else { return }
        let safeFileName = finalFileName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
        let audioSrcURL: URL? = (includeAudio && hasAudio && item.audioFileName != nil)
            ? AppState.audioStorageDirectory().appendingPathComponent(item.audioFileName!)
            : nil
        ObsidianExportManager.shared.export(
            itemID: item.id,
            content: content,
            fileName: safeFileName,
            vaultPath: vaultPath,
            audioSrcURL: audioSrcURL,
            useGemini: useGemini,
            geminiPrompt: geminiPrompt,
            timestamp: item.timestamp
        )
        onDismiss()
    }
}

// MARK: - Native Text View

private struct NoteTextView: NSViewRepresentable {
    let text: String
    var bottomPadding: CGFloat = 0
    var onCommit: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onCommit: onCommit) }

    private func configureForTranscriptDisplay(_ textView: NSTextView) {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.enabledTextCheckingTypes = 0
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.layoutManager?.allowsNonContiguousLayout = true
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        configureForTranscriptDisplay(textView)
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainerInset = NSSize(width: 40, height: 20)
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        applyText(text, to: textView, bottomPadding: bottomPadding)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.onCommit = onCommit
        let currentContent = textView.string.trimmingCharacters(in: .newlines)
        let newContent = text.trimmingCharacters(in: .newlines)
        if textView.window?.firstResponder !== textView, currentContent != newContent {
            applyText(text, to: textView, bottomPadding: bottomPadding)
        }
    }

    private func applyText(_ text: String, to textView: NSTextView, bottomPadding: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacing = 6
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15),
            .paragraphStyle: style,
            .foregroundColor: NSColor.labelColor
        ]
        let lineCount = bottomPadding > 0 ? max(1, Int(bottomPadding / 18)) : 0
        let padding = String(repeating: "\n", count: lineCount)
        let newText = text + padding
        let attrStr = NSMutableAttributedString(string: newText, attributes: attrs)
        textView.textStorage?.setAttributedString(attrStr)
        textView.typingAttributes = attrs
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var onCommit: ((String) -> Void)?
        private var debounceTimer: Timer?

        init(onCommit: ((String) -> Void)?) { self.onCommit = onCommit }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            debounceTimer?.invalidate()
            let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self, weak textView] _ in
                guard let text = textView?.string else { return }
                self?.onCommit?(text.trimmingCharacters(in: .newlines))
            }
            RunLoop.current.add(timer, forMode: .common)
            debounceTimer = timer
        }
    }
}

// MARK: - Shared Indicators

private struct YellowSpinner: View {
    var color: Color = .yellow
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.65)
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 8, height: 8)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.75).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// MARK: - Live Recording Badge

private struct LiveRecordingBadge: View {
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.red)
                .frame(width: 5, height: 5)
                .opacity(pulsing ? 0.3 : 1.0)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
                .onAppear { pulsing = true }
            Text("REC")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.red.opacity(0.7))
        }
        .help("실시간 전사 중")
    }
}

/// Transparent click target that pops up a native NSMenu of audio inputs.
/// Used so the Note Browser's chevron glyph is fully custom and the current
/// input shows a native checkmark.
private struct InputMenuCatcher: NSViewRepresentable {
    let sources: [(id: String, name: String)]
    let mics: [(id: String, name: String)]
    let selectedID: String
    let onSelect: (String) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.apply(sources: sources, mics: mics, selectedID: selectedID, onSelect: onSelect)
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.apply(sources: sources, mics: mics, selectedID: selectedID, onSelect: onSelect)
    }

    final class CatcherView: NSView {
        private var sources: [(id: String, name: String)] = []
        private var mics: [(id: String, name: String)] = []
        private var selectedID = ""
        private var onSelect: ((String) -> Void)?

        override var isFlipped: Bool { true }
        // Open the menu on the first click even when the window is in the background.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        func apply(
            sources: [(id: String, name: String)],
            mics: [(id: String, name: String)],
            selectedID: String,
            onSelect: @escaping (String) -> Void
        ) {
            self.sources = sources
            self.mics = mics
            self.selectedID = selectedID
            self.onSelect = onSelect
        }

        override func mouseDown(with event: NSEvent) {
            let menu = NSMenu()
            for option in sources {
                menu.addItem(makeItem(option))
            }
            if !mics.isEmpty {
                menu.addItem(.separator())
                for option in mics {
                    menu.addItem(makeItem(option))
                }
            }
            // Flipped view: y == bounds.height is the bottom edge, so the menu
            // drops just below the chevron.
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
        }

        private func makeItem(_ option: (id: String, name: String)) -> NSMenuItem {
            let item = NSMenuItem(title: option.name, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.id
            item.state = AudioInputDevice.isSameInput(option.id, selectedID) ? .on : .off
            return item
        }

        @objc private func pick(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            onSelect?(id)
        }
    }
}
