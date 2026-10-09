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
        print("NoteSyncCloudRecordTests passed")
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
}
