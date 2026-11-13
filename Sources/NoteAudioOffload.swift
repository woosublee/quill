import Foundation
import QuillNoteSyncCore

/// Optimize Storage on this Mac: the setting, and what the pass reads of a
/// note. The rule itself is `NoteAudioOffloadPolicy`.
enum NoteAudioOffload {
    /// UserDefaults, Bool, off by default.
    static let isOnKey = "NoteAudioOptimizeStorage"
    /// At most this many recordings are asked about, and removed, per pass.
    static let maxPerPass = 5
    /// The bundle a development build runs as (`make run`).
    static let developmentBundleIdentifier = "com.woosublee.quill.dev"
    static let retentionArgument = "-QuillAudioOffloadRetentionSeconds"

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

    /// The file the pass may remove: a plain, non-empty file (not a link),
    /// identified so a file put in its place meanwhile isn't taken for it.
    struct LocalFile: Equatable {
        let fileNumber: UInt64
        let size: UInt64

        init?(at url: URL) {
            // Doesn't follow a final link: a link is never removed.
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.uint64Value, size > 0,
                  let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { return nil }
            self.fileNumber = fileNumber
            self.size = size
        }
    }

    /// How long a recording must go unused here. A development build may
    /// shorten it with `-QuillAudioOffloadRetentionSeconds <n>` for the
    /// manual check; any other bundle, the released app included, keeps
    /// the policy's 7 days.
    static func retention(bundleIdentifier: String?, arguments: [String]) -> TimeInterval {
        guard bundleIdentifier == developmentBundleIdentifier,
              let index = arguments.firstIndex(of: retentionArgument),
              arguments.indices.contains(index + 1),
              let seconds = TimeInterval(arguments[index + 1]),
              seconds.isFinite, seconds > 0 else { return NoteAudioOffloadPolicy.retention }
        return seconds
    }

    static var retention: TimeInterval {
        retention(bundleIdentifier: Bundle.main.bundleIdentifier, arguments: ProcessInfo.processInfo.arguments)
    }

    /// The `now` to give the policy so that it applies `retention` instead
    /// of its own: unused for `retention` here is unused for the policy's
    /// retention there. With the policy's retention it is `now` itself.
    static func policyNow(_ now: Date, retention: TimeInterval) -> Date {
        now.addingTimeInterval(NoteAudioOffloadPolicy.retention - retention)
    }
}
