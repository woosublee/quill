import Foundation

@main
struct NoteFileExportTests {
    static func main() throws {
        try testSanitizedBaseNameAndFallback()
        try testDestinationNamesPreserveAudioExtension()
        try testExportsTranscriptAndAudio()
        try testConflictDoesNotOverwriteWithoutConsent()
        try testPreparedFileReportsLateConflict()
        try testReplaceOverwritesExistingFile()
        try testPartialFailureKeepsSuccessfulTranscript()
        print("NoteFileExportTests passed")
    }

    private static func testSanitizedBaseNameAndFallback() throws {
        precondition(
            NoteFileExporter.sanitizedBaseName(
                "  meeting/a:b?  ",
                fallback: "fallback"
            ) == "meeting-a-b-"
        )
        precondition(
            NoteFileExporter.sanitizedBaseName(
                " /:*?\"<>| ",
                fallback: "2026-07-21 10-30"
            ) == "2026-07-21 10-30"
        )
    }

    private static func testDestinationNamesPreserveAudioExtension() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("source.m4a")
        try Data([1, 2, 3]).write(to: audio)
        let request = NoteFileExportRequest(
            source: NoteFileExportSource(transcript: "hello", audioURL: audio),
            selectedItems: [.transcript, .audio],
            textFormat: .markdown,
            baseName: "Meeting",
            destinationDirectory: root
        )
        let urls = NoteFileExporter.destinationURLs(for: request)

        precondition(urls[.transcript]?.lastPathComponent == "Meeting.md")
        precondition(urls[.audio]?.lastPathComponent == "Meeting.m4a")
    }

    private static func testExportsTranscriptAndAudio() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let audio = sourceDirectory.appendingPathComponent("recording.wav")
        try Data([4, 5, 6]).write(to: audio)
        let request = NoteFileExportRequest(
            source: NoteFileExportSource(transcript: "# Transcript", audioURL: audio),
            selectedItems: [.transcript, .audio],
            textFormat: .plainText,
            baseName: "Meeting",
            destinationDirectory: destination
        )

        let result = NoteFileExporter.export(request, replaceExisting: false)

        let transcript = try String(
            contentsOf: destination.appendingPathComponent("Meeting.txt"),
            encoding: .utf8
        )
        let audioData = try Data(
            contentsOf: destination.appendingPathComponent("Meeting.wav")
        )
        precondition(Set(result.savedItems) == [.transcript, .audio])
        precondition(result.failures.isEmpty)
        precondition(transcript == "# Transcript")
        precondition(audioData == Data([4, 5, 6]))
    }

    private static func testConflictDoesNotOverwriteWithoutConsent() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("Meeting.txt")
        try "old".write(to: existing, atomically: true, encoding: .utf8)
        let request = NoteFileExportRequest(
            source: NoteFileExportSource(transcript: "new", audioURL: nil),
            selectedItems: [.transcript],
            textFormat: .plainText,
            baseName: "Meeting",
            destinationDirectory: root
        )

        let result = NoteFileExporter.export(request, replaceExisting: false)

        precondition(result.savedItems.isEmpty)
        let existingContent = try String(contentsOf: existing, encoding: .utf8)
        precondition(result.failures == [
            NoteFileExportFailure(item: .transcript, reason: .destinationExists)
        ])
        precondition(existingContent == "old")
    }

    private static func testPreparedFileReportsLateConflict() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = root.appendingPathComponent("prepared.tmp")
        let destination = root.appendingPathComponent("Meeting.txt")
        try "new".write(to: prepared, atomically: true, encoding: .utf8)
        try "old".write(to: destination, atomically: true, encoding: .utf8)

        do {
            try NoteFileExporter.installPreparedFile(
                prepared,
                at: destination,
                replaceExisting: false
            )
            preconditionFailure("Expected a late destination conflict")
        } catch let error as NoteFileExporter.ExportWriteError {
            precondition(error == .destinationExists)
        }
        let destinationContent = try String(contentsOf: destination, encoding: .utf8)
        precondition(destinationContent == "old")
    }

    private static func testReplaceOverwritesExistingFile() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("Meeting.txt")
        try "old".write(to: existing, atomically: true, encoding: .utf8)
        let request = NoteFileExportRequest(
            source: NoteFileExportSource(transcript: "new", audioURL: nil),
            selectedItems: [.transcript],
            textFormat: .plainText,
            baseName: "Meeting",
            destinationDirectory: root
        )

        let result = NoteFileExporter.export(request, replaceExisting: true)

        let existingContent = try String(contentsOf: existing, encoding: .utf8)
        precondition(result.savedItems == [.transcript])
        precondition(result.failures.isEmpty)
        precondition(existingContent == "new")
    }

    private static func testPartialFailureKeepsSuccessfulTranscript() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingAudio = root.appendingPathComponent("missing.wav")
        let request = NoteFileExportRequest(
            source: NoteFileExportSource(transcript: "saved text", audioURL: missingAudio),
            selectedItems: [.transcript, .audio],
            textFormat: .plainText,
            baseName: "Meeting",
            destinationDirectory: root
        )

        let result = NoteFileExporter.export(request, replaceExisting: false)

        precondition(result.savedItems == [.transcript])
        let transcript = try String(
            contentsOf: root.appendingPathComponent("Meeting.txt"),
            encoding: .utf8
        )
        precondition(result.failures == [
            NoteFileExportFailure(item: .audio, reason: .sourceMissing)
        ])
        precondition(transcript == "saved text")
    }

    private static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("note-file-export-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
