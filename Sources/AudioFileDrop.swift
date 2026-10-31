import Foundation
import UniformTypeIdentifiers

/// Which dropped files the Note Browser imports (#703): the same types as
/// the import panel, one file at a time.
enum AudioFileDrop {
    /// What a drag over the Note Browser would do.
    enum Target: Equatable {
        /// At least one file is audio Quill can import.
        case importable
        /// Files, but none Quill can import.
        case unsupported
    }

    /// A dropped file, or a file Voice Memos promises to write.
    enum Item: Equatable {
        case file(URL)
        case promise(typeIdentifiers: [String])

        var isImportable: Bool {
            switch self {
            case .file(let url):
                return AudioFileDrop.isImportable(fileURL: url)
            case .promise(let typeIdentifiers):
                // The written file is checked again once it arrives.
                return typeIdentifiers.contains(where: AudioFileDrop.isImportable(typeIdentifier:))
            }
        }
    }

    /// The file to import and how many other importable files were left out.
    struct Choice: Equatable {
        let item: Item
        let itemIndex: Int
        let skippedCount: Int
    }

    /// How long a mouse event, or a drag update, counts as the one being
    /// handled now.
    static let recentEventWindow: TimeInterval = 0.5

    /// Whether the window-wide drop view answers a hit test that isn't for a
    /// mouse event being handled now, so AppKit finds it as a drag's
    /// destination. Only a drag needs it, and a drag holds a mouse button
    /// down (it may already be up as the drop lands, right after the last
    /// update of a drag the view takes). Otherwise the pointer is hovering:
    /// AppKit's help tags hit-test from a timer, long after the last mouse
    /// event, and answering then hid every help tag under the view (#739).
    static func dropViewTakesHitTest(
        isMouseButtonDown: Bool,
        secondsSinceDragUpdate: TimeInterval?
    ) -> Bool {
        if isMouseButtonDown { return true }
        guard let secondsSinceDragUpdate else { return false }
        return secondsSinceDragUpdate < recentEventWindow
    }

    static func isImportable(fileURL url: URL) -> Bool {
        url.isFileURL
            && AudioImportOptions.broadlySupportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func isImportable(typeIdentifier: String) -> Bool {
        guard let type = UTType(typeIdentifier) else { return false }
        return AudioImportOptions.broadlySupportedExtensions.contains { fileExtension in
            UTType(filenameExtension: fileExtension).map(type.conforms(to:)) ?? false
        }
    }

    /// Nil when nothing in the drag is a file.
    static func target(for items: [Item]) -> Target? {
        guard !items.isEmpty else { return nil }
        return items.contains(where: \.isImportable) ? .importable : .unsupported
    }

    /// The first importable item. The panel takes one file at a time, so
    /// other audio dropped with it is skipped and counted; files that aren't
    /// audio are ignored.
    static func choice(from items: [Item]) -> Choice? {
        guard let index = items.firstIndex(where: \.isImportable) else { return nil }
        let importableCount = items.filter(\.isImportable).count
        return Choice(item: items[index], itemIndex: index, skippedCount: importableCount - 1)
    }

    // MARK: - Promised files

    /// Where promised files are written: a folder of Quill's own in the
    /// temporary directory, one subfolder per drop.
    static func promiseRoot(in temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> URL {
        temporaryDirectory.appendingPathComponent("QuillAudioDrops", isDirectory: true)
    }

    /// A new subfolder for one drop's promised file.
    static func makePromiseFolder(
        root: URL = promiseRoot(),
        fileManager: FileManager = .default
    ) throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Removes a drop's folder once its file was copied into the note or the
    /// import was cancelled. Only folders inside `root` are removed.
    static func removePromiseFolder(
        _ folder: URL,
        root: URL = promiseRoot(),
        fileManager: FileManager = .default
    ) {
        let rootPath = root.standardizedFileURL.path + "/"
        guard folder.standardizedFileURL.path.hasPrefix(rootPath) else { return }
        try? fileManager.removeItem(at: folder)
    }

    /// Removes drop folders left by an earlier run, for example after a crash
    /// mid-import. A folder newer than `maxAge` may belong to an import in
    /// progress, so it stays.
    static func removeStalePromiseFolders(
        root: URL = promiseRoot(),
        now: Date = Date(),
        maxAge: TimeInterval = 24 * 60 * 60,
        fileManager: FileManager = .default
    ) {
        guard let folders = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            guard let created, now.timeIntervalSince(created) > maxAge else { continue }
            try? fileManager.removeItem(at: folder)
        }
    }
}
