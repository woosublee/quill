import Foundation

/// A file a note can be saved as from Save Files.
public enum NoteExportItem: String, CaseIterable, Hashable, Sendable {
    case transcript
    /// The meeting summary, as Markdown, saved as `<name>-summary`.
    case summary
    case audio
}

/// The text format Save Files writes the transcript and the summary in.
public enum NoteExportTextFormat: String, CaseIterable, Identifiable, Sendable {
    case plainText
    case markdown

    public var id: String { rawValue }

    public var pathExtension: String {
        switch self {
        case .plainText: return "txt"
        case .markdown: return "md"
        }
    }
}

/// What Save Files offers for a note and what the files are named, the same
/// on the Mac and the iPhone (woosublee/quill-universal-private#281). A
/// transcript or summary that is only spaces and line breaks isn't offered.
/// A summary made from an older transcript is still offered, with a note
/// that the transcript changed (`summaryStaleNoteKey`). Each app writes the
/// files itself: the Mac into a folder the person picks, the iPhone into a
/// temporary folder for the share sheet.
public struct NoteExportPlan: Equatable, Sendable {
    /// The name used when the person's name has nothing usable left.
    public static let fallbackBaseName = "Quill Recording"
    /// The longest file name, in UTF-16 code units, both file systems take.
    public static let maximumFileNameLength = 255
    /// The String Catalog key for the note beside a stale summary.
    public static let summaryStaleNoteKey = "Transcript changed after this summary was generated."

    public let transcript: String?
    public let summary: String?
    /// The saved recording's extension, or nil when there is no recording.
    public let audioPathExtension: String?
    /// The summary was made from an older transcript. Only with a summary.
    public let isSummaryStale: Bool

    public init(
        transcript: String?,
        summary: String?,
        audioPathExtension: String?,
        isSummaryStale: Bool = false
    ) {
        self.transcript = Self.hasText(transcript) ? transcript : nil
        self.summary = Self.hasText(summary) ? summary : nil
        self.audioPathExtension = audioPathExtension
        self.isSummaryStale = self.summary != nil && isSummaryStale
    }

    public var availableItems: Set<NoteExportItem> {
        var items = Set<NoteExportItem>()
        if transcript != nil { items.insert(.transcript) }
        if summary != nil { items.insert(.summary) }
        if audioPathExtension != nil { items.insert(.audio) }
        return items
    }

    /// The files to write for the selected items that are available, in
    /// transcript, summary, recording order.
    public func fileNames(
        for selectedItems: Set<NoteExportItem>,
        textFormat: NoteExportTextFormat,
        baseName: String
    ) -> [(item: NoteExportItem, name: String)] {
        let available = availableItems
        let name = Self.sanitizedBaseName(baseName, fallback: Self.fallbackBaseName)
        return NoteExportItem.allCases.compactMap { item in
            guard selectedItems.contains(item), available.contains(item) else { return nil }
            return (item, Self.fileName(
                for: item,
                sanitizedBaseName: name,
                textFormat: textFormat,
                audioPathExtension: audioPathExtension
            ))
        }
    }

    /// One item's file name from an already sanitized base name. A recording
    /// without an extension is saved as `.wav`.
    public static func fileName(
        for item: NoteExportItem,
        sanitizedBaseName baseName: String,
        textFormat: NoteExportTextFormat,
        audioPathExtension: String?
    ) -> String {
        switch item {
        case .transcript:
            return "\(baseName).\(textFormat.pathExtension)"
        case .summary:
            return "\(baseName)-summary.\(textFormat.pathExtension)"
        case .audio:
            let pathExtension = audioPathExtension ?? ""
            return "\(baseName).\(pathExtension.isEmpty ? "wav" : pathExtension)"
        }
    }

    public static func isFileNameTooLong(_ name: String) -> Bool {
        name.utf16.count > maximumFileNameLength
    }

    /// The name Save Files suggests: the note's own title, then its
    /// calendar event's title, then its recording time.
    public static func suggestedBaseName(
        customTitle: String?,
        calendarTitle: String?,
        timestamp: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        for candidate in [customTitle, calendarTitle] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        let formatted = Date.FormatStyle(
            date: .long,
            time: .shortened,
            locale: locale,
            timeZone: timeZone
        ).format(timestamp)
        return formatted.replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{2009}", with: " ")
    }

    /// Replaces characters file systems reject with "-" and trims spaces
    /// and dots from the ends. A name with nothing usable left falls back.
    public static func sanitizedBaseName(_ candidate: String, fallback: String) -> String {
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
            ?? fallbackBaseName
    }

    private static func hasText(_ text: String?) -> Bool {
        text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
