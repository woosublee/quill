import CloudKit
import Foundation

@main
struct NoteSyncCloudRecordTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func main() throws {
        try testRecordCarriesPayloadAndPlainFields()
        try testSystemFieldsKeepIdentity()
        testNoteIDRejectsForeignNames()
        try testMismatchedSystemFieldsAreIgnored()
        try testOutboxFilesAreRemoved()
        testSendErrorsAreClassified()
        testFailedSendsAreRouted()
        testAudioPartRecordIDs()
        if #available(macOS 14.0, *) { testBatchesSendNotesFirstThenOneAudioPart() }
        try testAudioPartRecords()
        print("NoteSyncCloudRecordTests passed")
    }

    static func testAudioPartRecordIDs() {
        let part = NoteAudioPartID(noteID: UUID(), key: "0123456789abcdef", index: 2)
        let id = NoteAudioCloudRecord.recordID(for: part)
        precondition(id.zoneID.zoneName == "NoteAudio" && id.recordName == part.recordName)
        precondition(NoteAudioCloudRecord.part(from: id) == part)
        let noteRecord = NoteSyncCloudRecord.recordID(for: part.noteID)
        precondition(NoteAudioCloudRecord.part(from: noteRecord) == nil, "a note record is not a part")
        precondition(NoteSyncCloudRecord.noteID(from: id) == nil, "a part is not a note")
    }

    @available(macOS 14.0, *)
    static func testBatchesSendNotesFirstThenOneAudioPart() {
        let note = CKSyncEngine.PendingRecordZoneChange.saveRecord(NoteSyncCloudRecord.recordID(for: UUID()))
        let id = UUID()
        let part0 = CKSyncEngine.PendingRecordZoneChange.saveRecord(NoteAudioCloudRecord.recordID(for: NoteAudioPartID(noteID: id, key: "0123456789abcdef", index: 0)))
        let part1 = CKSyncEngine.PendingRecordZoneChange.saveRecord(NoteAudioCloudRecord.recordID(for: NoteAudioPartID(noteID: id, key: "0123456789abcdef", index: 1)))
        let deletePart = CKSyncEngine.PendingRecordZoneChange.deleteRecord(NoteAudioCloudRecord.recordID(for: NoteAudioPartID(noteID: UUID(), key: "0123456789abcdef", index: 0)))
        precondition(NoteAudioCloudRecord.nextBatch([part0, note, part1]) == [note], "text first")
        precondition(NoteAudioCloudRecord.nextBatch([part0, deletePart, part1]) == [deletePart], "small deletes before big uploads")
        precondition(NoteAudioCloudRecord.nextBatch([part0, part1]) == [part0], "one part per request")
        precondition(NoteAudioCloudRecord.nextBatch([]).isEmpty)
    }

    static func testAudioPartRecords() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quill-audio-record-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("a.wav")
        try Data((0..<10).map { UInt8($0) }).write(to: source)
        let outbox = dir.appendingPathComponent("outbox", isDirectory: true)
        let id = UUID()

        let whole = NoteSyncOutgoingAudio(part: NoteAudioPartID(noteID: id, key: "0123456789abcdef", index: 0), fileURL: source, byteCount: 10)
        let single = try NoteAudioCloudRecord.makeRecord(whole, outbox: outbox, partSize: 16)
        precondition((single["data"] as? CKAsset)?.fileURL == source, "one part sends the file itself")
        precondition(single["index"] as? Int == 0 && single["noteID"] as? String == id.uuidString)

        let second = NoteSyncOutgoingAudio(part: NoteAudioPartID(noteID: id, key: "0123456789abcdef", index: 1), fileURL: source, byteCount: 10)
        let split = try NoteAudioCloudRecord.makeRecord(second, outbox: outbox, partSize: 4)
        let partURL = (split["data"] as? CKAsset)?.fileURL
        precondition(partURL == NoteAudioCloudRecord.partFile(for: second.part, in: outbox))
        let partBytes = try Data(contentsOf: partURL!)
        precondition(partBytes == Data([4, 5, 6, 7]))

        NoteSyncCloudRecord.removeAllOutboxFiles(in: outbox)
        precondition(!FileManager.default.fileExists(atPath: partURL!.path), "part files are cleaned up with payloads")
    }

    static func outbox() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("quill-sync-outbox-\(UUID().uuidString)")
    }

    static func outgoing(_ id: UUID = UUID(), deletedAt: Date? = nil, systemFields: Data? = nil) -> NoteSyncOutgoing {
        NoteSyncOutgoing(
            record: NoteSyncRecord(
                noteID: id,
                fields: [
                    NoteSyncField.customTitle.rawValue: .string("Synthetic title"),
                    NoteSyncRecord.schemaVersionKey: .int(NoteSyncRecord.schemaVersion)
                ],
                clock: NoteFieldClock.uniform(t0),
                deletedAt: deletedAt
            ),
            systemFields: systemFields
        )
    }

    static func testRecordCarriesPayloadAndPlainFields() throws {
        let folder = outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sent = outgoing(deletedAt: t0)
        let record = try NoteSyncCloudRecord.makeRecord(sent, outbox: folder)
        precondition(record.recordType == "Note")
        precondition(record.recordID.recordName == sent.record.noteID.uuidString)
        precondition(record.recordID.zoneID.zoneName == "Notes")
        precondition(record["schemaVersion"] as? Int == NoteSyncRecord.schemaVersion)
        precondition(record["deletedAt"] as? Date == t0)
        let payload = NoteSyncCloudRecord.payload(of: record)
        let received = try payload.map(NoteSyncPayload.decode)
        precondition(received == sent.record, "the payload asset holds the whole record")
    }

    static func testSystemFieldsKeepIdentity() throws {
        let folder = outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try NoteSyncCloudRecord.makeRecord(outgoing(), outbox: folder)
        let fields = NoteSyncCloudRecord.systemFields(of: first)
        let id = NoteSyncCloudRecord.noteID(from: first.recordID)!
        let again = try NoteSyncCloudRecord.makeRecord(outgoing(id, systemFields: fields), outbox: folder)
        precondition(again.recordID == first.recordID && again.recordType == first.recordType)
    }

    static func testNoteIDRejectsForeignNames() {
        let zone = NoteSyncCloudRecord.zoneID()
        precondition(NoteSyncCloudRecord.noteID(from: CKRecord.ID(recordName: "not-a-uuid", zoneID: zone)) == nil)
        let id = UUID()
        precondition(NoteSyncCloudRecord.noteID(from: NoteSyncCloudRecord.recordID(for: id)) == id)
    }

    static func testMismatchedSystemFieldsAreIgnored() throws {
        let folder = outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let other = try NoteSyncCloudRecord.makeRecord(outgoing(), outbox: folder)
        let mine = outgoing(systemFields: NoteSyncCloudRecord.systemFields(of: other))
        let record = try NoteSyncCloudRecord.makeRecord(mine, outbox: folder)
        precondition(record.recordID.recordName == mine.record.noteID.uuidString, "another note's system fields never rename a record")
    }

    static func testOutboxFilesAreRemoved() throws {
        let folder = outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = outgoing(), b = outgoing()
        _ = try NoteSyncCloudRecord.makeRecord(a, outbox: folder)
        _ = try NoteSyncCloudRecord.makeRecord(b, outbox: folder)
        NoteSyncCloudRecord.removeOutboxFile(for: a.record.noteID, in: folder)
        precondition(!FileManager.default.fileExists(atPath: NoteSyncCloudRecord.outboxFile(for: a.record.noteID, in: folder).path))
        precondition(FileManager.default.fileExists(atPath: NoteSyncCloudRecord.outboxFile(for: b.record.noteID, in: folder).path))
        NoteSyncCloudRecord.removeAllOutboxFiles(in: folder)
        precondition(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty, "no note content is left on disk")
    }

    /// Saves and deletes read CloudKit errors the same way: a missing zone
    /// means it was deleted, a lost connection is a network pause, a busy
    /// server isn't offline, and an account that needs attention says so.
    static func testSendErrorsAreClassified() {
        let expected: [(CKError.Code, NoteSyncSendErrorKind)] = [
            (.zoneNotFound, .zoneGone),
            (.userDeletedZone, .zoneGone),
            (.serverRecordChanged, .serverChanged),
            (.quotaExceeded, .quotaExceeded),
            (.networkUnavailable, .network),
            (.networkFailure, .network),
            (.serviceUnavailable, .throttled),
            (.requestRateLimited, .throttled),
            (.zoneBusy, .throttled),
            (.notAuthenticated, .accountNeedsAttention),
            (.accountTemporarilyUnavailable, .accountNeedsAttention),
            (.unknownItem, .unknownItem),
            (.permissionFailure, .other),
            (.limitExceeded, .other)
        ]
        for (code, kind) in expected {
            precondition(NoteSyncCloudRecord.sendErrorKind(code) == kind, "\(code.rawValue)")
        }
    }

    /// Where each failed save or delete goes, for notes and audio parts,
    /// and while this Mac deletes its iCloud data.
    static func testFailedSendsAreRouted() {
        typealias R = NoteSyncSendRoute
        let rows: [(R.Sent, Bool, CKError.Code, Bool, R)] = [
            // Notes, saved.
            (.note, true, .serverRecordChanged, false, .serverChanged),
            (.note, true, .zoneNotFound, false, .zoneDeletedElsewhere),
            (.note, true, .zoneNotFound, true, .holdForOwnDelete),
            (.note, true, .quotaExceeded, false, .quotaExceeded),
            (.note, true, .networkFailure, false, .network),
            (.note, true, .requestRateLimited, false, .none),
            (.note, true, .notAuthenticated, false, .accountNeedsAttention),
            (.note, true, .unknownItem, false, .unknownItemOnSave),
            (.note, true, .invalidArguments, false, .failed),
            // Notes, deleted.
            (.note, false, .userDeletedZone, false, .zoneDeletedElsewhere),
            (.note, false, .userDeletedZone, true, .holdForOwnDelete),
            (.note, false, .unknownItem, false, .unknownItemOnDelete),
            (.note, false, .serverRecordChanged, false, .failed),
            (.note, false, .quotaExceeded, false, .failed),
            (.note, false, .zoneBusy, false, .none),
            // Audio parts, saved.
            (.part, true, .serverRecordChanged, false, .savedAlready),
            (.part, true, .unknownItem, false, .resendNow),
            (.part, true, .zoneNotFound, false, .partWithoutZone),
            (.part, true, .zoneNotFound, true, .holdForOwnDelete),
            (.part, true, .quotaExceeded, false, .quotaExceeded),
            (.part, true, .limitExceeded, false, .failed),
            // Audio parts, deleted.
            (.part, false, .zoneNotFound, false, .none),
            (.part, false, .zoneNotFound, true, .none),
            (.part, false, .unknownItem, false, .none),
            (.part, false, .networkUnavailable, false, .network),
            (.part, false, .accountTemporarilyUnavailable, false, .accountNeedsAttention),
            (.part, false, .internalError, false, .failed),
        ]
        for (sent, isSave, code, deleting, expected) in rows {
            let route = R.route(sent, isSave: isSave, code: code, deletingZone: deleting)
            precondition(route == expected, "\(sent) save=\(isSave) \(code.rawValue) deleting=\(deleting): \(route)")
        }
    }
}
