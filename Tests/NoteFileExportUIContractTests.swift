import Foundation

@main
struct NoteFileExportUIContractTests {
    static func main() throws {
        let exportView = try source("Sources/NoteFileExportView.swift")
        let noteBrowser = try source("Sources/NoteBrowserView.swift")

        for marker in [
            "struct NoteFileExportView: View",
            "Toggle(\"Transcript Text\"",
            "Toggle(\"Recording File\"",
            "Picker(\"Text Format\"",
            "NSOpenPanel()",
            "NoteFileExporter.conflicts(for:",
            "NoteFileExporter.export(",
            "note_file_export_last_directory",
            "Replace Existing Files?"
        ] {
            try expect(exportView.contains(marker), "file export view contains \(marker)")
        }

        try expect(
            noteBrowser.contains("Image(systemName: \"square.and.arrow.down\")"),
            "pill uses the save-files symbol"
        )
        try expect(
            noteBrowser.contains("showFileExportSheet = true"),
            "save-files action opens the generic sheet"
        )
        try expect(
            noteBrowser.contains("Menu {"),
            "pill exposes a more-actions menu"
        )
        try expect(
            noteBrowser.contains("ObsidianExportSheet("),
            "legacy Obsidian export remains reachable"
        )
        try expect(
            noteBrowser.contains("Image(systemName: \"ellipsis\")"),
            "more-actions menu uses the approved symbol"
        )
        print("NoteFileExportUIContractTests passed")
    }

    private static func source(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else { throw TestFailure(label) }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
