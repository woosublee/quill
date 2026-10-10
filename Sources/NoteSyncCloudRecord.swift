import CloudKit
import Foundation

/// How a failed save or delete is handled, read from its CloudKit error.
enum NoteSyncSendErrorKind: Equatable {
    /// The `Notes` zone is gone: deleted by another Mac, or by this one.
    case zoneGone
    case serverChanged
    case quotaExceeded
    /// Offline; the engine retries these itself.
    case network
    /// The server is busy or rate limits this Mac; the engine waits and
    /// retries these itself, and the Mac isn't offline.
    case throttled
    /// The iCloud account needs attention (a password, new terms).
    case account
    case unknownItem
    case other
}

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

    static func sendErrorKind(_ code: CKError.Code) -> NoteSyncSendErrorKind {
        switch code {
        case .zoneNotFound, .userDeletedZone: return .zoneGone
        case .serverRecordChanged: return .serverChanged
        case .quotaExceeded: return .quotaExceeded
        case .networkUnavailable, .networkFailure: return .network
        case .serviceUnavailable, .requestRateLimited, .zoneBusy: return .throttled
        case .notAuthenticated, .accountTemporarilyUnavailable: return .account
        case .unknownItem: return .unknownItem
        default: return .other
        }
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

    /// Payload and audio part files hold note content, so each is removed once its save is
    /// done, and any left from an earlier run are removed when sync starts.
    static func removeOutboxFile(for noteID: UUID, in outbox: URL) {
        try? FileManager.default.removeItem(at: outboxFile(for: noteID, in: outbox))
    }

    static func removeAllOutboxFiles(in outbox: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" || file.pathExtension == "part" {
            try? FileManager.default.removeItem(at: file)
        }
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
