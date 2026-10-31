import CryptoKit
import Foundation

/// Notices dismissed on a note while a condition holds, synced so closing
/// one on any device closes it on every device (#745). Unlike
/// `NoteDismissedNotices`, each dismissal lasts only while the note still
/// shows what it was dismissed for: a new failure, a changed transcript, or
/// a retry brings the notice back everywhere.
///
/// The `noticeDismissals` field holds a JSON object of entries by notice
/// key. Merges keep the later entry of each key, so dismissals made on two
/// devices at once both survive. Ending a dismissal writes an entry with no
/// condition rather than removing the key, so an older copy can't bring it
/// back.
public struct NoteNoticeDismissals: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// What the notice was dismissed for, or nil once it should show
        /// again.
        public let condition: String?
        public let at: Date

        public init(condition: String?, at: Date) {
            self.condition = condition
            self.at = at
        }
    }

    public private(set) var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    // MARK: Keys

    /// A post-processing warning above the transcript, one per issue code.
    public static func postProcessingWarning(code: String) -> String {
        postProcessingWarningPrefix + code
    }

    public static let postProcessingWarningPrefix = "postProcessing.warning."
    /// Every summary notice's key starts with this, so deleting a summary
    /// ends them together.
    public static let summaryPrefix = "summary."
    /// The saved summary's failed-attempt notice.
    public static let summaryFailure = summaryPrefix + "failure"
    /// "Transcript changed after this summary was generated."
    public static let summaryStale = summaryPrefix + "stale"
    /// "Some evidence could not be verified."
    public static let summaryUnverifiedEvidence = summaryPrefix + "unverifiedEvidence"
    /// "Meeting Summary is off", shown only on a device where it is off.
    public static let summaryFeatureDisabled = summaryPrefix + "featureDisabled"
    /// "Summary model is unavailable.", shown only on a device without one.
    public static let summaryModelUnavailable = summaryPrefix + "modelUnavailable"

    // MARK: Conditions, alike on every device

    /// A warning stays dismissed while the note keeps this status.
    public static func condition(postProcessingStatus status: String) -> String {
        SHA256.hash(data: Data(status.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A notice tied to one moment (the failed attempt, the summary's
    /// creation) stays dismissed for that moment.
    public static func condition(date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1000).rounded()))
    }

    // MARK: The notices that sync, alike on every device

    /// A notice whose dismissal syncs, with what it is dismissed for. Both
    /// apps build the key and condition here, so a dismissal written on one
    /// device matches the same notice on the other.
    public enum Notice: Equatable, Sendable {
        /// The post-processing warning above the transcript, for the note's
        /// `postProcessingStatus`.
        case postProcessingWarning(code: String, status: String)
        /// The saved summary's failed attempt, by when it happened.
        case summaryFailure(attemptAt: Date)
        /// "Transcript changed after this summary was generated.", for the
        /// transcript's source fingerprint.
        case summaryStale(sourceFingerprint: String)
        /// "Some evidence could not be verified.", for the summary's time.
        case summaryUnverifiedEvidence(generatedAt: Date)
        /// "Meeting Summary is off", for the summary's time. Each device
        /// shows it only while its own setting is off; a dismissal on one
        /// device keeps it closed on the others for this summary.
        case summaryFeatureDisabled(generatedAt: Date)
        /// "Summary model is unavailable.", for the summary's time, shown
        /// like `summaryFeatureDisabled`.
        case summaryModelUnavailable(generatedAt: Date)

        public var key: String {
            switch self {
            case .postProcessingWarning(let code, _): NoteNoticeDismissals.postProcessingWarning(code: code)
            case .summaryFailure: NoteNoticeDismissals.summaryFailure
            case .summaryStale: NoteNoticeDismissals.summaryStale
            case .summaryUnverifiedEvidence: NoteNoticeDismissals.summaryUnverifiedEvidence
            case .summaryFeatureDisabled: NoteNoticeDismissals.summaryFeatureDisabled
            case .summaryModelUnavailable: NoteNoticeDismissals.summaryModelUnavailable
            }
        }

        public var condition: String {
            switch self {
            case .postProcessingWarning(_, let status): NoteNoticeDismissals.condition(postProcessingStatus: status)
            case .summaryFailure(let date), .summaryUnverifiedEvidence(let date),
                 .summaryFeatureDisabled(let date), .summaryModelUnavailable(let date):
                NoteNoticeDismissals.condition(date: date)
            case .summaryStale(let fingerprint): fingerprint
            }
        }
    }

    public func isDismissed(_ notice: Notice) -> Bool {
        isDismissed(notice.key, condition: notice.condition)
    }

    public func dismissing(_ notice: Notice, at date: Date) -> NoteNoticeDismissals? {
        dismissing(notice.key, condition: notice.condition, at: date)
    }

    // MARK: Reading and changing

    public func isDismissed(_ key: String, condition: String) -> Bool {
        entries[key]?.condition == condition
    }

    /// These dismissals with `key` dismissed for `condition`, or nil when it
    /// already is.
    public func dismissing(_ key: String, condition: String, at date: Date) -> NoteNoticeDismissals? {
        guard !isDismissed(key, condition: condition) else { return nil }
        var updated = self
        updated.entries[key] = Entry(condition: condition, at: date)
        return updated
    }

    /// These dismissals with every live one whose key starts with `prefix`
    /// ended, or nil when there is none to end.
    public func ending(keysWithPrefix prefix: String, at date: Date) -> NoteNoticeDismissals? {
        let live = entries.filter { $0.key.hasPrefix(prefix) && $0.value.condition != nil }
        guard !live.isEmpty else { return nil }
        var updated = self
        for key in live.keys {
            updated.entries[key] = Entry(condition: nil, at: date)
        }
        return updated
    }

    /// Both sides' dismissals, keeping the later entry of each key; on a tie,
    /// the higher condition, so every device settles alike.
    public static func merged(_ lhs: NoteNoticeDismissals, _ rhs: NoteNoticeDismissals) -> NoteNoticeDismissals {
        var entries = lhs.entries
        for (key, theirs) in rhs.entries {
            guard let mine = entries[key] else {
                entries[key] = theirs
                continue
            }
            if theirs.at != mine.at {
                if theirs.at > mine.at { entries[key] = theirs }
            } else if (theirs.condition ?? "") > (mine.condition ?? "") {
                entries[key] = theirs
            }
        }
        return NoteNoticeDismissals(entries: entries)
    }

    public var isEmpty: Bool { entries.isEmpty }

    // MARK: Field value

    /// The dismissals in a `noticeDismissals` value. Anything unreadable
    /// reads as none.
    public static func decode(_ value: NoteSyncValue?) -> NoteNoticeDismissals {
        guard case .data(let data)? = value,
              let entries = try? decoder.decode([String: Entry].self, from: data) else {
            return NoteNoticeDismissals()
        }
        return NoteNoticeDismissals(entries: entries)
    }

    /// The field value, encoded alike on every device.
    public var value: NoteSyncValue {
        .data((try? Self.encoder.encode(entries)) ?? Data("{}".utf8))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
