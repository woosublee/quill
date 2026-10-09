import CryptoKit
import Foundation

/// One part of a note's audio in iCloud: record `<note UUID>-<index>`.
struct NoteAudioPartID: Hashable, Sendable {
    let noteID: UUID
    let index: Int

    init(noteID: UUID, index: Int) {
        self.noteID = noteID
        self.index = index
    }

    init?(recordName: String) {
        guard let dash = recordName.lastIndex(of: "-"),
              let noteID = UUID(uuidString: String(recordName[..<dash])),
              let index = Int(recordName[recordName.index(after: dash)...]),
              index >= 0 else { return nil }
        self.init(noteID: noteID, index: index)
    }

    var recordName: String { "\(noteID.uuidString)-\(index)" }
}

/// What an audio part in iCloud was cut from: the note's audio file name
/// and size. A part cut from an earlier file of the note doesn't match.
struct NoteAudioPartStamp: Hashable, Sendable {
    let fileName: String
    let fileBytes: Int64
}

/// Says a note's audio is entirely in iCloud. It is set only after every
/// part is saved, so a Mac that sees it can download the audio. Shared with
/// the iPhone app: keys never change once shipped.
struct NoteAudioManifest: Codable, Equatable, Sendable {
    static let version = 1

    let sha256: String
    let bytes: Int64
    let partSize: Int64
    let parts: Int

    private enum CodingKeys: String, CodingKey {
        case v, sha256, bytes, partSize, parts
    }

    init(sha256: String, bytes: Int64, partSize: Int64, parts: Int) {
        self.sha256 = sha256
        self.bytes = bytes
        self.partSize = partSize
        self.parts = parts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sha256 = try container.decode(String.self, forKey: .sha256)
        bytes = try container.decode(Int64.self, forKey: .bytes)
        partSize = try container.decode(Int64.self, forKey: .partSize)
        parts = try container.decode(Int.self, forKey: .parts)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .v)
        try container.encode(sha256, forKey: .sha256)
        try container.encode(bytes, forKey: .bytes)
        try container.encode(partSize, forKey: .partSize)
        try container.encode(parts, forKey: .parts)
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)) ?? Data()
    }

    static func decode(_ data: Data) -> NoteAudioManifest? {
        try? JSONDecoder().decode(NoteAudioManifest.self, from: data)
    }
}

/// How a note's audio file splits into parts for iCloud.
enum NoteAudioParts {
    static let partSize: Int64 = 50_000_000
    private static let chunkSize = 1 << 20

    static func count(bytes: Int64, partSize: Int64 = partSize) -> Int {
        guard bytes > 0 else { return 0 }
        return Int((bytes + partSize - 1) / partSize)
    }

    static func range(index: Int, bytes: Int64, partSize: Int64 = partSize) -> Range<Int64> {
        let start = Int64(index) * partSize
        return start..<min(start + partSize, bytes)
    }

    /// Copies part `index` of `source` into `destination`, replacing it.
    static func writePart(index: Int, of source: URL, partSize: Int64 = partSize, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let bytes = Int64(try input.seekToEnd())
        let range = range(index: index, bytes: bytes, partSize: partSize)
        try? FileManager.default.removeItem(at: destination)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try input.seek(toOffset: UInt64(range.lowerBound))
        var remaining = range.count
        while remaining > 0 {
            guard let chunk = try input.read(upToCount: min(chunkSize, remaining)), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            remaining -= chunk.count
        }
    }

    /// The file's SHA-256 as lowercase hex, read in chunks.
    static func sha256(of url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
