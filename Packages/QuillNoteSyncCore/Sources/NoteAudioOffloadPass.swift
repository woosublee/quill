import Foundation

/// How an Optimize Storage pass goes, on every device: whom it asks iCloud
/// about, which file it may remove, and how long a recording must go unused.
/// Whether one note may go is `NoteAudioOffloadPolicy`; asking iCloud and
/// removing the file stay in each app.
public enum NoteAudioOffloadPass {
    /// At most this many recordings are asked about, and removed, per pass.
    public static let maxPerPass = 20
    /// A note iCloud didn't confirm (its note unreadable there, say) isn't
    /// asked about again for this long, so it can't hold up the others.
    public static let unconfirmedWait: TimeInterval = 24 * 60 * 60
    /// A development build may shorten the retention with this launch
    /// argument and a number of seconds, for the manual check.
    public static let retentionArgument = "-QuillAudioOffloadRetentionSeconds"

    /// Who a pass asks iCloud about: the candidates used longest ago, at
    /// most `maxPerPass`, leaving out a note asked about and not confirmed
    /// less than `unconfirmedWait` ago. `waiting` (when each such note was
    /// asked) comes back holding only the waits still running for notes
    /// still candidates; a wait dated ahead of the clock is over. Ids must be
    /// unique.
    public static func notesToAsk(
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
            // Same date: by id, so both apps and every pass pick the same ones.
            .sorted { ($0.lastUsed, $0.id.uuidString) < ($1.lastUsed, $1.id.uuidString) }
            .prefix(maxPerPass)
            .map(\.id)
        return (Array(ask), stillWaiting)
    }

    /// Two names with the same key may name the same file: a disk may
    /// ignore case and Unicode form, and names come from synced records. A
    /// file two notes may name stays.
    public static func sameFileKey(_ fileName: String) -> String {
        fileName.folding(options: .caseInsensitive, locale: nil)
            .precomposedStringWithCanonicalMapping
    }

    /// The file a pass may remove: a plain, non-empty file (not a link),
    /// identified so a file put in its place meanwhile isn't taken for it.
    public struct LocalFile: Equatable, Sendable {
        public let fileNumber: UInt64
        public let size: UInt64

        public init?(at url: URL) {
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
        public func matches(_ manifest: NoteAudioManifest) -> Bool {
            manifest.bytes > 0 && size == UInt64(manifest.bytes)
        }
    }

    /// How long a recording must go unused on this device. Only a
    /// development build may shorten it, with `retentionArgument <seconds>`;
    /// any other build, the released app included, keeps the policy's 7 days.
    public static func retention(isDevelopmentBuild: Bool, arguments: [String]) -> TimeInterval {
        guard isDevelopmentBuild,
              let index = arguments.firstIndex(of: retentionArgument),
              arguments.indices.contains(index + 1),
              let seconds = TimeInterval(arguments[index + 1]),
              seconds.isFinite, seconds > 0 else { return NoteAudioOffloadPolicy.retention }
        return seconds
    }
}
