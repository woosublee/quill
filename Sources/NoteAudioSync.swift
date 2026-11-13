import Foundation
import QuillNoteSyncCore

/// A syncable note's audio as sync sees it, read for every note at once.
struct NoteAudioSyncSnapshot: Equatable, Sendable {
    let id: UUID
    let audioFileName: String?
    let manifest: NoteAudioManifest?
    let uploadKey: String?
}

/// What the offload pass needs of a note, read for every note at once.
/// `lastUsedAt` stays on this Mac.
struct NoteAudioOffloadSnapshot: Equatable, Sendable {
    let id: UUID
    let audioFileName: String?
    let manifest: NoteAudioManifest?
    let lastUsedAt: Date?
    let recordingEndedAt: Date?
    /// The item's `timestamp`.
    let createdAt: Date
    let hasTranscript: Bool
    let isRecentlyDeleted: Bool
    let hasUnrecoveredPieces: Bool
}

/// What iCloud may hold of a deleted or replaced note's audio: the parts
/// its marker names, and the parts of an upload this Mac had started.
struct NoteAudioSyncState: Equatable, Sendable {
    var manifest: NoteAudioManifest?
    /// The SHA-256 of the file this Mac was uploading.
    var uploadKey: String?
}
