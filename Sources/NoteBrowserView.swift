import SwiftUI
import UserNotifications
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Cursor helper

private class CursorNSView: NSView {
    var cursor: NSCursor

    /// Cursor overrides currently in a window. Text views underneath one
    /// (such as the transcript under the floating toolbar) defer to it.
    private static let liveViews = NSHashTable<CursorNSView>.weakObjects()

    init(cursor: NSCursor) {
        self.cursor = cursor
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            Self.liveViews.remove(self)
        } else {
            Self.liveViews.add(self)
        }
    }

    /// The override cursor for a point in window coordinates, if one covers it.
    static func cursor(atWindowPoint point: NSPoint, in window: NSWindow?) -> NSCursor? {
        guard let window else { return nil }
        for view in liveViews.allObjects
        where view.window === window && !view.isHiddenOrHasHiddenAncestor {
            if view.convert(view.bounds, to: nil).contains(point) {
                return view.cursor
            }
        }
        return nil
    }

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

// MARK: - Audio Import

private struct PendingAudioImport: Identifiable {
    let id = UUID()
    let fileURL: URL
    let currentChoice: TranscriptionBackendChoice
    let apiStandardModelID: String
    let hasAPIKey: Bool
    let hasNativeLocalWhisperModel: Bool
    let legacyLocalWhisperModels: [TranscriptionModel]
    let localAIModels: [AudioImportLocalAIModel]
    let fileSizeBytes: Int64?

    init(
        fileURL: URL,
        currentChoice: TranscriptionBackendChoice,
        apiStandardModelID: String,
        hasAPIKey: Bool,
        hasNativeLocalWhisperModel: Bool,
        legacyLocalWhisperModels: [TranscriptionModel],
        localAIModels: [AudioImportLocalAIModel]
    ) {
        self.fileURL = fileURL
        self.currentChoice = currentChoice
        self.apiStandardModelID = apiStandardModelID
        self.hasAPIKey = hasAPIKey
        self.hasNativeLocalWhisperModel = hasNativeLocalWhisperModel
        self.legacyLocalWhisperModels = legacyLocalWhisperModels
        self.localAIModels = localAIModels
        let accessGranted = fileURL.startAccessingSecurityScopedResource()
        self.fileSizeBytes = accessGranted ? AppState.fileSizeBytes(for: fileURL) : nil
        if accessGranted {
            fileURL.stopAccessingSecurityScopedResource()
        }
    }

    var options: AudioImportOptions {
        AudioImportOptions(
            fileExtension: fileURL.pathExtension,
            currentChoice: currentChoice,
            apiStandardModelID: apiStandardModelID,
            fileSizeBytes: fileSizeBytes,
            hasAPIKey: hasAPIKey,
            hasNativeLocalWhisperModel: hasNativeLocalWhisperModel,
            legacyLocalWhisperModels: legacyLocalWhisperModels,
            localAIModels: localAIModels,
            nativeWhisperModelID: NativeWhisperModelCatalog.recommended.id,
            nativeWhisperDisplayName: NativeWhisperModelCatalog.recommended.displayName
        )
    }
}

/// Picks the model for one transcription the user starts by hand: an audio
/// import, or transcribing a saved note when no usable model is selected.
/// The choice applies to that transcription only.
struct TranscriptionChoiceSheet: View {
    let title: LocalizedStringKey
    let subtitle: String
    let showsSettingNote: Bool
    let options: AudioImportOptions
    let onConfirm: (TranscriptionBackendChoice) -> Void
    let onOpenProviderSettings: () -> Void
    let onCancel: () -> Void

    @State private var selectedChoice: TranscriptionBackendChoice

    init(
        title: LocalizedStringKey,
        subtitle: String,
        showsSettingNote: Bool,
        options: AudioImportOptions,
        fallbackChoice: TranscriptionBackendChoice,
        onConfirm: @escaping (TranscriptionBackendChoice) -> Void,
        onOpenProviderSettings: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.showsSettingNote = showsSettingNote
        self.options = options
        self.onConfirm = onConfirm
        self.onOpenProviderSettings = onOpenProviderSettings
        self.onCancel = onCancel
        _selectedChoice = State(initialValue: options.defaultChoice ?? fallbackChoice)
    }

    private var cloudRows: [TranscriptionChoiceDisplay] {
        options.displayRows.filter { $0.choice.usesCloudAPI }
    }

