import AppKit
import Combine
import SwiftUI

struct HistoryUnavailableRecoveryActions: View {
    @EnvironmentObject private var appState: AppState
    @State private var showsRecoveryArchiveConfirmation = false
    @State private var showsFreshArchiveConfirmation = false

    var body: some View {
        Group {
            if appState.isHistoryArchiveTransitioning {
                ProgressView("Archiving recording history…")
                    .controlSize(.small)
            } else {
                HStack(spacing: 10) {
                    Button("Open Data Folder") {
                        appState.openHistoryDataFolder()
                    }
                    if appState.historyArchiveSafety != .unresolvedInterruptedTransaction {
                        Button("Recover Earlier History…") {
                            showsRecoveryArchiveConfirmation = true
                        }
                        .disabled(!appState.isHistoryUnavailable)
                        Button("Start Fresh…") {
                            showsFreshArchiveConfirmation = true
                        }
                        .disabled(!appState.isHistoryUnavailable)
                    }
                    Button("Quit Quill") {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
        .confirmationDialog(
            "Archive old history and open Recovery?",
            isPresented: $showsRecoveryArchiveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Archive and Open Recovery", role: .destructive) {
                _ = appState.archiveOldHistoryAndStartFresh(postAction: .openRecovery)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Quill will preserve the original database, audio, transcripts, and recovery metadata in a recovery snapshot. It will then start a new history and open Recovery settings. Your earlier notes are not imported automatically."
            )
        }
        .confirmationDialog(
            "Archive old history and start fresh?",
            isPresented: $showsFreshArchiveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Archive and Start Fresh", role: .destructive) {
                _ = appState.archiveOldHistoryAndStartFresh(postAction: .startFresh)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Quill will preserve the original database, audio, transcripts, and recovery metadata in a recovery snapshot. It will then start a separate new history. You can import earlier notes later from Recovery settings."
            )
        }
    }
}

struct HistoryRecoverySettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var snapshotPendingDeletion: HistoryRecoverySnapshotDescriptor?

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        SettingsPageScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Recovery")
                    .font(.title2.weight(.semibold))

                RecentlyDeletedNotesSection()

                // Archived histories appear only after a fresh start from
                // protected mode, so the section shows only when there are some.
                if !appState.historyRecoverySnapshots.isEmpty {
                    Text("Review archived histories before importing them into the current history.")
                        .foregroundStyle(.secondary)
                    ForEach(appState.historyRecoverySnapshots) { snapshot in
                        snapshotCard(snapshot)
                    }
                }
            }
            .padding(24)
        }
        .overlay {
            if appState.isHistoryRecoveryOperationInProgress {
                ProgressView(appState.historyRecoveryOperationMessage ?? "Recovering history…")
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .onAppear {
            appState.refreshHistoryRecoverySnapshots()
            appState.ensureHistoryRecoveryInspection()
        }
        .onReceive(appState.$pipelineHistory.dropFirst()) { _ in
            appState.invalidateHistoryRecoveryInspectionResults()
        }
        // Inspection compares against Recently Deleted notes too.
        .onReceive(appState.$recentlyDeletedNotes.dropFirst()) { _ in
            appState.invalidateHistoryRecoveryInspectionResults()
        }
        .confirmationDialog(
            "Delete recovery snapshot?",
            isPresented: Binding(
                get: { snapshotPendingDeletion != nil },
                set: { if !$0 { snapshotPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Recovery Snapshot", role: .destructive) {
                if let snapshotPendingDeletion {
                    _ = appState.deleteHistoryRecoverySnapshot(id: snapshotPendingDeletion.id)
                }
                snapshotPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                snapshotPendingDeletion = nil
            }
        } message: {
            Text("This permanently deletes the archived history and its recovery progress. This cannot be undone.")
        }
    }

    @ViewBuilder
    private func snapshotCard(_ snapshot: HistoryRecoverySnapshotDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.snapshot.archivedAt, style: .date)
                        .font(.headline)
                    Text(Self.byteCountFormatter.string(fromByteCount: Int64(snapshot.payloadByteCount)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(statusTitle(for: snapshot))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor(for: snapshot))
            }

            if snapshot.integrity == .invalid {
                Text("This recovery snapshot could not be verified. It is preserved and can only be deleted manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if snapshot.status == .inspectionFailed {
                Text("This recovery snapshot could not be read. The original files are preserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let inspection = appState.historyRecoveryInspections[snapshot.id] {
                inspectionSummary(inspection)
            } else if appState.historyRecoveryInspectionSnapshotID == snapshot.id {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking recovery contents…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Checking recovery contents…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let importResult = appState.historyRecoveryImportResult,
               importResult.snapshotID == snapshot.id,
               importResult.failedRecordCount > 0 || importResult.conflictRecordCount > 0 {
                Text(localizedCatalogString("Some history could not be recovered."))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let deletionDate = snapshot.scheduledDeletionAt {
                Text(
                    localizedCatalogFormat(
                        "Scheduled for deletion on %@.",
                        deletionDate.formatted(date: .abbreviated, time: .shortened)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if snapshot.integrity == .ready,
                   snapshot.status == .inspectionFailed {
                    Button("Retry Inspection") {
                        _ = appState.retryHistoryRecoveryInspection(id: snapshot.id)
                    }
                    .disabled(
                        appState.isHistoryRecoveryOperationInProgress
                            || appState.historyRecoveryInspectionSnapshotID != nil
                    )
                }

                if let inspection = appState.historyRecoveryInspections[snapshot.id],
                   snapshot.status != .completed {
                    Button(
                        localizedRecoveryRecordCount(
                            inspection.importableRecordCount,
                            singularKey: "Import %lld record…",
                            pluralKey: "Import %lld records…"
                        )
                    ) {
                        _ = appState.importHistoryRecoverySnapshot(id: snapshot.id)
                    }
                    .disabled(appState.isHistoryRecoveryOperationInProgress)
                }

                Button("Open Recovery Folder") {
                    appState.openHistoryRecoveryFolder()
                }
                .disabled(appState.isHistoryRecoveryOperationInProgress)

                Spacer()

                if snapshot.integrity == .ready, snapshot.scheduledDeletionAt != nil {
                    Button("Cancel Scheduled Deletion") {
                        _ = appState.cancelHistoryRecoveryScheduledDeletion(id: snapshot.id)
                    }
                    .disabled(
                        appState.isHistoryRecoveryOperationInProgress
                            || appState.historyRecoveryInspectionSnapshotID != nil
                    )
                    Button("Delete Now", role: .destructive) {
                        snapshotPendingDeletion = snapshot
                    }
                    .disabled(
                        appState.isHistoryRecoveryOperationInProgress
                            || appState.historyRecoveryInspectionSnapshotID != nil
                    )
                } else {
                    Button("Delete Recovery Snapshot…", role: .destructive) {
                        snapshotPendingDeletion = snapshot
                    }
                    .disabled(
                        appState.isHistoryRecoveryOperationInProgress
                            || appState.historyRecoveryInspectionSnapshotID != nil
                    )
                }
            }
            .controlSize(.small)
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

    @ViewBuilder
    private func inspectionSummary(_ inspection: HistoryRecoveryInspection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(
                localizedRecoveryRecordCount(
                    inspection.readableRecordCount,
                    singularKey: "%lld record found.",
                    pluralKey: "%lld records found."
                )
            )
            Text(
                localizedRecoveryRecordCount(
                    inspection.importableRecordCount,
                    singularKey: "%lld record is ready to import.",
                    pluralKey: "%lld records are ready to import."
                )
            )
            if inspection.alreadyPresentRecordCount > 0 {
                Text(
                    localizedRecoveryRecordCount(
                        inspection.alreadyPresentRecordCount,
                        singularKey: "%lld record is already in the current history.",
                        pluralKey: "%lld records are already in the current history."
                    )
                )
            }
            if inspection.conflictRecordCount > 0 {
                Text(
                    localizedRecoveryRecordCount(
                        inspection.conflictRecordCount,
                        singularKey: "%lld record conflicts with the current history.",
                        pluralKey: "%lld records conflict with the current history."
                    )
                )
                .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func localizedRecoveryRecordCount(
        _ count: Int,
        singularKey: String,
        pluralKey: String
    ) -> String {
        localizedCatalogFormat(count == 1 ? singularKey : pluralKey, count)
    }

    private func statusTitle(for snapshot: HistoryRecoverySnapshotDescriptor) -> LocalizedStringKey {
        guard snapshot.integrity == .ready else { return "Needs Attention" }
        switch snapshot.status {
        case .available:
            return "Available"
        case .partial:
            return "Partially Recovered"
        case .completed:
            return "Recovery Complete"
        case .inspectionFailed:
            return "Unable to Inspect"
        }
    }

    private func statusColor(for snapshot: HistoryRecoverySnapshotDescriptor) -> Color {
        guard snapshot.integrity == .ready else { return .orange }
        switch snapshot.status {
        case .available:
            return .secondary
        case .partial, .inspectionFailed:
            return .orange
        case .completed:
            return .green
        }
    }
}
