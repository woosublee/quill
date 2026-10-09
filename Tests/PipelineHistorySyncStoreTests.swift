import CoreData
import Foundation

@main
struct PipelineHistorySyncStoreTests {
    static func main() throws {
        try testLocalWritesReportChanges()
        try testSyncedApplyIsSilentAndVerbatim()
        try testMergeKeepsNewerLocalGroupsAndAsksForUpload()
        try testSameRecordAppliedAgainNeedsNoUpload()
        try testUnknownKeysPersistAcrossReload()
        testIncompleteNewRecordIsRejected()
        try testDeleteOfSyncedNoteSaysSo()
        try testRemoveSyncedIsSilentAndReturnsAssets()
        try testSyncableIDsSkipNotesInProgress()
        try testClearAllReportsEveryDelete()
        try testClearAllSyncSystemFields()
        try testLegacyStoreMigratesWithNewAttributes()
        testChangeTagForMissingNoteThrows()
        try testUnreadableRecordIsRejected()
        try testLocalOnlyEditsAreNotReported()
        try testAudioManifestTravelsWithTheNote()
        try testAudioManifestFromICloudIsKept()
        try testNewAudioFileClearsTheManifest()
        try testDeleteReportsAudioParts()
        try testClearingChangeTagsClearsAudioManifests()
        try testAudioManifestCanBeCleared()
        print("PipelineHistorySyncStoreTests passed")
    }

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func makeItem(
        id: UUID = UUID(),
        title: String? = nil,
        status: String = "succeeded",
        audio: String? = nil,
        clock: NoteFieldClock? = nil
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: id,
            timestamp: t0,
            rawTranscript: "synthetic raw",
            postProcessedTranscript: "synthetic edited",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: status,
            debugStatus: "",
            customVocabulary: "",
            audioFileName: audio,
            customTitle: title,
            fieldClock: clock
        )
    }

    private static func store(at clock: Date = t0) -> PipelineHistoryStore {
        let store = PipelineHistoryStore(inMemory: true)
        store.now = { clock }
        return store
    }

    private static func load(_ store: PipelineHistoryStore, _ id: UUID) -> PipelineHistoryItem {
        store.loadAllHistory().first { $0.id == id }!
    }

    private static func temporaryStoreURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-sync-store-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("PipelineHistory.sqlite")
    }

    private static func testLocalWritesReportChanges() throws {
        let s = store()
        var changes: [PipelineHistoryChange] = []
        s.onChange = { changes += $0 }
        let note = makeItem()
        _ = try s.append(note, maxCount: Int.max)
        try s.update(note.withCustomTitle("Edited"))
        _ = try s.upsert(note.withCustomTitle("Upserted"), maxCount: Int.max)
        try s.setDeletedAt(t0, id: note.id)
        _ = try s.delete(id: note.id)
        precondition(changes == [
            .saved(note.id), .saved(note.id), .saved(note.id), .saved(note.id),
            .deleted(note.id, wasSynced: false)
        ], "every local write reports its note")
    }

    private static func testSyncedApplyIsSilentAndVerbatim() throws {
        let s = store(at: t0.addingTimeInterval(999))
        var changes: [PipelineHistoryChange] = []
        s.onChange = { changes += $0 }
        let remote = NoteSyncRecord(item: makeItem(title: "From another Mac", clock: .uniform(t0)))
        let result1 = try s.applySynced(remote, systemFields: Data([1]))
        precondition(result1 == .inserted)
        precondition(changes.isEmpty, "applying a synced record never reports a local change")
        let stored = load(s, remote.noteID)
        precondition(stored.customTitle == "From another Mac")
        precondition(stored.fieldClock == remote.clock, "the record's clock is kept, not re-stamped")
        precondition(s.syncSystemFields(id: remote.noteID) == Data([1]))
    }

    private static func testMergeKeepsNewerLocalGroupsAndAsksForUpload() throws {
        let s = store(at: t0)
        let note = makeItem(title: "Base")
        _ = try s.append(note, maxCount: Int.max)
        s.now = { t0.addingTimeInterval(100) }
        try s.update(note.withCustomTitle("Local title"))
        var remote = NoteSyncRecord(item: makeItem(id: note.id, title: "Base", clock: .uniform(t0)))
        remote.fields[NoteSyncField.postProcessedTranscript.rawValue] = .string("Remote edit")
        remote.clock = remote.clock.setting(.editedTranscript, to: t0.addingTimeInterval(50))
        var changes: [PipelineHistoryChange] = []
        s.onChange = { changes += $0 }
        let result2 = try s.applySynced(remote, systemFields: nil)
        precondition(result2 == .updated(needsUpload: true))
        let stored = load(s, note.id)
        precondition(stored.customTitle == "Local title", "the newer local title stays")
        precondition(stored.postProcessedTranscript == "Remote edit", "the newer remote edit arrives")
        precondition(changes.isEmpty)
    }

    private static func testSameRecordAppliedAgainNeedsNoUpload() throws {
        let s = store()
        let remote = NoteSyncRecord(item: makeItem(title: "Same", clock: .uniform(t0)))
        _ = try s.applySynced(remote, systemFields: nil)
        let result3 = try s.applySynced(remote, systemFields: nil)
        precondition(result3 == .updated(needsUpload: false))
    }

    private static func testUnknownKeysPersistAcrossReload() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var remote = NoteSyncRecord(item: makeItem(clock: .uniform(t0)))
        remote.fields["futureField"] = .string("from a newer build")
        _ = try PipelineHistoryStore(storeURL: url).applySynced(remote, systemFields: nil)
        let reopened = PipelineHistoryStore(storeURL: url)
        precondition(reopened.syncRecord(id: remote.noteID)?.fields["futureField"] == .string("from a newer build"))
    }

    private static func testIncompleteNewRecordIsRejected() {
        var remote = NoteSyncRecord(item: makeItem(clock: .uniform(t0)))
        remote.fields.removeValue(forKey: NoteSyncField.timestamp.rawValue)
        let s = store()
        do {
            _ = try s.applySynced(remote, systemFields: nil)
            preconditionFailure("an incomplete new record must be rejected")
        } catch PipelineHistorySyncError.incompleteRecord {
        } catch {
            preconditionFailure("wrong error \(error)")
        }
        precondition(s.loadAllHistory().isEmpty)
    }

    private static func testDeleteOfSyncedNoteSaysSo() throws {
        let s = store()
        let note = makeItem()
        _ = try s.append(note, maxCount: Int.max)
        try s.setSyncSystemFields(Data([9]), id: note.id)
        var changes: [PipelineHistoryChange] = []
        s.onChange = { changes += $0 }
        _ = try s.delete(id: note.id)
        precondition(changes == [.deleted(note.id, wasSynced: true)])
    }

    private static func testRemoveSyncedIsSilentAndReturnsAssets() throws {
        let s = store()
        let note = makeItem(audio: "synthetic.m4a")
        _ = try s.append(note, maxCount: Int.max)
        var changes: [PipelineHistoryChange] = []
        s.onChange = { changes += $0 }
        let result4 = try s.removeSynced(id: note.id)?.audioFileName
        precondition(result4 == "synthetic.m4a")
        precondition(changes.isEmpty && s.loadAllHistory().isEmpty)
        let result5 = try s.removeSynced(id: note.id)
        precondition(result5 == nil, "a note already gone is not an error")
    }

    private static func testSyncableIDsSkipNotesInProgress() throws {
        let s = store()
        let done = makeItem()
        let recording = makeItem(status: "live-recording")
        _ = try s.append(done, maxCount: Int.max)
        _ = try s.append(recording, maxCount: Int.max)
        precondition(s.syncableNoteIDs() == [done.id])
        precondition(s.isSyncable(id: done.id) && !s.isSyncable(id: recording.id))
        precondition(!s.isSyncable(id: UUID()))
    }

    private static func testClearAllReportsEveryDelete() throws {
        let s = store()
        let a = makeItem(), b = makeItem()
        _ = try s.append(a, maxCount: Int.max)
        _ = try s.append(b, maxCount: Int.max)
        try s.setSyncSystemFields(Data([1]), id: a.id)
        var changes: [PipelineHistoryChange] = []
        s.onChange = { changes += $0 }
        _ = try s.clearAll()
        precondition(Set(changes.map { "\($0)" }) == Set([
            "\(PipelineHistoryChange.deleted(a.id, wasSynced: true))",
            "\(PipelineHistoryChange.deleted(b.id, wasSynced: false))"
        ]))
    }

    private static func testClearAllSyncSystemFields() throws {
        let s = store()
        let a = makeItem()
        _ = try s.append(a, maxCount: Int.max)
        try s.setSyncSystemFields(Data([1]), id: a.id)
        try s.clearAllSyncSystemFields(forgettingAudio: true)
        precondition(s.syncSystemFields(id: a.id) == nil)
    }

    private static func testLegacyStoreMigratesWithNewAttributes() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID()
        try PipelineHistoryStore.writeLegacyStoreForTesting(at: url, id: id, timestamp: t0)
        let reopened = PipelineHistoryStore(storeURL: url)
        precondition(reopened.availability == .ready)
        precondition(reopened.syncRecord(id: id) != nil && reopened.syncSystemFields(id: id) == nil)
    }

    private static func testUnreadableRecordIsRejected() throws {
        let s = store()
        let note = makeItem(title: "Local")
        _ = try s.append(note, maxCount: Int.max)
        var remote = NoteSyncRecord(item: makeItem(id: note.id, title: "Remote", clock: .uniform(t0.addingTimeInterval(500))))
        remote.fields[NoteSyncField.intent.rawValue] = .string("meetingV2")
        do {
            _ = try s.applySynced(remote, systemFields: nil)
            preconditionFailure("a record with a value this build can't read is not applied")
        } catch PipelineHistorySyncError.unreadableRecord {
        } catch {
            preconditionFailure("wrong error \(error)")
        }
        precondition(load(s, note.id).customTitle == "Local")
    }

    private static func testLocalOnlyEditsAreNotReported() throws {
        let s = store()
        let note = makeItem()
        _ = try s.append(note, maxCount: Int.max)
        var changes: [PipelineHistoryChange] = []
        s.onChange = { changes += $0 }
        let localOnly = PipelineHistoryItem(
            id: note.id,
            timestamp: t0,
            rawTranscript: "synthetic raw",
            postProcessedTranscript: "synthetic edited",
            postProcessingPrompt: "a new local prompt",
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "succeeded",
            debugStatus: "new debug detail",
            customVocabulary: ""
        )
        try s.update(localOnly)
        _ = try s.upsert(localOnly, maxCount: Int.max)
        precondition(changes.isEmpty, "a change only to fields that never sync uploads nothing")
        try s.update(localOnly.withCustomTitle("Visible"))
        precondition(changes == [.saved(note.id)])
    }

    private static let manifest = NoteAudioManifest(sha256: "synthetic", bytes: 120_000_000, partSize: 50_000_000, parts: 3)

    private static func testAudioManifestTravelsWithTheNote() throws {
        let s = store()
        var changes: [PipelineHistoryChange] = []
        let note = makeItem(audio: "\(UUID().uuidString).wav")
        _ = try s.append(note, maxCount: Int.max)
        s.onChange = { changes += $0 }
        s.now = { t0.addingTimeInterval(10) }
        try s.setAudioManifest(manifest, id: note.id)
        precondition(s.audioManifest(id: note.id) == manifest)
        let record = s.syncRecord(id: note.id)!
        precondition(record.fields[NoteSyncField.audioManifest.rawValue] == .data(manifest.encoded()))
        precondition(record.clock.stamp(for: .audio) == t0.addingTimeInterval(10), "the audio group is stamped")
        precondition(changes.isEmpty, "the coordinator sends the note itself")
    }

    private static func testAudioManifestFromICloudIsKept() throws {
        let s = store()
        let note = makeItem(audio: "\(UUID().uuidString).wav")
        _ = try s.append(note, maxCount: Int.max)
        var remote = s.syncRecord(id: note.id)!
        remote.fields[NoteSyncField.audioManifest.rawValue] = .data(manifest.encoded())
        remote.clock = remote.clock.setting(.audio, to: t0.addingTimeInterval(60))
        _ = try s.applySynced(remote, systemFields: nil)
        precondition(s.audioManifest(id: note.id) == manifest)
        _ = try s.applySynced(remote, systemFields: nil)
        precondition(s.syncRecord(id: note.id) == remote, "applying the same record again changes nothing")
    }

    private static func testNewAudioFileClearsTheManifest() throws {
        let s = store()
        let note = makeItem(audio: "\(UUID().uuidString).wav")
        _ = try s.append(note, maxCount: Int.max)
        try s.setAudioManifest(manifest, id: note.id)
        try s.update(note.replacingAssetFileNames(audioFileName: "\(UUID().uuidString).wav", transcriptFileName: nil))
        precondition(s.audioManifest(id: note.id) == nil, "a new file has to upload again")
    }

    private static func testDeleteReportsAudioParts() throws {
        let s = store()
        var changes: [PipelineHistoryChange] = []
        let note = makeItem(audio: "\(UUID().uuidString).wav")
        _ = try s.append(note, maxCount: Int.max)
        try s.setAudioManifest(manifest, id: note.id)
        s.onChange = { changes += $0 }
        _ = try s.delete(id: note.id)
        precondition(changes == [.deleted(note.id, wasSynced: false, audioParts: 3, hasAudio: true)])
    }

    /// When iCloud loses the notes, it lost their audio too: the marker
    /// goes, stamped newer, so a Mac still holding it can't bring it back.
    private static func testClearingChangeTagsClearsAudioManifests() throws {
        let s = store()
        let marked = makeItem(audio: "\(UUID().uuidString).wav")
        _ = try s.append(marked, maxCount: Int.max)
        try s.setAudioManifest(manifest, id: marked.id)
        s.now = { t0.addingTimeInterval(90) }
        try s.clearAllSyncSystemFields(forgettingAudio: false)
        precondition(s.audioManifest(id: marked.id) == manifest, "after an account change iCloud may still hold it")
        try s.clearAllSyncSystemFields(forgettingAudio: true)
        precondition(s.audioManifest(id: marked.id) == nil)
        let record = s.syncRecord(id: marked.id)!
        precondition(record.fields[NoteSyncField.audioManifest.rawValue] == nil)
        precondition(record.clock.stamp(for: .audio) == t0.addingTimeInterval(90), "the cleared marker wins merges")
    }

    private static func testAudioManifestCanBeCleared() throws {
        let s = store()
        let note = makeItem(audio: "\(UUID().uuidString).wav")
        _ = try s.append(note, maxCount: Int.max)
        try s.setAudioManifest(manifest, id: note.id)
        s.now = { t0.addingTimeInterval(30) }
        try s.setAudioManifest(nil, id: note.id)
        precondition(s.audioManifest(id: note.id) == nil)
        precondition(s.syncRecord(id: note.id)!.clock.stamp(for: .audio) == t0.addingTimeInterval(30))
    }

    private static func testChangeTagForMissingNoteThrows() {
        let s = store()
        do {
            try s.setSyncSystemFields(Data([1]), id: UUID())
            preconditionFailure("recording a change tag for a missing note must fail")
        } catch {}
    }
}