    private var onThisMacRows: [TranscriptionChoiceDisplay] {
        options.displayRows.filter { !$0.choice.usesCloudAPI }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                Text(verbatim: subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if showsSettingNote {
                Label(
                    "The selected model is used for this transcription only. Your transcription setting stays the same.",
                    systemImage: "info.circle"
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if options.supportedChoices.isEmpty {
                Text("No transcription model is ready. Set one up in Settings, then try again.")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !options.isChoiceReady(selectedChoice) {
                Label(
                    "Add an API key to transcribe this file with the selected Cloud model.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Transcription Method")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                if !cloudRows.isEmpty {
                    section("Cloud", rows: cloudRows)
                }
                if !onThisMacRows.isEmpty {
                    section("On This Mac", rows: onThisMacRows)
                }
            }

            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if options.isChoiceReady(selectedChoice) {
                    Button("Transcribe") { onConfirm(selectedChoice) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Open Provider Settings") {
                        onOpenProviderSettings()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        options.supportedChoices.isEmpty
                            || !options.supportedChoices.contains(selectedChoice)
                    )
                }
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func section(
        _ heading: LocalizedStringKey,
        rows: [TranscriptionChoiceDisplay]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            ForEach(rows) { display in
                Button {
                    selectedChoice = display.choice
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: selectedChoice == display.choice ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: display.localizedCompactLabel())
                            if let unavailableReason = display.unavailableReason {
                                Text(display.localizedUnavailableReason() ?? unavailableReason)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .disabled(!display.isAvailable)
                .opacity(display.isAvailable ? 1 : 0.45)
            }
        }
    }
}

// MARK: - Note Browser View

private struct NoteListTopOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

/// Hides the focus ring where focus is shown another way, such as the
/// accent-colored open row in the note list. macOS 13 keeps the ring.
private struct NoFocusRing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

private struct DimmedWhenDisabled: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    func body(content: Content) -> some View {
        content.opacity(isEnabled ? 1 : 0.35)
    }
}

struct RetryChoiceRequest: Identifiable {
    let id = UUID()
    let options: AudioImportOptions
}

private struct RecoveryScrollRestoreRequest: Identifiable {
    let id = UUID()
    let itemID: UUID
}

struct NoteBrowserView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection = NoteSelection()
    @State private var pendingDeletionIDs: [UUID] = []
    /// A short notice when a deletion has to wait, such as for Recover Again.
    @State private var deletionNotice: String?
    @State private var deletionNoticeID: UUID?
    @State private var showDeletionConfirmation = false
    @State private var searchText = ""
    @State private var searchMatcher = NoteSearchMatcher()
    @State private var knownHistoryIDs: Set<UUID> = []
    @State private var recoveryScrollRestoreRequest: RecoveryScrollRestoreRequest?
    @State private var pendingAudioImport: PendingAudioImport?
    @State private var isSearchOpen = false
    @FocusState private var isSearchFieldFocused: Bool
    @State private var noteListTopOffset: CGFloat = 0
    @State private var sidebarHeaderHeight: CGFloat = 0
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var increasesContrast: Bool { colorSchemeContrast == .increased }

    private var filteredHistory: [PipelineHistoryItem] {
        guard !searchText.isEmpty else {
            searchMatcher.clearCache()
            return appState.pipelineHistory
        }
        searchMatcher.retainCache(for: Set(appState.pipelineHistory.map(\.id)))
        return appState.pipelineHistory.filter(matchesSearch)
    }

    private func matchesSearch(_ item: PipelineHistoryItem) -> Bool {
        searchMatcher.matches(item, query: searchText)
    }

    /// The note shown in the detail pane when one note is selected.
    private var selectedItemID: UUID? { selection.focusedID }
    /// True while the note list has keyboard focus: ↑/↓ move the open note
    /// and the open row is drawn in the accent color, like Finder.
    @FocusState private var isNoteListFocused: Bool

    /// Opens the note above or below the open one and keeps it in view.
    private func moveListFocus(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        guard !selection.showsSelectionUI else { return }
        let ids = filteredHistory.map(\.id)
        guard !ids.isEmpty else { return }
        let step: Int
        switch direction {
        case .up: step = -1
        case .down: step = 1
        default: return
        }
        let current = selectedItemID.flatMap { ids.firstIndex(of: $0) }
        let nextIndex = current.map { min(max($0 + step, 0), ids.count - 1) } ?? 0
        let nextID = ids[nextIndex]
        selection.click(
            nextID,
            modifier: .none,
            orderedIDs: ids,
            isSelectable: isBulkSelectable
        )
        // Center it: the header covers the list's top and the Record
        // button its bottom, so a row scrolled just into view can be hidden.
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(nextID, anchor: .center)
        }
    }

    private func isBulkSelectable(_ id: UUID) -> Bool {
        isBulkSelectable(id, in: appState.pipelineHistory)
    }

    private func isBulkSelectable(_ id: UUID, in history: [PipelineHistoryItem]) -> Bool {
        guard let item = history.first(where: { $0.id == id }) else { return false }
        // A note making its summary is busy too, so bulk delete never skips it silently.
        return transcriptStatus(for: item, retrying: appState.retryingItemIDs).isBulkSelectable
            && !appState.meetingSummaryGeneratingNoteIDs.contains(id)
            && !appState.recoveringRecordingIDs.contains(id)
    }

    private func handleRowClick(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        let modifier: NoteSelectionModifier = flags.contains(.command)
            ? .toggle
            : flags.contains(.shift) ? .extend : .none
        selection.click(
            id,
            modifier: modifier,
            orderedIDs: filteredHistory.map(\.id),
            isSelectable: isBulkSelectable
        )
    }

    private func beginSelection(including id: UUID? = nil) {
        selection.beginSelectionMode()
        if let id, !selection.selectedIDs.contains(id) {
            selection.click(
                id,
                modifier: .none,
                orderedIDs: filteredHistory.map(\.id),
                isSelectable: isBulkSelectable
            )
        }
    }

    private func selectAllVisibleNotes() -> Bool {
        let ids = filteredHistory.map(\.id)
        guard ids.contains(where: isBulkSelectable) else { return false }
        selection.selectAll(orderedIDs: ids, isSelectable: isBulkSelectable)
        return true
    }

    /// Asks to delete the multi-selection, or the clicked note when it is not part of it.
    private func requestDeletion(of id: UUID? = nil) {
        if let id, appState.recoveringRecordingIDs.contains(id) {
            showDeletionNotice(localizedCatalogString(
                "Wait for the recording recovery to finish, then try again."
            ))
            return
        }
        let ids: [UUID]
        if let id, !(selection.showsSelectionUI && selection.selectedIDs.contains(id)) {
            ids = [id]
        } else {
            ids = filteredHistory.map(\.id).filter { selection.selectedIDs.contains($0) }
        }
        guard !ids.isEmpty else { return }
        pendingDeletionIDs = ids
        showDeletionConfirmation = true
    }

    /// Deletes one note after the user confirmed. A settled note waits for the
    /// Cancel toast; a note still recording or processing is deleted for good,
    /// because its running work can't be put back.
    private func deleteConfirmedNote(_ id: UUID) {
        let nextID = NoteSelection.nextFocusedID(
            afterDeleting: [id],
            in: filteredHistory.map(\.id)
        )
        let wasChecked = selection.showsSelectionUI && selection.selectedIDs.contains(id)
        let wasFocused = selection.focusedID == id
        if appState.canDeleteHistoryEntryCancellably(id: id) {
            appState.deleteHistoryEntryCancellably(id: id)
        } else {
            appState.deleteHistoryEntry(id: id)
        }
        guard !appState.pipelineHistory.contains(where: { $0.id == id }) else { return }
        if wasChecked {
            selection.focus(nextID)
        } else if wasFocused, !selection.isSelectionModeRequested {
            // In selection mode the viewed note may be unchecked; keep the checked notes.
            selection.focus(nextID)
        }
    }

    private func performPendingDeletion() {
        let ids = pendingDeletionIDs
        pendingDeletionIDs = []
        guard !ids.isEmpty else { return }
        if ids.count == 1 {
            deleteConfirmedNote(ids[0])
            return
        }
        let nextID = NoteSelection.nextFocusedID(
            afterDeleting: Set(ids),
            in: filteredHistory.map(\.id)
        )
        let result = appState.deleteConfirmedHistoryEntries(ids: ids)
        if result.failedIDs.isEmpty, result.skippedIDs.isEmpty {
            selection.focus(nextID)
        } else {
            selection.retainVisible(filteredHistory.map(\.id))
        }
    }

    private func handleKeyCommand(_ command: NoteBrowserKeyCommand) -> Bool {
        switch command {
        case .selectAll:
            return selectAllVisibleNotes()
        case .endSelection:
            guard selection.showsSelectionUI else { return false }
            selection.endSelectionMode()
            return true
        case .delete:
            guard selection.showsSelectionUI, !selection.selectedIDs.isEmpty else { return false }
            requestDeletion()
            return true
        }
    }

    private var deletionConfirmationTitle: Text {
        if pendingDeletionIDs.count == 1 {
            return pendingDeletionIncludesRecordingPieces
                ? Text("Delete this note and its recording pieces?")
                : Text("Delete this note?")
        }
        return Text(localizedCatalogFormat("Delete %lld notes?", pendingDeletionIDs.count))
    }

    /// Whether a note waiting to be deleted still holds the pieces of a
    /// recording that could not be recovered; they are deleted with it.
    private var pendingDeletionIncludesRecordingPieces: Bool {
        appState.pipelineHistory.contains {
            pendingDeletionIDs.contains($0.id) && $0.hasUnrecoveredRecordingPieces
        }
    }

    /// Whether a note waiting to be deleted is for a recording that could not
    /// be recovered. Such notes are deleted right away, without Cancel.
    private var pendingDeletionIncludesUnrecoveredRecording: Bool {
        appState.pipelineHistory.contains {
            pendingDeletionIDs.contains($0.id) && $0.unrecoveredRecordingContext != nil
        }
    }

    private func showDeletionNotice(_ message: String) {
        let id = UUID()
        deletionNoticeID = id
        deletionNotice = message
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard deletionNoticeID == id else { return }
            deletionNotice = nil
        }
    }

    private func noteDeletionToastMessage(count: Int) -> String {
        count == 1
            ? localizedCatalogString("Note deleted")
            : localizedCatalogFormat("%lld notes deleted", count)
    }

    private func scheduleRecoveryScrollRestore(for itemID: UUID) {
        recoveryScrollRestoreRequest = RecoveryScrollRestoreRequest(itemID: itemID)
    }

    private func restoreRecoveryScrollPosition(
        request: RecoveryScrollRestoreRequest?,
        proxy: ScrollViewProxy
    ) {
        guard let request,
              filteredHistory.contains(where: { $0.id == request.itemID }) else {
            return
        }
        DispatchQueue.main.async {
            proxy.scrollTo(request.itemID, anchor: .center)
        }
    }

    private var transcriptionSelectionLabel: String {
        appState.transcriptionEnabled
            ? appState.noteBrowserTranscriptionChoiceLabel
            : localizedCatalogString("Off")
    }

    private var transcriptionSelectionDetailLabel: String {
        appState.transcriptionEnabled
            ? appState.noteBrowserTranscriptionChoiceDetailLabel
            : localizedCatalogString("Off")
    }

    private func transcriptionChoiceDisplays(in section: String) -> [TranscriptionChoiceDisplay] {
        appState.noteBrowserTranscriptionChoiceDisplays.filter { $0.section == section }
    }

    var body: some View {
        Group {
            if appState.isHistoryUnavailable {
                historyUnavailableView
            } else {
                HStack(spacing: 0) {
            sidebarPanel
            detailPanel
                // The note runs under the title bar too; its date line lines
                // up with the traffic lights, and the space around it drags.
                .ignoresSafeArea(.container, edges: .top)
                .overlay(alignment: .top) {
                    WindowDragArea()
                        .frame(height: 16)
                }
                .overlay(alignment: .bottom) {
                    if let pending = appState.pendingNoteDeletion {
                        NoteBrowserToastView(
                            message: noteDeletionToastMessage(count: pending.noteCount),
                            actionTitle: "Cancel",
                            action: { appState.cancelPendingNoteDeletion() }
                        )
                        .padding(.horizontal, 24)
                        .padding(.bottom, 72)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if let deletionNotice {
                        NoteBrowserToastView(message: deletionNotice)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 72)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.16), value: appState.pendingNoteDeletion?.id)
                .onChange(of: appState.pendingNoteDeletion?.id) { _ in
                    guard let pending = appState.pendingNoteDeletion else { return }
                    NSAccessibility.post(
                        element: NSApplication.shared,
                        notification: .announcementRequested,
                        userInfo: [
                            .announcement: noteDeletionToastMessage(count: pending.noteCount),
                            .priority: NSAccessibilityPriorityLevel.medium.rawValue
                        ]
                    )
                }
        }
        .frame(minWidth: 800, minHeight: 520)
        .onAppear {
            let ids = Set(appState.pipelineHistory.map(\.id))
            knownHistoryIDs = ids
            if selectedItemID == nil {
                selection.focus(appState.pipelineHistory.first?.id)
            }
        }
        .sheet(item: $pendingAudioImport) { importRequest in
            TranscriptionChoiceSheet(
                title: "Import Audio File",
                subtitle: importRequest.fileURL.lastPathComponent,
                showsSettingNote: false,
                options: importRequest.options,
                fallbackChoice: .apiStandard(modelID: importRequest.apiStandardModelID)
            ) { choice in
                pendingAudioImport = nil
                appState.importAudioFile(importRequest.fileURL, choice: choice)
            } onOpenProviderSettings: {
                pendingAudioImport = nil
                appState.openProviderSettings()
            } onCancel: {
                pendingAudioImport = nil
            }
        }
        .confirmationDialog(
            deletionConfirmationTitle,
            isPresented: $showDeletionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { performPendingDeletion() }
            Button("Cancel", role: .cancel) { pendingDeletionIDs = [] }
        } message: {
            if pendingDeletionIDs.count == 1, pendingDeletionIncludesRecordingPieces {
                Text("The recording pieces Quill couldn't recover will also be deleted. This can't be undone.")
            } else if pendingDeletionIDs.count != 1, pendingDeletionIncludesUnrecoveredRecording {
                Text("Audio and summaries are deleted too. Notes for recordings Quill couldn't recover are deleted right away, with any recording pieces, and can't be restored.")
            } else if pendingDeletionIDs.count != 1 {
                Text("Audio and summaries are deleted too. You can cancel for a few seconds after deleting.")
            } else if appState.canDeleteHistoryEntryCancellably(id: pendingDeletionIDs[0]) {
                Text("You can cancel for a few seconds after deleting.")
            } else {
                Text("Deleted notes cannot be recovered.")
            }
        }
        .background(NoteBrowserKeyCommandMonitor(handle: handleKeyCommand))
        // Notes that start a summary or a retry while checked leave the selection.
        .onChange(of: appState.meetingSummaryGeneratingNoteIDs) { _ in
            selection.retainSelectable(isBulkSelectable)
        }
        .onChange(of: appState.retryingItemIDs) { _ in
            selection.retainSelectable(isBulkSelectable)
        }
        .onChange(of: appState.recoveringRecordingIDs) { _ in
            selection.retainSelectable(isBulkSelectable)
        }
        .onChange(of: searchText) { _ in
            if selection.showsSelectionUI {
                selection.retainVisible(filteredHistory.map(\.id))
            }
        }
        .onReceive(appState.$pipelineHistory) { newHistory in
            let ids = newHistory.map(\.id)
            if selection.showsSelectionUI {
                // Keep a multi-selection; new notes don't take over while selecting.
                // This fires before the change lands, so filter the new value.
                selection.retainVisible(newHistory.filter(matchesSearch).map(\.id))
                selection.retainSelectable { isBulkSelectable($0, in: newHistory) }
                knownHistoryIDs = Set(ids)
                return
            }
            let isRecoveryImport = appState.isHistoryRecoveryOperationInProgress
            // Keep the note the user was viewing visible after a recovery import.
            guard let current = selectedItemID, ids.contains(current) else {
                selection.focus(ids.first)
                if isRecoveryImport, let fallback = ids.first {
                    scheduleRecoveryScrollRestore(for: fallback)
                }
                knownHistoryIDs = Set(ids)
                return
            }
            if isRecoveryImport {
                scheduleRecoveryScrollRestore(for: current)
            } else if let newest = ids.first, newest != current, !knownHistoryIDs.contains(newest) {
                // Auto-select only genuinely new items; ignore existing item edits.
                selection.focus(newest)
            }
            knownHistoryIDs = Set(ids)
                }
            }
        }
    }

    private var historyUnavailableView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.orange)
            Text("Recording history couldn’t be opened")
                .font(.system(size: 20, weight: .semibold))
            Text("Your notes and audio files were not deleted. Restart Quill to try again, or open the data folder for support and recovery.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            HistoryUnavailableRecoveryActions()
                .controlSize(.large)
            Spacer()
        }
        .padding(32)
        .frame(minWidth: 800, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Sidebar

    /// Fixed-width source control: icons for what the next recording
    /// captures (microphone, System Audio, or both). Clicking opens an AppKit
    /// NSMenu with the audio source and microphone choices, mirroring the menu
    /// bar Microphone submenu. While recording, selecting an input switches the
    /// active recording's input instead of only setting the next recording's.
    private var inputPickerMenu: some View {
        HStack(spacing: 2) {
            HStack(spacing: 2) {
                if appState.selectedAudioSource.requiresMicrophonePermission {
                    Image(systemName: "mic")
                }
                if appState.selectedAudioSource == .microphoneAndSystemAudio {
                    Text(verbatim: "+")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                if appState.selectedAudioSource != .microphone {
                    // "This Mac": sound playing on the computer.
                    Image(systemName: "macbook")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .frame(maxWidth: .infinity)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 7)
        .frame(width: 66, height: 26)
        .background(
            Color.primary.opacity(QuillContrast.fillOpacity(0.06, increased: increasesContrast)),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .contentShape(Rectangle())
        // The overlay below is the control VoiceOver reads.
        .accessibilityHidden(true)
        .overlay {
            InputMenuCatcher(configuration: AudioInputMenuConfiguration(
                sources: AudioRecordingSource.allCases.map {
                    AudioInputMenuOption(
                        id: $0.id,
                        name: $0.titleKey,
                        isStaticQuillName: true
                    )
                },
                disabledSourceIDs: Set(
                    AudioRecordingSource.allCases
                        .filter { !appState.isAudioSourceSelectable($0) }
                        .map(\.id)
                ),
                microphones: [
                    AudioInputMenuOption(
                        id: AudioInputDevice.defaultMicrophoneID,
                        name: appState.systemDefaultMicrophoneDisplayName(),
                        isStaticQuillName: false
                    )
                ] + appState.availableMicrophones.map {
                    AudioInputMenuOption(
                        id: $0.uid,
                        name: $0.name,
                        isStaticQuillName: false
                    )
                },
                selectedSourceID: appState.selectedAudioSourceID,
                selectedMicrophoneID: appState.selectedMicrophoneDeviceID,
                microphoneSelectionEnabled: !appState.isRecording,
                accessibilityLabel: localizedCatalogString("Audio Source"),
                accessibilityValue: audioInputSummary,
                onSelectSource: appState.selectAudioSource(withID:),
                onSelectMicrophone: appState.selectMicrophoneDevice
            ))
        }
        .help(Text(verbatim: audioInputSummary))
        .overrideCursor(.arrow)
    }

    /// The microphone name and source, such as "MacBook Pro Microphone +
    /// System Audio", for the source control's tooltip.
    private var audioInputSummary: String {
        let microphoneName: String
        if appState.selectedMicrophoneDeviceID == AudioInputDevice.defaultMicrophoneID {
            microphoneName = appState.systemDefaultMicrophoneDisplayName()
        } else {
            microphoneName = appState.availableMicrophones
                .first(where: { $0.uid == appState.selectedMicrophoneDeviceID })?
                .name ?? appState.systemDefaultMicrophoneDisplayName()
        }
        switch appState.selectedAudioSource {
        case .microphone:
            return microphoneName
        case .systemAudio:
            return localizedCatalogString("System Audio")
        case .microphoneAndSystemAudio:
            return localizedCatalogFormat("%@ + System Audio", microphoneName)
        }
    }

    /// The transcription model control. It fills the space beside the source
    /// control, so its size never changes with the selected model. Like the
    /// source control, the whole pill opens the menu, not only its label.
    private var transcriptionModelMenu: some View {
        let isEnabled = !appState.isRecording && !appState.isTranscribing
        return HStack(spacing: 6) {
            Image(systemName: "waveform")
            Text(transcriptionSelectionLabel)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .frame(maxWidth: .infinity)
        .background(
            Color.primary.opacity(QuillContrast.fillOpacity(0.06, increased: increasesContrast)),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Rectangle())
        // The overlay below is the control VoiceOver reads.
        .accessibilityHidden(true)
        .overlay {
            TranscriptionMenuCatcher(configuration: TranscriptionMenuConfiguration(
                off: TranscriptionMenuOption(
                    id: Self.transcriptionOffMenuID,
                    title: localizedCatalogString("Off"),
                    isSelected: !appState.transcriptionEnabled,
                    isEnabled: true
                ),
                sections: ["Cloud", "On This Mac"].map { section in
                    TranscriptionMenuSection(
                        title: localizedCatalogString(section),
                        options: transcriptionChoiceDisplays(in: section)
                            .map(transcriptionMenuOption)
                    )
                },
                isEnabled: isEnabled,
                accessibilityLabel: localizedCatalogString("Transcription Method"),
                accessibilityValue: transcriptionSelectionDetailLabel,
                onSelect: selectTranscriptionMenuOption
            ))
        }
        .help(Text(verbatim: transcriptionSelectionDetailLabel))
        .overrideCursor(.arrow)
    }

    private static let transcriptionOffMenuID = "transcription-off"

    private func transcriptionMenuOption(
        _ display: TranscriptionChoiceDisplay
    ) -> TranscriptionMenuOption {
        TranscriptionMenuOption(
            id: display.choice.id,
            title: display.localizedCompactLabel(),
            isSelected: appState.transcriptionEnabled
                && appState.currentNoteBrowserTranscriptionChoice == display.choice,
            isEnabled: appState.isNoteBrowserTranscriptionChoiceReady(display.choice)
        )
    }

    private func selectTranscriptionMenuOption(_ id: String) {
        if id == Self.transcriptionOffMenuID {
            appState.setNoteBrowserTranscriptionSelection(nil)
        } else if let display = appState.noteBrowserTranscriptionChoiceDisplays
            .first(where: { $0.choice.id == id }) {
            appState.setNoteBrowserTranscriptionSelection(display.choice)
        }
    }

    /// "3 selected", shown beside Select All in selection mode.
    private var selectedCountText: String {
        localizedCatalogFormat("%lld selected", selection.selectedIDs.count)
    }

    private func headerIconButton(
        _ systemImage: String,
        help: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 24)
                .modifier(DimmedWhenDisabled())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
        .overrideCursor(.arrow)
    }

    /// The first row shares the title bar with the traffic lights: search,
    /// import, and Select on the right. Empty space in it drags the window.
    private var sidebarTitleRow: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 6)
            headerIconButton("magnifyingglass", help: "Search Notes") {
                toggleSearch()
            }
            .foregroundStyle(searchText.isEmpty ? Color.secondary : Color.accentColor)
            .background {
                // ⌘F opens or focuses search and keeps the query; only the
                // magnifier itself closes an open search.
                Button("") { openSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            // Search and import stay in place but pause while selecting.
            .disabled(selection.showsSelectionUI)
            headerIconButton("waveform.badge.plus", help: "Import Audio File") {
                showAudioImportPicker()
            }
            .foregroundStyle(.secondary)
            .disabled(appState.isRecording || selection.showsSelectionUI)
            // One button in one place: Select, then Done in selection mode.
            if selection.showsSelectionUI {
                Button("Done") { selection.endSelectionMode() }
                    .buttonStyle(SidebarCapsuleButtonStyle())
                    .overrideCursor(.arrow)
            } else {
                Button("Select") { beginSelection() }
                    .buttonStyle(SidebarCapsuleButtonStyle())
                    .help("Select multiple notes")
                    .disabled(appState.pipelineHistory.isEmpty)
                    .overrideCursor(.arrow)
            }
        }
        .padding(.leading, 90)
        .padding(.trailing, 10)
        // Matches the unified toolbar's title bar height, where the traffic
        // lights are vertically centered.
        .frame(height: 52)
        .background(WindowDragArea())
    }

    /// Everything above the note list. It sits in the list's top safe area,
    /// so notes scroll beneath it once the list is scrolled.
    private var sidebarHeader: some View {
        VStack(spacing: 0) {
            sidebarTitleRow
            // Selection mode and search swap the source and model row for the
            // selected count and Select All, or the search field, so the
            // header keeps its height.
            HStack(spacing: 6) {
                if isSearchOpen && !selection.showsSelectionUI {
                    searchField
                } else if selection.showsSelectionUI {
                    Text(verbatim: selectedCountText)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .padding(.leading, 2)
                    Spacer()
                    Button("Select All") { _ = selectAllVisibleNotes() }
                        .buttonStyle(SidebarCapsuleButtonStyle())
                        .overrideCursor(.arrow)
                } else {
                    inputPickerMenu
                    transcriptionModelMenu
                }
            }
            .frame(height: 26)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        // Always translucent, so notes never show through unblurred even when
        // a fast scroll outruns the scroll-offset update. Only the hairline
        // follows the scroll position. Opaque under Reduce Transparency.
        .background(QuillTransparency.background(.ultraThinMaterial, reduceTransparency: reduceTransparency))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(QuillContrast.fillOpacity(0.1, increased: increasesContrast)))
                .frame(height: 0.5)
                .opacity(isNoteListScrolled ? 1 : 0)
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { sidebarHeaderHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { sidebarHeaderHeight = $0 }
            }
        )
    }

    /// True once the first note has scrolled under the header.
    private var isNoteListScrolled: Bool {
        !filteredHistory.isEmpty && noteListTopOffset < sidebarHeaderHeight + 5
    }

    private func toggleSearch() {
        if isSearchOpen && isSearchFieldFocused {
            closeSearch()
        } else {
            openSearch()
        }
    }

    private func openSearch() {
        guard !selection.showsSelectionUI else { return }
        isSearchOpen = true
        DispatchQueue.main.async { isSearchFieldFocused = true }
    }

    private func closeSearch() {
        searchText = ""
        isSearchFieldFocused = false
        isSearchOpen = false
    }

    private var floatingRecordButton: some View {
        Button {
            appState.toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .fill(appState.isRecording ? Color.orange : Color.red)
                if appState.isRecording {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.white)
                        .frame(width: 14, height: 14)
                }
            }
            .frame(width: 44, height: 44)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(appState.isRecording ? "Stop recording" : "Start recording")
        .accessibilityLabel(appState.isRecording ? "Stop recording" : "Start recording")
        .padding(.bottom, 16)
        .overrideCursor(.arrow)
    }

    private var sidebarPanel: some View {
        ZStack(alignment: .bottom) {
            // The header overlays the list, and the list reserves the header's
            // height at its top, so notes scroll beneath the header.
            noteList
                .overlay(alignment: .top) { sidebarHeader }
            if !selection.showsSelectionUI {
                floatingRecordButton
            }
        }
        .frame(width: 280)
        .background(QuillTransparency.background(.ultraThinMaterial, reduceTransparency: reduceTransparency))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(QuillContrast.fillOpacity(0.07, increased: increasesContrast)))
                .frame(width: 0.5)
        }
        // The sidebar runs under the transparent title bar, so its first row
        // shares the title bar with the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
    }

