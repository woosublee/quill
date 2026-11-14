import Foundation

/// When a device may remove a note's recording from its own storage
/// (Optimize Storage). The recording stays in iCloud; this only decides
/// whether the device may ask iCloud and then remove its local file.
/// Whether iCloud really holds every part is checked by the caller.
public enum NoteAudioOffloadPolicy {
    /// How long a recording must go unused on this device first.
    public static let retention: TimeInterval = 7 * 24 * 60 * 60

    /// What the rule needs to know about one note on this device.
    public struct Note: Equatable, Sendable {
        /// The note has an audio manifest (its recording is in iCloud).
        public var hasMarker: Bool
        /// The note has a finished, non-empty transcript.
        public var hasTranscript: Bool
        /// A non-empty recording file is on this device.
        public var hasLocalAudio: Bool
        /// Transcribing, retranscribing, a saved cloud job, playing,
        /// exporting, or downloading.
        public var isBusy: Bool
        public var isRecentlyDeleted: Bool
        public var hasUnrecoveredPieces: Bool
        /// When this device last used the recording.
        public var lastUsedAt: Date?
        public var recordingEndedAt: Date?
        public var createdAt: Date

        public init(
            hasMarker: Bool,
            hasTranscript: Bool,
            hasLocalAudio: Bool,
            isBusy: Bool,
            isRecentlyDeleted: Bool,
            hasUnrecoveredPieces: Bool,
            lastUsedAt: Date?,
            recordingEndedAt: Date?,
            createdAt: Date
        ) {
            self.hasMarker = hasMarker
            self.hasTranscript = hasTranscript
            self.hasLocalAudio = hasLocalAudio
            self.isBusy = isBusy
            self.isRecentlyDeleted = isRecentlyDeleted
            self.hasUnrecoveredPieces = hasUnrecoveredPieces
            self.lastUsedAt = lastUsedAt
            self.recordingEndedAt = recordingEndedAt
            self.createdAt = createdAt
        }
    }

    /// `lastUsedAt`, else `recordingEndedAt`, else `createdAt`.
    public static func lastUsed(_ note: Note) -> Date {
        note.lastUsedAt ?? note.recordingEndedAt ?? note.createdAt
    }

    /// True when this device may ask iCloud and then remove the file.
    /// A last-used date in the future (the clock moved back) never counts.
    /// `retention` is this type's own unless a development build shortens it.
    public static func isCandidate(
        _ note: Note,
        isOptimizeOn: Bool,
        isSyncRunning: Bool,
        now: Date,
        retention: TimeInterval = NoteAudioOffloadPolicy.retention
    ) -> Bool {
        guard isOptimizeOn, isSyncRunning else { return false }
        guard note.hasMarker, note.hasTranscript, note.hasLocalAudio else { return false }
        guard !note.isBusy, !note.isRecentlyDeleted, !note.hasUnrecoveredPieces else { return false }
        let unusedFor = now.timeIntervalSince(lastUsed(note))
        return unusedFor >= retention
    }

    /// True when iCloud backs this device's recording: every part the local
    /// marker names is there (`partsPresent`), and iCloud's note names that
    /// same marker. Parts alone may be an upload whose note never went up.
    public static func isConfirmedInICloud(
        local: NoteAudioManifest,
        partsPresent: Bool,
        serverMarker: NoteAudioManifest?
    ) -> Bool {
        partsPresent && serverMarker == local
    }
}

/// Copy keys for the Optimize Storage setting; each app translates them
/// with its own String Catalog.
public enum NoteAudioOffloadCopy {
    public static let toggleKey = "Optimize Storage"
    public static let detailKey = "Recordings you haven't used for a week are removed from this device and kept in iCloud. You can download them again."
    public static let needsSyncKey = "Turn on iCloud sync to use this."
}
