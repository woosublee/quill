import Foundation

@main
struct NoteSyncCoordinatorTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    static func main() async throws {
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
        try testUnavailableStoreAsksForFullRefetch()
        testFailedSavesAreRetriedAfterTheNextSync()
        testFailedDeleteIsRetriedAsADelete()
        testLateFailuresDoNotRestartStoppedSync()
        try testNoteBackFromAnotherMacCancelsItsDelete()
        testSaveOfAMissingRecordStartsFresh()
        try testAudioOfASettledNoteIsQueuedInParts()
        try testAudioIsQueuedOnceAndNeverWhenInICloud()
        try await testManifestIsWrittenAfterTheLastPart()
        try await testFirstUploadCountsAudio()
        try testDeleteRemovesAudioParts()
        try testAudioFailuresPauseAndRetry()
        try testOutgoingAudioDropsStaleParts()
        try await testResumeQueuesAudioLeftFromLastRun()
        try await testManifestWaitsForEveryPartInICloud()
        try await testPartWaitingForRetryKeepsTheMarkerOff()
        try await testPartsOfAnEarlierFileGoUpAgain()
        try await testResumeFinishesAudioAlreadyInICloud()
        try await testStaleMarkerIsClearedAtTurnOn()
        try await testLookupFailureIsRetriedAfterTheNextSync()
        try testDeleteRemovesPartsSentBeforeTheMarker()
        try testRemoteDeletionRemovesThisMacsParts()
        await testPartSavedAfterItsNoteIsGoneIsDeleted()
        try testFailingPartIsGivenUpAfterThreeTries()
        try testTurnOnReadsWaitingPartsOnce()
        try testDeletedNoteNoLongerHoldsUpProgress()
        try testAccountChangeForgetsAudioMarkers()
        try await testMarkerClearedElsewhereIsCheckedAgain()
        try testZoneDeletedElsewhereForgetsAudioMarkers()
        try await testMarkersWithoutLocalAudioAreCheckedAtTurnOn()
        try await testDeleteAfterRelaunchCountsPartsFromTheFile()
        try testRemoteDeletionUsesThisMacsMarker()
        try await testStoppedCoordinatorWritesNoMarker()
        try await testMarkedNotesGoUpOnlyAfterTheCheck()
        try await testEditAfterAGivenUpPartChecksICloudFirst()
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
        var isReadyForSync = true

        func syncRecord(id: UUID) -> NoteSyncRecord? { records[id] }
        func syncSystemFields(id: UUID) -> Data? { systemFields[id] }
        var systemFieldsSaveError: Error?
        func setSyncSystemFields(_ data: Data?, id: UUID) throws {
            if let systemFieldsSaveError { throw systemFieldsSaveError }
            systemFields[id] = data
        }
        func clearAllSyncSystemFields(forgettingAudio: Bool) throws {
            if let systemFieldsSaveError { throw systemFieldsSaveError }
            clearedSystemFields = true
            systemFields = [:]
            if forgettingAudio { manifests = [:] }
        }
        func syncableNoteIDs() -> [UUID] { records.keys.filter(syncable.contains).sorted { $0.uuidString < $1.uuidString } }
        func isSyncable(id: UUID) -> Bool { syncable.contains(id) && records[id] != nil }
        func applySynced(_ record: NoteSyncRecord, systemFields: Data?) throws -> NoteSyncApplyResult {
            if let applyError { throw applyError }
            applied.append((record, systemFields))
            return applyResult
        }
        var manifests: [UUID: NoteAudioManifest] = [:]
        func audioManifest(id: UUID) -> NoteAudioManifest? { manifests[id] }
        func setAudioManifest(_ manifest: NoteAudioManifest?, id: UUID) throws { manifests[id] = manifest }
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
        var cancelledDeletes: [UUID] = []
        func cancelDeletes(_ ids: [UUID]) { cancelledDeletes += ids }
        var audioSaves: [NoteAudioPartID] = []
        var audioDeletes: [NoteAudioPartID] = []
        var pendingAudio: [NoteAudioPartID] = []
        func enqueueAudioSaves(_ parts: [NoteAudioPartID]) { audioSaves += parts; pendingAudio += parts }
        func enqueueAudioDeletes(_ parts: [NoteAudioPartID]) { audioDeletes += parts }
        var pendingAudioReads = 0
        func pendingAudioSaves() -> [NoteAudioPartID] {
            pendingAudioReads += 1
            return pendingAudio
        }
        func cancelAudioSaves(noteID: UUID) { pendingAudio.removeAll { $0.noteID == noteID } }
        /// Parts iCloud holds, and what each was cut from.
        var stamps: [NoteAudioPartID: NoteAudioPartStamp] = [:]
        var stampError: Error?
        var onLookup: (() -> Void)?
        func audioPartStamps(_ parts: [NoteAudioPartID]) async throws -> [NoteAudioPartID: NoteAudioPartStamp] {
            onLookup?()
            if let stampError { throw stampError }
            return stamps.filter { parts.contains($0.key) }
        }
        /// What CKSyncEngine does when a part is saved.
        func finish(_ part: NoteAudioPartID, _ stamp: NoteAudioPartStamp) {
            pendingAudio.removeAll { $0 == part }
            stamps[part] = stamp
        }
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

