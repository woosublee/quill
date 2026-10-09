import Foundation

@main
struct NoteSyncCoordinatorTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    static func main() throws {
        testLocalSaveEnqueuesOnlySettledNotes()
        testSettlingNoteIsEnqueued()
        testDeleteEnqueuesOnlyWhenSynced()
        try testFetchedRecordIsAppliedWithoutEcho()
        try testFetchedRecordNeedingUploadIsEnqueued()
        try testUndecodableRecordIsSkippedAndCounted()
        testRemoteDeletionPurgesAndReturnsAssets()
        try testServerChangedMergesAndResends()
        try testServerChangedWithSameContentIsNotResent()
        testQuotaAndNetworkPause()
        testInitialUploadEnqueuesEverySyncableNote()
        testAccountChangePausesWithoutDeleting()
        testZoneDeletedElsewherePausesWithoutPurging()
        testOutgoingSkipsGoneAndInProgressNotes()
        try testServerChangedForDeletedNoteDeletesInsteadOfReviving()
        testServerChangedWithUnreadableServerCopyIsNotOverwritten()
        testSavedNoteThatIsGoneIsDeletedFromICloud()
        try testStoppedCoordinatorIgnoresEverything()
        testUnsavedChangeTagIsNotCountedAsUploaded()
        testAccountChangeStaysPausedWhenClearingFails()
        print("NoteSyncCoordinatorTests passed")
    }

    final class FakeStore: NoteSyncLocalStore {
        var records: [UUID: NoteSyncRecord] = [:]
        var systemFields: [UUID: Data] = [:]
        var syncable: Set<UUID> = []
        var applyResult: NoteSyncApplyResult = .inserted
        var applyError: Error?
        var applied: [(NoteSyncRecord, Data?)] = []
        var removed: [UUID] = []
        var clearedSystemFields = false

        func syncRecord(id: UUID) -> NoteSyncRecord? { records[id] }
        func syncSystemFields(id: UUID) -> Data? { systemFields[id] }
        var systemFieldsSaveError: Error?
        func setSyncSystemFields(_ data: Data?, id: UUID) throws {
            if let systemFieldsSaveError { throw systemFieldsSaveError }
            systemFields[id] = data
        }
        func clearAllSyncSystemFields() throws {
            if let systemFieldsSaveError { throw systemFieldsSaveError }
            clearedSystemFields = true
            systemFields = [:]
        }
        func syncableNoteIDs() -> [UUID] { records.keys.filter(syncable.contains).sorted { $0.uuidString < $1.uuidString } }
        func isSyncable(id: UUID) -> Bool { syncable.contains(id) && records[id] != nil }
        func applySynced(_ record: NoteSyncRecord, systemFields: Data?) throws -> NoteSyncApplyResult {
            if let applyError { throw applyError }
            applied.append((record, systemFields))
            return applyResult
        }
        func removeSynced(id: UUID) throws -> DeletedPipelineHistoryAssets? {
            removed.append(id)
            return DeletedPipelineHistoryAssets(historyID: id, audioFileName: "synthetic.m4a", transcriptFileName: nil)
        }
    }

    final class FakeEngine: NoteSyncEngineClient {
        var saves: [UUID] = []
        var deletes: [UUID] = []
        func enqueueSaves(_ ids: [UUID]) { saves += ids }
        func enqueueDeletes(_ ids: [UUID]) { deletes += ids }
    }

    static func record(_ id: UUID = UUID(), title: String = "Synthetic") -> NoteSyncRecord {
        NoteSyncRecord(
            noteID: id,
            fields: [NoteSyncField.customTitle.rawValue: .string(title)],
            clock: NoteFieldClock.uniform(t0),
            deletedAt: nil
        )
    }

    @MainActor
    static func make() -> (NoteSyncCoordinator, FakeStore, FakeEngine) {
        let store = FakeStore()
        let engine = FakeEngine()
        let coordinator = NoteSyncCoordinator(store: store, engine: engine, now: { t0 })
        return (coordinator, store, engine)
    }

    @MainActor
    static func fetched(_ record: NoteSyncRecord, fields: Data = Data([7])) throws -> NoteSyncFetched {
        NoteSyncFetched(noteID: record.noteID, payload: try NoteSyncPayload.encode(record), systemFields: fields)
    }

    @MainActor
    static func testLocalSaveEnqueuesOnlySettledNotes() {
        let (coordinator, store, engine) = make()
        let settled = record(), inProgress = record()
        store.records = [settled.noteID: settled, inProgress.noteID: inProgress]
        store.syncable = [settled.noteID]
        coordinator.handleLocalChanges([.saved(settled.noteID), .saved(inProgress.noteID)])
        precondition(engine.saves == [settled.noteID], "only settled notes are sent")
    }

    @MainActor
    static func testSettlingNoteIsEnqueued() {
        let (coordinator, store, engine) = make()
        let note = record()
        store.records[note.noteID] = note
        coordinator.handleLocalChanges([.saved(note.noteID)])
        precondition(engine.saves.isEmpty)
        store.syncable.insert(note.noteID)
        coordinator.handleLocalChanges([.saved(note.noteID)])
        precondition(engine.saves == [note.noteID], "the update that settles a note sends it")
    }

    @MainActor
    static func testDeleteEnqueuesOnlyWhenSynced() {
        let (coordinator, _, engine) = make()
        let synced = UUID(), local = UUID()
        coordinator.handleLocalChanges([.deleted(synced, wasSynced: true), .deleted(local, wasSynced: false)])
        precondition(engine.deletes == [synced])
    }

    @MainActor
    static func testFetchedRecordIsAppliedWithoutEcho() throws {
        let (coordinator, store, engine) = make()
        let remote = record(title: "From another Mac")
        store.applyResult = .inserted
        let change = coordinator.handleFetched([try fetched(remote)], deletions: [])
        precondition(store.applied.count == 1 && store.applied[0].0 == remote && store.applied[0].1 == Data([7]))
        precondition(change.changed == [remote.noteID] && change.skipped == 0)
        precondition(engine.saves.isEmpty, "a fetched record is never sent back")
    }

    @MainActor
    static func testFetchedRecordNeedingUploadIsEnqueued() throws {
        let (coordinator, store, engine) = make()
        let remote = record()
        store.applyResult = .updated(needsUpload: true)
        _ = coordinator.handleFetched([try fetched(remote)], deletions: [])
        precondition(engine.saves == [remote.noteID], "this Mac's newer groups go back up")
    }

    @MainActor
    static func testUndecodableRecordIsSkippedAndCounted() throws {
        let (coordinator, store, _) = make()
        let good = record()
        let change = coordinator.handleFetched([
            NoteSyncFetched(noteID: UUID(), payload: Data("not json".utf8), systemFields: Data()),
            NoteSyncFetched(noteID: UUID(), payload: nil, systemFields: Data()),
            try fetched(good)
        ], deletions: [])
        precondition(change.skipped == 2 && change.changed == [good.noteID])
        precondition(store.applied.count == 1)

        store.applyError = PipelineHistorySyncError.incompleteRecord
        let incomplete = coordinator.handleFetched([try fetched(record())], deletions: [])
        precondition(incomplete.skipped == 1 && incomplete.changed.isEmpty)
    }

    @MainActor
    static func testRemoteDeletionPurgesAndReturnsAssets() {
        let (coordinator, store, engine) = make()
        let id = UUID()
        let change = coordinator.handleFetched([], deletions: [id])
        precondition(store.removed == [id])
        precondition(change.purged.map(\.historyID) == [id])
        precondition(engine.deletes.isEmpty && engine.saves.isEmpty)
    }

    @MainActor
    static func testServerChangedMergesAndResends() throws {
        let (coordinator, store, engine) = make()
        let server = record(title: "Server")
        store.applyResult = .updated(needsUpload: true)
        store.records[server.noteID] = record(server.noteID, title: "Local")
        coordinator.handleSendFailures([
            .serverChanged(noteID: server.noteID, serverPayload: try NoteSyncPayload.encode(server), serverSystemFields: Data([3]))
        ])
        precondition(store.applied.count == 1 && store.applied[0].0 == server && store.applied[0].1 == Data([3]))
        precondition(engine.saves == [server.noteID], "the merged note is sent again with the server's tag")
    }

    @MainActor
    static func testServerChangedWithSameContentIsNotResent() throws {
        let (coordinator, store, engine) = make()
        let server = record()
        store.applyResult = .updated(needsUpload: false)
        store.records[server.noteID] = record(server.noteID, title: "Local")
        coordinator.handleSendFailures([
            .serverChanged(noteID: server.noteID, serverPayload: try NoteSyncPayload.encode(server), serverSystemFields: Data([3]))
        ])
        precondition(engine.saves.isEmpty)
    }

    @MainActor
    static func testQuotaAndNetworkPause() {
        let (coordinator, _, _) = make()
        coordinator.handleSendFailures([.network(noteID: UUID())])
        precondition(coordinator.status == .paused(.offline))
        coordinator.handleSendFailures([.quotaExceeded(noteID: UUID()), .quotaExceeded(noteID: UUID())])
        precondition(coordinator.status == .paused(.quotaExceeded(pending: 2)))
        coordinator.handleFetchFinished(pending: 0)
        precondition(coordinator.status == .upToDate(t0), "a finished sync clears the pause")
    }

    @MainActor
    static func testInitialUploadEnqueuesEverySyncableNote() {
        let (coordinator, store, engine) = make()
        let a = record(), b = record(), c = record()
        store.records = [a.noteID: a, b.noteID: b, c.noteID: c]
        store.syncable = [a.noteID, b.noteID]
        var statuses: [NoteSyncStatus] = []
        coordinator.onStatusChange = { statuses.append($0) }
        coordinator.startInitialUpload()
        precondition(Set(engine.saves) == [a.noteID, b.noteID])
        precondition(coordinator.status == .uploading(done: 0, total: 2))
        coordinator.handleSaved(id: a.noteID, systemFields: Data([1]))
        precondition(coordinator.status == .uploading(done: 1, total: 2))
        precondition(store.systemFields[a.noteID] == Data([1]))
        coordinator.handleSaved(id: b.noteID, systemFields: Data([2]))
        coordinator.handleFetchFinished(pending: 0)
        precondition(coordinator.status == .upToDate(t0))
        precondition(statuses.last == .upToDate(t0))
    }

    @MainActor
    static func testAccountChangePausesWithoutDeleting() {
        let (coordinator, store, engine) = make()
        let note = record()
        store.records[note.noteID] = note
        store.syncable = [note.noteID]
        coordinator.handleAccountChange(signedOut: false)
        precondition(coordinator.status == .paused(.accountChanged))
        precondition(store.clearedSystemFields && store.removed.isEmpty)
        coordinator.handleLocalChanges([.saved(note.noteID)])
        precondition(engine.saves.isEmpty, "nothing is sent after the account changed")
        let (signedOut, _, _) = make()
        signedOut.handleAccountChange(signedOut: true)
        precondition(signedOut.status == .paused(.signedOut))
    }

    @MainActor
    static func testZoneDeletedElsewherePausesWithoutPurging() {
        let (coordinator, store, engine) = make()
        coordinator.handleZoneDeleted()
        precondition(coordinator.status == .paused(.deletedElsewhere))
        precondition(store.clearedSystemFields && store.removed.isEmpty && engine.deletes.isEmpty)
    }

    @MainActor
    static func testOutgoingSkipsGoneAndInProgressNotes() {
        let (coordinator, store, _) = make()
        let settled = record(), inProgress = record()
        store.records = [settled.noteID: settled, inProgress.noteID: inProgress]
        store.syncable = [settled.noteID]
        store.systemFields[settled.noteID] = Data([4])
        precondition(coordinator.outgoing(for: settled.noteID) == NoteSyncOutgoing(record: settled, systemFields: Data([4])))
        precondition(coordinator.outgoing(for: inProgress.noteID) == nil)
        precondition(coordinator.outgoing(for: UUID()) == nil)
    }

    @MainActor
    static func testServerChangedForDeletedNoteDeletesInsteadOfReviving() throws {
        let (coordinator, store, engine) = make()
        let server = record()
        coordinator.handleSendFailures([
            .serverChanged(noteID: server.noteID, serverPayload: try NoteSyncPayload.encode(server), serverSystemFields: Data([3]))
        ])
        precondition(store.applied.isEmpty, "a note deleted here is not brought back")
        precondition(engine.saves.isEmpty && engine.deletes == [server.noteID])
    }

    @MainActor
    static func testServerChangedWithUnreadableServerCopyIsNotOverwritten() {
        let (coordinator, store, engine) = make()
        let note = record()
        store.records[note.noteID] = note
        store.syncable = [note.noteID]
        store.systemFields[note.noteID] = Data([1])
        coordinator.handleSendFailures([
            .serverChanged(noteID: note.noteID, serverPayload: nil, serverSystemFields: Data([3])),
            .serverChanged(noteID: note.noteID, serverPayload: Data("not json".utf8), serverSystemFields: Data([3]))
        ])
        store.applyError = PipelineHistorySyncError.unreadableRecord
        coordinator.handleSendFailures([
            .serverChanged(noteID: note.noteID, serverPayload: try! NoteSyncPayload.encode(note), serverSystemFields: Data([3]))
        ])
        precondition(engine.saves.isEmpty, "an unmerged local copy never overwrites the server")
        precondition(store.systemFields[note.noteID] == Data([1]), "the old change tag is kept, so the next send conflicts again")
    }

    @MainActor
    static func testSavedNoteThatIsGoneIsDeletedFromICloud() {
        let (coordinator, store, engine) = make()
        let id = UUID()
        coordinator.handleSaved(id: id, systemFields: Data([1]))
        precondition(engine.deletes == [id], "a note deleted while its upload was in flight is deleted from iCloud")
        precondition(store.systemFields[id] == nil)
    }

    @MainActor
    static func testStoppedCoordinatorIgnoresEverything() throws {
        let (coordinator, store, engine) = make()
        let note = record()
        store.records[note.noteID] = note
        store.syncable = [note.noteID]
        coordinator.handleZoneDeleted()
        let change = coordinator.handleFetched([try fetched(record())], deletions: [UUID()])
        precondition(change == NoteSyncRemoteChange() && store.applied.isEmpty && store.removed.isEmpty)
        precondition(coordinator.outgoing(for: note.noteID) == nil, "queued saves are dropped")
        coordinator.handleSaved(id: note.noteID, systemFields: Data([5]))
        precondition(store.systemFields[note.noteID] == nil && engine.deletes.isEmpty)
    }

    @MainActor
    static func testUnsavedChangeTagIsNotCountedAsUploaded() {
        let (coordinator, store, _) = make()
        let note = record()
        store.records[note.noteID] = note
        store.syncable = [note.noteID]
        coordinator.startInitialUpload()
        store.systemFieldsSaveError = PipelineHistoryStoreError.storeUnavailable
        coordinator.handleSaved(id: note.noteID, systemFields: Data([1]))
        precondition(coordinator.status == .uploading(done: 0, total: 1), "a save this Mac couldn't record isn't counted as done")
    }

    @MainActor
    static func testAccountChangeStaysPausedWhenClearingFails() {
        let (coordinator, store, engine) = make()
        let note = record()
        store.records[note.noteID] = note
        store.syncable = [note.noteID]
        store.systemFieldsSaveError = PipelineHistoryStoreError.storeUnavailable
        coordinator.handleAccountChange(signedOut: false)
        precondition(coordinator.status == .paused(.accountChanged))
        coordinator.handleLocalChanges([.saved(note.noteID)])
        precondition(engine.saves.isEmpty, "sync stays stopped even if clearing failed")
    }
}
