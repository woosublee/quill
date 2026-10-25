import Foundation

/// A note as it travels between Macs: only fields a person sees, the field
/// clock, and the deletion time. Unknown keys from newer builds are kept.
public struct NoteSyncRecord: Equatable, Sendable {
    public static let schemaVersion = 1
    public static let schemaVersionKey = "schemaVersion"

    /// The raw values of the Mac app's `PipelineHistoryItemIntent`.
    public static let knownIntents: Set<String> = ["dictation", "command:automatic", "command:manual"]
    /// The raw values of the Mac app's `SpokenLanguageResolutionSource`.
    public static let knownSpokenLanguageResolutions: Set<String> = ["configured", "engineDetected", "transcriptInferred", "unavailable"]

    public let noteID: UUID
    public var fields: [String: NoteSyncValue]
    public var clock: NoteFieldClock
    public var deletedAt: Date?

    public init(noteID: UUID, fields: [String: NoteSyncValue], clock: NoteFieldClock, deletedAt: Date?) {
        self.noteID = noteID
        self.fields = fields
        self.clock = clock
        self.deletedAt = deletedAt
    }

    /// Whether a known field holds a value this build can't read: another
    /// value kind, or an intent or language source it doesn't know. Such a
    /// record is skipped rather than applied with values lost. Newer builds
    /// never change the shape of a shipped key; a new shape gets a new key.
    public var hasUnreadableKnownFields: Bool {
        if let version = fields[Self.schemaVersionKey], case .int = version {} else if fields[Self.schemaVersionKey] != nil {
            return true
        }
        return NoteSyncField.allCases.contains { field in
            guard let value = fields[field.rawValue] else { return false }
            switch (field.valueKind, value) {
            case (.string, .string(let text)):
                switch field {
                case .intent: return !Self.knownIntents.contains(text)
                case .spokenLanguageResolution: return !Self.knownSpokenLanguageResolutions.contains(text)
                default: return false
                }
            case (.date, .date), (.bool, .bool), (.data, .data):
                return false
            default:
                return true
            }
        }
    }

    /// Whether every field a note needs is present. A record without them
    /// can update a note this Mac has, but never create one.
    public var hasRequiredFields: Bool {
        NoteSyncField.allCases.allSatisfy { !$0.isRequired || fields[$0.rawValue] != nil }
    }
}

extension NoteFieldClock {
    /// CloudKit keeps dates to the millisecond, so stamps are compared and
    /// sent at that precision; the same edit then reads equal on every Mac.
    public func roundedToMilliseconds() -> NoteFieldClock {
        NoteFieldClock(stamps: stamps.mapValues { $0.roundedToMilliseconds() })
    }
}

extension Date {
    /// The date as the sync payload carries it.
    public func roundedToMilliseconds() -> Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}
