import CloudKit
import Foundation

/// Maps audio parts to CloudKit `NoteAudio` records. They live in their own
/// zone, which the engine never fetches, so audio downloads only on demand.
enum NoteAudioCloudRecord {
    static let zoneName = "NoteAudio"
    static let recordType = "NoteAudio"

    private enum Key {
        static let data = "data"
        static let index = "index"
        static let noteID = "noteID"
        static let fileName = "fileName"
        static let fileBytes = "fileBytes"
    }

    /// The fields `stamp(of:)` reads, so a lookup never downloads audio.
    static let stampKeys = [Key.fileName, Key.fileBytes]

    static func zoneID() -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    static func recordID(for part: NoteAudioPartID) -> CKRecord.ID {
        CKRecord.ID(recordName: part.recordName, zoneID: zoneID())
    }

    static func part(from recordID: CKRecord.ID) -> NoteAudioPartID? {
        guard recordID.zoneID == zoneID() else { return nil }
        return NoteAudioPartID(recordName: recordID.recordName)
    }

    static func partFile(for part: NoteAudioPartID, in outbox: URL) -> URL {
        outbox.appendingPathComponent("\(part.recordName).part")
    }

    /// Audio that fits one part sends the file itself; a part of a longer
    /// file is cut into `outbox` first.
    static func makeRecord(
        _ outgoing: NoteSyncOutgoingAudio,
        systemFields: Data?,
        outbox: URL,
        partSize: Int64 = NoteAudioParts.partSize
    ) throws -> CKRecord {
        let id = recordID(for: outgoing.part)
        let record = systemFields
            .flatMap(NoteSyncCloudRecord.record(fromSystemFields:))
            .flatMap { $0.recordID == id && $0.recordType == recordType ? $0 : nil }
            ?? CKRecord(recordType: recordType, recordID: id)
        let file: URL
        if NoteAudioParts.count(bytes: outgoing.byteCount, partSize: partSize) == 1 {
            file = outgoing.fileURL
        } else {
            try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
            file = partFile(for: outgoing.part, in: outbox)
            try NoteAudioParts.writePart(index: outgoing.part.index, of: outgoing.fileURL, partSize: partSize, to: file)
        }
        record[Key.data] = CKAsset(fileURL: file)
        record[Key.index] = outgoing.part.index
        record[Key.noteID] = outgoing.part.noteID.uuidString
        record[Key.fileName] = outgoing.fileName
        record[Key.fileBytes] = outgoing.byteCount
        return record
    }

    /// What the part was cut from, or nil for a record without it.
    static func stamp(of record: CKRecord) -> NoteAudioPartStamp? {
        guard let name = record[Key.fileName] as? String,
              let bytes = (record[Key.fileBytes] as? NSNumber)?.int64Value else { return nil }
        return NoteAudioPartStamp(fileName: name, fileBytes: bytes)
    }

    static func removePartFile(for part: NoteAudioPartID, in outbox: URL) {
        try? FileManager.default.removeItem(at: partFile(for: part, in: outbox))
    }

    /// What one send carries: every waiting note change first, then audio
    /// deletes, then a single audio part, so text never waits behind audio
    /// and one request holds at most one part.
    @available(macOS 14.0, *)
    static func nextBatch(_ pending: [CKSyncEngine.PendingRecordZoneChange]) -> [CKSyncEngine.PendingRecordZoneChange] {
        let audioZone = zoneID()
        func isAudio(_ change: CKSyncEngine.PendingRecordZoneChange) -> Bool {
            switch change {
            case .saveRecord(let id), .deleteRecord(let id): return id.zoneID == audioZone
            @unknown default: return false
            }
        }
        let notes = pending.filter { !isAudio($0) }
        if !notes.isEmpty { return notes }
        let deletes = pending.filter {
            if case .deleteRecord = $0 { return true }
            return false
        }
        if !deletes.isEmpty { return deletes }
        return Array(pending.prefix(1))
    }
}
