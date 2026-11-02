import Foundation
import QuillNoteCore

/// Save Files' items, names, and summary rules are shared with the iPhone
/// (`NoteExportPlan` in QuillNoteCore). The Mac writes into a folder the
/// person picks.
enum NoteFileExportNaming {
    static func suggestedBaseName(
        customTitle: String?,
        calendarTitle: String?,
        timestamp: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        NoteExportPlan.suggestedBaseName(
            customTitle: customTitle,
            calendarTitle: calendarTitle,
            timestamp: timestamp,
            locale: locale,
            timeZone: timeZone
        )
    }
}

typealias NoteFileExportItem = NoteExportItem
typealias NoteFileExportTextFormat = NoteExportTextFormat

struct NoteFileExportSource: Sendable {
    /// The shared rules for what is offered and how files are named.
    let plan: NoteExportPlan
    let audioURL: URL?
    /// The audio is in iCloud: `audioURL` is where it lands once downloaded.
    let audioNeedsDownload: Bool
    /// Why there is no audio to save, when it isn't simply missing.
    let audioUnavailableMessage: String?

    init(
        transcript: String,
        audioURL: URL?,
        summary: String? = nil,
        isSummaryStale: Bool = false,
        audioNeedsDownload: Bool = false,
        audioUnavailableMessage: String? = nil
    ) {
        plan = NoteExportPlan(
            transcript: transcript,
            summary: summary,
            audioPathExtension: audioURL?.pathExtension,
            isSummaryStale: isSummaryStale
        )
        self.audioURL = audioURL
        self.audioNeedsDownload = audioURL != nil && audioNeedsDownload
        self.audioUnavailableMessage = audioUnavailableMessage
    }

    /// Nil when there is no text to save.
    var transcript: String? { plan.transcript }
    var summary: String? { plan.summary }
    /// The summary was made from an older transcript. Only with a summary.
    var isSummaryStale: Bool { plan.isSummaryStale }
    var availableItems: Set<NoteFileExportItem> { plan.availableItems }
}

struct NoteFileExportRequest: Sendable {
    let source: NoteFileExportSource
    let selectedItems: Set<NoteFileExportItem>
    let textFormat: NoteFileExportTextFormat
    let baseName: String
    let destinationDirectory: URL
}

enum NoteFileExportFailureReason: Equatable, Sendable {
    case sourceMissing
    case destinationExists
    case fileNameTooLong
    case writeFailed
}

struct NoteFileExportFailure: Equatable, Sendable {
    let item: NoteFileExportItem
    let reason: NoteFileExportFailureReason
}

struct NoteFileExportResult: Equatable, Sendable {
    let savedItems: [NoteFileExportItem]
    let failures: [NoteFileExportFailure]

    var isComplete: Bool { !savedItems.isEmpty && failures.isEmpty }
}

enum NoteFileExporter {
    static func sanitizedBaseName(_ candidate: String, fallback: String) -> String {
        NoteExportPlan.sanitizedBaseName(candidate, fallback: fallback)
    }

    static func destinationURLs(
        for request: NoteFileExportRequest
    ) -> [NoteFileExportItem: URL] {
        // Only items that are there get a name; a selected item without
        // one is reported as missing when saving.
        var urls: [NoteFileExportItem: URL] = [:]
        for entry in request.source.plan.fileNames(
            for: request.selectedItems,
            textFormat: request.textFormat,
            baseName: request.baseName
        ) {
            urls[entry.item] = request.destinationDirectory.appendingPathComponent(entry.name)
        }
        return urls
    }

    static func fileNameFailures(
        for request: NoteFileExportRequest
    ) -> [NoteFileExportFailure] {
        let destinations = destinationURLs(for: request)
        return NoteFileExportItem.allCases.compactMap { item in
            guard let destination = destinations[item],
                  NoteExportPlan.isFileNameTooLong(destination.lastPathComponent) else {
                return nil
            }
            return NoteFileExportFailure(item: item, reason: .fileNameTooLong)
        }
    }

    static func conflicts(for request: NoteFileExportRequest) -> [URL] {
        destinationURLs(for: request).values
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func export(
        _ request: NoteFileExportRequest,
        replaceExisting: Bool
    ) -> NoteFileExportResult {
        let nameFailures = fileNameFailures(for: request)
        guard nameFailures.isEmpty else {
            return NoteFileExportResult(savedItems: [], failures: nameFailures)
        }
        let destinations = destinationURLs(for: request)
        var savedItems: [NoteFileExportItem] = []
        var failures: [NoteFileExportFailure] = []

        for item in NoteFileExportItem.allCases
        where request.selectedItems.contains(item) {
            guard let destination = destinations[item] else {
                failures.append(
                    NoteFileExportFailure(item: item, reason: .sourceMissing)
                )
                continue
            }
            if FileManager.default.fileExists(atPath: destination.path),
               !replaceExisting {
                failures.append(
                    NoteFileExportFailure(item: item, reason: .destinationExists)
                )
                continue
            }

            do {
                switch item {
                case .transcript, .summary:
                    let text = item == .transcript
                        ? request.source.transcript
                        : request.source.summary
                    guard let text else {
                        throw ExportWriteError.sourceMissing
                    }
                    try installData(
                        Data(text.utf8),
                        at: destination,
                        replaceExisting: replaceExisting
                    )
                case .audio:
                    guard let audioURL = request.source.audioURL,
                          FileManager.default.fileExists(atPath: audioURL.path) else {
                        throw ExportWriteError.sourceMissing
                    }
                    try installCopy(
                        from: audioURL,
                        to: destination,
                        replaceExisting: replaceExisting
                    )
                }
                savedItems.append(item)
            } catch ExportWriteError.sourceMissing {
                failures.append(
                    NoteFileExportFailure(item: item, reason: .sourceMissing)
                )
            } catch ExportWriteError.destinationExists {
                failures.append(
                    NoteFileExportFailure(item: item, reason: .destinationExists)
                )
            } catch {
                failures.append(
                    NoteFileExportFailure(item: item, reason: .writeFailed)
                )
            }
        }

        return NoteFileExportResult(
            savedItems: savedItems,
            failures: failures
        )
    }

    enum ExportWriteError: Error, Equatable {
        case sourceMissing
        case destinationExists
    }

    private static func installData(
        _ data: Data,
        at destination: URL,
        replaceExisting: Bool
    ) throws {
        let temporary = temporarySibling(of: destination)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try installPreparedFile(
            temporary,
            at: destination,
            replaceExisting: replaceExisting
        )
    }

    private static func installCopy(
        from source: URL,
        to destination: URL,
        replaceExisting: Bool
    ) throws {
        let temporary = temporarySibling(of: destination)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        try installPreparedFile(
            temporary,
            at: destination,
            replaceExisting: replaceExisting
        )
    }

    static func installPreparedFile(
        _ prepared: URL,
        at destination: URL,
        replaceExisting: Bool
    ) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            guard replaceExisting else {
                throw ExportWriteError.destinationExists
            }
            _ = try FileManager.default.replaceItemAt(
                destination,
                withItemAt: prepared
            )
        } else {
            try FileManager.default.moveItem(at: prepared, to: destination)
        }
    }

    private static func temporarySibling(of destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            ".quill-export-\(UUID().uuidString).tmp"
        )
    }
}
