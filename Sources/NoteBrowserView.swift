import SwiftUI
import UserNotifications
import AVFoundation

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

@available(macOS 26.0, *)
private class LiquidGlassNSView: NSView {
    private let glassView = NSGlassEffectView()
    var cornerRadius: CGFloat? = nil

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        glassView.contentView = NSView()
        glassView.wantsLayer = true
        addSubview(glassView)
    }

    override func layout() {
        super.layout()
        glassView.frame = bounds
        glassView.cornerRadius = cornerRadius ?? bounds.height / 2
    }
}

private struct GlassView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var cornerRadius: CGFloat? = nil

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let view = LiquidGlassNSView()
            if let cornerRadius {
                view.cornerRadius = cornerRadius
            }
            return view
        }
        let view = GlassNSView(material: material)
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let nsView = nsView as? GlassNSView {
            nsView.material = material
            nsView.cornerRadius = cornerRadius
        }
        if #available(macOS 26.0, *), let nsView = nsView as? LiquidGlassNSView {
            nsView.cornerRadius = cornerRadius
        }
    }
}

// MARK: - Status helpers

private enum TranscriptStatus {
    case done, progress, fail
}

private func transcriptStatus(for item: PipelineHistoryItem, retrying: Set<UUID>) -> TranscriptStatus {
    if retrying.contains(item.id) { return .progress }
    if item.postProcessingStatus == "live-recording" { return .progress }
    if item.postProcessingStatus.hasPrefix("Error:") { return .fail }
    return .done
}

// MARK: - Obsidian Export Manager

final class ObsidianExportManager: ObservableObject {
    static let shared = ObsidianExportManager()
    private init() {}

    @Published private(set) var processingIDs: Set<UUID> = []

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

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
                let audioEmbed = audioSrcURL != nil ? "\n![[\(fileName).wav]]\n" : ""

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
                   FileManager.default.fileExists(atPath: srcURL.path) {
                    let dstURL = vaultURL.appendingPathComponent(fileName + ".wav")
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
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = success ? .default : nil
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
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

// MARK: - Note Title Store

final class NoteTitleStore: ObservableObject {
    static let shared = NoteTitleStore()
    @Published private(set) var titles: [UUID: String] = [:]
    private let key = "note_custom_titles"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            titles = Dictionary(uniqueKeysWithValues: raw.compactMap {
                guard let uuid = UUID(uuidString: $0.key) else { return nil }
                return (uuid, $0.value)
            })
        }
    }

    func setTitle(_ title: String, for id: UUID) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { titles.removeValue(forKey: id) } else { titles[id] = trimmed }
        save()
    }

    func title(for id: UUID) -> String? { titles[id] }

    private func save() {
        let raw = Dictionary(uniqueKeysWithValues: titles.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(raw) { UserDefaults.standard.set(data, forKey: key) }
    }
}

// MARK: - Note Browser View