    /// A sparse file of `bytes` bytes in a fresh directory; quick even at 120 MB.
    static func audioDirectory(files: [String: Int64]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quill-sync-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, bytes) in files {
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(bytes))
            try handle.close()
        }
        return dir
    }

    @MainActor
    static func makeWithAudio(_ files: [String: Int64]) throws -> (NoteSyncCoordinator, FakeStore, FakeEngine, URL) {
        let store = FakeStore()
        let engine = FakeEngine()
        let dir = try audioDirectory(files: files)
        let coordinator = NoteSyncCoordinator(
            store: store,
            engine: engine,
            now: { t0 },
            localAudioURL: { name in
                let url = dir.appendingPathComponent(name)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            },
            hashFile: { _ in "synthetic-hash" }
        )
        return (coordinator, store, engine, dir)
    }

    static func record(_ id: UUID = UUID(), audio: String) -> NoteSyncRecord {
        var note = record(id)
        note.fields[NoteSyncField.audioFileName.rawValue] = .string(audio)
        return note
    }

    static func parts(_ id: UUID, _ count: Int) -> [NoteAudioPartID] {
        (0..<count).map { NoteAudioPartID(noteID: id, index: $0) }
    }

    @MainActor
    static func testAudioOfASettledNoteIsQueuedInParts() throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 120_000_000])
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = record(audio: "a.wav")
        store.records[note.noteID] = note
        store.syncable = [note.noteID]
        coordinator.handleLocalChanges([.saved(note.noteID)])
        precondition(engine.saves == [note.noteID], "text goes first")
        precondition(engine.audioSaves == parts(note.noteID, 3))
    }

    @MainActor
    static func testAudioIsQueuedOnceAndNeverWhenInICloud() throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10, "b.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let queued = record(audio: "a.wav"), uploaded = record(audio: "b.wav"), missing = record(audio: "c.wav")
        for note in [queued, uploaded, missing] {
            store.records[note.noteID] = note
            store.syncable.insert(note.noteID)
        }
        store.manifests[uploaded.noteID] = NoteAudioManifest(sha256: "x", bytes: 10, partSize: 50_000_000, parts: 1)
        coordinator.handleLocalChanges([.saved(queued.noteID), .saved(uploaded.noteID), .saved(missing.noteID)])
        coordinator.handleLocalChanges([.saved(queued.noteID)])
        precondition(engine.audioSaves == parts(queued.noteID, 1), "once, and only audio that is here and not in iCloud")
    }

    @MainActor
    static func testManifestIsWrittenAfterTheLastPart() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 60_000_000])
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = record(audio: "a.wav")
        store.records[note.noteID] = note
        store.syncable = [note.noteID]
        coordinator.handleLocalChanges([.saved(note.noteID)])
        engine.saves = []
        let first = NoteAudioPartID(noteID: note.noteID, index: 0)
        let second = NoteAudioPartID(noteID: note.noteID, index: 1)
        let stamp = NoteAudioPartStamp(fileName: "a.wav", fileBytes: 60_000_000)
        engine.finish(first, stamp)
        await coordinator.handleAudioPartSaved(first)
        precondition(store.manifests[note.noteID] == nil, "a part is still waiting")
        engine.finish(second, stamp)
        await coordinator.handleAudioPartSaved(second)
        precondition(store.manifests[note.noteID] == NoteAudioManifest(
            sha256: "synthetic-hash", bytes: 60_000_000, partSize: 50_000_000, parts: 2
        ))
        precondition(engine.saves == [note.noteID], "the note goes up again with its manifest")
    }

    @MainActor
    static func testFirstUploadCountsAudio() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let withAudio = record(audio: "a.wav"), textOnly = record()
        for note in [withAudio, textOnly] {
            store.records[note.noteID] = note
            store.syncable.insert(note.noteID)
        }
        coordinator.startInitialUpload()
        precondition(coordinator.status == .uploading(done: 0, total: 2))
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioSaves == parts(withAudio.noteID, 1), "iCloud doesn't have it yet")
        coordinator.handleSaved(id: withAudio.noteID, systemFields: Data([1]))
        coordinator.handleSaved(id: textOnly.noteID, systemFields: Data([1]))
        precondition(coordinator.status == .uploading(done: 1, total: 2), "the note with audio isn't done yet")
        let part = NoteAudioPartID(noteID: withAudio.noteID, index: 0)
        engine.finish(part, NoteAudioPartStamp(fileName: "a.wav", fileBytes: 10))
        await coordinator.handleAudioPartSaved(part)
        precondition(coordinator.status == .uploading(done: 2, total: 2))
    }

    @MainActor
    static func testDeleteRemovesAudioParts() throws {
        let (coordinator, _, engine, dir) = try makeWithAudio([:])
        defer { try? FileManager.default.removeItem(at: dir) }
        let uploaded = UUID(), midUpload = UUID()
        engine.pendingAudio = parts(midUpload, 3).suffix(2).map { $0 }
        coordinator.handleLocalChanges([
            .deleted(uploaded, wasSynced: true, audioParts: 3),
            .deleted(midUpload, wasSynced: true, audioParts: 0)
        ])
        precondition(engine.audioDeletes == parts(uploaded, 3) + parts(midUpload, 3), "sent parts are deleted too")
        precondition(engine.pendingAudio.isEmpty, "waiting parts never go up")
    }

    @MainActor
    static func testAudioFailuresPauseAndRetry() throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = record(audio: "a.wav")
        store.records[note.noteID] = note
        store.syncable = [note.noteID]
        let part = NoteAudioPartID(noteID: note.noteID, index: 0)
        let gone = NoteAudioPartID(noteID: UUID(), index: 0)
        coordinator.handleAudioSendFailures([.quotaExceeded(part), .deleteFailed(gone)])
        precondition(coordinator.status == .paused(.quotaExceeded(pending: 1)))
        coordinator.handleFetchFinished(pending: 1)
        precondition(engine.audioSaves == [part], "the part is tried again after the next sync")
        precondition(engine.audioDeletes == [gone])
    }

    @MainActor
    static func testOutgoingAudioDropsStaleParts() throws {
        let (coordinator, store, _, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = record(audio: "a.wav")
        store.records[note.noteID] = note
        store.syncable = [note.noteID]
        let part = NoteAudioPartID(noteID: note.noteID, index: 0)
        precondition(coordinator.outgoingAudio(for: part) == NoteSyncOutgoingAudio(
            part: part, fileURL: dir.appendingPathComponent("a.wav"), fileName: "a.wav", byteCount: 10
        ))
        precondition(coordinator.outgoingAudio(for: NoteAudioPartID(noteID: note.noteID, index: 1)) == nil, "past the end")
        store.manifests[note.noteID] = NoteAudioManifest(sha256: "x", bytes: 10, partSize: 50_000_000, parts: 1)
        precondition(coordinator.outgoingAudio(for: part) == nil, "already in iCloud")
    }

    @MainActor
    static func testResumeQueuesAudioLeftFromLastRun() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10, "b.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let waiting = record(audio: "a.wav"), notStarted = record(audio: "b.wav")
        for note in [waiting, notStarted] {
            store.records[note.noteID] = note
            store.syncable.insert(note.noteID)
        }
        engine.pendingAudio = parts(waiting.noteID, 1)
        coordinator.resumeAudioUploads()
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioSaves == parts(notStarted.noteID, 1), "parts still waiting are not queued twice")
    }


    static let smallStamp = NoteAudioPartStamp(fileName: "a.wav", fileBytes: 10)

    @MainActor
    static func noteWithAudio(_ store: FakeStore, _ file: String = "a.wav") -> UUID {
        let note = record(audio: file)
        store.records[note.noteID] = note
        store.syncable.insert(note.noteID)
        return note.noteID
    }

    /// A part dropped before it was sent leaves the marker off, and goes up again.
    @MainActor
    static func testManifestWaitsForEveryPartInICloud() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 60_000_000])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        coordinator.handleLocalChanges([.saved(id)])
        let stamp = NoteAudioPartStamp(fileName: "a.wav", fileBytes: 60_000_000)
        let first = NoteAudioPartID(noteID: id, index: 0), second = NoteAudioPartID(noteID: id, index: 1)
        engine.pendingAudio.removeAll { $0 == second }
        engine.audioSaves = []
        engine.finish(first, stamp)
        await coordinator.handleAudioPartSaved(first)
        precondition(store.manifests[id] == nil, "a part iCloud doesn't have keeps the marker off")
        precondition(engine.audioSaves == [second], "the missing part goes up again")
        engine.finish(second, stamp)
        await coordinator.handleAudioPartSaved(second)
        precondition(store.manifests[id]?.parts == 2)
    }

    @MainActor
    static func testPartWaitingForRetryKeepsTheMarkerOff() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 60_000_000])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        coordinator.handleLocalChanges([.saved(id)])
        let stamp = NoteAudioPartStamp(fileName: "a.wav", fileBytes: 60_000_000)
        let first = NoteAudioPartID(noteID: id, index: 0), second = NoteAudioPartID(noteID: id, index: 1)
        engine.pendingAudio.removeAll { $0 == second }
        coordinator.handleAudioSendFailures([.failed(second)])
        engine.audioSaves = []
        engine.finish(first, stamp)
        await coordinator.handleAudioPartSaved(first)
        precondition(store.manifests[id] == nil && engine.audioSaves.isEmpty, "the failed part waits for its retry")
    }

    /// Parts cut from an earlier file of the note don't count.
    @MainActor
    static func testPartsOfAnEarlierFileGoUpAgain() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        let part = NoteAudioPartID(noteID: id, index: 0)
        engine.stamps[part] = NoteAudioPartStamp(fileName: "old.wav", fileBytes: 10)
        coordinator.resumeAudioUploads()
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioSaves == [part] && store.manifests[id] == nil)
    }

    /// Quit after the last part went up but before the marker was written:
    /// the marker is written without sending the audio again.
    @MainActor
    static func testResumeFinishesAudioAlreadyInICloud() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        engine.stamps[NoteAudioPartID(noteID: id, index: 0)] = smallStamp
        coordinator.resumeAudioUploads()
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioSaves.isEmpty, "nothing goes up twice")
        precondition(store.manifests[id]?.sha256 == "synthetic-hash" && engine.saves == [id])
    }

    /// A Mac that was off when iCloud lost the audio still holds the
    /// marker; turning sync on finds the parts missing and sends them.
    @MainActor
    static func testStaleMarkerIsClearedAtTurnOn() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        store.manifests[id] = NoteAudioManifest(sha256: "x", bytes: 10, partSize: 50_000_000, parts: 1)
        coordinator.startInitialUpload()
        await coordinator.lastAudioCheck?.value
        precondition(store.manifests[id] == nil, "iCloud lost this audio")
        precondition(engine.audioSaves == parts(id, 1))
        precondition(engine.saves == [id], "the note goes up once, with its marker cleared")

        let (kept, keptStore, keptEngine, keptDir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: keptDir) }
        let keptID = noteWithAudio(keptStore)
        keptStore.manifests[keptID] = NoteAudioManifest(sha256: "x", bytes: 10, partSize: 50_000_000, parts: 1)
        keptEngine.stamps[NoteAudioPartID(noteID: keptID, index: 0)] = smallStamp
        kept.startInitialUpload()
        await kept.lastAudioCheck?.value
        precondition(keptStore.manifests[keptID] != nil && keptEngine.audioSaves.isEmpty, "audio in iCloud stays marked")
    }

    @MainActor
    static func testLookupFailureIsRetriedAfterTheNextSync() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        engine.stampError = URLError(.notConnectedToInternet)
        coordinator.resumeAudioUploads()
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioSaves.isEmpty)
        engine.stampError = nil
        coordinator.handleFetchFinished(pending: 0)
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioSaves == parts(id, 1), "checked again after the next sync")
    }

    /// Every part went up but the marker isn't written yet: deleting the
    /// note still removes the parts.
    @MainActor
    static func testDeleteRemovesPartsSentBeforeTheMarker() throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 120_000_000])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        coordinator.handleLocalChanges([.saved(id)])
        engine.pendingAudio = []
        store.records[id] = nil
        coordinator.handleLocalChanges([.deleted(id, wasSynced: true, audioParts: 0)])
        precondition(engine.audioDeletes == parts(id, 3))
    }

    /// Another Mac deleted the note for good while this Mac was sending its
    /// audio, before any marker: this Mac removes what it sent.
    @MainActor
    static func testRemoteDeletionRemovesThisMacsParts() throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 120_000_000])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        coordinator.handleLocalChanges([.saved(id)])
        engine.pendingAudio = Array(parts(id, 3).suffix(2))
        _ = coordinator.handleFetched([], deletions: [id])
        precondition(engine.pendingAudio.isEmpty, "nothing more goes up")
        precondition(engine.audioDeletes == parts(id, 3))
    }

    @MainActor
    static func testPartSavedAfterItsNoteIsGoneIsDeleted() async {
        let (coordinator, _, engine) = make()
        let part = NoteAudioPartID(noteID: UUID(), index: 0)
        await coordinator.handleAudioPartSaved(part)
        precondition(engine.audioDeletes == [part], "a part in flight when its note was deleted is removed")
    }

    @MainActor
    static func testFailingPartIsGivenUpAfterThreeTries() throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        let part = NoteAudioPartID(noteID: id, index: 0)
        for _ in 0..<3 {
            coordinator.handleAudioSendFailures([.failed(part)])
            coordinator.handleFetchFinished(pending: 1)
        }
        precondition(engine.audioSaves == [part, part], "two retries, then it waits for the next launch")
    }

    @MainActor
    static func testTurnOnReadsWaitingPartsOnce() throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        for _ in 0..<50 { _ = noteWithAudio(store) }
        coordinator.startInitialUpload()
        precondition(engine.pendingAudioReads <= 1, "not once per note")
    }

    @MainActor
    static func testDeletedNoteNoLongerHoldsUpProgress() throws {
        let (coordinator, store, _, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let withAudio = noteWithAudio(store)
        let textOnly = record()
        store.records[textOnly.noteID] = textOnly
        store.syncable.insert(textOnly.noteID)
        coordinator.startInitialUpload()
        coordinator.handleSaved(id: withAudio, systemFields: Data([1]))
        coordinator.handleSaved(id: textOnly.noteID, systemFields: Data([1]))
        store.records[withAudio] = nil
        coordinator.handleLocalChanges([.deleted(withAudio, wasSynced: true)])
        precondition(coordinator.status == .uploading(done: 2, total: 2))
    }

    /// Another Mac cleared the marker (it learned late that iCloud lost the
    /// audio): the Mac with the file checks iCloud and marks it again.
    @MainActor
    static func testMarkerClearedElsewhereIsCheckedAgain() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        engine.stamps[NoteAudioPartID(noteID: id, index: 0)] = smallStamp
        store.applyResult = .updated(needsUpload: false)
        _ = coordinator.handleFetched([try fetched(store.records[id]!)], deletions: [])
        await coordinator.lastAudioCheck?.value
        precondition(store.manifests[id] != nil && engine.audioSaves.isEmpty)
    }

    /// Signing back into the same account finds the audio still there, so
    /// markers stay; turning sync on checks them against iCloud.
    /// After switching accounts, an old account's marker must not reach the
    /// new account's iCloud before the check clears it.
    @MainActor
    static func testMarkedNotesGoUpOnlyAfterTheCheck() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let marked = noteWithAudio(store)
        store.manifests[marked] = NoteAudioManifest(sha256: "x", bytes: 10, partSize: 50_000_000, parts: 1)
        let plain = record()
        store.records[plain.noteID] = plain
        store.syncable.insert(plain.noteID)
        engine.stampError = URLError(.notConnectedToInternet)
        coordinator.startInitialUpload()
        await coordinator.lastAudioCheck?.value
        precondition(engine.saves == [plain.noteID], "the marked note waits for its check")
        engine.stampError = nil
        coordinator.handleFetchFinished(pending: 0)
        await coordinator.lastAudioCheck?.value
        precondition(engine.saves == [plain.noteID, marked] && store.manifests[marked] == nil)
    }

    @MainActor
    static func testEditAfterAGivenUpPartChecksICloudFirst() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 60_000_000])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        let first = NoteAudioPartID(noteID: id, index: 0), second = NoteAudioPartID(noteID: id, index: 1)
        engine.stamps[first] = NoteAudioPartStamp(fileName: "a.wav", fileBytes: 60_000_000)
        for _ in 0..<3 { coordinator.handleAudioSendFailures([.failed(second)]) }
        engine.audioSaves = []
        coordinator.handleLocalChanges([.saved(id)])
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioSaves.isEmpty, "the part in iCloud isn't sent again, and the given-up one waits")
    }

    @MainActor
    static func testAccountChangeForgetsAudioMarkers() throws {
        let (coordinator, store, _, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        store.manifests[id] = NoteAudioManifest(sha256: "x", bytes: 10, partSize: 50_000_000, parts: 1)
        coordinator.handleAccountChange(signedOut: true)
        precondition(store.clearedSystemFields && store.manifests[id] != nil)
    }

    @MainActor
    static func testZoneDeletedElsewhereForgetsAudioMarkers() throws {
        let (coordinator, store, _, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        store.manifests[id] = NoteAudioManifest(sha256: "x", bytes: 10, partSize: 50_000_000, parts: 1)
        coordinator.handleZoneDeleted()
        precondition(store.manifests[id] == nil, "iCloud lost this audio")
    }

    /// Audio another Mac recorded: kept marked when iCloud has it, cleared
    /// when it doesn't.
    @MainActor
    static func testMarkersWithoutLocalAudioAreCheckedAtTurnOn() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio([:])
        defer { try? FileManager.default.removeItem(at: dir) }
        let backed = noteWithAudio(store, "b.wav"), lost = noteWithAudio(store, "c.wav")
        for id in [backed, lost] {
            store.manifests[id] = NoteAudioManifest(sha256: "x", bytes: 60_000_000, partSize: 50_000_000, parts: 2)
        }
        for index in 0..<2 {
            engine.stamps[NoteAudioPartID(noteID: backed, index: index)] = NoteAudioPartStamp(fileName: "b.wav", fileBytes: 60_000_000)
        }
        engine.stamps[NoteAudioPartID(noteID: lost, index: 0)] = NoteAudioPartStamp(fileName: "c.wav", fileBytes: 60_000_000)
        coordinator.startInitialUpload()
        await coordinator.lastAudioCheck?.value
        precondition(store.manifests[backed] != nil)
        precondition(store.manifests[lost] == nil && engine.audioSaves.isEmpty)
        precondition(engine.saves.filter { $0 == lost }.count == 1, "the cleared marker goes up")
        precondition(engine.saves.contains(backed))
    }

    /// Parts can go up out of order (a failed one is queued again). After a
    /// relaunch the part count comes from the file, not the waiting parts.
    @MainActor
    static func testDeleteAfterRelaunchCountsPartsFromTheFile() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 120_000_000])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        engine.pendingAudio = [NoteAudioPartID(noteID: id, index: 1)]
        coordinator.resumeAudioUploads()
        await coordinator.lastAudioCheck?.value
        store.records[id] = nil
        coordinator.handleLocalChanges([.deleted(id, wasSynced: true, audioParts: 0)])
        precondition(engine.audioDeletes == parts(id, 3))
    }

    @MainActor
    static func testRemoteDeletionUsesThisMacsMarker() throws {
        let (coordinator, store, engine, dir) = try makeWithAudio([:])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store, "b.wav")
        store.manifests[id] = NoteAudioManifest(sha256: "x", bytes: 120_000_000, partSize: 50_000_000, parts: 3)
        _ = coordinator.handleFetched([], deletions: [id])
        precondition(engine.audioDeletes == parts(id, 3))
    }

    /// A coordinator replaced by a restart must not write a marker whose
    /// note save goes to its stopped engine.
    @MainActor
    static func testStoppedCoordinatorWritesNoMarker() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        engine.stamps[NoteAudioPartID(noteID: id, index: 0)] = smallStamp
        engine.onLookup = { coordinator.stop() }
        coordinator.resumeAudioUploads()
        await coordinator.lastAudioCheck?.value
        precondition(store.manifests[id] == nil && engine.saves.isEmpty)
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
        precondition(coordinator.status == .paused(.quotaExceeded(pending: 2)), "notes still waiting for space aren't up to date")
        coordinator.handleFetchFinished(pending: 0)
        precondition(coordinator.status == .upToDate(t0), "once the retried notes went up, the pause clears")
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

    @MainActor
    static func testUnavailableStoreAsksForFullRefetch() throws {
        let (coordinator, store, _) = make()
        var refetches = 0
        coordinator.onNeedsFullRefetch = { refetches += 1 }
        store.applyError = PipelineHistoryStoreError.storeUnavailable
        _ = coordinator.handleFetched([try fetched(record())], deletions: [])
        precondition(refetches == 1, "a record the store couldn't take is fetched again from the start")
        store.applyError = nil
        store.isReadyForSync = false
        let change = coordinator.handleFetched([try fetched(record())], deletions: [UUID()])
        precondition(refetches == 2 && store.applied.isEmpty && store.removed.isEmpty && change == NoteSyncRemoteChange())
    }

    @MainActor
    static func testFailedSavesAreRetriedAfterTheNextSync() {
        let (coordinator, _, engine) = make()
        let full = UUID(), other = UUID()
        coordinator.handleSendFailures([.quotaExceeded(noteID: full), .other(noteID: other)])
        precondition(engine.saves.isEmpty)
        coordinator.handleFetchFinished(pending: 0)
        precondition(Set(engine.saves) == [full, other], "notes that couldn't upload are tried again")
        coordinator.handleFetchFinished(pending: 0)
        precondition(engine.saves.count == 2, "each failure is retried once per failure")
    }

    /// A note deleted here whose iCloud delete failed is deleted again,
    /// never re-sent as a save that is dropped and leaves it in iCloud.
    @MainActor
    static func testFailedDeleteIsRetriedAsADelete() {
        let (coordinator, store, engine) = make()
        let gone = UUID()
        coordinator.handleSendFailures([.deleteFailed(noteID: gone)])
        coordinator.handleFetchFinished(pending: 0)
        precondition(engine.deletes == [gone] && engine.saves.isEmpty)
        coordinator.handleFetchFinished(pending: 0)
        precondition(engine.deletes == [gone], "retried once per failure")

        // A note back on this Mac (another Mac's edit arrived) isn't deleted.
        let back = record()
        coordinator.handleSendFailures([.deleteFailed(noteID: back.noteID)])
        store.records[back.noteID] = back
        coordinator.handleFetchFinished(pending: 0)
        precondition(!engine.deletes.contains(back.noteID))
    }

    /// A send that fails after sync stopped (for an account change) must
    /// not replace the stop with a quota or offline pause and resume.
    @MainActor
    static func testLateFailuresDoNotRestartStoppedSync() {
        let (coordinator, store, engine) = make()
        let note = record()
        store.records[note.noteID] = note
        store.syncable = [note.noteID]
        coordinator.handleAccountChange(signedOut: false)
        coordinator.handleSendFailures([.quotaExceeded(noteID: note.noteID), .network(noteID: note.noteID), .deleteFailed(noteID: UUID())])
        precondition(coordinator.status == .paused(.accountChanged))
        coordinator.handleFetchFinished(pending: 0)
        precondition(engine.saves.isEmpty && engine.deletes.isEmpty, "nothing reaches the new account")
    }

    /// A note deleted here while offline, then edited on another Mac, comes
    /// back with that edit; the delete still waiting to go up is cancelled
    /// so it can't remove the note from iCloud.
    @MainActor
    static func testNoteBackFromAnotherMacCancelsItsDelete() throws {
        let (coordinator, store, engine) = make()
        let note = record()
        coordinator.handleSendFailures([.deleteFailed(noteID: note.noteID)])
        _ = coordinator.handleFetched([try fetched(note)], deletions: [])
        precondition(engine.cancelledDeletes == [note.noteID])
        store.records[note.noteID] = nil
        coordinator.handleFetchFinished(pending: 0)
        precondition(engine.deletes.isEmpty, "the retry is cancelled too")
    }

    /// Saving with a change tag for a record iCloud no longer has keeps
    /// failing; the tag is dropped so the next try saves it fresh.
    @MainActor
    static func testSaveOfAMissingRecordStartsFresh() {
        let (coordinator, store, engine) = make()
        let note = record()
        store.records[note.noteID] = note
        store.syncable = [note.noteID]
        store.systemFields[note.noteID] = Data([7])
        coordinator.handleSendFailures([.unknownItemOnSave(noteID: note.noteID)])
        precondition(store.systemFields[note.noteID] == nil)
        coordinator.handleFetchFinished(pending: 0)
        precondition(engine.saves == [note.noteID])
    }
}