    @ViewBuilder
    private var noteList: some View {
        Group {
            if appState.pipelineHistory.isEmpty {
                emptyListState
                    .padding(.top, sidebarHeaderHeight)
            } else if filteredHistory.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                    Text("No Search Results")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.top, sidebarHeaderHeight)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 2) {
                            ForEach(filteredHistory) { item in
                                NoteListRow(
                                    displayData: NoteListRowDisplayData(
                                        item: item,
                                        retryingIDs: appState.retryingItemIDs,
                                        cloudProgress: appState.cloudTranscriptionProgressByHistoryID[item.id]
                                    ),
                                    isSelected: selection.showsSelectionUI
                                        ? selection.selectedIDs.contains(item.id)
                                        : selectedItemID == item.id,
                                    isKeyboardHighlighted: isNoteListFocused
                                        && !selection.showsSelectionUI
                                        && selectedItemID == item.id,
                                    selectionMark: selectionMark(for: item.id)
                                )
                                .id(item.id)
                                .onTapGesture { handleRowClick(item.id) }
                                .accessibilityAction { handleRowClick(item.id) }
                                .accessibilityAction(named: Text("Select")) {
                                    beginSelection(including: item.id)
                                }
                                .accessibilityAction(named: Text("Delete…")) {
                                    requestDeletion(of: item.id)
                                }
                                .contextMenu {
                                    Button("Select") { beginSelection(including: item.id) }
                                    Divider()
                                    Button("Delete…", role: .destructive) {
                                        requestDeletion(of: item.id)
                                    }
                                    // Wait for Recover Again to finish.
                                    .disabled(appState.recoveringRecordingIDs.contains(item.id))
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        // Tracks where the list's top sits relative to the
                        // header. Measured on the whole stack, which stays
                        // alive however far the list scrolls.
                        .background(
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: NoteListTopOffsetKey.self,
                                    value: geometry.frame(in: .named("noteList")).minY
                                )
                            }
                        )
                        .padding(.top, sidebarHeaderHeight + 6)
                        // Room for the floating Record button.
                        .padding(.bottom, selection.showsSelectionUI ? 6 : 72)
                    }
                    .coordinateSpace(name: "noteList")
                    // Tab reaches the list; ↑/↓ then move the open note.
                    .focusable()
                    .focused($isNoteListFocused)
                    .modifier(NoFocusRing())
                    .onMoveCommand { direction in
                        moveListFocus(direction, proxy: proxy)
                    }
                    .accessibilityLabel(Text("Notes"))
                    .onPreferenceChange(NoteListTopOffsetKey.self) { noteListTopOffset = $0 }
                    .onAppear {
                        restoreRecoveryScrollPosition(
                            request: recoveryScrollRestoreRequest,
                            proxy: proxy
                        )
                    }
                    .onChange(of: recoveryScrollRestoreRequest?.id) { _ in
                        restoreRecoveryScrollPosition(
                            request: recoveryScrollRestoreRequest,
                            proxy: proxy
                        )
                    }
                }
            }
        }
    }

    /// Opened by the magnifier or ⌘F. With an empty query it closes when focus
    /// leaves; Esc or the clear button clears the query and closes it.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("Search Notes", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isSearchFieldFocused)
                .onExitCommand { closeSearch() }
            if !searchText.isEmpty {
                Button { closeSearch() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .onChange(of: isSearchFieldFocused) { isFocused in
            if !isFocused && searchText.isEmpty {
                isSearchOpen = false
            }
        }
    }

    private func selectionMark(for id: UUID) -> NoteListRow.SelectionMark? {
        guard selection.showsSelectionUI else { return nil }
        if selection.selectedIDs.contains(id) { return .selected }
        return isBulkSelectable(id) ? .unselected : .unavailable
    }

    private func showAudioImportPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Array(AudioImportOptions.broadlySupportedExtensions)
            .sorted()
            .compactMap { UTType(filenameExtension: $0) }
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose an audio file. Supported formats: FLAC, MP3, MP4, MPEG, MPGA, M4A, OGG, WAV, WEBM")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            pendingAudioImport = PendingAudioImport(
                fileURL: url,
                currentChoice: appState.currentNoteBrowserTranscriptionChoice,
                apiStandardModelID: appState.transcriptionModel,
                hasAPIKey: appState.hasTranscriptionAPIKey,
                hasNativeLocalWhisperModel: appState.hasNativeLocalWhisperModel,
                legacyLocalWhisperModels: appState.installedLegacyLocalWhisperModels,
                localAIModels: appState.audioImportLocalAIModels
            )
        }
    }

    /// One quiet line; the detail pane carries the full empty state.
    private var emptyListState: some View {
        VStack {
            Text("No recordings yet")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.top, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPanel: some View {
        if selection.showsSelectionUI {
            NoteMultiSelectionPanel(count: selection.selectedIDs.count) {
                requestDeletion()
            }
        } else if let id = selectedItemID,
           let item = appState.pipelineHistory.first(where: { $0.id == id }) {
            NoteDetailView(
                item: item,
                isSearchActive: !searchText.isEmpty,
                prefersSummaryTab: searchMatcher.matchesOnlyInSummary(item, query: searchText)
            ) {
                deleteConfirmedNote(id)
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
            Text("Select a Note")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Select a recording from the list to view its transcript")
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
            Text("No Recordings")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Start your first recording with the Record button or your shortcut.\nYour transcript will appear here.")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Horizontally Scrollable Title Field

private struct HorizontallyScrollableTitleField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> TitleHorizontalScrollView {
        let scrollView = TitleHorizontalScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // The note runs under the transparent title bar; without this the
        // scroll view insets its text by the title bar height and clips it.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .automatic

        let textView = TitleSingleLineTextView()
        textView.delegate = context.coordinator
        textView.placeholder = placeholder
        textView.setAccessibilityLabel(localizedCatalogString("Note Title"))
        textView.setAccessibilityPlaceholderValue(placeholder)
        textView.string = text
        textView.font = .systemFont(ofSize: 28, weight: .bold)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.maximumNumberOfLines = 1
        textView.textContainer?.lineBreakMode = .byClipping
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 38)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = false
        textView.minSize = NSSize(width: 0, height: 38)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 38)
        textView.updateDocumentWidth(minimumWidth: 0)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: TitleHorizontalScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? TitleSingleLineTextView else { return }
        textView.placeholder = placeholder
        textView.font = .systemFont(ofSize: 28, weight: .bold)
        textView.textColor = .labelColor
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            let stringLength = (textView.string as NSString).length
            let clampedRanges = selectedRanges.map { value -> NSValue in
                let range = value.rangeValue
                let location = min(range.location, stringLength)
                let length = min(range.length, stringLength - location)
                return NSValue(range: NSRange(location: location, length: length))
            }
            textView.selectedRanges = clampedRanges
        }
        textView.updateDocumentWidth(minimumWidth: scrollView.contentView.bounds.width)
        textView.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HorizontallyScrollableTitleField

        init(_ parent: HorizontallyScrollableTitleField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? TitleSingleLineTextView else { return }
            textView.updateDocumentWidth(minimumWidth: textView.enclosingScrollView?.contentView.bounds.width ?? 0)
            parent.text = textView.string
        }
    }
}

private final class TitleHorizontalScrollView: NSScrollView {
    private var maximumScrollX: CGFloat {
        max(0, (documentView?.bounds.width ?? 0) - contentView.bounds.width)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        (documentView as? TitleSingleLineTextView)?.updateDocumentWidth(minimumWidth: contentView.bounds.width)
    }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > 0.01 {
            super.scrollWheel(with: event)
            return
        }

        guard abs(event.scrollingDeltaY) > 0.1 else {
            super.scrollWheel(with: event)
            return
        }

        let delta = -normalizedScrollDelta(event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
        guard canScrollHorizontally(by: delta) else {
            super.scrollWheel(with: event)
            return
        }

        scrollHorizontally(by: delta)
    }

    private func canScrollHorizontally(by delta: CGFloat) -> Bool {
        let maximumX = maximumScrollX
        guard maximumX > 0 else { return false }
        let currentX = contentView.bounds.origin.x
        return delta > 0 ? currentX < maximumX : currentX > 0
    }

    func clampHorizontalScrollOffset() {
        let maximumX = maximumScrollX
        let nextX = min(max(contentView.bounds.origin.x, 0), maximumX)
        contentView.scroll(to: NSPoint(x: nextX, y: 0))
        reflectScrolledClipView(contentView)
    }

    private func scrollHorizontally(by delta: CGFloat) {
        let maximumX = maximumScrollX
        let nextX = min(max(contentView.bounds.origin.x + delta, 0), maximumX)
        contentView.scroll(to: NSPoint(x: nextX, y: 0))
        reflectScrolledClipView(contentView)
    }

    private func normalizedScrollDelta(_ delta: CGFloat, precise: Bool) -> CGFloat {
        precise ? delta : delta * 38
    }
}

/// A text view that keeps its I-beam cursor except where a view on top of it
/// (the floating note toolbar) asks for its own cursor.
private final class CursorDeferringTextView: NSTextView {
    override func mouseMoved(with event: NSEvent) {
        if let cursor = CursorNSView.cursor(atWindowPoint: event.locationInWindow, in: window) {
            cursor.set()
            return
        }
        super.mouseMoved(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        if let cursor = CursorNSView.cursor(atWindowPoint: event.locationInWindow, in: window) {
            cursor.set()
            return
        }
        super.cursorUpdate(with: event)
    }
}

private final class TitleSingleLineTextView: NSTextView {
    var placeholder: String = ""

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 38)
    }

    override func insertNewline(_ sender: Any?) {
        window?.makeFirstResponder(nil)
    }

    // A one-line field: Tab and Shift-Tab move focus like a text field
    // instead of typing a tab into the title.
    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(sender)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if let string = insertString as? String {
            super.insertText(Self.singleLine(string), replacementRange: replacementRange)
        } else if let attributedString = insertString as? NSAttributedString {
            super.insertText(NSAttributedString(string: Self.singleLine(attributedString.string)), replacementRange: replacementRange)
        } else {
            super.insertText(insertString, replacementRange: replacementRange)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 28, weight: .bold),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        placeholder.draw(at: .zero, withAttributes: attributes)
    }

    func updateDocumentWidth(minimumWidth: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 28, weight: .bold)
        ]
        let measuredText = string.isEmpty ? placeholder : string
        let measuredWidth = ceil((measuredText as NSString).size(withAttributes: attributes).width) + 8
        let width = max(minimumWidth, measuredWidth)
        setFrameSize(NSSize(width: width, height: 38))
        textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 38)
        (enclosingScrollView as? TitleHorizontalScrollView)?.clampHorizontalScrollOffset()
    }

    private static func singleLine(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

// MARK: - Note List Row

private struct NoteListRow: View {
    enum SelectionMark {
        case selected, unselected
        /// Still recording or processing, so it can't join a multi-selection.
        case unavailable
    }

    let displayData: NoteListRowDisplayData
    let isSelected: Bool
    /// The open row while the list has keyboard focus.
    var isKeyboardHighlighted: Bool = false
    var selectionMark: SelectionMark? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var isHovered = false

    private var increasesContrast: Bool { colorSchemeContrast == .increased }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let selectionMark {
                NoteSelectionCheckbox(mark: selectionMark)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            // Content
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(displayData.rowDate)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(selectedMetaColor)
                        .textCase(.uppercase)
                        .kerning(0.4)
                    if displayData.status == .audioOnly {
                        Text(localizedCatalogString("Audio only"))
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(selectedMetaColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Color.primary.opacity(QuillContrast.fillOpacity(0.08, increased: increasesContrast)),
                                in: Capsule()
                            )
                    }
                    if displayData.hasMeetingSummary {
                        Text(localizedCatalogString("Summary"))
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(selectedMetaColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Color.primary.opacity(QuillContrast.fillOpacity(0.08, increased: increasesContrast)),
                                in: Capsule()
                            )
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
                    isKeyboardHighlighted
                        ? Color.accentColor.opacity(0.85)
                        : isSelected
                        ? (colorScheme == .dark ? Color.white.opacity(0.07) : Color.primary.opacity(0.08))
                        : (isHovered
                            ? (colorScheme == .dark ? Color.white.opacity(0.03) : Color.primary.opacity(0.05))
                            : Color.clear)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isKeyboardHighlighted
                                ? Color.accentColor
                                : isSelected
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
        // One element for VoiceOver, with the state in words.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: NoteListRowAccessibility.label(
            title: displayData.displayTitle,
            date: displayData.rowDate,
            status: displayData.status,
            hasSummary: displayData.hasMeetingSummary,
            selection: selectionMark.map { mark in
                switch mark {
                case .selected: return .checked
                case .unselected: return .unchecked
                case .unavailable: return .unavailable
                }
            },
            isUnrecoveredRecording: displayData.isUnrecoveredRecording
        )))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Row date and badges; stronger under Increase Contrast.
    private var selectedMetaColor: Color {
        if isKeyboardHighlighted { return Color.white.opacity(metaOpacity(0.85)) }
        return isSelected
            ? (colorScheme == .dark ? Color.white.opacity(metaOpacity(0.72)) : Color.primary.opacity(metaOpacity(0.55)))
            : Color.secondary.opacity(metaOpacity(0.7))
    }

    private func metaOpacity(_ normal: Double) -> Double {
        QuillContrast.opacity(normal, increased: increasesContrast)
    }

    private var selectedTitleColor: Color {
        if isKeyboardHighlighted { return .white }
        return isSelected
            ? (colorScheme == .dark ? .white : .primary)
            : .primary
    }

    private var selectedPreviewColor: Color {
        if isKeyboardHighlighted { return Color.white.opacity(0.85) }
        return isSelected
            ? (colorScheme == .dark ? Color.white.opacity(0.78) : Color.primary.opacity(0.72))
            : .secondary
    }

    private var toolbarStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.primary.opacity(0.10)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        statusIndicatorContent
            // On the accent-colored row, a thin white ring keeps a dot of the
            // same color as the accent visible.
            .overlay {
                if isKeyboardHighlighted,
                   [.done, .audioOnly, .fail].contains(displayData.status),
                   !(differentiateWithoutColor && displayData.status == .fail) {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
                        .frame(width: 8, height: 8)
                }
            }
    }

    @ViewBuilder
    private var statusIndicatorContent: some View {
        switch displayData.status {
        case .done:
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
        case .recording:
            // A red dot and the running time; the stage text is in the detail.
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                if let startedAt = displayData.recordingStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(verbatim: RecordingElapsedFormatter.string(from: startedAt, to: context.date))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.red.opacity(metaOpacity(0.8)))
                    }
                }
            }
        case .transcribing:
            YellowSpinner(color: .orange)
        case .audioOnly:
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
        case .recovered:
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.orange.opacity(metaOpacity(0.7)))
        case .fail:
            if differentiateWithoutColor {
                // Differentiate Without Color: a failed note gets a shape,
                // not only a red dot that matches a finished note's size.
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isKeyboardHighlighted ? Color.white : Color.red)
            } else {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
            }
        }
    }

}

