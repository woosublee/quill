import Foundation

@main
struct CloudTranscriptionHistoryCoordinatorTests {
    @MainActor
    static func main() async {
        do {
            try replacementCancelsOldTaskAndRejectsOldSession()
            try duplicateInstallForSameSessionKeepsOriginalTask()
            try staleProgressAndFinishCannotReplaceCurrentState()
            try activeSessionCheckRejectsReplacedAndCancelledSessions()
            try cancellationInvalidatesSessionAndClearsProgress()
            try cancelAllInvalidatesEverySession()
            try await cleanupAssetsCancelInvalidateAndRejectLateCheckpoint()
            print("CloudTranscriptionHistoryCoordinatorTests passed")
        } catch {
            fputs("CloudTranscriptionHistoryCoordinatorTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func replacementCancelsOldTaskAndRejectsOldSession() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let coordinator = CloudTranscriptionHistoryCoordinator()
        let record = makeRecord()
        let sessionA = fixture.store.beginSession(historyID: record.historyID)
        try fixture.store.create(record, session: sessionA)
        let taskA = suspendedTask()
        coordinator.install(
            task: taskA,
            historyID: record.historyID,
            session: sessionA
        )

        let sessionB = fixture.store.beginSession(historyID: record.historyID)
        let taskB = suspendedTask()
        coordinator.install(
            task: taskB,
            historyID: record.historyID,
            session: sessionB
        )

        try expect(taskA.isCancelled, "replacement cancels old task")
        try expect(!taskB.isCancelled, "replacement keeps new task")
        try expectEqual(
            coordinator.activeSession(historyID: record.historyID),
            sessionB,
            "replacement installs new session"
        )
        do {
            try fixture.store.update(record, session: sessionA)
            throw TestFailure("replacement must invalidate old store session")
        } catch CloudTranscriptionJobStoreError.staleSession {
            // expected
        }
        coordinator.cancelAndInvalidate(
            historyID: record.historyID,
            store: fixture.store
        )
    }

    @MainActor
    private static func duplicateInstallForSameSessionKeepsOriginalTask() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let coordinator = CloudTranscriptionHistoryCoordinator()
        let record = makeRecord()
        let session = fixture.store.beginSession(historyID: record.historyID)
        try fixture.store.create(record, session: session)
        let originalTask = suspendedTask()
        let duplicateTask = suspendedTask()

        coordinator.install(
            task: originalTask,
            historyID: record.historyID,
            session: session
        )
        coordinator.install(
            task: duplicateTask,
            historyID: record.historyID,
            session: session
        )

        try expect(!originalTask.isCancelled, "duplicate keeps original provider flow")
        try expect(duplicateTask.isCancelled, "duplicate provider flow is cancelled")
        try expect(
            coordinator.activeSession(historyID: record.historyID) == session,
            "duplicate keeps the active session"
        )
        coordinator.cancelAndInvalidate(
            historyID: record.historyID,
            store: fixture.store
        )
    }

    @MainActor
    private static func staleProgressAndFinishCannotReplaceCurrentState() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let coordinator = CloudTranscriptionHistoryCoordinator()
        let record = makeRecord()
        let sessionA = fixture.store.beginSession(historyID: record.historyID)
        let taskA = suspendedTask()
        coordinator.install(
            task: taskA,
            historyID: record.historyID,
            session: sessionA
        )
        let sessionB = fixture.store.beginSession(historyID: record.historyID)
        let taskB = suspendedTask()
        coordinator.install(
            task: taskB,
            historyID: record.historyID,
            session: sessionB
        )
        let currentProgress = CloudTranscriptionDisplayProgress(
            completedChunkCount: 2,
            totalChunkCount: 7,
            activeAttempt: 1
        )
        coordinator.updateProgress(
            currentProgress,
            historyID: record.historyID,
            session: sessionB
        )

        coordinator.updateProgress(
            CloudTranscriptionDisplayProgress(
                completedChunkCount: 6,
                totalChunkCount: 7,
                activeAttempt: 3
            ),
            historyID: record.historyID,
            session: sessionA
        )
        coordinator.finish(
            historyID: record.historyID,
            session: sessionA
        )

        try expectEqual(
            coordinator.progress[record.historyID],
            currentProgress,
            "stale progress is ignored"
        )
        try expectEqual(
            coordinator.activeSession(historyID: record.historyID),
            sessionB,
            "stale finish keeps current task"
        )
        try expect(!taskB.isCancelled, "stale finish does not cancel current task")
        coordinator.cancelAndInvalidate(
            historyID: record.historyID,
            store: fixture.store
        )
    }

