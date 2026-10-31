import Foundation

/// A summary regeneration that came back with the text the note already
/// showed, synced so "The new summary is the same as the current one." shows
/// on every device, whichever one ran it, and closing it on one closes it on
/// all (#745). The `unchangedSummaryRegeneration` field holds this as JSON,
/// last writer wins in its own group. Like `NoteUnchangedRetranscription`, a
/// dismissed notice is a marker with no summary rather than a removed field.
public struct NoteUnchangedSummaryRegeneration: Codable, Equatable, Sendable {
    /// When the kept summary was generated, or nil once the notice is
    /// dismissed, the summary is edited, or a new summary starts.
    public let summaryGeneratedAt: Date?
    public let recordedAt: Date

    public init(summaryGeneratedAt: Date?, recordedAt: Date) {
        self.summaryGeneratedAt = summaryGeneratedAt
        self.recordedAt = recordedAt
    }

    /// The marker for a regeneration that kept the summary generated at
    /// `generatedAt`.
    public static func matching(summaryGeneratedAt generatedAt: Date, at date: Date) -> Self {
        Self(summaryGeneratedAt: generatedAt, recordedAt: date)
    }

    /// The marker once the notice is gone.
    public static func cleared(at date: Date) -> Self {
        Self(summaryGeneratedAt: nil, recordedAt: date)
    }

    public var isCleared: Bool { summaryGeneratedAt == nil }

    /// The notice shows while the note still has the summary it kept. Times
    /// compare to the millisecond, the precision the field keeps.
    public func matches(summaryGeneratedAt generatedAt: Date) -> Bool {
        guard let summaryGeneratedAt else { return false }
        return NoteNoticeDismissals.condition(date: summaryGeneratedAt)
            == NoteNoticeDismissals.condition(date: generatedAt)
    }

    /// The marker in an `unchangedSummaryRegeneration` value. Anything
    /// unreadable reads as none.
    public static func decode(_ value: NoteSyncValue?) -> Self? {
        guard case .data(let data)? = value else { return nil }
        return try? decoder.decode(Self.self, from: data)
    }

    /// The field value for this marker, encoded alike on every device.
    public var value: NoteSyncValue {
        .data((try? Self.encoder.encode(self)) ?? Data("{}".utf8))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
