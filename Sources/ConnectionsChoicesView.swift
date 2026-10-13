import SwiftUI

enum ConnectionsChoices {
    /// Set once setup finishes or an existing user closes "New settings".
    static let seenStorageKey = "connections_choices_seen"

    /// What the user picked. Both apply together when setup finishes or
    /// the New settings window closes, never while choosing.
    struct Selection: Equatable {
        var wantsICloudSync = false
        var wantsMCP = false
        /// The AI tools switch when the choices opened; only a change is
        /// applied, so a switch flipped in Settings meanwhile stays.
        var mcpWasOn = false
    }

    /// The iCloud sync consent sentence about calendar events, shared by
    /// setup, New settings, and Settings › iCloud Sync.
    static let iCloudCalendarDisclosure: LocalizedStringKey = "Calendar events matched to notes (title, times, calendar and event IDs, your calendar account's email, and each attendee's name, email, response, and whether they're optional or you) are stored in your private iCloud too."

    /// What a connected AI tool receives: the consent text for every
    /// AI tools switch (setup, New settings, Settings › AI Tools).
    static let mcpDisclosure: LocalizedStringKey = "A connected AI tool can start and stop recordings, add notes to a recording, and read your notes. It receives their titles, transcripts (original and edited), summaries, recording times, the app context Quill noted while recording, audio file locations, and matched calendar events (title, times, and each attendee's name, email, response, and whether they're optional, a room, or you), and gets each new transcript as soon as it's ready. Quill passes this so the tool you connect can work with your notes, not to train AI. Once the tool has it, its provider's terms apply, including whether it trains on it, so check your AI tool's data settings."
}

/// The New settings window's choices, kept outside the view so closing
/// the window applies them as Done does.
@MainActor
final class ConnectionsChoicesModel: ObservableObject {
    @Published var selection: ConnectionsChoices.Selection

    init(selection: ConnectionsChoices.Selection) {
        self.selection = selection
    }
}

/// iCloud sync and AI tools (MCP), both off until the user turns them on.
/// What each one shares is shown next to its switch the whole time, so
/// turning a switch on is the consent (#530). Used by the setup step and
/// by the one-time "New settings" window existing users see.
struct ConnectionsChoicesView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selection: ConnectionsChoices.Selection
    /// Existing users who had AI tools connect are told the switch now
    /// starts off.
    var showsMCPChangeNote = false

    var body: some View {
        VStack(spacing: 14) {
            if let controller = appState.noteSyncController, controller.unavailableReason == nil {
                ConnectionsSyncCard(controller: controller, wantsICloudSync: $selection.wantsICloudSync)
            }
            mcpCard
        }
    }

    private var mcpCard: some View {
        ConnectionsCard(icon: "link", title: "AI Tool Connection (MCP)", isOn: $selection.wantsMCP) {
            Text(ConnectionsChoices.mcpDisclosure)
            if showsMCPChangeNote {
                Text("Until now AI tools could always connect; from this version the switch starts off. If you used Claude Code with Quill, turn it back on.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ConnectionsSyncCard: View {
    @ObservedObject var controller: NoteSyncController
    @Binding var wantsICloudSync: Bool
    /// Counted once when the switch goes on, as Settings does; reading
    /// every note on each redraw would be slow.
    @State private var noteCount = 0
    @State private var audioBytes: Int64 = 0

    /// What turning it on uploads. Hidden until there is something to
    /// count; right after launch the note store may still be loading.
    @ViewBuilder
    private var uploadSize: some View {
        if wantsICloudSync, noteCount > 0 {
            let size = ByteCountFormatter.string(fromByteCount: audioBytes, countStyle: .file)
            switch (noteCount == 1, audioBytes > 0) {
            case (true, false):
                Text("This uploads 1 note from this Mac.")
            case (true, true):
                Text("This uploads 1 note from this Mac, including \(size) of audio.")
            case (false, false):
                Text("This uploads \(noteCount) notes from this Mac.")
            case (false, true):
                Text("This uploads \(noteCount) notes from this Mac, including \(size) of audio.")
            }
        }
    }

    var body: some View {
        ConnectionsCard(
            icon: "icloud",
            title: "iCloud Sync",
            isOn: controller.isEnabled ? .constant(true) : $wantsICloudSync,
            isDisabled: controller.isEnabled
        ) {
            Text("Keeps your notes the same on your Macs with this iCloud account. Notes and audio are stored only in your private iCloud.")
            if !controller.isEnabled {
                uploadSize
            }
            Text(ConnectionsChoices.iCloudCalendarDisclosure)
            Text("Screenshots, window titles, selected text, and AI instructions aren't uploaded.")
        }
        .onChange(of: wantsICloudSync) { wants in
            guard wants else { return }
            noteCount = controller.syncableNoteCount
            audioBytes = controller.uploadAudioByteCount
        }
    }
}

private struct ConnectionsCard<Details: View>: View {
    let icon: String
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    var isDisabled = false
    @ViewBuilder let details: Details

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Toggle(isOn: $isOn) {
                    Text(title)
                        .font(.headline)
                }
                .toggleStyle(.switch)
                .disabled(isDisabled)
            }
            VStack(alignment: .leading, spacing: 6) {
                details
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 36)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }
}

/// The one-time window existing users get after updating: only the two
/// new switches, leaving their other settings and shortcuts as they are.
struct NewSettingsView: View {
    @ObservedObject var model: ConnectionsChoicesModel
    var showsMCPChangeNote: Bool
    var onDone: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("New settings")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .accessibilityAddTraits(.isHeader)
                        Text("From this version, these work only after you turn them on. Your other settings stay as they are.")
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ConnectionsChoicesView(selection: $model.selection, showsMCPChangeNote: showsMCPChangeNote)
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(32)
            }

            Divider()

            HStack {
                Text("You can change these later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 560, minHeight: 520)
    }
}