struct NoteBrowserView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var exportManager: ObsidianExportManager
    @StateObject private var titleStore = NoteTitleStore.shared
    @State private var selectedItemID: UUID?
    @State private var searchText = ""
    @State private var knownHistoryIDs: Set<UUID> = []

    private var filteredHistory: [PipelineHistoryItem] {
        guard !searchText.isEmpty else { return appState.pipelineHistory }
        let q = searchText.lowercased()
        return appState.pipelineHistory.filter {
            $0.postProcessedTranscript.lowercased().contains(q) ||
            $0.contextSummary.lowercased().contains(q) ||
            (titleStore.title(for: $0.id) ?? "").lowercased().contains(q)
        }
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

    private var sidebarPanel: some View {
        VStack(spacing: 0) {
            // Title row
            HStack(spacing: 8) {
                Text("Recordings")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                if !appState.pipelineHistory.isEmpty {
                    Text("\(appState.pipelineHistory.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                Spacer()
                // Record button
                Button {
                    appState.toggleRecording()
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(.white)
                            .frame(width: 6, height: 6)
                            .opacity(appState.isRecording ? 0.6 : 1.0)
                            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                                       value: appState.isRecording)
                        Text(appState.isRecording ? "중지" : "녹음")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(appState.isRecording ? Color.orange : Color.red, in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .overrideCursor(.arrow)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

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
                                item: item,
                                isSelected: selectedItemID == item.id,
                                customTitle: titleStore.title(for: item.id),
                                retryingIDs: appState.retryingItemIDs
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
            NoteDetailView(item: item, titleStore: titleStore) {
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
    let item: PipelineHistoryItem
    let isSelected: Bool
    var customTitle: String? = nil
    let retryingIDs: Set<UUID>

    @EnvironmentObject private var exportManager: ObsidianExportManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var status: TranscriptStatus { transcriptStatus(for: item, retrying: retryingIDs) }

    private var isExporting: Bool { exportManager.processingIDs.contains(item.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Content
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(rowDate)
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

                Text(displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selectedTitleColor)
                    .lineLimit(1)

                Text(notePreview.isEmpty ? " " : notePreview)
                    .font(.system(size: 11.5))
                    .foregroundStyle(selectedPreviewColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .opacity(notePreview.isEmpty ? 0 : 1)
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
        switch status {
        case .done:
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
        case .progress:
            YellowSpinner(color: .yellow)
        case .fail:
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
        }
    }

    private var rowDate: String {
        let f = DateFormatter()
        f.dateFormat = "M월 d일 · HH:mm"
        return f.string(from: item.timestamp)
    }

    private var normalizedContent: String {
        item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayTitle: String {
        if let custom = customTitle, !custom.isEmpty { return custom }
        return autoTitle
    }

    private var autoTitle: String {
        let content = normalizedContent
        if content.isEmpty {
            if status == .fail { return "전사 실패" }
            if status == .progress { return "녹음 중..." }
            return "(내용 없음)"
        }
        let firstLine = content.components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? content
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= 60 ? trimmed : String(trimmed.prefix(60))
    }

    private var notePreview: String {
        if status == .fail { return item.postProcessingStatus.replacingOccurrences(of: "Error: ", with: "") }
        let content = normalizedContent
        if customTitle != nil {
            return String(content.prefix(100))
        }
        guard content.count > autoTitle.count else { return "" }
        let rest = content.dropFirst(autoTitle.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(rest.prefix(100))
    }
}

// MARK: - Note Detail View

private struct NoteDetailView: View {
    let item: PipelineHistoryItem
    let titleStore: NoteTitleStore
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
                customTitle: titleStore.title(for: item.id),
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
            // Meta line — monospace, small caps
            HStack(spacing: 8) {
                Text(item.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .kerning(0.5)
                statusBadges
                if isLiveRecording {
                    LiveRecordingBadge()
                } else if isError {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10, weight: .light))
                        .foregroundStyle(.red.opacity(0.6))
                        .help("전사 실패")
                }
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
                Spacer()
            }

            // Title — auto-save on change
            TextField(
                item.timestamp.formatted(date: .long, time: .shortened),
                text: $titleDraft
            )
            .font(.system(size: 28, weight: .bold))
            .textFieldStyle(.plain)
            .foregroundStyle(.primary)
            .onChange(of: titleDraft) { newValue in
                titleDebounceTimer?.invalidate()
                let timer = Timer(timeInterval: 0.5, repeats: false) { [weak titleStore] _ in
                    titleStore?.setTitle(newValue, for: item.id)
                }
                RunLoop.main.add(timer, forMode: .common)
                titleDebounceTimer = timer
            }
            .onAppear {
                titleDraft = titleStore.title(for: item.id) ?? ""
            }
            .overrideCursor(.iBeam)

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
                Text("전사에 실패했습니다")
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
                Text("내용 없음")
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
            GlassView(material: .underWindowBackground)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(toolbarStrokeColor, lineWidth: 0.6))
        }
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

    @State private var barHeights: [CGFloat] = Array(repeating: 0.15, count: 80)

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(elapsed / duration, 1.0)
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
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .offset(x: isPlaying ? 0 : 1.5)
                }
            }
            .buttonStyle(.plain)

            // Waveform — border-radius:1px, opacity:0.45 unplayed, accent played
            GeometryReader { geo in
                let barCount = barHeights.count
                let gap: CGFloat = 2
                let totalGap = gap * CGFloat(barCount - 1)
                let barWidth = max(1, (geo.size.width - totalGap) / CGFloat(barCount))
                let playedCount = Int(Double(barCount) * progress)

                HStack(alignment: .center, spacing: gap) {
                    ForEach(0..<barCount, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(i < playedCount
                                  ? Color.accentColor
                                  : Color.primary.opacity(0.45))
                            .frame(width: barWidth, height: geo.size.height * barHeights[i])
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 44)

            // Time — monospaced, tabular, var(--ink-2) ≈ secondary, min-width 80
            Text("\(formatDuration(elapsed)) / \(formatDuration(duration))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 80, alignment: .center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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

            guard !samples.isEmpty else { return }
            let bucketSize = max(1, samples.count / 80)
            var heights: [CGFloat] = []
            for i in 0..<80 {
                let start = i * bucketSize
                let end = min(start + bucketSize, samples.count)
                let rms = sqrt(samples[start..<end].map { $0 * $0 }.reduce(0, +) / Float(end - start))
                heights.append(CGFloat(min(1.0, max(0.04, rms * 8))))
            }
            let resolvedHeights = heights
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
            stopPlayback()
        } else {
            guard FileManager.default.fileExists(atPath: audioURL.path) else { return }
            do {
                let p = try AVAudioPlayer(contentsOf: audioURL)
                delegate.onFinish = { stopPlayback() }
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
        player?.stop()
        player = nil
        isPlaying = false
        progressTimer?.invalidate()
        progressTimer = nil
        elapsed = 0
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

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
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
        if textView.string == newText {
            textView.typingAttributes = attrs
            return
        }
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
