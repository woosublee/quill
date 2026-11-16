import Foundation

/// Whether a note's recording can be had on this device right now, for
/// the audio bar, playback, Retranscribe, and Save Files (#836). Shared
/// by both apps: the Mac's notes, and the iPhone's received notes and its
/// own once Optimize Storage removes them.
public enum NoteAudioAvailability: Equatable, Sendable {
    /// The note has no audio.
    case none
    case local
    case downloadable
    case downloading(Double)
    case unavailable(Reason)

    /// Why the recording can't be had right now.
    public enum Reason: Equatable, Sendable {
        /// No marker: the device that recorded it hasn't finished uploading.
        case notUploadedYet
        case syncOff
        case offline
        case failed
        /// On cellular with Use Cellular Data off (iPhone).
        case waitingForWiFi
    }

    /// A download that failed, and the marker it was for.
    public struct Failure: Equatable, Sendable {
        public var sha256: String
        public var reason: Reason

        public init(sha256: String, reason: Reason) {
            self.sha256 = sha256
            self.reason = reason
        }
    }

    /// What decides it, read by each app.
    public struct Input: Equatable, Sendable {
        /// The note names a recording.
        public var hasAudio: Bool
        /// The recording file is on this device.
        public var isLocal: Bool
        /// A download running for this note.
        public var downloadProgress: Double?
        /// The note's marker: its recording is in iCloud.
        public var marker: NoteAudioManifest?
        public var isSyncOn: Bool
        /// The last download's failure, and the marker it was for.
        public var lastFailure: Failure?
        /// Downloading now would use cellular data the user didn't allow.
        public var waitsForWiFi: Bool
        /// The recording only ever came from iCloud on this device (a
        /// note received from another device). Read only while sync is
        /// off with no marker: such a note still has audio to wait for
        /// (sync off), while a file this device made or kept and has lost
        /// is no audio. With sync on, no marker is always "not uploaded".
        public var comesFromICloud: Bool

        public init(
            hasAudio: Bool,
            isLocal: Bool,
            downloadProgress: Double? = nil,
            marker: NoteAudioManifest?,
            isSyncOn: Bool,
            lastFailure: Failure? = nil,
            waitsForWiFi: Bool = false,
            comesFromICloud: Bool = false
        ) {
            self.hasAudio = hasAudio
            self.isLocal = isLocal
            self.downloadProgress = downloadProgress
            self.marker = marker
            self.isSyncOn = isSyncOn
            self.lastFailure = lastFailure
            self.waitsForWiFi = waitsForWiFi
            self.comesFromICloud = comesFromICloud
        }
    }

    /// The order: no audio, the file here, a download running, sync off,
    /// no marker, cellular not allowed, the last failure for this same
    /// marker, then downloadable. Cellular comes before a failure so a
    /// retry isn't offered that would use data the user didn't allow.
    public static func of(_ input: Input) -> NoteAudioAvailability {
        guard input.hasAudio else { return .none }
        if input.isLocal { return .local }
        if let progress = input.downloadProgress { return .downloading(progress) }
        guard input.isSyncOn else {
            // A file missing on a device that never synced it is no audio,
            // as before sync; audio in iCloud, or still to come from it,
            // waits for sync.
            if input.marker == nil, !input.comesFromICloud { return .none }
            return .unavailable(.syncOff)
        }
        guard let marker = input.marker else { return .unavailable(.notUploadedYet) }
        if input.waitsForWiFi { return .unavailable(.waitingForWiFi) }
        // A failure for an earlier marker says nothing about this one.
        if let failure = input.lastFailure, failure.sha256 == marker.sha256 { return .unavailable(failure.reason) }
        return .downloadable
    }
}