/// Neutral capsule matching the sidebar's transcription picker.
private struct SidebarCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06),
                in: Capsule()
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

private struct NoteSelectionCheckbox: View {
    let mark: NoteListRow.SelectionMark

    var body: some View {
        ZStack {
            switch mark {
            case .selected:
                Circle().fill(Color.accentColor)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            case .unselected:
                Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5)
            case .unavailable:
                Circle()
                    .strokeBorder(
                        Color.secondary.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1.5, dash: [2, 2])
                    )
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
        .modifier(UnavailableSelectionHelp(isUnavailable: mark == .unavailable))
    }
}

private struct UnavailableSelectionHelp: ViewModifier {
    let isUnavailable: Bool

    func body(content: Content) -> some View {
        if isUnavailable {
            content.help("Notes that are recording or processing can't be selected.")
        } else {
            content
        }
    }
}

/// Detail pane while several notes are selected.
private struct NoteMultiSelectionPanel: View {
    let count: Int
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 10) {
                ZStack {
                    stackedNote.rotationEffect(.degrees(-9)).offset(x: -8)
                    stackedNote.rotationEffect(.degrees(7)).offset(x: 8)
                    stackedNote
                }
                .frame(width: 74, height: 88)
                .padding(.bottom, 6)
                .accessibilityHidden(true)
                countTitle
                    .font(.system(size: 17, weight: .semibold))
                Text("Click notes in the list to add or remove them.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
            .padding(.bottom, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button(action: onDelete) {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .medium))
                    deleteLabel
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Color.red.opacity(count == 0 ? 0.4 : 0.9))
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(Capsule().fill(
                    QuillTransparency.background(.ultraThinMaterial, reduceTransparency: reduceTransparency)
                ))
                .overlay(Capsule().strokeBorder(toolbarStrokeColor, lineWidth: 0.6))
                .shadow(color: .black.opacity(0.085), radius: 14, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(count == 0)
            .padding(.bottom, 20)
            .overrideCursor(.arrow)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var stackedNote: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
            .frame(width: 74, height: 88)
    }

    private var countTitle: Text {
        switch count {
        case 0: return Text("No notes selected")
        case 1: return Text("1 note selected")
        default: return Text(localizedCatalogFormat("%lld notes selected", count))
        }
    }

    private var deleteLabel: Text {
        count == 1 ? Text("Delete Note") : Text(localizedCatalogFormat("Delete %lld Notes", count))
    }

    private var toolbarStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.primary.opacity(0.10)
    }
}

/// Handles Note Browser list shortcuts (⌘A, esc, delete) for its own window only,
/// and never while a text field or text view is editing.
private struct NoteBrowserKeyCommandMonitor: NSViewRepresentable {
    let handle: (NoteBrowserKeyCommand) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.handle = handle
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.handle = handle
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.removeMonitor()
    }

    final class MonitorView: NSView {
        var handle: ((NoteBrowserKeyCommand) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self,
                          let window = self.window,
                          event.window === window,
                          !(window.firstResponder is NSText),
                          let command = NoteBrowserKeyCommand(
                            keyCode: event.keyCode,
                            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                            modifierFlags: event.modifierFlags
                          ),
                          self.handle?(command) == true else {
                        return event
                    }
                    return nil
                }
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}

// MARK: - Note Detail View

enum NoteContentMode: Hashable {
    case transcript
    case summary
}

private struct NoteDetailView: View {
    let item: PipelineHistoryItem
    let isSearchActive: Bool
    /// True while the Note Browser search matches this note only in its
    /// saved summary, so the note opens on the Summary tab.
    let prefersSummaryTab: Bool
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @EnvironmentObject var appState: AppState
    @State private var loadedContent: String?
    @State private var isCopied = false
    @State private var showFileExportSheet = false
    @State private var retryChoiceRequest: RetryChoiceRequest?
    @State private var toastMessage: String?
    @State private var toastID: UUID?
    @State private var titleDraft = ""
    @State private var isRetrying = false
    @State private var titleDebounceTimer: Timer?
    @State private var showDeleteConfirmation = false
    @State private var showDeleteChoice = false
    @State private var showUnrecoveredDeleteConfirmation = false
    @State private var selectedContentMode: NoteContentMode = .transcript
    /// Set once the person picks a tab for this note during the current
    /// search, so search-driven tab changes stop overriding their choice.
    @State private var userChoseContentModeDuringSearch = false
    @State private var summaryIssue: QuillUserIssueRecord?
    @State private var isSummaryIssueBannerDismissed = false
    @State private var dismissedSummaryAttemptAt: Date?
    @State private var dismissedSummaryNoticeKeys: Set<String> = []
    @State private var areSummaryNoticesExpanded = false
    @State private var highlightedSourceQuote: String?

