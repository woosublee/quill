import Foundation

@main
struct AudioFileDropTests {
    static func main() throws {
        testAcceptsTheImportPanelTypes()
        testTargetForDraggedItems()
        testChoiceTakesFirstImportableAndCountsTheRest()
        try testPromiseFoldersStayInsideTheirRoot()
        try testStalePromiseFoldersAreRemoved()
        testNoteBrowserUsesOneImportPath()
        testDropViewTakesHitTestOnlyDuringADrag()
        print("AudioFileDropTests passed")
    }

    /// Hovering must reach the views below, or their help tags never show
    /// (#739): AppKit hit-tests for them from a timer, with no fresh event.
    private static func testDropViewTakesHitTestOnlyDuringADrag() {
        precondition(!AudioFileDrop.dropViewTakesHitTest(isMouseButtonDown: false, secondsSinceDragUpdate: nil),
                     "a hover's help tag lookup goes below")
        precondition(AudioFileDrop.dropViewTakesHitTest(isMouseButtonDown: true, secondsSinceDragUpdate: nil),
                     "a drag from another app finds the view")
        precondition(AudioFileDrop.dropViewTakesHitTest(isMouseButtonDown: false, secondsSinceDragUpdate: 0.49),
                     "the drop lands right after the button comes up")
        precondition(!AudioFileDrop.dropViewTakesHitTest(isMouseButtonDown: false, secondsSinceDragUpdate: 0.5),
                     "a finished drag doesn't keep the view answering")
        let source = try! String(contentsOfFile: "Sources/AudioFileDropTarget.swift", encoding: .utf8)
        precondition(source.contains("isMouseButtonDown: NSEvent.pressedMouseButtons != 0"), "the view asks for the button state")
        precondition(source.contains("guard target == .importable else { return [] }\n        lastDragUpdate = "),
                     "only a drag the view takes counts as a drag update")
        precondition(source.contains("func clearTarget() {\n        lastDragUpdate = nil"), "a drag that leaves or lands stops counting")
    }

    private static func file(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/quill-drop-fixtures/\(name)")
    }

    private static func testAcceptsTheImportPanelTypes() {
        for fileExtension in AudioImportOptions.broadlySupportedExtensions {
            precondition(AudioFileDrop.isImportable(fileURL: file("memo.\(fileExtension)")), fileExtension)
            precondition(AudioFileDrop.isImportable(fileURL: file("MEMO.\(fileExtension.uppercased())")), fileExtension)
        }
        precondition(!AudioFileDrop.isImportable(fileURL: file("notes.txt")))
        precondition(!AudioFileDrop.isImportable(fileURL: file("folder")))
        precondition(!AudioFileDrop.isImportable(fileURL: URL(string: "https://example.com/memo.m4a")!))

        precondition(AudioFileDrop.isImportable(typeIdentifier: "com.apple.m4a-audio"))
        precondition(AudioFileDrop.isImportable(typeIdentifier: "com.microsoft.waveform-audio"))
        precondition(AudioFileDrop.isImportable(typeIdentifier: "public.mp3"))
        precondition(!AudioFileDrop.isImportable(typeIdentifier: "public.plain-text"))
        precondition(!AudioFileDrop.isImportable(typeIdentifier: "com.apple.coreaudio-format"))
        precondition(!AudioFileDrop.isImportable(typeIdentifier: "not a type"))
    }

    private static func testTargetForDraggedItems() {
        precondition(AudioFileDrop.target(for: []) == nil)
        precondition(AudioFileDrop.target(for: [.file(file("memo.m4a"))]) == .importable)
        precondition(AudioFileDrop.target(for: [.file(file("notes.txt"))]) == .unsupported)
        precondition(AudioFileDrop.target(for: [.file(file("notes.txt")), .file(file("memo.wav"))]) == .importable)
        precondition(AudioFileDrop.target(for: [.promise(typeIdentifiers: ["com.apple.m4a-audio"])]) == .importable)
        precondition(AudioFileDrop.target(for: [.promise(typeIdentifiers: ["public.jpeg"])]) == .unsupported)
        // A promise that names no type isn't taken.
        precondition(AudioFileDrop.target(for: [.promise(typeIdentifiers: [])]) == .unsupported)
    }

