import CloudKit
import Foundation

/// One audio part to send: which bytes of which file.
public struct NoteSyncOutgoingAudio: Equatable, Sendable {
    public let part: NoteAudioPartID
    public let fileURL: URL
    /// The whole file's size.
    public let byteCount: Int64

    public init(part: NoteAudioPartID, fileURL: URL, byteCount: Int64) {
        self.part = part
        self.fileURL = fileURL
        self.byteCount = byteCount
    }
}

/// Maps audio parts to CloudKit `NoteAudio` records. They live in their own
/// zone, which the engine never fetches, so audio downloads only on demand.
public enum NoteAudioCloudRecord {
    public static let zoneName = "NoteAudio"
    public static let recordType = "NoteAudio"

    private enum Key {
        static let data = "data"
        static let index = "index"
        static let noteID = "noteID"
    }

    /// The one small field a lookup asks for, so it never downloads audio.
    public static let lookupKeys = [Key.index]
    /// The field holding the part's bytes, for a download.
    public static let dataKey = Key.data

    public static func zoneID() -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    public static func recordID(for part: NoteAudioPartID) -> CKRecord.ID {
        CKRecord.ID(recordName: part.recordName, zoneID: zoneID())
    }

    public static func part(from recordID: CKRecord.ID) -> NoteAudioPartID? {
        guard recordID.zoneID == zoneID() else { return nil }
        return NoteAudioPartID(recordName: recordID.recordName)
    }

    public static func partFile(for part: NoteAudioPartID, in outbox: URL) -> URL {
        outbox.appendingPathComponent("\(part.recordName).part")
    }

    /// Audio that fits one part sends the file itself; a part of a longer
    /// file is cut into `outbox` first. A part's name says which bytes it
    /// holds, so it is always saved as a new record, never over another.
    public static func makeRecord(
        _ outgoing: NoteSyncOutgoingAudio,
        outbox: URL,
        partSize: Int64 = NoteAudioParts.partSize
    ) throws -> CKRecord {
        let record = CKRecord(recordType: recordType, recordID: recordID(for: outgoing.part))
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
        return record
    }

    public static func removePartFile(for part: NoteAudioPartID, in outbox: URL) {
        try? FileManager.default.removeItem(at: partFile(for: part, in: outbox))
    }

    /// What one send carries: every waiting note change first, then audio
    /// deletes, then a single audio part, so text never waits behind audio
    /// and one request holds at most one part.
    @available(iOS 17.0, macOS 14.0, *)
    public static func nextBatch(_ pending: [CKSyncEngine.PendingRecordZoneChange]) -> [CKSyncEngine.PendingRecordZoneChange] {
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
