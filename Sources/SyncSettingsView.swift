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
    @State private var noteCount = 0

    private var switchBinding: Binding<Bool> {
        Binding(
            get: { controller.isEnabled },
            set: { wantsOn in
                if wantsOn {
                    noteCount = controller.syncableNoteCount
                    isConfirmingTurnOn = true
                } else {
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
                Toggle(isOn: switchBinding) {
                    Text("Sync this Mac's notes with iCloud")
                }
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(controller.unavailableReason != nil || isTurningOff)
            }

            statusDetail

            // What goes to iCloud, then what stays here, one sentence pair
            // per line so lines break where the thought does.
            VStack(alignment: .leading, spacing: 8) {
                Text("Notes, transcripts, and summaries are saved to your iCloud. They appear on your other Macs with the same iCloud account.")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screenshots and window details stay on this Mac.")
                    Text("Settings, vocabulary, and API keys don't sync. Each Mac keeps its own.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if controller.isEnabled {
                Text(noteCountText(controller.syncableNoteCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .alert("Turn on iCloud sync?", isPresented: $isConfirmingTurnOn) {
            Button("Cancel", role: .cancel) {}
            Button("Turn On and Upload") {
                controller.turnOn()
            }
        } message: {
            Text(turnOnMessage) + Text("\n\n") + Text("Screenshots, window titles, selected text, and AI instructions aren't uploaded. You can keep using Quill while it uploads.")
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
            Text("Notes on this Mac stay. Turn Off Sync keeps notes in iCloud for your other Macs. Turn Off and Delete from iCloud deletes all Quill data in iCloud: sync stops on every Mac, and each Mac keeps its notes.")
        }
        .alert("Couldn't delete from iCloud", isPresented: $turnOffFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check your internet connection and try again. Sync is still on.")
        }
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

    private func noteCountText(_ count: Int) -> LocalizedStringKey {
        count == 1 ? "1 note" : "\(count) notes"
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
                    Text("Up to date · \(Self.relativeTime(date, now: context.date))")
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
            case .off, .starting, .upToDate:
                EmptyView()
            }
        }
    }

    /// "Just now" for the first minute, then "3 min. ago" and so on; a sync
    /// that just finished never reads "in 0 seconds".
    private static func relativeTime(_ date: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return localizedCatalogString("Just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