    private var isError: Bool {
        if case .failed = item.machineStatus { return true }
        return false
    }
    private var isAudioOnly: Bool {
        item.machineStatus == .audioOnly
    }
    private var transcriptionActionHelp: LocalizedStringKey {
        isAudioOnly ? "Transcribe audio" : "Retry transcription"
    }
    private var isCloudTranscribing: Bool {
        item.machineStatus == .cloudTranscribing
    }
    private var cloudProgress: CloudTranscriptionDisplayProgress? {
        appState.cloudTranscriptionProgressByHistoryID[item.id]
    }
    private var cloudProgressText: String {
        guard let cloudProgress else {
            return localizedCatalogString("Resuming cloud transcription…")
        }
        guard cloudProgress.activeAttempt != nil else {
            return localizedCatalogString("Resuming cloud transcription…")
        }
        return localizedCatalogFormat(
            "Transcribing %d of %d…",
            min(
                cloudProgress.completedChunkCount + 1,
                cloudProgress.totalChunkCount
            ),
            cloudProgress.totalChunkCount
        )
    }
    private var isRecoveredRecording: Bool { item.isRecoveredRecording }
    private var unrecoveredContext: UnrecoveredRecordingContext? {
        item.unrecoveredRecordingContext
    }
    /// Pieces of this recording remain on disk; deleting the note removes them.
    private var keepsRecordingPieces: Bool {
        item.hasUnrecoveredRecordingPieces
    }
    private var isRecoveringRecording: Bool {
        appState.recoveringRecordingIDs.contains(item.id)
    }
    private var unrecoveredPresentation: QuillUserIssuePresentation? {
        guard let unrecoveredContext else { return nil }
        let startTime = (item.recordingStartedAt ?? item.timestamp)
            .formatted(date: .omitted, time: .shortened)
        let title = unrecoveredContext.localizedTitle()
        return QuillUserIssuePresentation(
            title: title,
            body: unrecoveredContext.localizedBody(startTime: startTime),
            suggestion: "",
            compactMessage: title,
            detailsRows: [],
            recoveryAction: .none,
            severity: .error
        )
    }
    private var recoveredRecordingContext: RecoveredRecordingContext {
        item.recoveredRecordingContext ?? RecoveredRecordingContext(
            mode: .complete,
            interruptionReason: nil
        )
    }
    private var recoveryTitle: String {
        localizedCatalogString(recoveredRecordingContext.titleLocalizationKey)
    }
    private var recoveryPresentation: QuillUserIssuePresentation {
        QuillUserIssuePresentation(
            title: recoveryTitle,
            body: recoveredRecordingContext.localizedResult(),
            suggestion: recoveredRecordingContext.localizedCause() ?? "",
            compactMessage: recoveryTitle,
            detailsRows: [],
            recoveryAction: .retryTranscription,
            severity: .warning
        )
    }
    private var isLiveRecording: Bool { item.postProcessingStatus == "live-recording" }
    private var displayContent: String {
        loadedContent ?? item.postProcessedTranscript
    }
    private var summaryEnvelope: MeetingSummaryEnvelope? {
        item.meetingSummary
    }
    private var summaryAttempt: MeetingSummaryAttempt? {
        item.meetingSummaryAttempt
    }
    private var currentSummaryAttempt: MeetingSummaryAttempt? {
        guard let summaryAttempt,
              summaryAttempt.isCurrent(for: appState.meetingSummarySource(for: item)) else {
            return nil
        }
        return summaryAttempt
    }
    private var summaryAvailability: MeetingSummaryAvailability {
        appState.meetingSummaryAvailability(for: item)
    }
    private var showsSummaryTab: Bool {
        summaryEnvelope != nil || (currentSummaryAttempt?.outcome == .failed && currentSummaryAttempt?.issue != nil) || summaryIssue != nil
    }
    private var isSummaryAttemptBannerDismissed: Bool {
        dismissedSummaryAttemptAt == currentSummaryAttempt?.occurredAt
    }
    private var isGeneratingSummary: Bool {
        appState.meetingSummaryGeneratingNoteIDs.contains(item.id)
    }
    private var isSummaryStale: Bool {
        guard let summaryEnvelope else { return false }
        return summaryEnvelope.sourceFingerprint
            != appState.meetingSummarySource(for: item).fingerprint
    }
    private var summaryToolbarAction: SummaryToolbarAction {
        if summaryEnvelope != nil {
            return .regenerate
        }
        if currentSummaryAttempt?.outcome == .failed
            || hasRetryableTransientSummaryIssue {
            return .retry
        }
        return .create
    }
    private var hasRetryableTransientSummaryIssue: Bool {
        guard let summaryIssue else { return false }
        if case .retrySummary = MeetingSummaryIssueAction.resolve(
            summaryIssue.presentation()
        ) {
            return true
        }
        return false
    }
    private var canDeleteSummary: Bool {
        summaryEnvelope != nil
            || (currentSummaryAttempt?.outcome == .failed
                && currentSummaryAttempt?.issue != nil)
    }
    private var summaryActionIsDisabled: Bool {
        switch summaryAvailability {
        case .available, .featureDisabled:
            return false
        case .modelUnavailable, .transcriptUnavailable,
             .transcriptionInProgress, .generationInProgress:
            return true
        }
    }
    private var canCopyDisplayedContent: Bool {
        switch selectedContentMode {
        case .transcript:
            return !displayContent.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        case .summary:
            return summaryEnvelope != nil
        }
    }
    private var unavailableCopyHelp: LocalizedStringKey {
        switch selectedContentMode {
        case .transcript:
            return "No transcript text to copy."
        case .summary:
            return "No summary text to copy."
        }
    }
    private var storedAudioURL: URL? {
        appState.noteBrowserStoredAudioURL(for: item)
    }
    private var retryAvailability: NoteBrowserRetryAvailability {
        appState.noteBrowserRetryAvailability(for: item)
    }
    private var actionState: NoteBrowserActionState {
        NoteBrowserActionState(
            hasStoredAudio: storedAudioURL != nil,
            transcript: displayContent,
            retryAvailability: retryAvailability,
            postProcessingEnabled: !appState.disablePostProcessing,
            hasSummary: summaryEnvelope != nil
        )
    }
    private var issuePresentation: QuillUserIssuePresentation? {
        item.userIssueRecord.map {
            NoteBrowserRecoveryPresentation.presentation(
                for: $0,
                actionState: actionState
            )
        }
    }
    private var warningPresentation: QuillUserIssuePresentation? {
        guard let issuePresentation,
              issuePresentation.severity == .warning,
              !isNothingToPostProcess else {
            return nil
        }
        return issuePresentation
    }
    /// Post-processing returned nothing to change. The original transcript is
    /// the result, so this is a quiet notice rather than a warning.
    private var isNothingToPostProcess: Bool {
        guard let record = item.userIssueRecord else { return false }
        return record.code == .postProcessingFailed
            && record.context.postProcessingFailureReason == .emptyOutput
    }
    private var warningBannerCode: QuillUserIssueCode? {
        item.userIssueRecord?.code
    }
    private var isWarningBannerDismissed: Bool {
        guard let warningBannerCode else { return false }
        return appState.isWarningBannerDismissed(noteID: item.id, code: warningBannerCode)
    }
    private var suggestedCalendarTitleInfo: (suggested: String, applied: String)? {
        NoteTitleResolver.suggestedCalendarTitle(for: item)
    }

