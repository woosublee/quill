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
        testDeleteRetryWaitsWhileTheStoreCantBeRead()
        testAccountNeedingAttentionPausesUntilAChangeGoesThrough()
        testAudioAccountFailureOnlyPauses()
        testOfflineDoesNotReplaceTheAccountNotice()
        await testUnreadableNoteIsNeverDeletedAfterASend()
        try await testUnreadableNoteKeepsItsParts()
        testLateFailuresDoNotRestartStoppedSync()
        try testNoteBackFromAnotherMacCancelsItsDelete()
        testSaveOfAMissingRecordStartsFresh()
        testLosingTheNetworkShowsOffline()
        try await testAudioIsNamedAfterItsFileAndQueuedInParts()
        try await testAudioIsQueuedOnceAndNeverWhenInICloud()
        try await testManifestIsWrittenAfterTheLastPart()
        try await testFirstUploadCountsAudio()
        try await testDeleteRemovesMarkedParts()
        try await testDeleteMidUploadLooksUpItsParts()
        try testAudioFailuresPauseAndRetry()
        try testOutgoingAudioDropsStaleParts()
        try await testResumeQueuesAudioLeftFromLastRun()
        try await testResumeFinishesAudioWithoutReadingItAgain()
        try await testManifestWaitsForEveryPartInICloud()
        try await testPartWaitingForRetryKeepsTheMarkerOff()
        try await testReplacedAudioDeletesTheEarlierParts()
        try await testCleanUpKeepsPartsTheNoteStillUses()
        try await testStaleMarkerIsClearedAtTurnOn()
        try await testLookupFailureIsRetriedAfterTheNextSync()
        try await testUnreadableAudioIsTriedAgain()
        try await testRemoteDeletionRemovesThisMacsParts()
        try await testRemoteDeletionUsesThisMacsMarker()
        try await testPurgeFindsPartsAnotherMacLeft()
        await testPartSavedAfterItsNoteIsGoneIsDeleted()
        try testFailingPartIsGivenUpAfterThreeTries()
        try testFullICloudCountsTowardTheRetryLimit()
        try await testTurnOnReadsWaitingPartsOnce()
        try testDeletedNoteNoLongerHoldsUpProgress()
        try testEmptyAudioDoesNotHoldUpProgress()
        try testAccountChangeKeepsAudioMarkers()
        try testZoneDeletedElsewhereForgetsAudioMarkers()
        try await testMarkerClearedElsewhereIsCheckedAgain()
        try await testMarkersWithoutLocalAudioAreCheckedAtTurnOn()
        try await testStoppedCoordinatorWritesNoMarker()
        try await testMarkedNotesGoUpOnlyAfterTheCheck()
        try await testHeldNoteEditedDuringItsCheckStillWaits()
        try await testHeldNoteDeletedDuringItsCheckIsNotSent()
        try await testEditAfterAGivenUpPartChecksICloudFirst()
        try testStatusStaysBusyWhileAudioIsRetried()
        try await testAudioChangedDuringCheckIsCheckedAgain()
        try await testEmptyLocalFileStillChecksTheMarker()
        try testGivenUpNotesAreNotLookedUpOnRemoteEdits()
        try await testTurnOnSendsEachNoteAsSoonAsItIsRead()
        try await testReplacedWithTheSameBytesKeepsTheParts()
        try await testFileChangedOnAnotherMacCleansUpThisMacsParts()
        try testReturnedNoteKeepsItsAudio()
        try await testMissingPartChecksTheMarker()
        try await testReturnedNoteDropsItsWaitingCleanUp()
        try await testUnbackedMarkerForAnotherFileUploadsTheFileHere()
        try await testLocalReplaceCleansUpPartsNoMarkerNamed()
        try await testLocalReplaceLeavesAnotherMacsUpload()
        try await testLocalReplaceLooksUpPartsWaitingToRetry()
        try await testNoteBackDuringItsCleanUpKeepsItsParts()
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
        /// The store couldn't be read.
        var readFails = false
        func noteExists(id: UUID) -> Bool? { readFails ? nil : records[id] != nil }
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
            onApply?(record)
            return applyResult
        }
        var manifests: [UUID: NoteAudioManifest] = [:]
        func audioManifest(id: UUID) -> NoteAudioManifest? { manifests[id] }
        func setAudioManifest(_ manifest: NoteAudioManifest?, id: UUID) throws { manifests[id] = manifest }
        var uploadKeys: [UUID: String] = [:]
        func audioUploadKey(id: UUID) -> String? { uploadKeys[id] }
        func setAudioUploadKey(_ key: String?, id: UUID) throws { uploadKeys[id] = key }
        var clearedKeys: [UUID: String] = [:]
        func takeClearedAudioUploadKeys() -> [UUID: String] {
            defer { clearedKeys = [:] }
            return clearedKeys
        }
        /// What the real store does to the note when a record is applied.
        var onApply: ((NoteSyncRecord) -> Void)?
        func removeSynced(id: UUID) throws -> DeletedPipelineHistoryAssets? {
            removed.append(id)
            records[id] = nil
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
        var cancelledAudioDeletes: [UUID] = []
        func cancelAudioDeletes(noteID: UUID) {
            cancelledAudioDeletes.append(noteID)
            audioDeletes.removeAll { $0.noteID == noteID }
        }
        func cancelAudioDeletes(_ parts: [NoteAudioPartID]) {
            audioDeletes.removeAll(where: parts.contains)
        }
        /// Parts iCloud holds.
        var iCloud: Set<NoteAudioPartID> = []
        var lookupError: Error?
        var onLookup: (() -> Void)?
        var lookups = 0
        func existingAudioParts(_ parts: [NoteAudioPartID]) async throws -> Set<NoteAudioPartID> {
            lookups += 1
            onLookup?()
            if let lookupError { throw lookupError }
            return iCloud.intersection(parts)
        }
        /// Runs while the notes' parts are being listed.
        var onListParts: (() -> Void)?
        func audioParts(ofNotes ids: Set<UUID>) async throws -> [NoteAudioPartID] {
            lookups += 1
            onListParts?()
            if let lookupError { throw lookupError }
            return iCloud.filter { ids.contains($0.noteID) }.sorted { $0.recordName < $1.recordName }
        }
        /// What CKSyncEngine does when a part is saved.
        func finish(_ part: NoteAudioPartID) {
            pendingAudio.removeAll { $0 == part }
            iCloud.insert(part)
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

    /// A made-up SHA-256 for a synthetic file, different per file name.
    static func sha(_ name: String) -> String {
        let hex = name.utf8.map { String(format: "%02x", $0) }.joined()
        return String((hex + String(repeating: "0", count: 64)).prefix(64))
    }

    /// Reads of audio files to hash them, and whether they fail.
    @MainActor static var hashReads = 0
    @MainActor static var hashFails = false
    @MainActor static var onHash: (() -> Void)?

    @MainActor
    static func makeWithAudio(_ files: [String: Int64]) throws -> (NoteSyncCoordinator, FakeStore, FakeEngine, URL) {
        let store = FakeStore()
        let engine = FakeEngine()
        let dir = try audioDirectory(files: files)
        hashReads = 0
        hashFails = false
        onHash = nil
        let coordinator = NoteSyncCoordinator(
            store: store,
            engine: engine,
            now: { t0 },
            localAudioURL: { name in
                let url = dir.appendingPathComponent(name)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            },
            hashFile: { url in
                await MainActor.run {
                    hashReads += 1
                    onHash?()
                }
                if await MainActor.run(body: { hashFails }) { throw CocoaError(.fileReadUnknown) }
                return sha(url.lastPathComponent)
            }
        )
        return (coordinator, store, engine, dir)
    }

    static func record(_ id: UUID = UUID(), audio: String) -> NoteSyncRecord {
        var note = record(id)
        note.fields[NoteSyncField.audioFileName.rawValue] = .string(audio)
        return note
    }

    /// The parts of `file`'s audio for this note.
    static func parts(_ id: UUID, _ count: Int, _ file: String = "a.wav") -> [NoteAudioPartID] {
        NoteAudioPartID.parts(of: id, sha256: sha(file), count: count)
    }

    static func manifest(_ file: String = "a.wav", bytes: Int64 = 10, parts: Int = 1) -> NoteAudioManifest {
        NoteAudioManifest(sha256: sha(file), bytes: bytes, partSize: 50_000_000, parts: parts)
    }

    @MainActor
    static func noteWithAudio(_ store: FakeStore, _ file: String = "a.wav") -> UUID {
        let note = record(audio: file)
        store.records[note.noteID] = note
        store.syncable.insert(note.noteID)
        return note.noteID
    }

    @MainActor
    static func testAudioIsNamedAfterItsFileAndQueuedInParts() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 120_000_000])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        coordinator.handleLocalChanges([.saved(id)])
        precondition(engine.saves == [id], "text goes first")
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioSaves == parts(id, 3))
        precondition(engine.audioSaves[0].recordName == "\(id.uuidString)-\(sha("a.wav").prefix(16))-0")
        precondition(store.uploadKeys[id] == sha("a.wav"), "the hash is kept, so it is read once")
    }

    @MainActor
    static func testAudioIsQueuedOnceAndNeverWhenInICloud() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10, "b.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let queued = noteWithAudio(store), uploaded = noteWithAudio(store, "b.wav"), missing = noteWithAudio(store, "c.wav")
        store.manifests[uploaded] = manifest("b.wav")
        coordinator.handleLocalChanges([.saved(queued), .saved(uploaded), .saved(missing)])
        await coordinator.lastAudioCheck?.value
        coordinator.handleLocalChanges([.saved(queued)])
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioSaves == parts(queued, 1), "once, and only audio that is here and not in iCloud")
    }

    @MainActor
    static func testManifestIsWrittenAfterTheLastPart() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 60_000_000])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        coordinator.handleLocalChanges([.saved(id)])
        await coordinator.lastAudioCheck?.value
        engine.saves = []
        let both = parts(id, 2)
        engine.finish(both[0])
        await coordinator.handleAudioPartSaved(both[0])
        precondition(store.manifests[id] == nil, "a part is still waiting")
        engine.finish(both[1])
        await coordinator.handleAudioPartSaved(both[1])
        precondition(store.manifests[id] == manifest(bytes: 60_000_000, parts: 2))
        precondition(engine.saves == [id], "the note goes up again with its manifest")
        precondition(hashReads == 1, "the file is read once, before its parts go up")
    }

    @MainActor
    static func testFirstUploadCountsAudio() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let withAudio = noteWithAudio(store), textOnly = record()
        store.records[textOnly.noteID] = textOnly
        store.syncable.insert(textOnly.noteID)
        coordinator.startInitialUpload()
        precondition(coordinator.status == .uploading(done: 0, total: 2))
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioSaves == parts(withAudio, 1), "iCloud doesn't have it yet")
        coordinator.handleSaved(id: withAudio, systemFields: Data([1]))
        coordinator.handleSaved(id: textOnly.noteID, systemFields: Data([1]))
        precondition(coordinator.status == .uploading(done: 1, total: 2), "the note with audio isn't done yet")
        engine.finish(parts(withAudio, 1)[0])
        await coordinator.handleAudioPartSaved(parts(withAudio, 1)[0])
        precondition(coordinator.status == .uploading(done: 2, total: 2))
    }

    @MainActor
    static func testDeleteRemovesMarkedParts() async throws {
        let (coordinator, _, engine, dir) = try makeWithAudio([:])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let marker = manifest(bytes: 120_000_000, parts: 3)
        coordinator.handleLocalChanges([.deleted(id, wasSynced: true, audio: NoteAudioSyncState(manifest: marker, uploadKey: marker.sha256))])
        precondition(engine.audioDeletes == marker.partIDs(noteID: id))
        precondition(coordinator.lastAudioCheck == nil, "the marker names every part: nothing to look up")
    }

    /// Deleted mid-upload: waiting parts never go up, and the parts already
    /// sent are found and deleted.
    @MainActor
    static func testDeleteMidUploadLooksUpItsParts() async throws {
        let (coordinator, _, engine, dir) = try makeWithAudio([:])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let all = parts(id, 3)
        engine.iCloud = [all[0]]
        engine.pendingAudio = Array(all.suffix(2))
        coordinator.handleLocalChanges([.deleted(id, wasSynced: true, audio: NoteAudioSyncState(uploadKey: sha("a.wav")))])
        precondition(engine.pendingAudio.isEmpty, "waiting parts never go up")
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioDeletes == [all[0]])
    }

    @MainActor
    static func testAudioFailuresPauseAndRetry() throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        store.uploadKeys[id] = sha("a.wav")
        let part = parts(id, 1)[0]
        let gone = parts(UUID(), 1)[0]
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
        let id = noteWithAudio(store)
        let part = parts(id, 1)[0]
        precondition(coordinator.outgoingAudio(for: part) == nil, "a part with no upload key behind it")
        store.uploadKeys[id] = sha("a.wav")
        precondition(coordinator.outgoingAudio(for: part) == NoteSyncOutgoingAudio(
            part: part, fileURL: dir.appendingPathComponent("a.wav"), byteCount: 10
        ))
        precondition(coordinator.outgoingAudio(for: parts(id, 2)[1]) == nil, "past the end")
        precondition(coordinator.outgoingAudio(for: parts(id, 1, "old.wav")[0]) == nil, "named for another file")
        store.manifests[id] = manifest()
        precondition(coordinator.outgoingAudio(for: part) == nil, "already in iCloud")
    }

    @MainActor
    static func testResumeQueuesAudioLeftFromLastRun() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10, "b.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let waiting = noteWithAudio(store), notStarted = noteWithAudio(store, "b.wav")
        engine.pendingAudio = parts(waiting, 1)
        coordinator.resumeAudioUploads()
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioSaves == parts(notStarted, 1, "b.wav"), "parts still waiting are not queued twice")
    }

    /// Quit after the last part went up but before the marker was written:
    /// the marker is written without reading or sending the audio again.
    @MainActor
    static func testResumeFinishesAudioWithoutReadingItAgain() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        store.uploadKeys[id] = sha("a.wav")
        engine.iCloud = Set(parts(id, 1))
        coordinator.resumeAudioUploads()
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioSaves.isEmpty && hashReads == 0)
        precondition(store.manifests[id] == manifest() && engine.saves == [id])
    }

    /// A part dropped before it was sent leaves the marker off, and goes up again.
    @MainActor
    static func testManifestWaitsForEveryPartInICloud() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 60_000_000])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        coordinator.handleLocalChanges([.saved(id)])
        await coordinator.lastAudioCheck?.value
        let both = parts(id, 2)
        engine.pendingAudio.removeAll { $0 == both[1] }
        engine.audioSaves = []
        engine.finish(both[0])
        await coordinator.handleAudioPartSaved(both[0])
        precondition(store.manifests[id] == nil, "a part iCloud doesn't have keeps the marker off")
        precondition(engine.audioSaves == [both[1]], "the missing part goes up again")
        engine.finish(both[1])
        await coordinator.handleAudioPartSaved(both[1])
        precondition(store.manifests[id]?.parts == 2)
    }

    @MainActor
    static func testPartWaitingForRetryKeepsTheMarkerOff() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 60_000_000])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        coordinator.handleLocalChanges([.saved(id)])
        await coordinator.lastAudioCheck?.value
        let both = parts(id, 2)
        engine.pendingAudio.removeAll { $0 == both[1] }
        coordinator.handleAudioSendFailures([.failed(both[1])])
        engine.audioSaves = []
        engine.finish(both[0])
        await coordinator.handleAudioPartSaved(both[0])
        precondition(store.manifests[id] == nil && engine.audioSaves.isEmpty, "the failed part waits for its retry")
    }

    /// The store reports the earlier audio before the note's save: its
    /// marked parts are deleted and the new file goes up under its own name.
    @MainActor
    static func testReplacedAudioDeletesTheEarlierParts() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["b.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store, "b.wav")
        let earlier = manifest("a.wav", bytes: 120_000_000, parts: 3)
        coordinator.handleLocalChanges([
            .audioReplaced(id, previous: NoteAudioSyncState(manifest: earlier, uploadKey: earlier.sha256)),
            .saved(id)
        ])
        precondition(engine.audioDeletes == earlier.partIDs(noteID: id), "queued at once, so a quit can't lose them")
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioDeletes == earlier.partIDs(noteID: id))
        precondition(engine.audioSaves == parts(id, 1, "b.wav"))
    }

    /// The new file has the same bytes as the earlier one: its parts are
    /// the same parts, so none is deleted.
    @MainActor
    static func testReplacedWithTheSameBytesKeepsTheParts() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["b.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store, "b.wav")
        let earlier = manifest("b.wav")
        engine.iCloud = Set(earlier.partIDs(noteID: id))
        coordinator.handleLocalChanges([
            .audioReplaced(id, previous: NoteAudioSyncState(manifest: earlier, uploadKey: earlier.sha256)),
            .saved(id)
        ])
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioDeletes.isEmpty && store.manifests[id] == earlier)
    }

    /// Turning sync on with a large library: the first note's parts go up
    /// before the next file is read, and marked notes don't wait for it.
    @MainActor
    static func testTurnOnSendsEachNoteAsSoonAsItIsRead() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10, "b.wav": 10, "c.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = noteWithAudio(store, "a.wav")
        _ = noteWithAudio(store, "b.wav")
        let marked = noteWithAudio(store, "c.wav")
        store.manifests[marked] = manifest("c.wav")
        engine.iCloud = Set(parts(marked, 1, "c.wav"))
        var sentBeforeEachRead: [Int] = []
        var markedReleased = false
        onHash = {
            sentBeforeEachRead.append(engine.audioSaves.count)
            markedReleased = markedReleased || engine.saves.contains(marked)
        }
        coordinator.startInitialUpload()
        await coordinator.lastAudioCheck?.value
        precondition(sentBeforeEachRead == [0, 1], "each note goes up as soon as its file is read")
        precondition(markedReleased, "a marked note goes up without waiting for files to be read")
    }

    /// Another Mac gave the note a new audio file while this Mac was
    /// sending the old one: what this Mac sent is cleaned up.
    @MainActor
    static func testFileChangedOnAnotherMacCleansUpThisMacsParts() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 120_000_000])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        store.uploadKeys[id] = sha("a.wav")
        let sent = parts(id, 3)
        engine.iCloud = [sent[0]]
        store.applyResult = .updated(needsUpload: false)
        store.onApply = { record in
            store.records[id] = record
            store.clearedKeys[id] = store.uploadKeys[id]
            store.uploadKeys[id] = nil
        }
        // The other Mac's upload of its new file, still without a marker.
        let theirs = parts(id, 1, "elsewhere.wav")
        engine.iCloud.formUnion(theirs)
        _ = coordinator.handleFetched([try fetched(record(id, audio: "elsewhere.wav"))], deletions: [])
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioDeletes == [sent[0]], "only what this Mac sent; the other Mac's upload stays")
    }

    /// A marker iCloud can't back, for a file of another size than this
    /// Mac's: the file here is read and sent under its own name.
    @MainActor
    static func testUnbackedMarkerForAnotherFileUploadsTheFileHere() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        store.manifests[id] = NoteAudioManifest(sha256: sha("other.wav"), bytes: 99, partSize: 50_000_000, parts: 1)
        coordinator.startInitialUpload()
        await coordinator.lastAudioCheck?.value
        precondition(store.manifests[id] == nil && engine.audioSaves == parts(id, 1))
    }

    /// The audio here changed while this Mac's upload of the earlier file
    /// had stopped partway (no marker): those parts are found and go.
    @MainActor
    static func testLocalReplaceCleansUpPartsNoMarkerNamed() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["b.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store, "b.wav")
        let left = parts(id, 2, "a.wav")
        engine.iCloud = Set(left)
        coordinator.handleLocalChanges([.audioReplaced(id, previous: NoteAudioSyncState(uploadKey: sha("a.wav"))), .saved(id)])
        await coordinator.lastAudioCheck?.value
        engine.lookups = 0
        coordinator.handleFetchFinished(pending: 0)
        await coordinator.lastAudioCheck?.value
        precondition(Set(engine.audioDeletes) == Set(left))
        precondition(engine.audioSaves == parts(id, 1, "b.wav"))
    }

    /// The note is still here, so only what this Mac sent goes: another
    /// Mac's upload for the same note, still without a marker, stays.
    @MainActor
    static func testLocalReplaceLeavesAnotherMacsUpload() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["b.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store, "b.wav")
        let mine = parts(id, 1, "a.wav"), theirs = parts(id, 2, "elsewhere.wav")
        engine.iCloud = Set(mine + theirs)
        coordinator.handleLocalChanges([.audioReplaced(id, previous: NoteAudioSyncState(uploadKey: sha("a.wav"))), .saved(id)])
        await coordinator.lastAudioCheck?.value
        coordinator.handleFetchFinished(pending: 0)
        await coordinator.lastAudioCheck?.value
        precondition(Set(engine.audioDeletes) == Set(mine), "the other Mac's upload stays")

        let (quiet, quietStore, quietEngine, quietDir) = try makeWithAudio(["b.wav": 10])
        defer { try? FileManager.default.removeItem(at: quietDir) }
        let quietID = noteWithAudio(quietStore, "b.wav")
        quietEngine.iCloud = Set(parts(quietID, 2, "elsewhere.wav"))
        quiet.handleLocalChanges([.audioReplaced(quietID, previous: NoteAudioSyncState())])
        await quiet.lastAudioCheck?.value
        precondition(quietEngine.audioDeletes.isEmpty && quietEngine.lookups == 0, "nothing sent from here, nothing to look up")
    }

    /// A part of the earlier file failed and waits to be retried (its
    /// upload key already cleared): it was sent from here, so the file's
    /// parts are looked up and go.
    @MainActor
    static func testLocalReplaceLooksUpPartsWaitingToRetry() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["b.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store, "b.wav")
        let mine = parts(id, 2, "a.wav")
        engine.iCloud = [mine[0]]
        coordinator.handleAudioSendFailures([.failed(mine[1])])
        coordinator.handleLocalChanges([.audioReplaced(id, previous: NoteAudioSyncState())])
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioDeletes == [mine[0]], "the part already saved goes")
    }

    /// Deleted here with no marker, so every part of the note is looked
    /// for; while the lookup runs, a fetch brings the note back with
    /// another Mac's upload. Nothing of it is deleted.
    @MainActor
    static func testNoteBackDuringItsCleanUpKeepsItsParts() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio([:])
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = record(audio: "b.wav")
        let theirs = parts(note.noteID, 2, "b.wav")
        engine.iCloud = Set(theirs)
        engine.onListParts = {
            engine.onListParts = nil
            store.records[note.noteID] = note
        }
        coordinator.handleLocalChanges([.deleted(note.noteID, wasSynced: true, audio: NoteAudioSyncState())])
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioDeletes.isEmpty, "a note that came back keeps its parts")
    }

    /// A note deleted here while offline and edited on another Mac comes
    /// back with its marker: its audio deletes are cancelled too.
    @MainActor
    static func testReturnedNoteKeepsItsAudio() throws {
        let (coordinator, store, engine, dir) = try makeWithAudio([:])
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = record(audio: "b.wav")
        let marker = manifest("b.wav")
        coordinator.handleLocalChanges([.deleted(note.noteID, wasSynced: true, audio: NoteAudioSyncState(manifest: marker))])
        coordinator.handleAudioSendFailures([.deleteFailed(marker.partIDs(noteID: note.noteID)[0])])
        store.applyResult = .inserted
        _ = coordinator.handleFetched([try fetched(note)], deletions: [])
        precondition(engine.cancelledAudioDeletes == [note.noteID] && engine.audioDeletes.isEmpty)
        coordinator.handleFetchFinished(pending: 0)
        precondition(engine.audioDeletes.isEmpty, "the failed delete isn't retried either")
    }

    /// A marked note whose parts are gone from iCloud: a delete this Mac
    /// or another sent before the note came back can't be recalled.
    @MainActor
    static func lostMarkedNote() throws -> (NoteSyncCoordinator, FakeStore, FakeEngine, URL, UUID) {
        let (coordinator, store, engine, dir) = try makeWithAudio([:])
        let note = record(audio: "b.wav")
        store.records[note.noteID] = note
        store.syncable.insert(note.noteID)
        store.manifests[note.noteID] = manifest("b.wav")
        return (coordinator, store, engine, dir, note.noteID)
    }

    /// A download found a part missing: the marker is checked, and cleared
    /// so the Mac with the file sends it again.
    @MainActor
    static func testMissingPartChecksTheMarker() async throws {
        let (coordinator, store, engine, dir, id) = try lostMarkedNote()
        defer { try? FileManager.default.removeItem(at: dir) }
        coordinator.handleAudioMissing(noteID: id)
        await coordinator.lastAudioCheck?.value
        precondition(store.manifests[id] == nil, "a marker iCloud can't back is cleared")
        precondition(engine.saves.contains(id), "the cleared marker goes up")
    }

    /// Deleted here while offline, with a clean-up still waiting; another
    /// Mac edited it and is uploading new audio. The note comes back, and
    /// the waiting clean-up must not delete that upload.
    @MainActor
    static func testReturnedNoteDropsItsWaitingCleanUp() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio([:])
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = record(audio: "b.wav")
        engine.lookupError = URLError(.notConnectedToInternet)
        coordinator.handleLocalChanges([.deleted(note.noteID, wasSynced: true, audio: NoteAudioSyncState())])
        await coordinator.lastAudioCheck?.value
        engine.lookupError = nil
        let theirs = parts(note.noteID, 1, "b.wav")
        engine.iCloud = Set(theirs)
        store.applyResult = .inserted
        store.onApply = { store.records[$0.noteID] = $0 }
        _ = coordinator.handleFetched([try fetched(note)], deletions: [])
        coordinator.handleFetchFinished(pending: 0)
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioDeletes.isEmpty, "the other Mac's upload stays")
    }

    /// An upload of an earlier file was cut short (no marker names its
    /// parts): they are found and deleted; the new file's parts stay.
    @MainActor
    static func testCleanUpKeepsPartsTheNoteStillUses() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["b.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store, "b.wav")
        store.uploadKeys[id] = sha("b.wav")
        let marked = noteWithAudio(store, "c.wav")
        store.manifests[marked] = manifest("c.wav")
        let old = parts(id, 2, "a.wav"), current = parts(id, 1, "b.wav")
        let markedOld = parts(marked, 1, "a.wav"), markedCurrent = parts(marked, 1, "c.wav")
        engine.iCloud = Set(old + current + markedOld + markedCurrent)
        func keys(_ files: String...) -> Set<String> { Set(files.map { NoteAudioPartID.key(sha256: sha($0)) }) }
        // Each note's target names its current key too: the upload key
        // keeps one, the marker the other.
        await coordinator.cleanUpAudio([id: keys("a.wav", "b.wav"), marked: keys("a.wav", "c.wav")])
        precondition(Set(engine.audioDeletes) == Set(old + markedOld))
    }

    /// A Mac that was off when iCloud lost the audio still holds the
    /// marker; turning sync on finds the parts missing and sends them.
    @MainActor
    static func testStaleMarkerIsClearedAtTurnOn() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        store.manifests[id] = manifest()
        coordinator.startInitialUpload()
        await coordinator.lastAudioCheck?.value
        precondition(store.manifests[id] == nil, "iCloud lost this audio")
        precondition(engine.audioSaves == parts(id, 1) && store.uploadKeys[id] == sha("a.wav"))
        precondition(engine.saves == [id], "the note goes up once, with its marker cleared")
        precondition(hashReads == 1, "the file here is read, not assumed to be the marked one")

        let (kept, keptStore, keptEngine, keptDir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: keptDir) }
        let keptID = noteWithAudio(keptStore)
        keptStore.manifests[keptID] = manifest()
        keptEngine.iCloud = Set(parts(keptID, 1))
        kept.startInitialUpload()
        await kept.lastAudioCheck?.value
        precondition(keptStore.manifests[keptID] != nil && keptEngine.audioSaves.isEmpty, "audio in iCloud stays marked")
    }

    @MainActor
    static func testLookupFailureIsRetriedAfterTheNextSync() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        engine.lookupError = URLError(.notConnectedToInternet)
        coordinator.resumeAudioUploads()
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioSaves.isEmpty)
        engine.lookupError = nil
        coordinator.handleFetchFinished(pending: 0)
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioSaves == parts(id, 1), "checked again after the next sync")
    }

    @MainActor
    static func testUnreadableAudioIsTriedAgain() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        hashFails = true
        coordinator.handleLocalChanges([.saved(id)])
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioSaves.isEmpty && store.uploadKeys[id] == nil)
        hashFails = false
        coordinator.handleFetchFinished(pending: 0)
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioSaves == parts(id, 1))
    }

    /// Another Mac deleted the note for good while this Mac was sending its
    /// audio: nothing more goes up, and what went up is found and removed.
    @MainActor
    static func testRemoteDeletionRemovesThisMacsParts() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 120_000_000])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        coordinator.handleLocalChanges([.saved(id)])
        await coordinator.lastAudioCheck?.value
        let all = parts(id, 3)
        engine.finish(all[0])
        _ = coordinator.handleFetched([], deletions: [id])
        precondition(engine.pendingAudio.isEmpty, "nothing more goes up")
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioDeletes == [all[0]])
    }

    @MainActor
    static func testRemoteDeletionUsesThisMacsMarker() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio([:])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store, "b.wav")
        store.manifests[id] = manifest("b.wav", bytes: 120_000_000, parts: 3)
        _ = coordinator.handleFetched([], deletions: [id])
        precondition(engine.audioDeletes == parts(id, 3, "b.wav"))
    }

    /// A note this Mac can't read might still be here: its parts stay.
    @MainActor
    static func testUnreadableNoteKeepsItsParts() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio([:])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        engine.iCloud = Set(parts(id, 2, "x.wav"))
        store.readFails = true
        coordinator.handleLocalChanges([.deleted(id, wasSynced: true, audio: NoteAudioSyncState())])
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioDeletes.isEmpty, "a note that can't be read isn't taken for gone")
    }

    /// A failed delete is sent again only once the store says the note is
    /// gone; while it can't be read, the delete waits.
    @MainActor
    static func testDeleteRetryWaitsWhileTheStoreCantBeRead() {
        let (coordinator, store, engine) = make()
        let id = UUID()
        store.readFails = true
        coordinator.handleSendFailures([.deleteFailed(noteID: id)])
        coordinator.handleFetchFinished(pending: 0)
        precondition(engine.deletes.isEmpty, "a note that can't be read isn't deleted")
        if case .upToDate = coordinator.status { preconditionFailure("a waiting delete isn't up to date") }
        store.readFails = false
        coordinator.handleFetchFinished(pending: 0)
        precondition(engine.deletes == [id], "the delete goes once the note reads as gone")
    }

    /// iCloud needs the account looked at (a password, new terms): sync
    /// says so, and sending again is left to the engine (or the failure's
    /// own retry). The notice stays until a change goes through, then gives
    /// way to the sync it interrupted.
    @MainActor
    static func testAccountNeedingAttentionPausesUntilAChangeGoesThrough() {
        let (coordinator, store, engine) = make()
        let note = record()
        store.records[note.noteID] = note
        coordinator.handleSendFailures([.accountNeedsAttention])
        precondition(coordinator.status == .paused(.accountNeedsAttention))
        coordinator.handleFetchFinished(pending: 0)
        precondition(coordinator.status == .paused(.accountNeedsAttention), "a sync that sent nothing doesn't clear it")
        precondition(engine.saves.isEmpty && engine.deletes.isEmpty, "nothing is queued again by the coordinator")
        coordinator.handleSaved(id: note.noteID, systemFields: Data([1]))
        precondition(coordinator.status == .starting, "a save that went through clears it")
        coordinator.handleSendFailures([.accountNeedsAttention])
        coordinator.handleDeleted(id: UUID())
        precondition(coordinator.status == .starting, "so does a delete")
    }

    /// An audio part that fails on the account says so; it isn't queued
    /// again by the coordinator.
    @MainActor
    static func testAudioAccountFailureOnlyPauses() {
        let (coordinator, _, engine) = make()
        coordinator.handleAudioSendFailures([.accountNeedsAttention])
        precondition(coordinator.status == .paused(.accountNeedsAttention))
        coordinator.handleFetchFinished(pending: 0)
        precondition(engine.audioSaves.isEmpty && engine.audioDeletes.isEmpty)
    }

    /// Being offline doesn't hide an account to look at: coming back online
    /// would clear the notice while the account still needs attention.
    @MainActor
    static func testOfflineDoesNotReplaceTheAccountNotice() {
        let (coordinator, _, _) = make()
        coordinator.handleSendFailures([.accountNeedsAttention])
        coordinator.handleSendFailures([.network(noteID: UUID())])
        coordinator.handleNetworkChange(isOnline: false)
        precondition(coordinator.status == .paused(.accountNeedsAttention))
    }

    /// Notes that can't be read are left alone: a finished save, a
    /// conflict and a saved audio part never turn into deletes.
    @MainActor
    static func testUnreadableNoteIsNeverDeletedAfterASend() async {
        let (coordinator, store, engine) = make()
        let id = UUID()
        store.readFails = true
        coordinator.handleSaved(id: id, systemFields: Data([1]))
        coordinator.handleSendFailures([.serverChanged(noteID: id, serverPayload: nil, serverSystemFields: Data())])
        await coordinator.handleAudioPartSaved(parts(id, 1)[0])
        coordinator.handleFetchFinished(pending: 0)
        precondition(engine.deletes.isEmpty && engine.audioDeletes.isEmpty, "nothing is deleted for a note that can't be read")
        // The saved part's note is checked once it can be read.
        store.readFails = false
        store.records[id] = record(id)
        store.manifests[id] = manifest()
        engine.lookups = 0
        coordinator.handleFetchFinished(pending: 0)
        await coordinator.lastAudioCheck?.value
        precondition(engine.lookups > 0, "the note whose part went up is checked later")
    }

    /// A Mac erased mid-upload left parts and no marker; deleting the note
    /// for good here finds those parts and deletes them.
    @MainActor
    static func testPurgeFindsPartsAnotherMacLeft() async throws {
        let (coordinator, _, engine, dir) = try makeWithAudio([:])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID(), other = UUID()
        engine.iCloud = Set(parts(id, 3, "x.wav") + parts(other, 1, "x.wav"))
        coordinator.handleLocalChanges([.deleted(id, wasSynced: true, audio: NoteAudioSyncState())])
        await coordinator.lastAudioCheck?.value
        precondition(Set(engine.audioDeletes) == Set(parts(id, 3, "x.wav")), "only this note's parts")
        let quiet = UUID()
        engine.audioDeletes = []
        engine.lookups = 0
        coordinator.handleLocalChanges([.deleted(quiet, wasSynced: true)])
        precondition(engine.audioDeletes.isEmpty && engine.lookups == 0, "a note without audio has nothing to find")
    }

    @MainActor
    static func testPartSavedAfterItsNoteIsGoneIsDeleted() async {
        let (coordinator, _, engine) = make()
        let part = parts(UUID(), 1)[0]
        await coordinator.handleAudioPartSaved(part)
        precondition(engine.audioDeletes == [part], "a part in flight when its note was deleted is removed")
    }

    @MainActor
    static func testFailingPartIsGivenUpAfterThreeTries() throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        store.uploadKeys[id] = sha("a.wav")
        let part = parts(id, 1)[0]
        for _ in 0..<3 {
            coordinator.handleAudioSendFailures([.failed(part)])
            coordinator.handleFetchFinished(pending: 1)
        }
        precondition(engine.audioSaves == [part, part], "two retries, then it waits for the next launch")
    }

    /// With iCloud full, a 50 MB part isn't sent again after every sync.
    @MainActor
    static func testFullICloudCountsTowardTheRetryLimit() throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        store.uploadKeys[id] = sha("a.wav")
        let part = parts(id, 1)[0]
        for _ in 0..<3 {
            coordinator.handleAudioSendFailures([.quotaExceeded(part)])
            coordinator.handleFetchFinished(pending: 1)
        }
        precondition(engine.audioSaves == [part, part])
        precondition(coordinator.status == .paused(.quotaExceeded(pending: 1)), "still shown as out of space")
    }

    /// Notes whose part names are known are checked together, so waiting
    /// parts are read once for them, not once per note.
    @MainActor
    static func testTurnOnReadsWaitingPartsOnce() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        for _ in 0..<50 {
            let id = noteWithAudio(store)
            store.uploadKeys[id] = sha("a.wav")
        }
        coordinator.startInitialUpload()
        await coordinator.lastAudioCheck?.value
        precondition(engine.pendingAudioReads <= 2, "not once per note")
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

    @MainActor
    static func testEmptyAudioDoesNotHoldUpProgress() throws {
        let (coordinator, store, _, dir) = try makeWithAudio(["a.wav": 0])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        coordinator.startInitialUpload()
        coordinator.handleSaved(id: id, systemFields: Data([1]))
        precondition(coordinator.status == .uploading(done: 1, total: 1), "an empty file has nothing to send")
    }

    /// Signing back into the same account finds the audio still there, so
    /// markers stay; turning sync on checks them against iCloud.
    @MainActor
    static func testAccountChangeKeepsAudioMarkers() throws {
        let (coordinator, store, _, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        store.manifests[id] = manifest()
        coordinator.handleAccountChange(signedOut: true)
        precondition(store.clearedSystemFields && store.manifests[id] != nil)
    }

    @MainActor
    static func testZoneDeletedElsewhereForgetsAudioMarkers() throws {
        let (coordinator, store, _, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        store.manifests[id] = manifest()
        coordinator.handleZoneDeleted()
        precondition(store.manifests[id] == nil, "iCloud lost this audio")
    }

    /// Another Mac cleared the marker (it learned late that iCloud lost the
    /// audio): the Mac with the file checks iCloud and marks it again.
    @MainActor
    static func testMarkerClearedElsewhereIsCheckedAgain() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        store.uploadKeys[id] = sha("a.wav")
        engine.iCloud = Set(parts(id, 1))
        store.applyResult = .updated(needsUpload: false)
        _ = coordinator.handleFetched([try fetched(store.records[id]!)], deletions: [])
        await coordinator.lastAudioCheck?.value
        precondition(store.manifests[id] != nil && engine.audioSaves.isEmpty)
    }

    /// Audio another Mac recorded: kept marked when iCloud has it, cleared
    /// when it doesn't.
    @MainActor
    static func testMarkersWithoutLocalAudioAreCheckedAtTurnOn() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio([:])
        defer { try? FileManager.default.removeItem(at: dir) }
        let backed = noteWithAudio(store, "b.wav"), lost = noteWithAudio(store, "c.wav")
        store.manifests[backed] = manifest("b.wav", bytes: 60_000_000, parts: 2)
        store.manifests[lost] = manifest("c.wav", bytes: 60_000_000, parts: 2)
        engine.iCloud = Set(parts(backed, 2, "b.wav") + [parts(lost, 1, "c.wav")[0]])
        coordinator.startInitialUpload()
        await coordinator.lastAudioCheck?.value
        precondition(store.manifests[backed] != nil)
        precondition(store.manifests[lost] == nil && engine.audioSaves.isEmpty)
        precondition(engine.saves.filter { $0 == lost }.count == 1, "the cleared marker goes up")
        precondition(engine.saves.contains(backed))
    }

    /// A coordinator replaced by a restart must not write a marker whose
    /// note save goes to its stopped engine.
    @MainActor
    static func testStoppedCoordinatorWritesNoMarker() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        store.uploadKeys[id] = sha("a.wav")
        engine.iCloud = Set(parts(id, 1))
        engine.onLookup = { coordinator.stop() }
        coordinator.resumeAudioUploads()
        await coordinator.lastAudioCheck?.value
        precondition(store.manifests[id] == nil && engine.saves.isEmpty)
    }

    /// After switching accounts, an old account's marker must not reach the
    /// new account's iCloud before the check clears it.
    @MainActor
    static func testMarkedNotesGoUpOnlyAfterTheCheck() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let marked = noteWithAudio(store)
        store.manifests[marked] = manifest()
        let plain = record()
        store.records[plain.noteID] = plain
        store.syncable.insert(plain.noteID)
        engine.lookupError = URLError(.notConnectedToInternet)
        coordinator.startInitialUpload()
        await coordinator.lastAudioCheck?.value
        precondition(engine.saves == [plain.noteID], "the marked note waits for its check")
        engine.lookupError = nil
        coordinator.handleFetchFinished(pending: 0)
        await coordinator.lastAudioCheck?.value
        precondition(engine.saves == [plain.noteID, marked] && store.manifests[marked] == nil)
    }

    /// A held note (its marker not yet checked) edited during the check
    /// still waits, so an old account's marker can't slip out.
    @MainActor
    static func testHeldNoteEditedDuringItsCheckStillWaits() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        store.manifests[id] = manifest()
        var savesDuringCheck: [UUID] = []
        engine.onLookup = {
            engine.onLookup = nil
            coordinator.handleLocalChanges([.saved(id)])
            savesDuringCheck = engine.saves
        }
        coordinator.startInitialUpload()
        await coordinator.lastAudioCheck?.value
        precondition(savesDuringCheck.isEmpty, "the edit waits for the check")
        precondition(engine.saves == [id] && store.manifests[id] == nil)
    }

    @MainActor
    static func testHeldNoteDeletedDuringItsCheckIsNotSent() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        store.manifests[id] = manifest()
        engine.onLookup = {
            store.records[id] = nil
            coordinator.handleLocalChanges([.deleted(id, wasSynced: false, audio: NoteAudioSyncState(manifest: manifest()))])
        }
        coordinator.startInitialUpload()
        await coordinator.lastAudioCheck?.value
        precondition(!engine.saves.contains(id), "a deleted note isn't sent")
    }

    @MainActor
    static func testEditAfterAGivenUpPartChecksICloudFirst() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 60_000_000])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        store.uploadKeys[id] = sha("a.wav")
        let both = parts(id, 2)
        engine.iCloud = [both[0]]
        for _ in 0..<3 { coordinator.handleAudioSendFailures([.failed(both[1])]) }
        engine.audioSaves = []
        coordinator.handleLocalChanges([.saved(id)])
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioSaves.isEmpty, "the part in iCloud isn't sent again, and the given-up one waits")
    }

    @MainActor
    static func testStatusStaysBusyWhileAudioIsRetried() throws {
        let (coordinator, store, _, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        store.uploadKeys[id] = sha("a.wav")
        coordinator.handleAudioSendFailures([.failed(parts(id, 1)[0])])
        coordinator.handleFetchFinished(pending: 0)
        precondition(coordinator.status != .upToDate(t0), "a part just queued again isn't up to date")
    }

    @MainActor
    static func testAudioChangedDuringCheckIsCheckedAgain() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10, "b.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        engine.iCloud = Set(parts(id, 1))
        engine.onLookup = {
            engine.onLookup = nil
            // What the store does when the file changes.
            store.records[id] = record(id, audio: "b.wav")
            store.uploadKeys[id] = nil
        }
        coordinator.resumeAudioUploads()
        await coordinator.lastAudioCheck?.value
        precondition(store.manifests[id] == nil, "the check saw the file change")
        coordinator.handleFetchFinished(pending: 0)
        await coordinator.lastAudioCheck?.value
        precondition(engine.audioSaves == parts(id, 1, "b.wav"), "the new file goes up")
    }

    @MainActor
    static func testEmptyLocalFileStillChecksTheMarker() async throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 0])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        store.manifests[id] = manifest()
        coordinator.startInitialUpload()
        await coordinator.lastAudioCheck?.value
        precondition(store.manifests[id] == nil && engine.saves == [id], "the marker is checked, then the note goes up")
    }

    @MainActor
    static func testGivenUpNotesAreNotLookedUpOnRemoteEdits() throws {
        let (coordinator, store, engine, dir) = try makeWithAudio(["a.wav": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = noteWithAudio(store)
        store.uploadKeys[id] = sha("a.wav")
        for _ in 0..<3 { coordinator.handleAudioSendFailures([.failed(parts(id, 1)[0])]) }
        store.applyResult = .updated(needsUpload: false)
        _ = coordinator.handleFetched([try fetched(store.records[id]!)], deletions: [])
        precondition(coordinator.lastAudioCheck == nil && engine.lookups == 0)
    }

    /// CKSyncEngine doesn't try to send without a network, so no send fails;
    /// the network monitor reports it instead.
    @MainActor
    static func testLosingTheNetworkShowsOffline() {
        let (coordinator, _, _) = make()
        coordinator.handleFetchFinished(pending: 0)
        coordinator.handleNetworkChange(isOnline: false)
        precondition(coordinator.status == .paused(.offline))
        coordinator.handleFetchFinished(pending: 0)
        precondition(coordinator.status == .paused(.offline), "nothing reads as up to date while offline")
        coordinator.handleNetworkChange(isOnline: true)
        precondition(coordinator.status == .starting, "back online, sync runs again")
        coordinator.handleFetchFinished(pending: 0)
        precondition(coordinator.status == .upToDate(t0))

        coordinator.handleSendFailures([.quotaExceeded(noteID: UUID())])
        coordinator.handleNetworkChange(isOnline: true)
        precondition(coordinator.status == .paused(.quotaExceeded(pending: 1)), "coming online doesn't hide a quota pause")

        let (stopped, _, _) = make()
        stopped.handleZoneDeleted()
        stopped.handleNetworkChange(isOnline: false)
        precondition(stopped.status == .paused(.deletedElsewhere), "a stop isn't replaced by offline")
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
