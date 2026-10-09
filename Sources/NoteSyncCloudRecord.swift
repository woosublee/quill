import CloudKit
import Foundation

/// Maps sync records to CloudKit `Note` records. The note travels as one
/// JSON asset (`payload`), so long transcripts never hit the record size
/// limit; `schemaVersion` and `deletedAt` are copied out for the console.
enum NoteSyncCloudRecord {
    static let zoneName = "Notes"
    static let recordType = "Note"

    private enum Key {
        static let payload = "payload"
        static let schemaVersion = "schemaVersion"
        static let deletedAt = "deletedAt"
    }

    static func zoneID() -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    static func recordID(for noteID: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: noteID.uuidString, zoneID: zoneID())
    }

    static func noteID(from recordID: CKRecord.ID) -> UUID? {
        UUID(uuidString: recordID.recordName)
    }

    static func outboxFile(for noteID: UUID, in outbox: URL) -> URL {
        outbox.appendingPathComponent("\(noteID.uuidString).json")
    }

    /// Writes the payload file under `outbox` and returns the record to save.
    /// Starting from the saved system fields keeps the change tag, so
    /// CloudKit can tell a stale save from a current one.
    static func makeRecord(_ outgoing: NoteSyncOutgoing, outbox: URL) throws -> CKRecord {
        let id = recordID(for: outgoing.record.noteID)
        let record = outgoing.systemFields
            .flatMap(record(fromSystemFields:))
            .flatMap { $0.recordID == id && $0.recordType == recordType ? $0 : nil }
            ?? CKRecord(recordType: recordType, recordID: id)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        let file = outboxFile(for: outgoing.record.noteID, in: outbox)
        try NoteSyncPayload.encode(outgoing.record).write(to: file, options: .atomic)
        record[Key.payload] = CKAsset(fileURL: file)
        if case .int(let version)? = outgoing.record.fields[NoteSyncRecord.schemaVersionKey] {
            record[Key.schemaVersion] = version
        } else {
            record[Key.schemaVersion] = NoteSyncRecord.schemaVersion
        }
        record[Key.deletedAt] = outgoing.record.deletedAt
        return record
    }

    static func payload(of record: CKRecord) -> Data? {
        guard let url = (record[Key.payload] as? CKAsset)?.fileURL else { return nil }
        return try? Data(contentsOf: url)
    }

    static func systemFields(of record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        return CKRecord(coder: unarchiver)
    }
}
