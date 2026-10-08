import SwiftUI

/// Settings › Recovery: deleted notes waiting out their 30 days.
struct RecentlyDeletedNotesSection: View {
    @EnvironmentObject private var appState: AppState
    /// Notes restored from this section, in the order they were restored.
    @State private var restoredNotes: [PipelineHistoryItem] = []
    @State private var pendingDeleteNow: PipelineHistoryItem?

    /// Restored rows, minus any note that was deleted again since.
    private var visibleRestoredNotes: [PipelineHistoryItem] {
        restoredNotes.filter { note in
            !appState.recentlyDeletedNotes.contains { $0.id == note.id }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recently Deleted Notes")
                    .font(.headline)
                Spacer()
                if !appState.recentlyDeletedNotes.isEmpty {
                    Text(verbatim: "\(appState.recentlyDeletedNotes.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Text("Deleted notes stay here for 30 days, then they're removed for good.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if appState.recentlyDeletedNotes.isEmpty && visibleRestoredNotes.isEmpty {
                Text("No recently deleted notes")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(appState.recentlyDeletedNotes, id: \.id) { note in
                        deletedRow(note)
                        Divider()
                    }
                    ForEach(visibleRestoredNotes, id: \.id) { note in
                        restoredRow(note)
                        Divider()
                    }
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        .onAppear { appState.purgeExpiredRecentlyDeletedNotes() }
        .confirmationDialog(
            "Delete this note now?",
            isPresented: Binding(
                get: { pendingDeleteNow != nil },
                set: { if !$0 { pendingDeleteNow = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Now", role: .destructive) {
                if let note = pendingDeleteNow {
                    appState.deleteRecentlyDeletedNoteNow(id: note.id)
                }
                pendingDeleteNow = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteNow = nil }
        } message: {
            Text("Its audio and transcript are removed too. This can't be undone.")
        }
    }

    private func deletedRow(_ note: PipelineHistoryItem) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: NoteTitleResolver.displayTitle(for: note))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(verbatim: preview(note))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if let deletedAt = note.deletedAt {
                let days = RecentlyDeletedPolicy.daysLeft(deletedAt: deletedAt, now: Date())
                Text(days == 1
                    ? localizedCatalogString("1 day left")
                    : localizedCatalogFormat("%lld days left", Int64(days)))
                    .font(.system(size: 11))
                    .foregroundStyle(days <= 1 ? Color.orange : Color.secondary)
                    .monospacedDigit()
            }
            Button("Restore") {
                appState.restoreRecentlyDeletedNote(id: note.id)
                if !appState.recentlyDeletedNotes.contains(where: { $0.id == note.id }),
                   !restoredNotes.contains(where: { $0.id == note.id }) {
                    restoredNotes.append(note)
                }
            }
            Button("Delete Now", role: .destructive) {
                pendingDeleteNow = note
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func restoredRow(_ note: PipelineHistoryItem) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: NoteTitleResolver.displayTitle(for: note))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text("Restored")
                .font(.system(size: 11))
                .foregroundStyle(.green)
            Button("Open Note") {
                appState.openNoteInBrowser(id: note.id)
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Recording date and the first line of the note, local only.
    private func preview(_ note: PipelineHistoryItem) -> String {
        let date = (note.recordingStartedAt ?? note.timestamp)
            .formatted(date: .abbreviated, time: .omitted)
        let text = note.postProcessedTranscript.isEmpty ? note.rawTranscript : note.postProcessedTranscript
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return firstLine.isEmpty ? date : "\(date) · \(firstLine)"
    }
}
