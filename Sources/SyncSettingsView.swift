import AppKit
import SwiftUI
import QuillDesignTokens
import QuillNoteSyncCore

/// Settings › iCloud Sync: one switch, the sync status, and what stays on
/// this Mac. Turning sync on asks first, with the number of notes to upload.
struct SyncSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        SettingsPageScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("iCloud Sync")
                    .font(.largeTitle.bold())

                if let controller = appState.noteSyncController {
                    NoteSyncSettingsCard(
                        controller: controller,
                        downloadThenDelete: appState.noteAudioDownloadThenDelete
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            appState.noteSyncController?.fetchSoon()
        }
    }
}

private struct NoteSyncSettingsCard: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var controller: NoteSyncController
    @ObservedObject var downloadThenDelete: NoteAudioDownloadThenDelete
    @State private var isConfirmingTurnOn = false
    @State private var isConfirmingTurnOff = false
    @State private var isTurningOff = false
    @State private var turnOffFailed = false
    @State private var turnOnFailure: NoteSyncTurnOnFailure?
    @State private var noteCount = 0
    @State private var audioBytes: Int64 = 0
    /// Read when the switch is flipped off, for the dialog's message, and
    /// again when Turn Off and Delete from iCloud is pressed, for the
    /// prompt. Nil when it can't be checked.
    @State private var audioOnlyInICloud: [NoteAudioOnlyInICloud]? = []
    @State private var isAskingAboutRecordings = false
    @AppStorage(NoteAudioOffload.isOnKey) private var optimizesStorage = false

    private var switchBinding: Binding<Bool> {
        Binding(
            get: { controller.isEnabled },
            set: { wantsOn in
                if wantsOn {
                    noteCount = controller.syncableNoteCount
                    audioBytes = controller.uploadAudioByteCount
                    isConfirmingTurnOn = true
                } else {
                    audioOnlyInICloud = controller.recordingsOnlyInICloud
                    isConfirmingTurnOff = true
                }
            }
        )
    }

    var body: some View {
        SettingsCard("iCloud Sync", icon: "icloud") {
            HStack(alignment: .center, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        title
                        statusLine
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        title
                        statusLine
                    }
                }
                Spacer(minLength: 0)
                if showsSyncNow {
                    Button {
                        Task { @MainActor in await controller.syncNow() }
                    } label: {
                        if controller.isSyncingNow {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(controller.isSyncingNow)
                    .help("Sync Now")
                    .accessibilityLabel(Text("Sync Now"))
                }
                Toggle(isOn: switchBinding) {
                    Text("Sync this Mac's notes with iCloud")
                }
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(controller.unavailableReason != nil || isTurningOff || controller.isTurningOn
                    || downloadThenDelete.isRunning)
            }

            statusDetail

            downloadThenDeleteRow

            optimizeStorageRow

            // What goes to iCloud is said once, when turning on.
            if !controller.isEnabled, controller.unavailableReason == nil {
                Text("Keeps your notes the same on your devices with this iCloud account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Turning the switch on is the consent to this (#530).
                Text(ConnectionsChoices.iCloudCalendarDisclosure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if controller.audioLeftOnlyInOtherAccounts {
                    Text("Some audio is still in another iCloud account. Quill deletes it when you sign in to that account again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if controller.audioLeftInICloud {
                    Text("Some audio couldn't be deleted from iCloud yet. Quill tries again when it opens and when you open this page.")
                        .font(.caption)
                        .foregroundStyle(QuillColor.issueWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task {
            // Audio a Turn Off and Delete left in iCloud is deleted again.
            await controller.deleteLeftoverAudio()
        }
        .alert("Turn on iCloud sync?", isPresented: $isConfirmingTurnOn) {
            Button("Cancel", role: .cancel) {}
            Button("Turn On and Upload") {
                Task { @MainActor in
                    turnOnFailure = await controller.turnOn()
                }
            }
        } message: {
            Text(turnOnMessage) + audioSizeText + Text("\n\n") + Text("Screenshots, window titles, selected text, and AI instructions aren't uploaded. You can keep using Quill while it uploads.")
        }
        .confirmationDialog("Turn off iCloud sync?", isPresented: $isConfirmingTurnOff, titleVisibility: .visible) {
            Button("Turn Off Sync") {
                turnOff(deleteFromICloud: false)
            }
            Button("Turn Off and Delete from iCloud", role: .destructive) {
                deleteFromICloudPressed()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Notes on this Mac stay. Turn Off Sync keeps notes in iCloud for your other devices. Turn Off and Delete from iCloud deletes all Quill data in iCloud: sync stops on every device, and each device keeps its notes.") + audioOnlyInICloudText
        }
        .alert(recordingsOnlyInICloudTitle, isPresented: $isAskingAboutRecordings) {
            Button(localizedCatalogString(NoteAudioICloudDeleteCopy.downloadThenDeleteKey)) {
                Task { @MainActor in await downloadThenDelete.run() }
            }
            .keyboardShortcut(.defaultAction)
            Button(localizedCatalogString(NoteAudioICloudDeleteCopy.deleteWithoutRecordingsKey), role: .destructive) {
                turnOff(deleteFromICloud: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(localizedCatalogString(NoteAudioICloudDeleteCopy.messageKey))
        }
        .alert(downloadThenDeleteNoticeTitle, isPresented: isShowingDownloadThenDeleteNotice) {
            Button("OK", role: .cancel) {
                downloadThenDelete.dismissNotice()
            }
        } message: {
            Text(downloadThenDeleteNoticeMessage)
        }
        // A failed delete says why in the alert below, as a plain Turn Off
        // and Delete does; a notice left while Settings was closed shows here.
        .onAppear { showDeleteFailure(downloadThenDelete.notice) }
        .onChange(of: downloadThenDelete.notice) { showDeleteFailure($0) }
        .alert("Couldn't turn on iCloud sync", isPresented: isShowingTurnOnFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            switch turnOnFailure {
            case .signedOut?:
                Text("Check your iCloud account in System Settings, then try again.")
            case .notReady?:
                Text("Notes can't sync right now. If history recovery is running, try again after it finishes.")
            case .unreachable?, nil:
                Text("Check your internet connection and try again. Sync is still off.")
            }
        }
        .alert("Couldn't delete from iCloud", isPresented: $turnOffFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            switch controller.turnOffFailure {
            case .accountUnknown:
                Text("Quill couldn't confirm which iCloud account sync used, so nothing was deleted. Try again after sync runs again. Sync is still on.")
            case .anotherAccount:
                Text("Another iCloud account is signed in, so nothing was deleted from the account sync used. Sync is off.")
            case .syncStopped:
                Text("Sync stopped before the delete finished, so some notes may still be in iCloud. Sync is off.")
            case .alreadyTurnedOff:
                Text("Sync was already turning off, so nothing was deleted from iCloud. Sync is off.")
            case .unreachable, nil:
                Text("Check your internet connection and try again. Sync is still on.")
            }
        }
    }

    /// Optimize Storage: off by default, needs sync on. Turning sync off keeps
    /// the stored choice; the pass just stops. Turning it on runs one pass so
    /// the first effect doesn't wait for the hourly one.
    private var optimizeStorageRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(localizedCatalogString(NoteAudioOffloadCopy.toggleKey))
                    .font(.body.weight(.semibold))
                Text(localizedCatalogString(controller.isEnabled
                    ? NoteAudioOffloadCopy.detailKey
                    : NoteAudioOffloadCopy.needsSyncKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle(isOn: optimizeStorageBinding) {
                Text(localizedCatalogString(NoteAudioOffloadCopy.toggleKey))
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(!controller.isEnabled || isTurningOff || controller.isTurningOn
                || downloadThenDelete.isRunning)
        }
    }

    /// Download, Then Delete running: how far it got, and Cancel until the
    /// delete begins.
    @ViewBuilder
    private var downloadThenDeleteRow: some View {
        switch downloadThenDelete.phase {
        case .idle:
            EmptyView()
        case .downloading(let done, let total, let current):
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(localizedCatalogFormat(NoteAudioICloudDeleteCopy.progressFormatKey, done + 1, total))
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                Spacer(minLength: 0)
                Button("Cancel") {
                    downloadThenDelete.cancel()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            DownloadThenDeleteProgressBar(
                feed: appState.noteAudioDownloader.progressFeed,
                done: done,
                total: total,
                current: current
            )
            Text(localizedCatalogString(NoteAudioICloudDeleteCopy.progressDetailKey))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .checking:
            // Fetching from iCloud before the list is read; Cancel still works.
            HStack(alignment: .center, spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Turn Off and Delete from iCloud"))
                Spacer(minLength: 0)
                Button("Cancel") {
                    downloadThenDelete.cancel()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        case .deleting:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(Text("Turn Off and Delete from iCloud"))
        }
    }

    private var recordingsOnlyInICloudTitle: String {
        guard let recordings = audioOnlyInICloud, !recordings.isEmpty else { return "" }
        let summary = NoteAudioICloudOnlySummary(markerBytes: recordings.map(\.bytes))
        let size = sizeText(summary.bytes)
        let key = NoteAudioICloudDeleteCopy.titleFormatKey(count: summary.count)
        return summary.count == 1
            ? localizedCatalogFormat(key, size)
            : localizedCatalogFormat(key, summary.count, size)
    }

    private var isShowingDownloadThenDeleteNotice: Binding<Bool> {
        Binding(
            get: {
                switch downloadThenDelete.notice {
                case .notEnoughSpace?, .downloadFailed?, .cannotCheck?, .syncPaused?:
                    return true
                default:
                    return false
                }
            },
            set: { if !$0 { downloadThenDelete.dismissNotice() } }
        )
    }

    private var downloadThenDeleteNoticeTitle: String {
        switch downloadThenDelete.notice {
        case .notEnoughSpace?:
            return localizedCatalogString(NoteAudioICloudDeleteCopy.notEnoughSpaceTitleKey)
        case .syncPaused?:
            return localizedCatalogString(NoteAudioICloudDeleteCopy.syncPausedTitleKey)
        default:
            return localizedCatalogString(NoteAudioICloudDeleteCopy.downloadFailedTitleKey)
        }
    }

    private var downloadThenDeleteNoticeMessage: String {
        switch downloadThenDelete.notice {
        case .notEnoughSpace(let shortBy)?:
            return localizedCatalogFormat(NoteAudioICloudDeleteCopy.notEnoughSpaceMessageFormatKey, sizeText(shortBy))
        case .cannotCheck?:
            return localizedCatalogString(NoteAudioICloudDeleteCopy.cannotCheckMessageKey)
        case .syncPaused?:
            return localizedCatalogString(NoteAudioICloudDeleteCopy.syncPausedMessageKey)
        default:
            return localizedCatalogString(NoteAudioICloudDeleteCopy.downloadFailedMessageKey)
        }
    }

    private func showDeleteFailure(_ notice: NoteAudioDownloadThenDelete.Outcome?) {
        guard notice == .deleteFailed else { return }
        downloadThenDelete.dismissNotice()
        turnOffFailed = true
    }

    private func sizeText(_ bytes: Int64) -> String {
        NoteAudioICloudDeletePolicy.sizeText(
            bytes: bytes,
            locale: Locale(identifier: preferredLocalizedStringLanguage())
        )
    }

    private var optimizeStorageBinding: Binding<Bool> {
        Binding(
            get: { optimizesStorage },
            set: { wantsOn in
                optimizesStorage = wantsOn
                if wantsOn { appState.removeUnusedNoteAudio() }
            }
        )
    }

    private var isShowingTurnOnFailure: Binding<Bool> {
        Binding(
            get: { turnOnFailure != nil },
            set: { if !$0 { turnOnFailure = nil } }
        )
    }

    private var title: some View {
        Text("Sync this Mac's notes with iCloud")
            .font(.body.weight(.semibold))
    }

    private var turnOnMessage: LocalizedStringKey {
        noteCount == 1
            ? "Upload 1 note from this Mac to iCloud. Notes from your other devices download too, and the lists merge into one."
            : "Upload \(noteCount) notes from this Mac to iCloud. Notes from your other devices download too, and the lists merge into one."
    }

    private var audioSizeText: Text {
        guard audioBytes > 0 else { return Text("") }
        let size = ByteCountFormatter.string(fromByteCount: audioBytes, countStyle: .file)
        return Text(" ") + Text("This includes \(size) of audio.")
    }

    private var audioOnlyInICloudText: Text {
        // Recordings only in iCloud are asked about after the button is pressed.
        guard audioOnlyInICloud == nil else { return Text("") }
        return Text("\n\n") + Text("Note history can't be opened, so Quill can't check which audio is only in iCloud. Turn Off and Delete from iCloud may delete audio that isn't on this Mac.")
    }

    /// Sync Now shows while sync runs, not after it stopped.
    private var showsSyncNow: Bool {
        guard controller.isEnabled, controller.unavailableReason == nil else { return false }
        switch controller.status {
        case .paused(.accountChanged), .paused(.signedOut), .paused(.deletedElsewhere), .paused(.historyUnavailable), .off:
            return false
        default:
            return true
        }
    }

    /// With recordings only in iCloud, asks whether to download them first;
    /// otherwise deletes as before. Read again here: the storage pass may
    /// have made a recording iCloud-only while the dialog was open.
    private func deleteFromICloudPressed() {
        audioOnlyInICloud = controller.recordingsOnlyInICloud
        guard let recordings = audioOnlyInICloud, !recordings.isEmpty else {
            turnOff(deleteFromICloud: true)
            return
        }
        // The dialog is still closing; an alert presented in the same turn
        // can be dropped.
        DispatchQueue.main.async {
            isAskingAboutRecordings = true
        }
    }

    private func turnOff(deleteFromICloud: Bool) {
        isTurningOff = true
        Task { @MainActor in
            let succeeded = await controller.turnOff(deleteFromICloud: deleteFromICloud)
            isTurningOff = false
            if !succeeded { turnOffFailed = true }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch controller.unavailableReason {
        case .requiresMacOS14?:
            Text("iCloud sync needs macOS 14 or later")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .buildWithoutICloud?:
            Text("This build doesn't support iCloud sync")
                .font(.caption)
                .foregroundStyle(.secondary)
        case nil:
            availableStatusLine
        }
    }

    @ViewBuilder
    private var availableStatusLine: some View {
        switch controller.status {
        case .off:
            EmptyView()
        case .starting:
            Text("Checking iCloud…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .uploading(let done, let total):
            Text("Uploading · \(done) of \(total) notes")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        case .upToDate(let date):
            TimelineView(.periodic(from: .now, by: 30)) { context in
                // Without the note count, as on the iPhone (decision y3).
                Label {
                    Text("Up to date · \(NoteSyncStatusText.relativeTime(date, now: context.date))")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .font(.caption)
                .foregroundStyle(QuillColor.statusDone)
            }
        case .paused(.offline):
            Text("Paused · Syncs again when you're online")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .paused(.quotaExceeded):
            Text("iCloud storage is full, so uploads are paused")
                .font(.caption)
                .foregroundStyle(QuillColor.issueWarning)
        case .paused(.accountNeedsAttention):
            Text("iCloud account needs attention")
                .font(.caption)
                .foregroundStyle(QuillColor.issueWarning)
        case .paused(.accountChanged):
            Text("Sync stopped because the iCloud account changed")
                .font(.caption)
                .foregroundStyle(QuillColor.issueWarning)
        case .paused(.signedOut):
            Text("Sync stopped because you signed out of iCloud")
                .font(.caption)
                .foregroundStyle(QuillColor.issueWarning)
        case .paused(.deletedElsewhere):
            Text("iCloud data was deleted from another device, so sync stopped")
                .font(.caption)
                .foregroundStyle(QuillColor.issueWarning)
        case .paused(.notesFailed(let count, _)):
            Text(count == 1 ? "1 note couldn't sync" : "\(count) notes couldn't sync")
                .font(.caption)
                .foregroundStyle(QuillColor.issueWarning)
        case .paused(.couldNotSaveHere):
            Text("Notes couldn't be saved on this Mac, so sync paused")
                .font(.caption)
                .foregroundStyle(QuillColor.issueWarning)
        case .paused(.historyUnavailable):
            Text("Note history couldn't be opened, so sync paused")
                .font(.caption)
                .foregroundStyle(QuillColor.issueWarning)
        }
    }

    @ViewBuilder
    private var statusDetail: some View {
        if controller.unavailableReason == nil {
            switch controller.status {
            case .uploading(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("You can keep using Quill while it uploads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .paused(.offline):
                Text("Notes on this Mac still work as usual.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .paused(.quotaExceeded):
                Text("Some notes are still only on this Mac. Uploading continues when there's space.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Manage iCloud Storage…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings?iCloud") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            case .paused(.accountNeedsAttention):
                Text("Check the Apple Account notice in System Settings to continue syncing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            case .paused(.accountChanged):
                Text("Your notes weren't deleted. Turn sync on again to continue with the new account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .paused(.signedOut):
                Text("Your notes weren't deleted. Sign in to iCloud, then turn sync on again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .paused(.deletedElsewhere):
                Text("Notes on this Mac weren't deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .paused(.notesFailed(_, let willRetry)):
                Text(willRetry
                     ? "It will try again automatically. These notes are still on this Mac."
                     : "These notes are still on this Mac. Edit a note or click ↻ to try again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .paused(.couldNotSaveHere):
                Text("Check this Mac's free space, then click ↻ to try again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .paused(.historyUnavailable):
                Text("Syncing continues once note history opens again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .off, .starting, .upToDate:
                EmptyView()
            }
        }
    }
}

/// The download bar on its own, so the card doesn't redraw with every part.
private struct DownloadThenDeleteProgressBar: View {
    @ObservedObject var feed: NoteAudioDownloadProgress
    let done: Int
    let total: Int
    let current: UUID

    var body: some View {
        let fraction = (Double(done) + (feed.values[current] ?? 0)) / Double(max(total, 1))
        ProgressView(value: min(max(fraction, 0), 1))
    }
}
