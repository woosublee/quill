import Foundation
import QuillNoteSyncCore

/// Optimize Storage on this Mac: the setting, and what the pass reads of a
/// note. The rule itself is `NoteAudioOffloadPolicy`; how a pass goes is
/// `NoteAudioOffloadPass`.
enum NoteAudioOffload {
    /// UserDefaults, Bool, off by default.
    static let isOnKey = "NoteAudioOptimizeStorage"
    /// The bundle a development build runs as (`make run`).
    static let developmentBundleIdentifier = "com.woosublee.quill.dev"

    static var isOn: Bool {
        UserDefaults.standard.bool(forKey: isOnKey)
    }

    /// The policy's note from the store's snapshot and what this Mac knows
    /// now: whether the file is here, and whether anything is using it.
    static func policyNote(
        _ snapshot: NoteAudioOffloadSnapshot,
        hasLocalAudio: Bool,
        isBusy: Bool
    ) -> NoteAudioOffloadPolicy.Note {
        NoteAudioOffloadPolicy.Note(
            hasMarker: snapshot.manifest != nil,
            hasTranscript: snapshot.hasTranscript,
            hasLocalAudio: hasLocalAudio,
            isBusy: isBusy,
            isRecentlyDeleted: snapshot.isRecentlyDeleted,
            hasUnrecoveredPieces: snapshot.hasUnrecoveredPieces,
            lastUsedAt: snapshot.lastUsedAt,
            recordingEndedAt: snapshot.recordingEndedAt,
            createdAt: snapshot.createdAt
        )
    }

    /// How long a recording must go unused here. A development build may
    /// shorten it with `-QuillAudioOffloadRetentionSeconds <n>` for the
    /// manual check; any other bundle, the released app included, keeps
    /// the policy's 7 days.
    static func retention(bundleIdentifier: String?, arguments: [String]) -> TimeInterval {
        NoteAudioOffloadPass.retention(
            isDevelopmentBuild: bundleIdentifier == developmentBundleIdentifier,
            arguments: arguments
        )
    }

    static var retention: TimeInterval {
        retention(bundleIdentifier: Bundle.main.bundleIdentifier, arguments: ProcessInfo.processInfo.arguments)
    }
}
