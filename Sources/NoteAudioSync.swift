import CryptoKit
import Foundation

/// One part of a note's audio in iCloud: record
/// `<note UUID>-<key>-<index>`, where `key` is the first 16 hex digits of
/// the file's SHA-256. A part is named after the bytes it holds, so a
/// changed file never writes over the parts of the earlier one.
struct NoteAudioPartID: Hashable, Sendable {
    static let keyLength = 16

    let noteID: UUID
    let key: String
    let index: Int

    init(noteID: UUID, key: String, index: Int) {
        self.noteID = noteID
        self.key = key
        self.index = index
    }

    init?(recordName: String) {
        guard let lastDash = recordName.lastIndex(of: "-"),
              let index = Int(recordName[recordName.index(after: lastDash)...]),
              index >= 0 else { return nil }
        let rest = recordName[..<lastDash]
        guard let keyDash = rest.lastIndex(of: "-"),
              let noteID = UUID(uuidString: String(rest[..<keyDash])) else { return nil }
        let key = String(rest[rest.index(after: keyDash)...])
        guard Self.isKey(key) else { return nil }
        self.init(noteID: noteID, key: key, index: index)
        // Only the name this would write, so a delete hits the record listed.
        guard self.recordName == recordName else { return nil }
    }

    var recordName: String { "\(noteID.uuidString)-\(key)-\(index)" }

    /// The part key for a file's SHA-256 (lowercase hex).
    static func key(sha256: String) -> String {
        String(sha256.prefix(keyLength))
    }

    static func isKey(_ text: String) -> Bool {
        text.count == keyLength && text.allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// Every part of a file with this SHA-256 and part count.
    static func parts(of noteID: UUID, sha256: String, count: Int) -> [NoteAudioPartID] {
        let key = key(sha256: sha256)
        return (0..<max(count, 0)).map { NoteAudioPartID(noteID: noteID, key: key, index: $0) }
    }
}

/// What iCloud may hold of a deleted or replaced note's audio: the parts
/// its marker names, and the parts of an upload this Mac had started.
struct NoteAudioSyncState: Equatable, Sendable {
    var manifest: NoteAudioManifest?
    /// The SHA-256 of the file this Mac was uploading.
    var uploadKey: String?
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
        // The hash names the parts, so one that can't is no marker at all.
        guard sha256.count == 64, sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw DecodingError.dataCorruptedError(forKey: .sha256, in: container, debugDescription: "Not a SHA-256")
        }
        bytes = try container.decode(Int64.self, forKey: .bytes)
        partSize = try container.decode(Int64.self, forKey: .partSize)
        parts = try container.decode(Int.self, forKey: .parts)
        // Counts that don't fit together would name parts that can't exist.
        guard Self.fits(bytes: bytes, partSize: partSize, parts: parts) else {
            throw DecodingError.dataCorruptedError(forKey: .parts, in: container, debugDescription: "Counts don't fit")
        }
    }

    /// The most parts a marker may name; far past any real recording.
    static let maxParts = 10_000

    private static func fits(bytes: Int64, partSize: Int64, parts: Int) -> Bool {
        guard bytes > 0, partSize > 0, (1...maxParts).contains(parts) else { return false }
        // As NoteAudioParts.count, without overflowing for huge values.
        let (whole, rest) = bytes.quotientAndRemainder(dividingBy: partSize)
        return whole + (rest > 0 ? 1 : 0) == Int64(parts)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .v)
        try container.encode(sha256, forKey: .sha256)
        try container.encode(bytes, forKey: .bytes)
        try container.encode(partSize, forKey: .partSize)
        try container.encode(parts, forKey: .parts)
    }

    /// The parts this marker says are in iCloud.
    func partIDs(noteID: UUID) -> [NoteAudioPartID] {
        NoteAudioPartID.parts(of: noteID, sha256: sha256, count: parts)
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

enum NoteAudioPartsError: Error {
    /// The file is shorter than when the part was planned.
    case pastEnd
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
        guard Int64(index) * partSize < bytes else { throw NoteAudioPartsError.pastEnd }
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