    private static func testChoiceTakesFirstImportableAndCountsTheRest() {
        precondition(AudioFileDrop.choice(from: []) == nil)
        precondition(AudioFileDrop.choice(from: [.file(file("notes.txt"))]) == nil)

        let one = AudioFileDrop.choice(from: [.file(file("memo.m4a"))])
        precondition(one == .init(item: .file(file("memo.m4a")), itemIndex: 0, skippedCount: 0))

        let several = AudioFileDrop.choice(from: [
            .file(file("notes.txt")),
            .file(file("first.mp3")),
            .file(file("second.wav"))
        ])
        precondition(several == .init(item: .file(file("first.mp3")), itemIndex: 1, skippedCount: 1))

        // A file that isn't audio doesn't count as skipped.
        let withText = AudioFileDrop.choice(from: [.file(file("notes.txt")), .file(file("memo.m4a"))])
        precondition(withText?.skippedCount == 0)

        let promised = AudioFileDrop.choice(from: [
            .promise(typeIdentifiers: ["com.apple.m4a-audio"]),
            .promise(typeIdentifiers: ["com.apple.m4a-audio"])
        ])
        precondition(promised?.itemIndex == 0 && promised?.skippedCount == 1)
    }

    private static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioFileDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func testPromiseFoldersStayInsideTheirRoot() throws {
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = AudioFileDrop.promiseRoot(in: base)
        precondition(root.lastPathComponent == "QuillAudioDrops")

        let folder = try AudioFileDrop.makePromiseFolder(root: root)
        precondition(folder.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        try Data("synthetic".utf8).write(to: folder.appendingPathComponent("memo.m4a"))
        AudioFileDrop.removePromiseFolder(folder, root: root)
        precondition(!FileManager.default.fileExists(atPath: folder.path))

        // A folder outside the drop root is never removed.
        let outside = base.appendingPathComponent("Keep", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        AudioFileDrop.removePromiseFolder(outside, root: root)
        AudioFileDrop.removePromiseFolder(root, root: root)
        precondition(FileManager.default.fileExists(atPath: outside.path))
        precondition(FileManager.default.fileExists(atPath: root.path))
    }

    private static func testStalePromiseFoldersAreRemoved() throws {
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = AudioFileDrop.promiseRoot(in: base)
        let old = try AudioFileDrop.makePromiseFolder(root: root)
        let recent = try AudioFileDrop.makePromiseFolder(root: root)
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)],
            ofItemAtPath: old.path
        )

        AudioFileDrop.removeStalePromiseFolders(root: root)

        precondition(!FileManager.default.fileExists(atPath: old.path), "a folder older than a day goes")
        precondition(FileManager.default.fileExists(atPath: recent.path), "an import in progress keeps its folder")
        AudioFileDrop.removeStalePromiseFolders(root: base.appendingPathComponent("Missing"))
    }

    /// A drop opens the same sheet as the panel: both go through
    /// `beginAudioImport`, which builds the one `PendingAudioImport`.
    private static func testNoteBrowserUsesOneImportPath() {
        let source = try! String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)
        precondition(source.components(separatedBy: "PendingAudioImport(").count == 2, "one place builds the import request")
        precondition(source.contains("guard response == .OK, let url = panel.url else { return }\n            beginAudioImport(url)"))
        precondition(source.contains("beginAudioImport(fileURL, promiseFolder: promiseFolder)"))
        precondition(source.contains("pendingAudioImport == nil"), "no drop while the import sheet is open")
        precondition(source.contains("&& !appState.isRecording"), "no drop while recording")
    }
}
