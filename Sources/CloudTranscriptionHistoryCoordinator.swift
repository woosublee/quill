import Foundation

struct CloudTranscriptionLocalRetryRunner {
    let store: CloudTranscriptionJobStore
    let historyID: UUID
    let session: CloudTranscriptionJobSession

    func run(
        sourceURL: URL,
        transcribe: (URL) throws -> String,
        saveHistory: (String) throws -> Void
    ) throws {
        let transcript = try transcribe(sourceURL)
        try saveHistory(transcript)
        try store.deleteCompletedJob(
            historyID: historyID,
            session: session
        )
    }
}

struct CloudTranscriptionHistoryCommitter {
    let store: CloudTranscriptionJobStore
    let session: CloudTranscriptionJobSession

    func commit(
        historyID: UUID,
        saveHistory: () throws -> Void
    ) throws {
        try saveHistory()
        try store.deleteCompletedJob(
            historyID: historyID,
            session: session
        )
    }
}

@MainActor
final class CloudTranscriptionHistoryCoordinator {
    private(set) var activeTasks: [UUID: Task<Void, Never>] = [:]
    private(set) var progress: [UUID: CloudTranscriptionDisplayProgress] = [:]

    private var activeSessions: [UUID: CloudTranscriptionJobSession] = [:]

    func activate(
        historyID: UUID,
        session: CloudTranscriptionJobSession
    ) {
        guard session.historyID == historyID else { return }
        if activeSessions[historyID] != session {
            activeTasks.removeValue(forKey: historyID)?.cancel()
            progress.removeValue(forKey: historyID)
        }
        activeSessions[historyID] = session
    }

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
            guard activeTasks[historyID] == nil else {
                task.cancel()
                return
            }
            activeTasks[historyID] = task
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

    func context(
        historyID: UUID,
        store: CloudTranscriptionJobStore
    ) -> CloudTranscriptionExecutionContext? {
        guard let session = activeSessions[historyID] else { return nil }
        return CloudTranscriptionExecutionContext(
            historyID: historyID,
            session: session,
            checkpointStore: store.checkpointStore(session: session),
            progress: { _ in }
        )
    }

    @discardableResult
    func updateProgress(
        _ progress: CloudTranscriptionDisplayProgress,
        historyID: UUID,
        session: CloudTranscriptionJobSession
    ) -> Bool {
        guard activeSessions[historyID] == session else { return false }
        self.progress[historyID] = progress
        return true
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
