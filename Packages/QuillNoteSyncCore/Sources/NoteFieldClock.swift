import Foundation

/// Groups of note fields that change, sync, and merge together. Only fields a
/// person sees are listed; screenshots, window context, selected text, and
/// prompts never sync.
public enum NoteFieldGroup: String, CaseIterable, Sendable {
    case title
    case rawTranscript
    case editedTranscript
    case summary
    case calendar
    case recordingTime
    case language
    case status
    case audio
    case deletion
}

/// When each field group of a note last changed. Sync keeps, per group, the
/// value with the later time. Keys are `NoteFieldGroup` raw values, so a
/// newer build's groups survive a round trip through this one.
public struct NoteFieldClock: Codable, Equatable, Sendable {
    public private(set) var stamps: [String: Date]

    public init(stamps: [String: Date] = [:]) {
        self.stamps = stamps
    }

    public static func uniform(_ date: Date) -> NoteFieldClock {
        NoteFieldClock(stamps: Dictionary(
            uniqueKeysWithValues: NoteFieldGroup.allCases.map { ($0.rawValue, date) }
        ))
    }

    public func stamp(for group: NoteFieldGroup) -> Date? {
        stamps[group.rawValue]
    }

    public func setting(_ group: NoteFieldGroup, to date: Date) -> NoteFieldClock {
        var copy = self
        copy.stamps[group.rawValue] = date
        return copy
    }
}

extension NoteFieldClock {
    /// The groups whose values differ between two field dictionaries: only
    /// groups whose values really changed. Never reports `deletion`.
    public static func changedGroups(
        from old: [String: NoteSyncValue], to new: [String: NoteSyncValue]
    ) -> Set<NoteFieldGroup> {
        Set(NoteSyncField.allCases.compactMap { field in
            old[field.rawValue] == new[field.rawValue] ? nil : field.group
        })
    }
}