    private var increasesContrast: Bool { colorSchemeContrast == .increased }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                noteHeader
                if showsSummaryTab {
                    contentModePicker
                }
                contentArea
                    .overlay {
                        if isRetrying {
                            retryingOverlay
                        } else if isRecoveringRecording {
                            retryingOverlay
                        }
                    }
            }
            floatingToolbar
            if let toastMessage {
                NoteBrowserToastView(message: toastMessage)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 72)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(101)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            loadContent()
            revealSummaryIfPending()
            applySearchTabPreference(prefersSummaryTab)
        }
        .onChange(of: prefersSummaryTab) { newValue in
            applySearchTabPreference(newValue)
        }
        .onChange(of: isSearchActive) { newValue in
            if !newValue {
                userChoseContentModeDuringSearch = false
            }
        }
        .onChange(of: item.postProcessedTranscript) { newValue in
            if !newValue.isEmpty {
                loadedContent = newValue
            }
        }
        .onChange(of: item.meetingSummaryJSON) { newValue in
            // Read newValue directly rather than a computed property on self:
            // this closure's captured self can still see the previous item
            // even though SwiftUI already passes the fresh trigger value.
            if newValue == nil {
                selectedContentMode = .transcript
            } else {
                revealSummaryIfPending()
            }
        }
        .onChange(of: item.meetingSummaryAttempt) { _ in
            dismissedSummaryAttemptAt = nil
        }
        .onChange(of: selectedContentMode) { newValue in
            if newValue != .transcript {
                highlightedSourceQuote = nil
            }
        }
        .sheet(isPresented: $showFileExportSheet) {
            NoteFileExportView(
                source: NoteFileExportSource(
                    transcript: displayContent,
                    audioURL: storedAudioURL,
                    summary: summaryEnvelope.map { MeetingSummaryMarkdownRenderer.render($0) },
                    isSummaryStale: isSummaryStale
                ),
                suggestedBaseName: NoteFileExportNaming.suggestedBaseName(
                    customTitle: item.customTitle,
                    calendarTitle: item.calendarMatch?.appliedTitle,
                    timestamp: item.timestamp
                ),
                onDismiss: { showFileExportSheet = false },
                onSaved: { showToast($0) }
            )
        }
        .sheet(item: $retryChoiceRequest) { request in
            TranscriptionChoiceSheet(
                title: "Transcribe Recording",
                subtitle: NoteTitleResolver.displayTitle(for: item),
                showsSettingNote: true,
                options: request.options,
                fallbackChoice: appState.currentNoteBrowserTranscriptionChoice
            ) { choice in
                retryChoiceRequest = nil
                appState.retryTranscription(item: item, choice: choice)
            } onOpenProviderSettings: {
                retryChoiceRequest = nil
                appState.openProviderSettings()
            } onCancel: {
                retryChoiceRequest = nil
            }
        }
        .onReceive(appState.$retryingItemIDs) { ids in
            withAnimation(.easeOut(duration: 0.16)) {
                isRetrying = ids.contains(item.id)
            }
        }
        // The pieces of a recording that could not be recovered go with the
        // note, so this asks first instead of offering an undo.
        .confirmationDialog("Delete this note and its recording pieces?", isPresented: $showUnrecoveredDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("The recording pieces Quill couldn't recover will also be deleted. This can't be undone.")
        }
        .confirmationDialog("Delete this note?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if appState.canDeleteHistoryEntryCancellably(id: item.id) {
                Text("You can cancel for a few seconds after deleting.")
            } else {
                Text("Deleted notes cannot be recovered.")
            }
        }
        // With a summary, the one trash button asks what to delete. The
        // buttons keep the same order in either tab, and Cancel stays the
        // default so Return never deletes anything.
        .confirmationDialog("What do you want to delete?", isPresented: $showDeleteChoice, titleVisibility: .visible) {
            Button("Delete Summary Only") { deleteSummary() }
            Button("Delete Entire Note", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            if appState.canDeleteHistoryEntryCancellably(id: item.id) {
                Text("Deleting the entire note removes its recording, transcript, and summary. You can cancel for a few seconds after deleting.")
            } else {
                Text("Deleting the entire note removes its recording, transcript, and summary, and cannot be undone.")
            }
        }
    }

    // MARK: Header

    private var noteHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            metadataLine

            // Title — auto-save on change
            HorizontallyScrollableTitleField(
                placeholder: item.timestamp.formatted(date: .long, time: .shortened),
                text: $titleDraft
            )
            .frame(minHeight: 38, maxHeight: 38, alignment: .leading)
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

            if let suggestedCalendarTitleInfo {
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
                        Text(suggestedCalendarTitleInfo.suggested)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Apply") {
                        titleDraft = suggestedCalendarTitleInfo.applied
                        appState.updateHistoryItemTitle(id: item.id, title: suggestedCalendarTitleInfo.applied)
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

            // Show the audio player only when the stored audio file exists
            if let storedAudioURL {
                NoteAudioPlayerView(audioURL: storedAudioURL)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 40)
        // Under the transparent title bar, just below the traffic lights' row.
        .padding(.top, 32)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Divider().opacity(QuillContrast.opacity(0.4, increased: increasesContrast))
        }
    }

    private var metadataLine: some View {
        let detailTimestamp = NoteTimestampFormatter.detailTimestamp(for: item)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                detailTimestampLabel(detailTimestamp)
                statusBadges
                noteStateIndicator
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    detailTimestampLabel(detailTimestamp)
                    noteStateIndicator
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    statusBadges
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func detailTimestampLabel(_ detailTimestamp: String) -> some View {
        Text(detailTimestamp)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(QuillContrast.hierarchicalStyle(.tertiary, increased: increasesContrast))
            .textCase(.uppercase)
            .kerning(0.5)
            .lineLimit(1)
    }

    @ViewBuilder
    private var noteStateIndicator: some View {
        if isLiveRecording {
            LiveRecordingBadge(startedAt: item.recordingStartedAt)
        } else if isRetrying || isCloudTranscribing || isRecoveringRecording {
            ProgressView()
                .controlSize(.mini)
                .help(isCloudTranscribing ? cloudProgressText : retryingStatusText)
                .accessibilityLabel(Text(verbatim: isCloudTranscribing ? cloudProgressText : retryingStatusText))
        } else if isRecoveredRecording {
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.orange.opacity(QuillContrast.opacity(0.7, increased: increasesContrast)))
                .help("Recording recovered after an unexpected shutdown")
                .accessibilityLabel(Text("Recording recovered after an unexpected shutdown"))
        }
        // A failed note shows no header indicator: its centered empty
        // state already says what happened.
    }

    @ViewBuilder
    private var statusBadges: some View {
        HStack(spacing: 5) {
            if isAudioOnly {
                metaTag(
                    localizedCatalogString("Audio only"),
                    active: true,
                    help: "Audio-only recording"
                )
            } else {
                metaTag(
                    item.usedLocalTranscription ? "LOCAL" : "CLOUD",
                    active: item.usedLocalTranscription,
                    help: item.usedLocalTranscription ? "Local transcription" : "Cloud transcription"
                )
            }
            metaDot
            metaTag(
                item.usedContextCapture ? "CTX" : "NO CTX",
                active: item.usedContextCapture,
                help: item.usedContextCapture ? "Context capture enabled" : "Context capture disabled"
            )
            metaDot
            metaTag(
                item.usedPostProcessing ? "LLM" : "NO LLM",
                active: item.usedPostProcessing,
                help: item.usedPostProcessing ? "LLM post-processing enabled" : "LLM post-processing disabled"
            )
            if item.transcriptionLanguageCode != "auto" {
                metaDot
                metaTag(
                    item.transcriptionLanguageCode.uppercased(),
                    active: true,
                    help: "Transcription language"
                )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        // VoiceOver reads the row once, in words, not the abbreviations.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: statusBadgesSpokenText))
    }

    /// The metadata row spelled out, such as "Local transcription, Context
    /// capture disabled, LLM post-processing enabled, Transcription language: KO".
    private var statusBadgesSpokenText: String {
        var parts: [String] = []
        if isAudioOnly {
            parts.append(localizedCatalogString("Audio-only recording"))
        } else {
            parts.append(localizedCatalogString(
                item.usedLocalTranscription ? "Local transcription" : "Cloud transcription"
            ))
        }
        parts.append(localizedCatalogString(
            item.usedContextCapture ? "Context capture enabled" : "Context capture disabled"
        ))
        parts.append(localizedCatalogString(
            item.usedPostProcessing ? "LLM post-processing enabled" : "LLM post-processing disabled"
        ))
        if item.transcriptionLanguageCode != "auto" {
            parts.append(localizedCatalogFormat(
                "Transcription language: %@",
                item.transcriptionLanguageCode.uppercased()
            ))
        }
        return parts.joined(separator: ", ")
    }

    private var metaDot: some View {
        Text("·")
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(QuillContrast.hierarchicalStyle(.quaternary, increased: increasesContrast))
    }

    /// A label with a tooltip. It is plain text, not a button, so Tab and
    /// VoiceOver don't stop on it; the row above reads it in words.
    private func metaTag(_ label: String, active: Bool, help tooltip: LocalizedStringKey) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.secondary.opacity(
                QuillContrast.opacity(active ? 0.7 : 0.5, increased: increasesContrast)
            ))
            .padding(.vertical, 3)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .help(tooltip)
    }

    // MARK: Content

    private var contentModePicker: some View {
        Picker("Note Content", selection: userContentModeSelection) {
            Text("Transcript").tag(NoteContentMode.transcript)
            if showsSummaryTab {
                Text("Summary").tag(NoteContentMode.summary)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .frame(maxWidth: 220)
        .accessibilityLabel("Note Content")
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var contentArea: some View {
        Group {
            if loadedContent == nil {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if selectedContentMode == .summary && showsSummaryTab {
                summaryContentArea
            } else {
                transcriptContentArea
            }
        }
    }

    @ViewBuilder
    private var transcriptContentArea: some View {
        if displayContent.isEmpty {
            emptyContentState
        } else {
            VStack(spacing: 0) {
                if isNothingToPostProcess,
                   !isWarningBannerDismissed,
                   !appState.retryingItemIDs.contains(item.id) {
                    QuillInfoNotice(
                        text: localizedCatalogString(
                            "Nothing to clean up; showing the original transcript."
                        ),
                        onDismiss: {
                            if let warningBannerCode {
                                appState.dismissWarningBanner(
                                    noteID: item.id,
                                    code: warningBannerCode
                                )
                            }
                        }
                    )
                    .padding(.horizontal, 40)
                    .padding(.top, 14)
                }
                if !isWarningBannerDismissed,
                   !appState.retryingItemIDs.contains(item.id),
                   let warningPresentation {
                    QuillUserIssueView(
                        presentation: warningPresentation,
                        style: .warningBanner,
                        action: {
                            performRecoveryAction(
                                warningPresentation.recoveryAction
                            )
                        },
                        onDismiss: {
                            if let warningBannerCode {
                                appState.dismissWarningBanner(
                                    noteID: item.id,
                                    code: warningBannerCode
                                )
                            }
                        }
                    )
                    .padding(.horizontal, 40)
                    .padding(.top, 16)
                }
                NoteTextView(
                    text: displayContent,
                    bottomPadding: 36,
                    highlightedSourceQuote: highlightedSourceQuote
                ) { edited in
                    loadedContent = edited
                    appState.updateTranscript(id: item.id, text: edited)
                }
            }
        }
    }

    private var summaryContentArea: some View {
        Group {
            if let summaryEnvelope {
                MeetingSummaryView(
                    envelope: summaryEnvelope,
                    sourceQuoteIsValid: { quote in
                        MeetingSummarySourceLocator.range(
                            of: quote,
                            in: displayContent
                        ) != nil
                    },
                    onToggleAction: { actionID, isCompleted in
                        do {
                            try appState.setMeetingSummaryActionCompleted(
                                noteID: item.id,
                                actionID: actionID,
                                isCompleted: isCompleted
                            )
                        } catch {
                            showToast(localizedCatalogString(
                                "Could not update action item."
                            ))
                        }
                    },
                    onViewSource: viewSource
                ) {
                    summaryNotices
                }
            } else if let attempt = currentSummaryAttempt,
                      let presentation = attempt.issuePresentation() {
                summaryFailureContent(presentation: presentation)
            } else if let summaryIssue {
                summaryFailureContent(presentation: summaryIssue.presentation())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Summary notices

    /// The saved summary's notices, most important first. Several at once
    /// show as one line with a "+N" pill that reveals the rest.
    private enum SummaryNoticeKind: Hashable {
        case failure
        case stale
        case unverifiedEvidence
        case featureDisabled
        case modelUnavailable
    }

    /// A newer failed attempt, or an issue from this session, shown above
    /// the summary that is still saved.
    private var summaryFailureNoticePresentation: QuillUserIssuePresentation? {
        let failedAttemptPresentation = currentSummaryAttempt?.outcome == .failed
            ? currentSummaryAttempt?.issuePresentation()
            : nil
        guard let presentation = summaryIssue?.presentation()
            ?? failedAttemptPresentation else {
            return nil
        }
        let isDismissed = summaryIssue != nil
            ? isSummaryIssueBannerDismissed
            : isSummaryAttemptBannerDismissed
        return isDismissed ? nil : presentation
    }

    /// A dismissal lasts while the condition is unchanged: another
    /// transcript edit or a new summary brings the notice back.
    private func summaryNoticeDismissalKey(_ kind: SummaryNoticeKind) -> String {
        switch kind {
        case .failure:
            return "failure"
        case .stale:
            return "stale:\(appState.meetingSummarySource(for: item).fingerprint)"
        case .unverifiedEvidence:
            let generatedAt = summaryEnvelope?.generatedAt.timeIntervalSince1970 ?? 0
            return "evidence:\(generatedAt)"
        case .featureDisabled:
            return "featureDisabled"
        case .modelUnavailable:
            return "modelUnavailable"
        }
    }

    private var visibleSummaryNotices: [SummaryNoticeKind] {
        guard let summaryEnvelope else { return [] }
        var kinds: [SummaryNoticeKind] = []
        if summaryFailureNoticePresentation != nil {
            kinds.append(.failure)
        }
        if isSummaryStale {
            kinds.append(.stale)
        }
        if summaryEnvelope.effectiveEvidenceVerification == .unverified {
            kinds.append(.unverifiedEvidence)
        }
        if summaryAvailability == .featureDisabled {
            kinds.append(.featureDisabled)
        } else if summaryAvailability == .modelUnavailable {
            kinds.append(.modelUnavailable)
        }
        return kinds.filter { kind in
            kind == .failure
                || !dismissedSummaryNoticeKeys.contains(summaryNoticeDismissalKey(kind))
        }
    }

    @ViewBuilder
    private var summaryNotices: some View {
        let notices = visibleSummaryNotices
        if let first = notices.first {
            VStack(alignment: .leading, spacing: 6) {
                summaryNoticeRow(
                    first,
                    expansion: notices.count > 1
                        ? QuillBannerExpansion(
                            hiddenCount: notices.count - 1,
                            isExpanded: areSummaryNoticesExpanded,
                            toggle: {
                                withAnimation(.easeOut(duration: 0.16)) {
                                    areSummaryNoticesExpanded.toggle()
                                }
                            }
                        )
                        : nil
                )
                if areSummaryNoticesExpanded {
                    ForEach(Array(notices.dropFirst()), id: \.self) { kind in
                        summaryNoticeRow(kind, expansion: nil)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func summaryNoticeRow(
        _ kind: SummaryNoticeKind,
        expansion: QuillBannerExpansion?
    ) -> some View {
        switch kind {
        case .failure:
            if let presentation = summaryFailureNoticePresentation {
                let summaryAction = summaryIssueAction(for: presentation)
                QuillUserIssueView(
                    presentation: presentation,
                    style: .warningBanner,
                    action: summaryAction.action,
                    actionTitleOverride: summaryAction.actionTitleOverride,
                    onDismiss: {
                        if summaryIssue != nil {
                            isSummaryIssueBannerDismissed = true
                        } else {
                            dismissedSummaryAttemptAt = currentSummaryAttempt?.occurredAt
                        }
                    },
                    expansion: expansion
                )
            }
        case .stale:
            summaryStatusNotice(
                kind,
                systemImage: "exclamationmark.triangle.fill",
                tint: QuillStatusBanner.warningTint,
                title: "Transcript changed after this summary was generated.",
                detail: "Regenerate to align the draft with the current transcript.",
                expansion: expansion
            )
        case .unverifiedEvidence:
            summaryStatusNotice(
                kind,
                systemImage: "exclamationmark.triangle.fill",
                tint: QuillStatusBanner.warningTint,
                title: "Some evidence could not be verified.",
                detail: "Review the summary before sharing it.",
                expansion: expansion
            )
        case .featureDisabled:
            summaryStatusNotice(
                kind,
                systemImage: "pause.circle",
                tint: .secondary,
                title: "Meeting Summary is off",
                detail: "This saved summary is still available. Turn the feature on to regenerate it.",
                expansion: expansion
            )
        case .modelUnavailable:
            summaryStatusNotice(
                kind,
                systemImage: "exclamationmark.circle",
                tint: .secondary,
                title: "Summary model is unavailable.",
                detail: "This saved summary remains available for review and copying.",
                expansion: expansion
            )
        }
    }

    private func summaryStatusNotice(
        _ kind: SummaryNoticeKind,
        systemImage: String,
        tint: Color,
        title: String,
        detail: String,
        expansion: QuillBannerExpansion?
    ) -> some View {
        QuillStatusBanner(
            systemImage: systemImage,
            tint: tint,
            title: localizedCatalogString(title),
            detail: localizedCatalogString(detail),
            expansion: expansion,
            onDismiss: {
                dismissedSummaryNoticeKeys.insert(summaryNoticeDismissalKey(kind))
            }
        )
    }

    private func summaryFailureContent(
        presentation: QuillUserIssuePresentation
    ) -> some View {
        let summaryAction = summaryIssueAction(for: presentation)
        return VStack(spacing: 0) {
            Spacer()
            QuillUserIssueView(
                presentation: presentation,
                style: .full,
                action: summaryAction.action,
                actionTitleOverride: summaryAction.actionTitleOverride
            )
            .padding(.horizontal, 60)
            Spacer()
        }
        .padding(.bottom, Self.floatingToolbarClearance)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The floating toolbar's height plus its bottom margin. Centered empty
    /// states leave this much room so they sit in the middle of what is
    /// visible above the toolbar, not of the whole pane.
    private static let floatingToolbarHeight: CGFloat = 48
    private static let floatingToolbarBottomMargin: CGFloat = 20
    private static let floatingToolbarClearance =
        floatingToolbarHeight + floatingToolbarBottomMargin

    @ViewBuilder
    private var emptyContentState: some View {
        VStack(spacing: 14) {
            Spacer()
            if isLiveRecording {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.08))
                        .frame(width: 80, height: 80)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.red.opacity(0.75))
                }
                Group {
                    if let startedAt = item.recordingStartedAt {
                        RecordingElapsedTitle(startedAt: startedAt)
                    } else {
                        Text("Recording...")
                    }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                Text(verbatim: appState.activeRecordingNoteHint)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)
            } else if isCloudTranscribing
                        || item.machineStatus == .importing
                        || item.postProcessingStatus
                        == PipelineHistoryItem.transcriptionRecoveryPlaceholderStatus {
                ProgressView()
                    .controlSize(.regular)
                Text(verbatim: processingStatusText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else if let unrecoveredContext,
                      let unrecoveredPresentation {
                unrecoveredRecordingState(
                    unrecoveredContext,
                    presentation: unrecoveredPresentation
                )
            } else if isRecoveredRecording {
                // Same empty state as a failed note, with the recovery icon
                // and an action that transcribes the recovered audio.
                QuillUserIssueView(
                    presentation: recoveryPresentation,
                    action: { retryTranscription() },
                    actionTitleOverride: "Transcribe",
                    systemImageOverride: "arrow.clockwise",
                    tintOverride: .orange
                )
                .padding(.horizontal, 60)
            } else if isAudioOnly {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.08))
                        .frame(width: 80, height: 80)
                    Image(systemName: "waveform")
                        .font(.system(size: 30, weight: .ultraLight))
                        .foregroundStyle(.blue.opacity(0.75))
                }
                Text("Audio recording")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Saved without transcription. You can transcribe it later.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            } else if isError {
                if let issuePresentation {
                    QuillUserIssueView(
                        presentation: issuePresentation,
                        action: {
                            performRecoveryAction(
                                issuePresentation.recoveryAction
                            )
                        }
                    )
                    .padding(.horizontal, 60)
                }
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
        .padding(.bottom, Self.floatingToolbarClearance)
        .frame(maxWidth: .infinity)
    }

    /// A recording startup recovery could not restore. With no audio left,
    /// the note can only be deleted; with pieces left, it can be recovered
    /// again or the pieces opened in Finder.
    @ViewBuilder
    private func unrecoveredRecordingState(
        _ context: UnrecoveredRecordingContext,
        presentation: QuillUserIssuePresentation
    ) -> some View {
        switch context.kind {
        case .noAudio:
            QuillUserIssueView(
                presentation: presentation,
                action: { showDeleteConfirmation = true },
                actionTitleOverride: "Delete Note"
            )
            .padding(.horizontal, 60)
        case .recoveryFailed:
            QuillUserIssueView(
                presentation: presentation,
                action: { recoverRecordingAgain() },
                actionTitleOverride: "Recover Again",
                secondaryAction: {
                    appState.openUnrecoveredRecordingFolder(id: item.id)
                },
                secondaryActionTitle: "Open Folder",
                actionDisabled: !appState.canRecoverRecordingAgain(item),
                secondaryActionDisabled: isRecoveringRecording
            )
            .padding(.horizontal, 60)
        }
    }

    private func recoverRecordingAgain() {
        appState.recoverRecordingAgain(id: item.id) { didRecover in
            showToast(localizedCatalogString(
                didRecover ? "Recording recovered" : "Couldn't recover again"
            ))
        }
    }

    /// The same stage the note list shows: "Post-processing…" once the
    /// transcript is being cleaned up, cloud chunk progress, or "Transcribing…".
    private var processingStatusText: String {
        if appState.postProcessingNoteIDs.contains(item.id) {
            return localizedCatalogString("Post-processing...")
        }
        return isCloudTranscribing
            ? cloudProgressText
            : localizedCatalogString("Transcribing...")
    }

    /// "Retranscribing…", or "Transcribing…" for an audio-only note that was
    /// never transcribed, then "Post-processing…" once the new transcript is
    /// being cleaned up.
    private var retryingStatusText: String {
        if isRecoveringRecording {
            return localizedCatalogString("Recovering…")
        }
        if appState.postProcessingNoteIDs.contains(item.id) {
            return localizedCatalogString("Post-processing...")
        }
        return localizedCatalogString(isAudioOnly ? "Transcribing..." : "Retranscribing...")
    }

    /// Covers the note body while it is transcribed again, keeping the
    /// existing content visible underneath.
    private var retryingOverlay: some View {
        ZStack {
            // A light wash, not a blur, so the text underneath stays readable.
            Rectangle()
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.35))
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(retryingStatusText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.bottom, 60)
        }
        .transition(.opacity)
        .allowsHitTesting(true)
    }

    // MARK: Floating Toolbar

    private var floatingToolbar: some View {
        HStack(spacing: 2) {
            if actionState.showsRetryButton {
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
                    help: transcriptionActionHelp
                )
                toolbarDivider
            }

            // Copy
            toolbarButton(
                action: { copyContent() },
                label: {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(
                            isCopied
                                ? Color.accentColor
                                : canCopyDisplayedContent
                                    ? Color.primary
                                    : Color.secondary
                        )
                },
                disabled: !canCopyDisplayedContent,
                help: canCopyDisplayedContent
                    ? "Copy content"
                    : unavailableCopyHelp
            )

            toolbarButton(
                action: { showFileExportSheet = true },
                label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 13, weight: .medium))
                        .accessibilityLabel(Text("Save Files"))
                        .foregroundStyle(
                            actionState.canSaveFiles
                                ? Color.primary
                                : Color.secondary
                        )
                },
                disabled: !actionState.canSaveFiles,
                help: "Save Files"
            )

            toolbarButton(
                action: { handleSummaryAction() },
                label: {
                    if isGeneratingSummary {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: summaryToolbarAction.systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(
                            summaryActionIsDisabled
                                ? Color.secondary
                                : Color.primary
                        )
                    }
                },
                disabled: summaryActionIsDisabled,
                help: summaryToolbarAction.help
            )

            toolbarDivider

            // Delete
            toolbarButton(
                action: {
                    if keepsRecordingPieces {
                        showUnrecoveredDeleteConfirmation = true
                    } else if canDeleteSummary {
                        showDeleteChoice = true
                    } else {
                        showDeleteConfirmation = true
                    }
                },
                label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.8))
                },
                disabled: isRecoveringRecording,
                help: "Delete note"
            )
        }
        .padding(.horizontal, 8)
        .frame(height: Self.floatingToolbarHeight)
        .background {
            // Opaque under Reduce Transparency.
            if reduceTransparency {
                Capsule().fill(QuillTransparency.opaqueBackgroundColor)
            } else {
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
        }
        .overlay(Capsule().strokeBorder(toolbarStrokeColor, lineWidth: 0.6))
        .compositingGroup()
        .shadow(color: .black.opacity(0.085), radius: 14, x: 0, y: 4)
        .shadow(color: .white.opacity(0.05), radius: 4, x: 0, y: -1)
        .padding(.bottom, Self.floatingToolbarBottomMargin)
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
        help: LocalizedStringKey
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
        let transcriptDirectory = appState.storageLayout.transcriptDirectory
        Task.detached(priority: .userInitiated) {
            let text: String
            if !postProcessed.isEmpty {
                text = postProcessed
            } else if let fileName {
                let fileURL = transcriptDirectory.appendingPathComponent(fileName)
                text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? raw
            } else {
                text = raw
            }
            await MainActor.run { loadedContent = text }
        }
    }

    private func performRecoveryAction(_ action: QuillUserRecoveryAction) {
        switch action {
        case .retryTranscription:
            retryTranscription()
        case .retryPostProcessing:
            switch appState.postProcessingRetryBlocker(for: item) {
            case .postProcessingOff:
                showToast(localizedCatalogString(
                    "Turn on post-processing in Settings to retry."
                ))
            case .noTranscript:
                showToast(localizedCatalogString(
                    "There is no transcript to post-process."
                ))
            case nil:
                appState.retryPostProcessing(item: item)
            }
        case .openModelsSettings:
            appState.selectedSettingsTab = .models
            NotificationCenter.default.post(name: .showSettings, object: nil)
        case .openProviderSettings:
            appState.openProviderSettings()
        case .openMicrophoneSettings:
            appState.openMicrophoneSettings()
        case .openSpeechRecognitionSettings:
            appState.openSpeechRecognitionSettings()
        case .openScreenRecordingSettings:
            appState.openScreenCaptureSettings()
        case .none:
            break
        }
    }

    private func retryTranscription() {
        switch retryAvailability {
        case .ready:
            appState.retryTranscription(item: item)
        case .needsModelSelection, .needsProviderConfiguration:
            // Transcription is off, or the selected model can't transcribe
            // this file or isn't ready: ask which model to use for this note.
            if let options = appState.noteBrowserRetryOptions(for: item) {
                retryChoiceRequest = RetryChoiceRequest(options: options)
            }
        case .needsModelSetup:
            showToast(
                localizedCatalogString(
                    "Set up a model in Settings to retry transcription."
                )
            )
        case .noAudio:
            break
        }
    }

    private func showToast(_ message: String) {
        let id = UUID()
        toastID = id
        withAnimation(.easeOut(duration: 0.16)) {
            toastMessage = message
        }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard toastID == id else { return }
            withAnimation(.easeIn(duration: 0.16)) {
                toastMessage = nil
                toastID = nil
            }
        }
    }

    private func viewSource(_ quote: String) {
        guard MeetingSummarySourceLocator.range(
            of: quote,
            in: displayContent
        ) != nil else {
            return
        }
        highlightedSourceQuote = quote
        selectedContentMode = .transcript
    }

    private func handleSummaryAction() {
        guard summaryAvailability != .featureDisabled else {
            showToast(localizedCatalogString(
                "Meeting Summary is off. Turn it on in Model Settings to create a summary."
            ))
            return
        }
        generateSummary()
    }

    /// The picker's binding; a tab picked here counts as the person's own
    /// choice for the rest of the current search.
    private var userContentModeSelection: Binding<NoteContentMode> {
        Binding(
            get: { selectedContentMode },
            set: { newValue in
                if isSearchActive {
                    userChoseContentModeDuringSearch = true
                }
                selectedContentMode = newValue
            }
        )
    }

    /// Opens the Summary tab when search matches this note only in its
    /// summary. It never forces the Transcript tab back and never overrides
    /// a tab the person picked during the current search.
    private func applySearchTabPreference(_ prefersSummary: Bool) {
        guard prefersSummary, !userChoseContentModeDuringSearch else { return }
        switchToSummaryTab()
    }

    private func revealSummaryIfPending() {
        guard appState.consumeMeetingSummaryPendingReveal(id: item.id) else { return }
        switchToSummaryTab()
    }

    private func switchToSummaryTab() {
        // The Summary segment is only added to the picker once showsSummaryTab
        // flips true. Selecting it in the same update as its first appearance
        // can be dropped by the underlying segmented control, so defer the
        // selection to the next run loop turn once the segment already exists.
        DispatchQueue.main.async {
            selectedContentMode = .summary
        }
    }

    private func summaryIssueAction(
        for presentation: QuillUserIssuePresentation
    ) -> SummaryIssueViewAction {
        switch MeetingSummaryIssueAction.resolve(presentation) {
        case .retrySummary:
            return SummaryIssueViewAction(
                action: generateSummary,
                actionTitleOverride: "Retry Summary"
            )
        case .recovery(let recoveryAction):
            return SummaryIssueViewAction(
                action: { performRecoveryAction(recoveryAction) },
                actionTitleOverride: nil
            )
        }
    }

    private func generateSummary() {
        let attemptBeforeGeneration = appState.pipelineHistory.first {
            $0.id == item.id
        }?.meetingSummaryAttempt?.occurredAt
        Task { @MainActor in
            do {
                try await appState.generateMeetingSummary(id: item.id)
                summaryIssue = nil
                isSummaryIssueBannerDismissed = false
            } catch {
                if let error = error as? MeetingSummaryError, error == .sourceChanged {
                    return
                }
                let persistedAttempt = appState.pipelineHistory.first {
                    $0.id == item.id
                }?.meetingSummaryAttempt
                if persistedAttempt?.outcome == .failed,
                   persistedAttempt?.occurredAt != attemptBeforeGeneration,
                   persistedAttempt?.issue != nil {
                    summaryIssue = nil
                    isSummaryIssueBannerDismissed = false
                } else if let error = error as? MeetingSummaryError {
                    summaryIssue = error.userIssue(
                        providerHost: URL(string: appState.apiBaseURL)?.host,
                        modelID: appState.meetingSummaryBackendChoice.modelID,
                        localBackend: appState.meetingSummaryBackendChoice.isLocal
                            ? "Local AI"
                            : nil
                    )
                } else if let error = error as? QuillUserIssueError {
                    summaryIssue = error.record
                } else {
                    summaryIssue = QuillUserIssueRecord(code: .unknown)
                }
                isSummaryIssueBannerDismissed = false
                switchToSummaryTab()
            }
        }
    }

    private func deleteSummary() {
        do {
            try appState.deleteMeetingSummary(noteID: item.id)
            summaryIssue = nil
            isSummaryIssueBannerDismissed = false
            dismissedSummaryAttemptAt = nil
        } catch {
            showToast(localizedCatalogString("Could not delete summary."))
        }
    }

    private func copyContent() {
        let content: String
        switch selectedContentMode {
        case .transcript:
            content = displayContent
        case .summary:
            guard let summaryEnvelope else { return }
            content = MeetingSummaryMarkdownRenderer.render(summaryEnvelope)
        }
        guard !content.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        withAnimation { isCopied = true }
        // The checkmark is visual only; tell VoiceOver too.
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: localizedCatalogString("Copied"),
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { isCopied = false }
        }
    }
}

