import Foundation
import QuillUserIssueCore

/// A notice above a note's transcript, the same on the Mac and the iPhone
/// (#697): which notices show, in what order, how the "+1" group folds,
/// and their copy keys. Each app decides the inputs (the post-processing
/// record, the dismissals it keeps, whether work runs), what the warning
/// says (from its issue record), and what the buttons do.
public enum NoteTranscriptNotice: String, CaseIterable, Equatable, Sendable {
    /// A retranscription gave the same text as the current transcript.
    case sameAsCurrent
    /// Cleanup had nothing to change, so the original transcript shows.
    case nothingToCleanUp
    /// Cleanup ended with a warning (its issue record says which).
    case warning
    /// A retranscription failed and the current transcript stayed
    /// (`NoteRetranscriptionFailure`). It draws as a warning banner whose
    /// detail is the failure's cause.
    case retranscriptionFailed

    /// What the note's post-processing record says, before dismissals.
    public enum PostProcessing: Equatable, Sendable {
        case nothingToCleanUp
        case warning
    }

    /// The grey info banner's symbol, or nil for a warning, which draws as
    /// its issue record's banner (icon and tint by severity).
    public var systemImage: String? {
        switch self {
        case .sameAsCurrent, .nothingToCleanUp: return "info.circle"
        case .warning, .retranscriptionFailed: return nil
        }
    }

    /// The banner title's copy key, or nil for a warning, whose title comes
    /// from its issue record.
    public var titleKey: String? {
        switch self {
        case .sameAsCurrent: return "The new transcript is the same as the current one."
        case .nothingToCleanUp: return "Nothing to clean up; showing the original transcript."
        case .warning: return nil
        case .retranscriptionFailed: return NoteRetranscriptionFailure.titleKey
        }
    }

    /// The banner detail's copy key, or nil when there is none ("Nothing to
    /// clean up") or it comes from the issue record (a warning).
    public var detailKey: String? {
        switch self {
        case .sameAsCurrent: return "The transcript text didn't change."
        case .nothingToCleanUp, .warning: return nil
        case .retranscriptionFailed: return NoteRetranscriptionFailure.unchangedKey
        }
    }

    /// Every copy key the notices use, for catalog checks.
    public static var allCopyKeys: [String] {
        allCases.flatMap { [$0.titleKey, $0.detailKey].compactMap { $0 } }
    }
}

/// The transcript's notices for one note, and how they fold.
public struct NoteTranscriptNoticeGroup: Equatable, Sendable {
    /// Every notice that shows, the leading one first.
    public let notices: [NoteTranscriptNotice]

    /// - Parameters:
    ///   - showsSameAsCurrent: The same-result marker matches the
    ///     displayed transcript.
    ///   - postProcessing: What the current transcript's post-processing
    ///     record says, if anything.
    ///   - isDisplayedTranscriptBlank: The transcript shown is empty or only
    ///     whitespace. "Nothing to clean up" points at the original
    ///     transcript, so it doesn't show over a blank one.
    ///   - isNothingToCleanUpDismissed: Dismissed on any device, or on this
    ///     device before the dismissal synced.
    ///   - isWarningDismissed: Dismissed while the note keeps this status
    ///     (#745), or on this device before the dismissal synced. Dismissing
    ///     the warning hides "Nothing to clean up" too (the Mac's rule).
    ///   - isWorkRunning: A retranscription or a cleanup runs for the note.
    ///     The notices describe the transcript being replaced, so none show
    ///     until the work ends.
    ///   - showsRetranscriptionFailure: The last retranscription failed and
    ///     the current transcript stayed (`NoteRetranscriptionFailure`), and
    ///     it isn't dismissed. It shows after the same-result notice and
    ///     before the post-processing one.
    public init(
        showsSameAsCurrent: Bool,
        postProcessing: NoteTranscriptNotice.PostProcessing?,
        isDisplayedTranscriptBlank: Bool,
        isNothingToCleanUpDismissed: Bool,
        isWarningDismissed: Bool,
        isWorkRunning: Bool,
        showsRetranscriptionFailure: Bool = false
    ) {
        guard !isWorkRunning else {
            notices = []
            return
        }
        var notices: [NoteTranscriptNotice] = []
        if showsSameAsCurrent { notices.append(.sameAsCurrent) }
        if showsRetranscriptionFailure { notices.append(.retranscriptionFailed) }
        switch postProcessing {
        case .nothingToCleanUp:
            if !isDisplayedTranscriptBlank, !isNothingToCleanUpDismissed, !isWarningDismissed {
                notices.append(.nothingToCleanUp)
            }
        case .warning:
            if !isWarningDismissed { notices.append(.warning) }
        case nil:
            break
        }
        self.notices = notices
    }

    /// The same-result notice leads and folds the rest behind "+N", like
    /// the Summary tab's notices. Without it, every notice shows.
    public var folds: Bool {
        notices.first == .sameAsCurrent && notices.count > 1
    }

    /// The "+N" count on the leading notice, or nil when nothing folds.
    public var hiddenCount: Int? {
        folds ? notices.count - 1 : nil
    }

    /// The notices to draw.
    public func shown(isExpanded: Bool) -> [NoteTranscriptNotice] {
        folds && !isExpanded ? Array(notices.prefix(1)) : notices
    }
}

/// A failed retranscription, alike on the Mac and the iPhone (quill-universal-private#429).
/// The Mac stores the failure as an error-level issue in the note's
/// `postProcessingStatus` and keeps the transcript; that status syncs. A note
/// whose status holds an error and whose transcript isn't blank is therefore
/// a retranscription that failed (a failed first transcription has no
/// transcript). The banner reads "Retranscription failed", its detail is the
/// issue's cause and that the transcript is unchanged, and it opens provider
/// settings when the shared rule sends the issue there. Each app translates
/// the keys and runs the button.
public enum NoteRetranscriptionFailure {
    public static let titleKey = "Retranscription failed"
    public static let unchangedKey = "The current transcript is unchanged."

    /// The failure a stored status describes, or nil when it isn't one: no
    /// issue, a warning (post-processing), or a blank transcript.
    public static func issue(
        postProcessingStatus: String,
        hasTranscriptText: Bool
    ) -> QuillUserIssueRecord? {
        guard hasTranscriptText,
              let record = NoteMachineStatus.userIssueRecord(postProcessingStatus: postProcessingStatus),
              record.severity == .error else { return nil }
        return record
    }

    /// The banner offers Open Provider Settings for this failure (a rejected
    /// key, a used-up quota, a provider set up wrong); otherwise it has no
    /// button and the toolbar's ↻ retries.
    public static func opensProviderSettings(_ issue: QuillUserIssueRecord) -> Bool {
        issue.recoveryAction == .openProviderSettings
    }
}
