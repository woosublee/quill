import AppKit
import SwiftUI

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
                    NoteSyncSettingsCard(controller: controller)
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
    @ObservedObject var controller: NoteSyncController
    @State private var isConfirmingTurnOn = false
    @State private var isConfirmingTurnOff = false
    @State private var isTurningOff = false
    @State private var turnOffFailed = false
    @State private var turnOnFailure: NoteSyncTurnOnFailure?
    @State private var noteCount = 0
    @State private var audioBytes: Int64 = 0
    @State private var audioOnlyInICloud = 0

    private var switchBinding: Binding<Bool> {
        Binding(
            get: { controller.isEnabled },
            set: { wantsOn in
                if wantsOn {
                    noteCount = controller.syncableNoteCount
                    audioBytes = controller.uploadAudioByteCount
                    isConfirmingTurnOn = true
                } else {
                    audioOnlyInICloud = controller.notesWithAudioOnlyInICloud
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
                .disabled(controller.unavailableReason != nil || isTurningOff || controller.isTurningOn)
            }

            statusDetail

            // What goes to iCloud is said once, when turning on.
            if !controller.isEnabled, controller.unavailableReason == nil {
                Text("Keeps your notes the same on your Macs with this iCloud account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                turnOff(deleteFromICloud: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Notes on this Mac stay. Turn Off Sync keeps notes in iCloud for your other Macs. Turn Off and Delete from iCloud deletes all Quill data in iCloud: sync stops on every Mac, and each Mac keeps its notes.") + audioOnlyInICloudText
        }
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
            Text("Check your internet connection and try again. Sync is still on.")
        }
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
            ? "Upload 1 note from this Mac to iCloud. Notes from your other Macs download too, and the lists merge into one."
            : "Upload \(noteCount) notes from this Mac to iCloud. Notes from your other Macs download too, and the lists merge into one."
    }

    private var audioSizeText: Text {
        guard audioBytes > 0 else { return Text("") }
        let size = ByteCountFormatter.string(fromByteCount: audioBytes, countStyle: .file)
        return Text(" ") + Text("This includes \(size) of audio.")
    }

    private var audioOnlyInICloudText: Text {
        switch audioOnlyInICloud {
        case 0:
            return Text("")
        case 1:
            return Text("\n\n") + Text("1 note has audio in iCloud that isn't on this Mac. After Turn Off and Delete from iCloud, this Mac can't get it.")
        default:
            return Text("\n\n") + Text("\(audioOnlyInICloud) notes have audio in iCloud that isn't on this Mac. After Turn Off and Delete from iCloud, this Mac can't get it.")
        }
    }

    private func noteCountText(_ count: Int) -> LocalizedStringKey {
        count == 1 ? "1 note" : "\(count) notes"
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
                Label {
                    Text("Up to date · \(NoteSyncStatusText.relativeTime(date, now: context.date))")
                        + Text(verbatim: " · ") + Text(noteCountText(controller.syncableNoteCount))
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .font(.caption)
                .foregroundStyle(.green)
            }
        case .paused(.offline):
            Text("Paused · Syncs again when you're online")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .paused(.quotaExceeded):
            Text("iCloud storage is full, so uploads are paused")
                .font(.caption)
                .foregroundStyle(.orange)
        case .paused(.accountNeedsAttention):
            Text("iCloud account needs attention")
                .font(.caption)
                .foregroundStyle(.orange)
        case .paused(.accountChanged):
            Text("Sync stopped because the iCloud account changed")
                .font(.caption)
                .foregroundStyle(.orange)
        case .paused(.signedOut):
            Text("Sync stopped because you signed out of iCloud")
                .font(.caption)
                .foregroundStyle(.orange)
        case .paused(.deletedElsewhere):
            Text("iCloud data was deleted from another Mac, so sync stopped")
                .font(.caption)
                .foregroundStyle(.orange)
        case .paused(.notesFailed(let count, _)):
            Text(count == 1 ? "1 note couldn't sync" : "\(count) notes couldn't sync")
                .font(.caption)
                .foregroundStyle(.orange)
        case .paused(.couldNotSaveHere):
            Text("Notes couldn't be saved on this Mac, so sync paused")
                .font(.caption)
                .foregroundStyle(.orange)
        case .paused(.historyUnavailable):
            Text("Note history couldn't be opened, so sync paused")
                .font(.caption)
                .foregroundStyle(.orange)
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
                     ? "It will try again shortly. These notes are still on this Mac."
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