// MARK: - Note Audio Player View (wireframe design)

private enum SummaryToolbarAction {
    case create
    case retry
    case regenerate

    var systemImage: String {
        switch self {
        case .create:
            "sparkles"
        case .retry, .regenerate:
            "arrow.triangle.2.circlepath"
        }
    }

    var help: LocalizedStringKey {
        switch self {
        case .create:
            "Create Summary"
        case .retry:
            "Retry Summary"
        case .regenerate:
            "Regenerate Summary"
        }
    }
}

private struct SummaryIssueViewAction {
    let action: () -> Void
    let actionTitleOverride: String?
}

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
            .accessibilityLabel(Text(isPlaying ? "Pause" : "Play"))

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
            // Keyboard and VoiceOver can move the position too: ←/→ when the
            // waveform has focus, and VoiceOver's adjust gestures, by 5 s.
            .focusable()
            .onMoveCommand { direction in
                switch direction {
                case .left: seek(by: -Self.keyboardSeekStep)
                case .right: seek(by: Self.keyboardSeekStep)
                default: break
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text("Playback position"))
            .accessibilityValue(Text(verbatim: localizedCatalogFormat(
                "%@ of %@",
                formatDuration(elapsed),
                formatDuration(duration)
            )))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: seek(by: Self.keyboardSeekStep)
                case .decrement: seek(by: -Self.keyboardSeekStep)
                @unknown default: break
                }
            }

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
            .help("Volume")
            .accessibilityLabel(Text("Volume"))
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

    /// How far arrow keys and VoiceOver's adjust gestures move the playhead.
    private static let keyboardSeekStep: TimeInterval = 5

    private func seek(by seconds: TimeInterval) {
        guard duration > 0 else { return }
        // `elapsed` only updates every 0.1 s while playing; start from the
        // player's actual position so each step is exactly 5 s.
        let current = player?.currentTime ?? elapsed
        seek(toFraction: (current + seconds) / duration)
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

private struct NoteBrowserToastView: View {
    let message: String
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .accessibilityLabel(Text(message))
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .underline()
                        .foregroundStyle(.white)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overrideCursor(.pointingHand)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.92))
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
    }
}

