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
            "panel.prompt = localizedCatalogString(\"Choose\")",
            "panel.message = localizedCatalogString(",
            "Choose a folder for the exported files.",
            "if isSaving {",
            "ProgressView()",
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
            !noteBrowser.contains("ToolbarIconMenu"),
            "pill no longer exposes a more-actions menu"
        )
        try expect(
            !noteBrowser.contains("ObsidianExportSheet"),
            "Obsidian export is removed"
        )
        let namingCall = try sourceSection(
            noteBrowser,
            from: "suggestedBaseName(",
            to: "onDismiss:"
        )
        try expect(
            namingCall.contains("timestamp: item.timestamp"),
            "file export names untitled notes from their timestamp"
        )
        try expect(
            !namingCall.contains("transcript:"),
            "file export naming does not use the transcript"
        )
        try expect(
            !exportView.contains("enum NoteFileExportNaming"),
            "file export naming stays outside the SwiftUI view"
        )
        print("NoteFileExportUIContractTests passed")
    }

    private static func source(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    private static func sourceSection(
        _ source: String,
        from startMarker: String,
        to endMarker: String
    ) throws -> Substring {
        guard let start = source.range(of: startMarker)?.lowerBound,
              let end = source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound else {
            throw TestFailure("Unable to locate source section from \(startMarker) to \(endMarker)")
        }
        return source[start..<end]
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