    @MainActor
    private static func activeSessionCheckRejectsReplacedAndCancelledSessions() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let coordinator = CloudTranscriptionHistoryCoordinator()
        let record = makeRecord()
        let sessionA = fixture.store.beginSession(historyID: record.historyID)
        coordinator.activate(historyID: record.historyID, session: sessionA)
        try expect(
            coordinator.isActive(historyID: record.historyID, session: sessionA),
            "current session is active"
        )

        let sessionB = fixture.store.beginSession(historyID: record.historyID)
        coordinator.activate(historyID: record.historyID, session: sessionB)
        try expect(
            !coordinator.isActive(historyID: record.historyID, session: sessionA),
            "replaced session is inactive"
        )
        try expect(
            coordinator.isActive(historyID: record.historyID, session: sessionB),
            "replacement session is active"
        )

        coordinator.cancelAndInvalidate(
            historyID: record.historyID,
            store: fixture.store
        )
        try expect(
            !coordinator.isActive(historyID: record.historyID, session: sessionB),
            "cancelled session is inactive"
        )
    }

    @MainActor
    private static func cancellationInvalidatesSessionAndClearsProgress() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let coordinator = CloudTranscriptionHistoryCoordinator()
        let record = makeRecord()
        let session = fixture.store.beginSession(historyID: record.historyID)
        try fixture.store.create(record, session: session)
        let task = suspendedTask()
        coordinator.install(
            task: task,
            historyID: record.historyID,
            session: session
        )
        coordinator.updateProgress(
            CloudTranscriptionDisplayProgress(
                completedChunkCount: 1,
                totalChunkCount: 2,
                activeAttempt: 1
            ),
            historyID: record.historyID,
            session: session
        )

        coordinator.cancelAndInvalidate(
            historyID: record.historyID,
            store: fixture.store
        )

        try expect(task.isCancelled, "cancel stops provider task")
        try expect(coordinator.activeTasks[record.historyID] == nil, "cancel removes active task")
        try expect(coordinator.progress[record.historyID] == nil, "cancel removes progress")
        do {
            try fixture.store.update(record, session: session)
            throw TestFailure("cancel must invalidate store session")
        } catch CloudTranscriptionJobStoreError.staleSession {
            // expected
        }
        coordinator.updateProgress(
            CloudTranscriptionDisplayProgress(
                completedChunkCount: 2,
                totalChunkCount: 2,
                activeAttempt: nil
            ),
            historyID: record.historyID,
            session: session
        )
        try expect(
            coordinator.progress[record.historyID] == nil,
            "late progress cannot resurrect cancelled job"
        )
    }

    @MainActor
    private static func cancelAllInvalidatesEverySession() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let coordinator = CloudTranscriptionHistoryCoordinator()
        let records = [makeRecord(historyID: UUID()), makeRecord(historyID: UUID())]
        var sessions: [CloudTranscriptionJobSession] = []
        var tasks: [Task<Void, Never>] = []
        for record in records {
            let session = fixture.store.beginSession(historyID: record.historyID)
            try fixture.store.create(record, session: session)
            let task = suspendedTask()
            sessions.append(session)
            tasks.append(task)
            coordinator.install(
                task: task,
                historyID: record.historyID,
                session: session
            )
            coordinator.updateProgress(
                CloudTranscriptionDisplayProgress(
                    completedChunkCount: 0,
                    totalChunkCount: 2,
                    activeAttempt: 1
                ),
                historyID: record.historyID,
                session: session
            )
        }

        coordinator.cancelAndInvalidateAll(store: fixture.store)

        try expect(tasks.allSatisfy(\.isCancelled), "cancel all stops every task")
        try expect(coordinator.activeTasks.isEmpty, "cancel all removes tasks")
        try expect(coordinator.progress.isEmpty, "cancel all removes progress")
        for (record, session) in zip(records, sessions) {
            do {
                try fixture.store.update(record, session: session)
                throw TestFailure("cancel all must invalidate \(record.historyID)")
            } catch CloudTranscriptionJobStoreError.staleSession {
                // expected
            }
        }
    }

    @MainActor
    private static func cleanupAssetsCancelInvalidateAndRejectLateCheckpoint() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let coordinator = CloudTranscriptionHistoryCoordinator()
        let record = makeRecord()
        let session = fixture.store.beginSession(historyID: record.historyID)
        try fixture.store.create(record, session: session)
        let checkpoint = fixture.store.checkpointStore(session: session)
        let task = suspendedTask()
        coordinator.install(
            task: task,
            historyID: record.historyID,
            session: session
        )
        coordinator.updateProgress(
            CloudTranscriptionDisplayProgress(
                completedChunkCount: 0,
                totalChunkCount: 2,
                activeAttempt: 1
            ),
            historyID: record.historyID,
            session: session
        )

        coordinator.cancelAndInvalidate(
            historyID: record.historyID,
            store: fixture.store
        )
        try fixture.store.delete(historyID: record.historyID, session: nil)

        try expect(task.isCancelled, "asset cleanup cancels active provider task")
        try expect(coordinator.progress[record.historyID] == nil, "asset cleanup removes progress")
        let storedRecord = try fixture.store.load(historyID: record.historyID)
        try expect(storedRecord == nil, "asset cleanup removes sidecar")
        do {
            try await checkpoint.save(CloudTranscriptionCheckpoint(
                identity: record.identity,
                completedRawTranscripts: ["late"]
            ))
            throw TestFailure("late checkpoint must not recreate cleaned job")
        } catch CloudTranscriptionJobStoreError.staleSession {
            // expected
        }
    }

    @MainActor
    private static func suspendedTask() -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private static func makeFixture() throws -> CoordinatorFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return CoordinatorFixture(
            root: root,
            store: CloudTranscriptionJobStore(
                jobsDirectory: root.appendingPathComponent("jobs", isDirectory: true),
                temporaryRoot: root.appendingPathComponent("temporary", isDirectory: true),
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )
    }

    private static func makeRecord(
        historyID: UUID = UUID()
    ) -> CloudTranscriptionJobRecord {
        let source = CloudTranscriptionSourceIdentity(
            audioFileName: "recording.wav",
            physicalByteCount: CanonicalPCM16WAV.headerByteCount + 12,
            sha256: String(repeating: "a", count: 64),
            dataByteCount: 12,
            frameCount: 6
        )
        let plan = CloudTranscriptionChunkPlan(
            algorithmVersion: CloudTranscriptionChunkPlan.currentAlgorithmVersion,
            encodedUploadCeilingBytes: 1_000,
            sourceFrameCount: 6,
            chunks: [
                CloudTranscriptionChunk(
                    index: 0,
                    startFrame: 0,
                    endFrame: 3,
                    estimatedEncodedByteCount: 500
                ),
                CloudTranscriptionChunk(
                    index: 1,
                    startFrame: 3,
                    endFrame: 6,
                    estimatedEncodedByteCount: 500
                )
            ],
            planID: "plan-v1"
        )
        return CloudTranscriptionJobRecord(
            schemaVersion: CloudTranscriptionJobRecord.currentSchemaVersion,
            historyID: historyID,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            phase: .transcribing,
            identity: CloudTranscriptionJobIdentity(
                providerID: String(repeating: "b", count: 64),
                model: "whisper-large-v3",
                language: "en",
                responseFormat: "verbose_json",
                source: source,
                planID: plan.planID
            ),
            plan: plan,
            completedChunks: [],
            firstIncompleteChunkIndex: 0,
            lastFailure: nil,
            completionPolicy: CloudTranscriptionCompletionPolicy(
                postProcessingEnabled: true,
                outputLanguage: "en",
                pressEnterCommandEnabled: false
            )
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else { throw TestFailure(label) }
    }

    private static func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ label: String
    ) throws {
        guard actual == expected else {
            throw TestFailure("\(label): expected \(expected), got \(actual)")
        }
    }
}

private struct CoordinatorFixture {
    let root: URL
    let store: CloudTranscriptionJobStore

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
