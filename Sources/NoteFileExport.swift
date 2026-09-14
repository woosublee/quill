import Foundation

enum NoteFileExportNaming {
    static func suggestedBaseName(
        customTitle: String?,
        calendarTitle: String?,
        timestamp: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        for candidate in [customTitle, calendarTitle] {
            let trimmed = candidate?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }

        let formatted = Date.FormatStyle(
            date: .long,
            time: .shortened,
            locale: locale,
            timeZone: timeZone
        ).format(timestamp)
        return normalizedSpaces(in: formatted)
    }

    private static func normalizedSpaces(in value: String) -> String {
        value.replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{2009}", with: " ")
    }
}

enum NoteFileExportItem: String, CaseIterable, Hashable, Sendable {
    case transcript
    case summary
    case audio
}

enum NoteFileExportTextFormat: String, CaseIterable, Identifiable, Sendable {
    case plainText
    case markdown

    var id: String { rawValue }

    var pathExtension: String {
        switch self {
        case .plainText: return "txt"
        case .markdown: return "md"
        }
    }
}

struct NoteFileExportSource: Sendable {
    let transcript: String?
    let summary: String?
    let audioURL: URL?
    let isSummaryStale: Bool

    init(
        transcript: String,
        audioURL: URL?,
        summary: String? = nil,
        isSummaryStale: Bool = false
    ) {
        self.transcript = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ? nil : transcript
        self.summary = summary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false ? summary : nil
        self.audioURL = audioURL
        self.isSummaryStale = self.summary != nil && isSummaryStale
    }

    var availableItems: Set<NoteFileExportItem> {
        var items = Set<NoteFileExportItem>()
        if transcript != nil { items.insert(.transcript) }
        if summary != nil { items.insert(.summary) }
        if audioURL != nil { items.insert(.audio) }
        return items
    }
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
        let invalid = CharacterSet(charactersIn: "/\\*?\"<>|")
            .union(.controlCharacters)
        let trimmedCharacters = CharacterSet(charactersIn: " .")

        func sanitize(_ value: String) -> String? {
            let components = value.components(separatedBy: invalid)
            let usableContent = components
                .joined()
                .trimmingCharacters(in: trimmedCharacters)
            guard !usableContent.isEmpty else { return nil }
            return components
                .joined(separator: "-")
                .trimmingCharacters(in: trimmedCharacters)
        }

        return sanitize(candidate)
            ?? sanitize(fallback)
            ?? "Quill Recording"
    }

    static func destinationURLs(
        for request: NoteFileExportRequest
    ) -> [NoteFileExportItem: URL] {
        var urls: [NoteFileExportItem: URL] = [:]
        let baseName = sanitizedBaseName(request.baseName, fallback: "Quill Recording")
        if request.selectedItems.contains(.transcript) {
            urls[.transcript] = request.destinationDirectory
                .appendingPathComponent(baseName)
                .appendingPathExtension(request.textFormat.pathExtension)
        }
        if request.selectedItems.contains(.summary) {
            urls[.summary] = request.destinationDirectory
                .appendingPathComponent("\(baseName)-summary")
                .appendingPathExtension(request.textFormat.pathExtension)
        }
        if request.selectedItems.contains(.audio),
           let audioURL = request.source.audioURL {
            let audioExtension = audioURL.pathExtension.isEmpty
                ? "wav"
                : audioURL.pathExtension
            urls[.audio] = request.destinationDirectory
                .appendingPathComponent(baseName)
                .appendingPathExtension(audioExtension)
        }
        return urls
    }

    static func fileNameFailures(
        for request: NoteFileExportRequest
    ) -> [NoteFileExportFailure] {
        let destinations = destinationURLs(for: request)
        return NoteFileExportItem.allCases.compactMap { item in
            guard let destination = destinations[item],
                  destination.lastPathComponent.utf16.count > 255 else {
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
