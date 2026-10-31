import CryptoKit
import Foundation

/// A retranscription that came back with the text the note already showed,
/// synced so "The new transcript is the same as the current one." shows on
/// every device, whichever one ran it, and closing it on one closes it on all
/// (#742). The `unchangedRetranscription` field holds this as JSON. It merges
/// last-writer-wins in its own group. A dismissed notice is written as a
/// marker with no transcript rather than by removing the field: a build that
/// keeps the field as an unknown key keeps whichever side changed last, and
/// a missing value would always lose to its old copy.
public struct NoteUnchangedRetranscription: Codable, Equatable, Sendable {
    /// SHA-256 (hex) of the trimmed transcript the retranscription matched,
    /// or nil once the notice is dismissed or a new retranscription starts.
    public let transcriptSHA256: String?
    public let recordedAt: Date

    public init(transcriptSHA256: String?, recordedAt: Date) {
        self.transcriptSHA256 = transcriptSHA256
        self.recordedAt = recordedAt
    }

    /// The marker for a retranscription that matched `transcript`.
    public static func matching(_ transcript: String, at date: Date) -> NoteUnchangedRetranscription {
        NoteUnchangedRetranscription(transcriptSHA256: hash(transcript), recordedAt: date)
    }

    /// The marker once the notice is gone.
    public static func cleared(at date: Date) -> NoteUnchangedRetranscription {
        NoteUnchangedRetranscription(transcriptSHA256: nil, recordedAt: date)
    }

    /// The notice shows while the note still shows the transcript it matched.
    public func matches(_ displayedTranscript: String) -> Bool {
        guard let transcriptSHA256 else { return false }
        let trimmed = displayedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && Self.hash(trimmed) == transcriptSHA256
    }

    public var isCleared: Bool { transcriptSHA256 == nil }

    static func hash(_ transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hash(data: Data(trimmed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The marker in an `unchangedRetranscription` value. Anything unreadable
    /// reads as none.
    public static func decode(_ value: NoteSyncValue?) -> NoteUnchangedRetranscription? {
        guard case .data(let data)? = value else { return nil }
        return try? Self.decoder.decode(NoteUnchangedRetranscription.self, from: data)
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
