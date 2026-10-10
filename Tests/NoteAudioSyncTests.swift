import Foundation

@main
struct NoteAudioSyncTests {
    static func main() throws {
        testPartCounts()
        testPartRanges()
        try testWritePartCopiesTheRightBytes()
        try testWritePartPastTheEndThrows()
        try testSHA256()
        testPartIDRoundTrip()
        testManifestShape()
        print("NoteAudioSyncTests passed")
    }

    static func testPartCounts() {
        let mb50 = NoteAudioParts.partSize
        precondition(mb50 == 50_000_000)
        precondition(NoteAudioParts.count(bytes: 0) == 0)
        precondition(NoteAudioParts.count(bytes: 1) == 1)
        precondition(NoteAudioParts.count(bytes: mb50) == 1)
        precondition(NoteAudioParts.count(bytes: mb50 + 1) == 2)
        precondition(NoteAudioParts.count(bytes: 120_000_000) == 3)
    }

    static func testPartRanges() {
        precondition(NoteAudioParts.range(index: 0, bytes: 10, partSize: 4) == 0..<4)
        precondition(NoteAudioParts.range(index: 2, bytes: 10, partSize: 4) == 8..<10)
        precondition(NoteAudioParts.range(index: 0, bytes: 3, partSize: 4) == 0..<3)
    }

    static func testWritePartCopiesTheRightBytes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quill-audio-parts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.wav")
        let bytes = Data((0..<10).map { UInt8($0) })
        try bytes.write(to: source)
        var joined = Data()
        for index in 0..<NoteAudioParts.count(bytes: 10, partSize: 4) {
            let part = dir.appendingPathComponent("\(index).part")
            try NoteAudioParts.writePart(index: index, of: source, partSize: 4, to: part)
            joined += try Data(contentsOf: part)
        }
        precondition(joined == bytes, "parts rejoin to the original bytes")
        let last = try Data(contentsOf: dir.appendingPathComponent("2.part"))
        precondition(last == Data([8, 9]))
    }

    /// The file got shorter after the part was planned: an error, not a crash.
    static func testWritePartPastTheEndThrows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quill-audio-short-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.wav")
        try Data([1, 2, 3]).write(to: source)
        do {
            try NoteAudioParts.writePart(index: 2, of: source, partSize: 4, to: dir.appendingPathComponent("2.part"))
            preconditionFailure("a part past the end of the file must throw")
        } catch {}
    }

    static func testSHA256() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("quill-audio-hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        let hash = try NoteAudioParts.sha256(of: file)
        precondition(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    static func testPartIDRoundTrip() {
        let id = UUID()
        let sha = String(repeating: "0123456789abcdef", count: 4)
        let part = NoteAudioPartID(noteID: id, key: NoteAudioPartID.key(sha256: sha), index: 12)
        precondition(part.recordName == "\(id.uuidString)-0123456789abcdef-12", "named after the file's bytes")
        precondition(NoteAudioPartID(recordName: part.recordName) == part)
        precondition(NoteAudioPartID.parts(of: id, sha256: sha, count: 2).map(\.index) == [0, 1])
        precondition(NoteAudioPartID(recordName: id.uuidString) == nil, "a note record name is not a part")
        precondition(NoteAudioPartID(recordName: "\(id.uuidString)-12") == nil, "a part needs its file key")
        precondition(NoteAudioPartID(recordName: "\(id.uuidString)-0123456789abcdef--1") == nil)
        precondition(NoteAudioPartID(recordName: "\(id.uuidString)-0123456789ABCDEF-1") == nil, "keys are lowercase hex")
        precondition(NoteAudioPartID(recordName: "\(id.uuidString)-0123-1") == nil)
        precondition(NoteAudioPartID(recordName: "synthetic-0123456789abcdef-1") == nil)
        precondition(NoteAudioPartID(recordName: "\(id.uuidString)-0123456789abcdef-01") == nil, "only the name it writes")
        precondition(NoteAudioPartID(recordName: "\(id.uuidString)-0123456789abcdef-+1") == nil)
        precondition(NoteAudioPartID(recordName: "\(id.uuidString.lowercased())-0123456789abcdef-1") == nil)
        let manifest = NoteAudioManifest(sha256: sha, bytes: 120_000_000, partSize: 50_000_000, parts: 3)
        precondition(manifest.partIDs(noteID: id) == NoteAudioPartID.parts(of: id, sha256: sha, count: 3))
        let malformed = Data(#"{"bytes":1,"partSize":50000000,"parts":1,"sha256":"not-a-hash","v":1}"#.utf8)
        precondition(NoteAudioManifest.decode(malformed) == nil, "a marker whose hash can't name parts is rejected")
        precondition(NoteAudioManifest.decode(manifest.encoded()) == manifest)
        // Counts that don't fit together are no marker: they would name
        // parts that can't exist.
        let hash = sha
        let marker = { (bytes: Int64, partSize: Int64, parts: Int) -> Data in
            Data(#"{"bytes":\#(bytes),"partSize":\#(partSize),"parts":\#(parts),"sha256":"\#(hash)","v":1}"#.utf8)
        }
        precondition(NoteAudioManifest.decode(marker(120_000_000, 50_000_000, 3)) == manifest)
        precondition(NoteAudioManifest.decode(marker(120_000_000, 50_000_000, -1)) == nil)
        precondition(NoteAudioManifest.decode(marker(120_000_000, 50_000_000, 2)) == nil)
        precondition(NoteAudioManifest.decode(marker(120_000_000, 0, 0)) == nil)
        precondition(NoteAudioManifest.decode(marker(-5, 50_000_000, 0)) == nil)
        precondition(NoteAudioManifest.decode(marker(Int64.max, 50_000_000, 1)) == nil)
        precondition(NoteAudioManifest.decode(marker(9_000_000_000_000, 1, Int.max)) == nil)
    }

    static func testManifestShape() {
        let manifest = NoteAudioManifest(sha256: String(repeating: "ab", count: 32), bytes: 120, partSize: 50, parts: 3)
        let text = String(data: manifest.encoded(), encoding: .utf8)
        precondition(text == #"{"bytes":120,"partSize":50,"parts":3,"sha256":"abababababababababababababababababababababababababababababababab","v":1}"#, "shared shape: \(text ?? "")")
        precondition(NoteAudioManifest.decode(manifest.encoded()) == manifest)
        precondition(NoteAudioManifest.decode(Data("{}".utf8)) == nil)
    }
}
