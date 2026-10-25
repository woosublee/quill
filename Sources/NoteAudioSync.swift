import Foundation
import QuillNoteSyncCore

/// A syncable note's audio as sync sees it, read for every note at once.
struct NoteAudioSyncSnapshot: Equatable, Sendable {
    let id: UUID
    let audioFileName: String?
    let manifest: NoteAudioManifest?
    let uploadKey: String?
}

/// What iCloud may hold of a deleted or replaced note's audio: the parts
/// its marker names, and the parts of an upload this Mac had started.
struct NoteAudioSyncState: Equatable, Sendable {
    var manifest: NoteAudioManifest?
    /// The SHA-256 of the file this Mac was uploading.
    var uploadKey: String?
}
