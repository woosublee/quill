import CoreData
import Foundation
import QuillNoteSyncCore

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
        try testNoteExistsSaysUnknownWhenTheStoreIsUnavailable()
        try testUnreadableRecordIsRejected()
        try testLocalOnlyEditsAreNotReported()
        try testAudioManifestTravelsWithTheNote()
        try testAudioManifestFromICloudIsKept()
        try testNewAudioFileClearsTheManifest()
        try testDeleteReportsAudioParts()
        try testReplacedAudioIsReported()
        try testClearingChangeTagsClearsAudioManifests()
        try testAudioManifestCanBeCleared()
        try testAudioSyncSnapshotsReadEverySyncableNote()
        try testDismissedNoticeIsKeptAndSyncs()
        try testDismissedNoticeFromICloudIsKept()
        try testUnchangedRetranscriptionIsKeptAndSyncs()
        try testConditionalDismissalIsKeptAndSyncs()
        try testUnchangedSummaryRegenerationIsKeptAndSyncs()
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

    /// A store that didn't load answers "can't tell", never "gone": sync
    /// would delete from iCloud every note it took for gone.
    private static func testNoteExistsSaysUnknownWhenTheStoreIsUnavailable() throws {
        let ready = PipelineHistoryStore(inMemory: true)
        let item = makeItem()
        try ready.append(item, maxCount: Int.max)
        precondition(ready.noteExists(id: item.id) == true && ready.noteExists(id: UUID()) == false)
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("synthetic damaged store".utf8).write(to: url)
        let broken = PipelineHistoryStore(storeURL: url)
        precondition(broken.availability != .ready)
        precondition(broken.noteExists(id: item.id) == nil, "an unavailable store can't say a note is gone")
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

    private static let manifest = NoteAudioManifest(sha256: String(repeating: "ab", count: 32), bytes: 120_000_000, partSize: 50_000_000, parts: 3)

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
        precondition(changes == [.deleted(note.id, wasSynced: false, audio: NoteAudioSyncState(manifest: manifest))])
    }

    /// The upload key names the parts of the file being sent; a new file
    /// clears it, and the store says what the earlier one left in iCloud.
    private static func testReplacedAudioIsReported() throws {
        let s = store()
        let note = makeItem(audio: "\(UUID().uuidString).wav")
        _ = try s.append(note, maxCount: Int.max)
        try s.setAudioManifest(manifest, id: note.id)
        try s.setAudioUploadKey(manifest.sha256, id: note.id)
        precondition(s.audioUploadKey(id: note.id) == manifest.sha256)
        var changes: [PipelineHistoryChange] = []
        s.onChange = { changes += $0 }
        try s.update(note.withCustomTitle("Renamed"))
        precondition(changes == [.saved(note.id)], "an edit that keeps the audio reports no replacement")
        changes = []
        try s.update(note.replacingAssetFileNames(audioFileName: "\(UUID().uuidString).wav", transcriptFileName: nil))
        precondition(changes == [
            .audioReplaced(note.id, previous: NoteAudioSyncState(manifest: manifest, uploadKey: manifest.sha256)),
            .saved(note.id)
        ])
        precondition(s.audioUploadKey(id: note.id) == nil && s.audioManifest(id: note.id) == nil)
        changes = []
        _ = try s.delete(id: note.id)
        precondition(changes == [.deleted(note.id, wasSynced: false, audio: NoteAudioSyncState())], "audio with nothing in iCloud yet")
        let silent = makeItem()
        _ = try s.append(silent, maxCount: Int.max)
        changes = []
        _ = try s.delete(id: silent.id)
        precondition(changes == [.deleted(silent.id, wasSynced: false)], "no audio, nothing to delete")
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

    /// A conditional dismissal is saved beside the note, stamped once,
    /// ended for a retry, and kept across reopening (#745).
    private static func testConditionalDismissalIsKeptAndSyncs() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let key = NoteSyncField.noticeDismissals.rawValue
        let warning = NoteNoticeDismissals.postProcessingWarning(code: "postProcessingFailed")
        let s = PipelineHistoryStore(storeURL: url)
        s.now = { t0 }
        let note = makeItem()
        _ = try s.append(note, maxCount: Int.max)
        var changes: [PipelineHistoryChange] = []
        s.onChange = { changes += $0 }
        s.now = { t0.addingTimeInterval(10) }
        try s.dismissNotice(warning, condition: "c1", id: note.id)
        try s.dismissNotice(warning, condition: "c1", id: note.id)
        precondition(changes == [.saved(note.id)], "the dismissal is sent once")
        precondition(s.noticeState().conditionalDismissals[note.id]?.isDismissed(warning, condition: "c1") == true)
        let record = s.syncRecord(id: note.id)!
        precondition(NoteNoticeDismissals.decode(record.fields[key]).isDismissed(warning, condition: "c1"))
        precondition(record.clock.stamp(for: .notices) == t0.addingTimeInterval(10))
        try s.dismissNotice(NoteDismissedNotices.nothingToCleanUp, id: note.id)
        precondition(s.noticeState().conditionalDismissals[note.id]?.isDismissed(warning, condition: "c1") == true,
                     "a permanent dismissal keeps the conditional ones")
        s.now = { t0.addingTimeInterval(20) }
        try s.endNoticeDismissals(withPrefix: NoteNoticeDismissals.postProcessingWarningPrefix, id: note.id)
        changes = []
        try s.endNoticeDismissals(withPrefix: NoteNoticeDismissals.postProcessingWarningPrefix, id: note.id)
        precondition(changes.isEmpty, "nothing to end, nothing sent")
        let reopened = PipelineHistoryStore(storeURL: url)
        precondition(reopened.noticeState().conditionalDismissals[note.id]?.isDismissed(warning, condition: "c1") == false)
        precondition(reopened.dismissedNotices() == [note.id: [NoteDismissedNotices.nothingToCleanUp]])
    }

    /// The "same summary" marker is saved, cleared once, and a newer clear
    /// from iCloud ends it (#745).
    private static func testUnchangedSummaryRegenerationIsKeptAndSyncs() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = PipelineHistoryStore(storeURL: url)
        s.now = { t0 }
        let note = makeItem()
        _ = try s.append(note, maxCount: Int.max)
        let marker = NoteUnchangedSummaryRegeneration.matching(summaryGeneratedAt: t0, at: t0.addingTimeInterval(10))
        s.now = { t0.addingTimeInterval(10) }
        try s.setUnchangedSummaryRegeneration(marker, id: note.id)
        precondition(s.noticeState().unchangedSummaries == [note.id: marker])
        precondition(s.syncRecord(id: note.id)?.clock.stamp(for: .unchangedSummaryRegeneration) == t0.addingTimeInterval(10))
        let reopened = PipelineHistoryStore(storeURL: url)
        precondition(reopened.noticeState().unchangedSummaries == [note.id: marker], "kept across reopening")
        var remote = reopened.syncRecord(id: note.id)!
        remote.fields[NoteSyncField.unchangedSummaryRegeneration.rawValue] =
            NoteUnchangedSummaryRegeneration.cleared(at: t0.addingTimeInterval(60)).value
        remote.clock = remote.clock.setting(.unchangedSummaryRegeneration, to: t0.addingTimeInterval(60))
        _ = try reopened.applySynced(remote, systemFields: nil)
        precondition(reopened.noticeState().unchangedSummaries.isEmpty, "a newer clear from iCloud ends it")
        var changes: [PipelineHistoryChange] = []
        reopened.onChange = { changes += $0 }
        try reopened.clearUnchangedSummaryRegeneration(id: note.id)
        precondition(changes.isEmpty, "already cleared, nothing sent")
    }

    /// A dismissal is saved beside the note, stamped, reported, kept when
    /// the note is edited or reopened, and never undone by an older record
    /// (#730).
    private static func testDismissedNoticeIsKeptAndSyncs() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let key = NoteSyncField.dismissedNotices.rawValue
        let notice = NoteDismissedNotices.nothingToCleanUp
        let s = PipelineHistoryStore(storeURL: url)
        s.now = { t0 }
        let note = makeItem()
        _ = try s.append(note, maxCount: Int.max)
        let before = s.syncRecord(id: note.id)!
        var changes: [PipelineHistoryChange] = []
        s.onChange = { changes += $0 }
        s.now = { t0.addingTimeInterval(10) }
        try s.dismissNotice(notice, id: note.id)
        try s.dismissNotice(notice, id: note.id)
        precondition(changes == [.saved(note.id)], "the dismissal is sent once")
        precondition(s.dismissedNotices() == [note.id: [notice]])
        let record = s.syncRecord(id: note.id)!
        precondition(NoteDismissedNotices.decode(record.fields[key]) == [notice])
        precondition(record.clock.stamp(for: .notices) == t0.addingTimeInterval(10), "the notices group is stamped")
        s.now = { t0.addingTimeInterval(20) }
        try s.update(note.withCustomTitle("Edited"))
        precondition(s.syncRecord(id: note.id)?.clock.stamp(for: .notices) == t0.addingTimeInterval(10),
                     "editing the note doesn't touch the notices group")
        _ = try s.applySynced(before, systemFields: nil)
        let reopened = PipelineHistoryStore(storeURL: url)
        precondition(reopened.dismissedNotices() == [note.id: [notice]], "kept across edits, older records, and reopening")
        precondition(NoteDismissedNotices.decode(reopened.syncRecord(id: note.id)?.fields[key]) == [notice])
        precondition(reopened.loadAllHistory().first?.customTitle == "Edited")
    }

    private static func testDismissedNoticeFromICloudIsKept() throws {
        let s = store()
        let note = makeItem()
        _ = try s.append(note, maxCount: Int.max)
        var remote = s.syncRecord(id: note.id)!
        remote.fields = NoteDismissedNotices.adding(NoteDismissedNotices.nothingToCleanUp, to: remote.fields)
        remote.clock = remote.clock.setting(.notices, to: t0.addingTimeInterval(60))
        let result = try s.applySynced(remote, systemFields: nil)
        precondition(result == .updated(needsUpload: false))
        precondition(s.dismissedNotices() == [note.id: [NoteDismissedNotices.nothingToCleanUp]])
        precondition(s.syncRecord(id: note.id) == remote, "the record reads back as it came")
    }

    /// The "same transcript" marker is saved beside the note, stamped,
    /// reported once, kept across edits and reopening, and a newer clear from
    /// iCloud ends it (#742).
    private static func testUnchangedRetranscriptionIsKeptAndSyncs() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let key = NoteSyncField.unchangedRetranscription.rawValue
        let s = PipelineHistoryStore(storeURL: url)
        s.now = { t0 }
        let note = makeItem()
        _ = try s.append(note, maxCount: Int.max)
        var changes: [PipelineHistoryChange] = []
        s.onChange = { changes += $0 }
        s.now = { t0.addingTimeInterval(10) }
        let marker = NoteUnchangedRetranscription.matching("Synthetic transcript.", at: t0.addingTimeInterval(10))
        try s.setUnchangedRetranscription(marker, id: note.id)
        try s.setUnchangedRetranscription(marker, id: note.id)
        precondition(changes == [.saved(note.id)], "the marker is sent once")
        precondition(s.unchangedRetranscriptions() == [note.id: marker])
        let record = s.syncRecord(id: note.id)!
        precondition(NoteUnchangedRetranscription.decode(record.fields[key]) == marker)
        precondition(record.clock.stamp(for: .unchangedRetranscription) == t0.addingTimeInterval(10))
        s.now = { t0.addingTimeInterval(20) }
        try s.update(note.withCustomTitle("Edited"))
        try s.dismissNotice(NoteDismissedNotices.nothingToCleanUp, id: note.id)
        let reopened = PipelineHistoryStore(storeURL: url)
        precondition(reopened.unchangedRetranscriptions() == [note.id: marker], "kept across edits, other notices, and reopening")
        precondition(reopened.dismissedNotices() == [note.id: [NoteDismissedNotices.nothingToCleanUp]])

        var remote = reopened.syncRecord(id: note.id)!
        let cleared = NoteUnchangedRetranscription.cleared(at: t0.addingTimeInterval(60))
        remote.fields[key] = cleared.value
        remote.clock = remote.clock.setting(.unchangedRetranscription, to: t0.addingTimeInterval(60))
        _ = try reopened.applySynced(remote, systemFields: nil)
        precondition(reopened.unchangedRetranscriptions().isEmpty, "a newer clear from iCloud ends it")
        precondition(NoteUnchangedRetranscription.decode(reopened.syncRecord(id: note.id)?.fields[key]) == cleared)

        // Clearing writes only when there is a live marker.
        var cleanChanges: [PipelineHistoryChange] = []
        reopened.onChange = { cleanChanges += $0 }
        try reopened.clearUnchangedRetranscription(id: note.id)
        precondition(cleanChanges.isEmpty, "already cleared: nothing to send")
        reopened.now = { t0.addingTimeInterval(70) }
        try reopened.setUnchangedRetranscription(marker, id: note.id)
        reopened.now = { t0.addingTimeInterval(80) }
        try reopened.clearUnchangedRetranscription(id: note.id)
        precondition(cleanChanges == [.saved(note.id), .saved(note.id)])
        precondition(reopened.unchangedRetranscriptions().isEmpty)
        precondition(reopened.syncRecord(id: note.id)?.clock.stamp(for: .unchangedRetranscription) == t0.addingTimeInterval(80))
    }

    private static func testChangeTagForMissingNoteThrows() {
        let s = store()
        do {
            try s.setSyncSystemFields(Data([1]), id: UUID())
            preconditionFailure("recording a change tag for a missing note must fail")
        } catch {}
    }

    /// One fetch gives what audio sync needs of every syncable note, in the
    /// order of `syncableNoteIDs`.
    private static func testAudioSyncSnapshotsReadEverySyncableNote() throws {
        let s = store()
        let marked = makeItem(audio: "marked.wav"), sending = makeItem(audio: "sending.wav"), text = makeItem()
        let busy = makeItem(status: "live-recording")
        for item in [marked, sending, text, busy] { _ = try s.append(item, maxCount: Int.max) }
        let manifest = NoteAudioManifest(sha256: String(repeating: "ab", count: 32), bytes: 10, partSize: 50_000_000, parts: 1)
        try s.setAudioManifest(manifest, id: marked.id)
        try s.setAudioUploadKey(String(repeating: "cd", count: 32), id: sending.id)
        let snapshots = s.audioSyncSnapshots()
        precondition(snapshots.map(\.id) == s.syncableNoteIDs() && !snapshots.contains { $0.id == busy.id })
        let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        precondition(byID[marked.id] == NoteAudioSyncSnapshot(id: marked.id, audioFileName: "marked.wav", manifest: manifest, uploadKey: nil))
        precondition(byID[sending.id]?.uploadKey == String(repeating: "cd", count: 32) && byID[sending.id]?.manifest == nil)
        precondition(byID[text.id]?.audioFileName == nil)
    }
}
