import Foundation

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
        case .warning: return nil
        }
    }

    /// The banner title's copy key, or nil for a warning, whose title comes
    /// from its issue record.
    public var titleKey: String? {
        switch self {
        case .sameAsCurrent: return "The new transcript is the same as the current one."
        case .nothingToCleanUp: return "Nothing to clean up; showing the original transcript."
        case .warning: return nil
        }
    }

    /// The banner detail's copy key, or nil when there is none ("Nothing to
    /// clean up") or it comes from the issue record (a warning).
    public var detailKey: String? {
        switch self {
        case .sameAsCurrent: return "The transcript text didn't change."
        case .nothingToCleanUp, .warning: return nil
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
    public init(
        showsSameAsCurrent: Bool,
        postProcessing: NoteTranscriptNotice.PostProcessing?,
        isDisplayedTranscriptBlank: Bool,
        isNothingToCleanUpDismissed: Bool,
        isWarningDismissed: Bool,
        isWorkRunning: Bool
    ) {
        guard !isWorkRunning else {
            notices = []
            return
        }
        var notices: [NoteTranscriptNotice] = []
        if showsSameAsCurrent { notices.append(.sameAsCurrent) }
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
