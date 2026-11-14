import Foundation
import QuillNoteSyncCore

/// Optimize Storage on this Mac: the setting, and what the pass reads of a
/// note. The rule itself is `NoteAudioOffloadPolicy`.
enum NoteAudioOffload {
    /// UserDefaults, Bool, off by default.
    static let isOnKey = "NoteAudioOptimizeStorage"
    /// At most this many recordings are asked about, and removed, per pass.
    static let maxPerPass = 20
    /// A note iCloud didn't confirm (its note unreadable there, say) isn't
    /// asked about again for this long, so it can't hold up the others.
    static let unconfirmedWait: TimeInterval = 24 * 60 * 60
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

    /// Who a pass asks iCloud about: the candidates used longest ago, at
    /// most `maxPerPass`, leaving out a note asked about and not confirmed
    /// less than `unconfirmedWait` ago. `waiting` (when each such note was
    /// asked) comes back holding only the waits still running for notes
    /// still candidates; a wait dated ahead of the clock is over.
    static func notesToAsk(
        candidates: [(id: UUID, lastUsed: Date)],
        waiting: [UUID: Date],
        now: Date
    ) -> (ask: [UUID], waiting: [UUID: Date]) {
        var stillWaiting: [UUID: Date] = [:]
        for candidate in candidates {
            guard let since = waiting[candidate.id] else { continue }
            let elapsed = now.timeIntervalSince(since)
            if elapsed >= 0, elapsed < unconfirmedWait { stillWaiting[candidate.id] = since }
        }
        let ask = candidates
            .filter { stillWaiting[$0.id] == nil }
            .sorted { $0.lastUsed < $1.lastUsed }
            .prefix(maxPerPass)
            .map(\.id)
        return (Array(ask), stillWaiting)
    }

    /// Two names with the same key may name the same file: the Mac's disk
    /// usually ignores case and Unicode form, and names come from synced
    /// records.
    static func sameFileKey(_ fileName: String) -> String {
        fileName.folding(options: .caseInsensitive, locale: nil)
            .precomposedStringWithCanonicalMapping
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

        /// The file is the size the marker names. Any other size is a file
        /// iCloud's copy may not stand for, so it stays.
        func matches(_ manifest: NoteAudioManifest) -> Bool {
            manifest.bytes > 0 && size == UInt64(manifest.bytes)
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
}
