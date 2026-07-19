import Foundation

@MainActor
final class CloudTranscriptionHistoryCoordinator {
    private(set) var activeTasks: [UUID: Task<Void, Never>] = [:]
    private(set) var progress: [UUID: CloudTranscriptionDisplayProgress] = [:]

    private var activeSessions: [UUID: CloudTranscriptionJobSession] = [:]

    func install(
        task: Task<Void, Never>,
        historyID: UUID,
        session: CloudTranscriptionJobSession
    ) {
        guard session.historyID == historyID else {
            task.cancel()
            return
        }
        if activeSessions[historyID] == session {
            task.cancel()
            return
        }
        activeTasks[historyID]?.cancel()
        activeTasks[historyID] = task
        activeSessions[historyID] = session
        progress.removeValue(forKey: historyID)
    }

    func activeSession(historyID: UUID) -> CloudTranscriptionJobSession? {
        activeSessions[historyID]
    }

    func updateProgress(
        _ progress: CloudTranscriptionDisplayProgress,
        historyID: UUID,
        session: CloudTranscriptionJobSession
    ) {
        guard activeSessions[historyID] == session else { return }
        self.progress[historyID] = progress
    }

    func finish(
        historyID: UUID,
        session: CloudTranscriptionJobSession
    ) {
        guard activeSessions[historyID] == session else { return }
        activeTasks.removeValue(forKey: historyID)
        activeSessions.removeValue(forKey: historyID)
        progress.removeValue(forKey: historyID)
    }

    func cancelAndInvalidate(
        historyID: UUID,
        store: CloudTranscriptionJobStore
    ) {
        activeTasks.removeValue(forKey: historyID)?.cancel()
        activeSessions.removeValue(forKey: historyID)
        store.invalidateSession(historyID: historyID)
        progress.removeValue(forKey: historyID)
    }

    func cancelAndInvalidateAll(store: CloudTranscriptionJobStore) {
        for historyID in Array(activeSessions.keys) {
            cancelAndInvalidate(historyID: historyID, store: store)
        }
    }
}