private struct ToolbarIconButton<Label: View>: View {
    let action: () -> Void
    let disabled: Bool
    let help: LocalizedStringKey
    @ViewBuilder let label: () -> Label

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(width: 36, height: 36)
                .opacity(disabled ? 0.35 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(ToolbarButtonStyle(isHovered: isHovered))
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(Text(help))
        .contentShape(Circle())
        .allowsHitTesting(true)
        .onHover { hovering in
            isHovered = hovering && !disabled
        }
        .overrideCursor(.arrow)
    }
}

// MARK: - Native Text View

private struct NoteTextView: NSViewRepresentable {
    let text: String
    let bottomPadding: CGFloat
    let highlightedSourceQuote: String?
    let onCommit: ((String) -> Void)?

    init(
        text: String,
        bottomPadding: CGFloat = 0,
        highlightedSourceQuote: String? = nil,
        onCommit: ((String) -> Void)? = nil
    ) {
        self.text = text
        self.bottomPadding = bottomPadding
        self.highlightedSourceQuote = highlightedSourceQuote
        self.onCommit = onCommit
    }

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
        // SwiftUI lays this out below the note header; don't let AppKit add
        // the transparent title bar's height as an extra top inset.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero

        let textView = CursorDeferringTextView()
        configureForTranscriptDisplay(textView)
        textView.setAccessibilityLabel(localizedCatalogString("Transcript"))
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
        context.coordinator.applyHighlight(
            highlightedSourceQuote,
            to: textView
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.onCommit = onCommit
        let currentContent = textView.string.trimmingCharacters(in: .newlines)
        let newContent = text.trimmingCharacters(in: .newlines)
        if textView.window?.firstResponder !== textView, currentContent != newContent {
            applyText(text, to: textView, bottomPadding: bottomPadding)
            context.coordinator.resetHighlight()
        }
        context.coordinator.applyHighlight(
            highlightedSourceQuote,
            to: textView
        )
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
        private var lastHighlightedQuote: String?
        private var highlightedRange: NSRange?

        init(onCommit: ((String) -> Void)?) { self.onCommit = onCommit }

        func resetHighlight() {
            lastHighlightedQuote = nil
            highlightedRange = nil
        }

        func applyHighlight(
            _ quote: String?,
            to textView: NSTextView
        ) {
            guard quote != lastHighlightedQuote else { return }
            removeHighlight(from: textView)
            lastHighlightedQuote = quote
            guard let quote,
                  let range = MeetingSummarySourceLocator.range(
                    of: quote,
                    in: textView.string
                  ) else {
                return
            }

            let nsRange = NSRange(range, in: textView.string)
            textView.textStorage?.addAttribute(
                .backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(0.28),
                range: nsRange
            )
            highlightedRange = nsRange
            textView.scrollRangeToVisible(nsRange)
        }

        private func removeHighlight(from textView: NSTextView) {
            guard let highlightedRange,
                  NSMaxRange(highlightedRange)
                    <= (textView.textStorage?.length ?? 0) else {
                self.highlightedRange = nil
                return
            }
            textView.textStorage?.removeAttribute(
                .backgroundColor,
                range: highlightedRange
            )
            self.highlightedRange = nil
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            removeHighlight(from: textView)
            lastHighlightedQuote = nil
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            // Reduce Motion: a still hourglass instead of a spinning ring.
            Image(systemName: "hourglass")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 8, height: 8)
        } else {
            spinner
        }
    }

    private var spinner: some View {
        Circle()
            .trim(from: 0, to: 0.65)
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 8, height: 8)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                // Start from 0 each time: after Reduce Motion is turned off
                // again, the ring reappears with rotation still at 360.
                rotation = 0
                withAnimation(.linear(duration: 0.75).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// MARK: - Live Recording Badge

private struct LiveRecordingBadge: View {
    var startedAt: Date?
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        HStack(spacing: 4) {
            if reduceMotion {
                // Reduce Motion: a steady dot; REC and the timer show the state.
                Circle()
                    .fill(Color.red)
                    .frame(width: 5, height: 5)
                    .onAppear { pulsing = false }
            } else {
                Circle()
                    .fill(Color.red)
                    .frame(width: 5, height: 5)
                    .opacity(pulsing ? 0.3 : 1.0)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
                    .onAppear { pulsing = true }
            }
            Text("REC")
            if let startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(verbatim: RecordingElapsedFormatter.string(from: startedAt, to: context.date))
                        .monospacedDigit()
                }
            }
        }
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .foregroundStyle(.red.opacity(
            QuillContrast.opacity(0.7, increased: colorSchemeContrast == .increased)
        ))
        .help("Recording in progress")
    }
}

/// "Recording · 03:12", updated every second.
private struct RecordingElapsedTitle: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(verbatim: localizedCatalogFormat(
                "Recording · %@",
                RecordingElapsedFormatter.string(from: startedAt, to: context.date)
            ))
            .monospacedDigit()
        }
    }
}

private struct AudioInputMenuOption {
    let id: String
    let name: String
    let isStaticQuillName: Bool
}

private struct AudioInputMenuConfiguration {
    let sources: [AudioInputMenuOption]
    let disabledSourceIDs: Set<String>
    let microphones: [AudioInputMenuOption]
    let selectedSourceID: String
    let selectedMicrophoneID: String
    let microphoneSelectionEnabled: Bool
    let accessibilityLabel: String
    let accessibilityValue: String
    let onSelectSource: (String) -> Void
    let onSelectMicrophone: (String) -> Void
}

private struct TranscriptionMenuOption {
    let id: String
    let title: String
    let isSelected: Bool
    let isEnabled: Bool
}

private struct TranscriptionMenuSection {
    let title: String
    let options: [TranscriptionMenuOption]
}

private struct TranscriptionMenuConfiguration {
    let off: TranscriptionMenuOption
    let sections: [TranscriptionMenuSection]
    let isEnabled: Bool
    let accessibilityLabel: String
    let accessibilityValue: String
    let onSelect: (String) -> Void
}

/// A transparent control over a custom pill that opens a native menu. The
/// pill is drawn in SwiftUI; this view makes the whole pill clickable and
/// gives it what a pop-up button has: a Tab stop when keyboard navigation
/// is on, a focus ring, Space/Return/Down Arrow to open, and a VoiceOver
/// pop-up button with a label and the current value.
class MenuButtonCatcherView: NSView {
    var isMenuEnabled = true
    var menuAccessibilityLabel = ""
    var menuAccessibilityValue = ""

    /// Subclasses build the menu each time it opens.
    func makeMenu() -> NSMenu? { nil }

    override var isFlipped: Bool { true }
    // Open the menu on the first click even when the window is in the background.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { isMenuEnabled }
    override var canBecomeKeyView: Bool {
        isMenuEnabled && NSApp.isFullKeyboardAccessEnabled
    }

    override func mouseDown(with event: NSEvent) {
        showMenu()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49, 36, 76, 125: // Space, Return, Enter, Down Arrow
            showMenu()
        default:
            super.keyDown(with: event)
        }
    }

    private func showMenu() {
        guard isMenuEnabled, let menu = makeMenu() else { return }
        // Flipped view: y == bounds.height is the bottom edge, so the menu
        // drops just below the pill.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
    override func accessibilityLabel() -> String? { menuAccessibilityLabel }
    override func accessibilityValue() -> Any? { menuAccessibilityValue }
    override func isAccessibilityEnabled() -> Bool { isMenuEnabled }

    override func accessibilityPerformPress() -> Bool {
        showMenu()
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        showMenu()
        return true
    }
}

/// Transparent click target over the whole model pill that pops up a native
/// NSMenu of transcription choices, matching the source control beside it.
private struct TranscriptionMenuCatcher: NSViewRepresentable {
    let configuration: TranscriptionMenuConfiguration

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.configuration = configuration
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.configuration = configuration
    }

    final class CatcherView: MenuButtonCatcherView {
        var configuration: TranscriptionMenuConfiguration? {
            didSet {
                isMenuEnabled = configuration?.isEnabled ?? false
                menuAccessibilityLabel = configuration?.accessibilityLabel ?? ""
                menuAccessibilityValue = configuration?.accessibilityValue ?? ""
            }
        }

        override func makeMenu() -> NSMenu? {
            guard let configuration, configuration.isEnabled else { return nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(makeItem(configuration.off))
            for section in configuration.sections where !section.options.isEmpty {
                menu.addItem(.separator())
                let header = NSMenuItem(title: section.title, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                for option in section.options {
                    menu.addItem(makeItem(option))
                }
            }
            return menu
        }

        private func makeItem(_ option: TranscriptionMenuOption) -> NSMenuItem {
            let item = NSMenuItem(
                title: option.title,
                action: #selector(pick(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option.id
            item.state = option.isSelected ? .on : .off
            item.isEnabled = option.isEnabled
            return item
        }

        @objc private func pick(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            configuration?.onSelect(id)
        }
    }
}

/// Transparent click target that pops up a native NSMenu of audio inputs.
/// Used so the Note Browser's chevron glyph is fully custom and the current
/// source and microphone show native checkmarks.
private struct InputMenuCatcher: NSViewRepresentable {
    let configuration: AudioInputMenuConfiguration

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.apply(configuration)
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.apply(configuration)
    }

    final class CatcherView: MenuButtonCatcherView {
        private var configuration: AudioInputMenuConfiguration?

        func apply(_ configuration: AudioInputMenuConfiguration) {
            self.configuration = configuration
            menuAccessibilityLabel = configuration.accessibilityLabel
            menuAccessibilityValue = configuration.accessibilityValue
        }

        override func makeMenu() -> NSMenu? {
            guard let configuration else { return nil }
            let menu = NSMenu()
            // Honor our per-item isEnabled; otherwise AppKit auto-enables every
            // item whose target responds to the action, masking the disabled state.
            menu.autoenablesItems = false
            menu.addItem(sectionHeader("Audio Source"))
            for option in configuration.sources {
                let item = makeItem(
                    option,
                    selectedID: configuration.selectedSourceID,
                    action: #selector(pickSource(_:))
                )
                item.isEnabled = !configuration.disabledSourceIDs.contains(option.id)
                menu.addItem(item)
            }
            if !configuration.microphones.isEmpty {
                menu.addItem(.separator())
                menu.addItem(sectionHeader("Microphone"))
                for option in configuration.microphones {
                    let item = makeItem(
                        option,
                        selectedID: configuration.selectedMicrophoneID,
                        action: #selector(pickMicrophone(_:))
                    )
                    item.isEnabled = configuration.microphoneSelectionEnabled
                    menu.addItem(item)
                }
            }
            return menu
        }

        private func sectionHeader(_ title: String) -> NSMenuItem {
            let item = NSMenuItem(
                title: localizedCatalogString(title),
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            return item
        }

        private func makeItem(
            _ option: AudioInputMenuOption,
            selectedID: String,
            action: Selector
        ) -> NSMenuItem {
            let title = option.isStaticQuillName
                ? localizedCatalogString(option.name)
                : option.name
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = option.id
            item.state = AudioInputDevice.isSameInput(option.id, selectedID) ? .on : .off
            return item
        }

        @objc private func pickSource(_ sender: NSMenuItem) {
            guard let configuration,
                  let id = sender.representedObject as? String else { return }
            configuration.onSelectSource(id)
        }

        @objc private func pickMicrophone(_ sender: NSMenuItem) {
            guard let configuration,
                  let id = sender.representedObject as? String else { return }
            configuration.onSelectMicrophone(id)
        }
    }
}
