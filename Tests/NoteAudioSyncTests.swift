import Foundation

@main
struct NoteAudioSyncTests {
    static func main() throws {
        testPartCounts()
        testPartRanges()
        try testWritePartCopiesTheRightBytes()
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

    static func testSHA256() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("quill-audio-hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        let hash = try NoteAudioParts.sha256(of: file)
        precondition(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    static func testPartIDRoundTrip() {
        let id = UUID()
        let part = NoteAudioPartID(noteID: id, index: 12)
        precondition(part.recordName == "\(id.uuidString)-12")
        precondition(NoteAudioPartID(recordName: part.recordName) == part)
        precondition(NoteAudioPartID(recordName: id.uuidString) == nil, "a note record name is not a part")
        precondition(NoteAudioPartID(recordName: "\(id.uuidString)--1") == nil)
        precondition(NoteAudioPartID(recordName: "synthetic-1") == nil)
        precondition(NoteAudioPartID(recordName: "\(id.uuidString)-") == nil)
    }

    static func testManifestShape() {
        let manifest = NoteAudioManifest(sha256: "abc", bytes: 120, partSize: 50, parts: 3)
        let text = String(data: manifest.encoded(), encoding: .utf8)
        precondition(text == #"{"bytes":120,"partSize":50,"parts":3,"sha256":"abc","v":1}"#, "shared shape: \(text ?? "")")
        precondition(NoteAudioManifest.decode(manifest.encoded()) == manifest)
        precondition(NoteAudioManifest.decode(Data("{}".utf8)) == nil)
    }
}
