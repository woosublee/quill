import Foundation

/// A notice above a saved meeting summary, the same on the Mac and the
/// iPhone (#697): which notices a summary has, in what order, how each
/// looks, its copy keys, and how its dismissal syncs (#745).
///
/// Each app still decides the inputs (whether the last attempt failed, the
/// summary is stale, the setting is off here), which dismissed notices it
/// hides, what a notice's button does, and translates the keys with its own
/// String Catalog. A failure notice's text comes from its issue record, so
/// it has no keys here.
public enum NoteSummaryNotice: String, CaseIterable, Equatable, Sendable {
    /// A regeneration produced the same summary, so the current one stayed.
    case unchanged
    /// The latest attempt from the current transcript failed.
    case failure
    /// The transcript changed after this summary was generated.
    case stale
    /// Some of the summary's evidence could not be verified.
    case unverifiedEvidence
    /// Meeting Summary is off on this device.
    case featureDisabled
    /// This device has no summary model to use.
    case modelUnavailable

    /// Why a device can't make a summary right now, for the last notice.
    public enum Setting: Equatable, Sendable {
        case ready
        case featureDisabled
        case modelUnavailable
    }

    /// A notice's button. A failure's button depends on its issue, so each
    /// app picks it from the issue record.
    public enum Action: Equatable, Sendable {
        /// Opens Settings › Models, where the summary model is set up and
        /// Meeting Summary is turned on.
        case openModels

        public var titleKey: String {
            switch self {
            case .openModels: "View Models"
            }
        }
    }

    /// How a notice is tinted: each app maps these to its own colors.
    public enum Tint: Equatable, Sendable {
        /// The banner warning color.
        case warning
        /// The secondary text color.
        case secondary
    }

    /// The notices a saved summary shows before dismissals, most important
    /// first. With no saved summary there are none.
    public static func notices(
        hasSummary: Bool,
        showsUnchanged: Bool,
        hasCurrentFailure: Bool,
        isStale: Bool,
        isUnverifiedEvidence: Bool,
        setting: Setting
    ) -> [NoteSummaryNotice] {
        guard hasSummary else { return [] }
        var notices: [NoteSummaryNotice] = []
        if showsUnchanged { notices.append(.unchanged) }
        if hasCurrentFailure { notices.append(.failure) }
        if isStale { notices.append(.stale) }
        if isUnverifiedEvidence { notices.append(.unverifiedEvidence) }
        switch setting {
        case .ready: break
        case .featureDisabled: notices.append(.featureDisabled)
        case .modelUnavailable: notices.append(.modelUnavailable)
        }
        return notices
    }

    public var systemImage: String {
        switch self {
        case .unchanged: return "info.circle"
        case .failure, .stale, .unverifiedEvidence: return "exclamationmark.triangle.fill"
        case .featureDisabled: return "pause.circle"
        case .modelUnavailable: return "exclamationmark.circle"
        }
    }

    public var tint: Tint {
        switch self {
        case .failure, .stale, .unverifiedEvidence: return .warning
        case .unchanged, .featureDisabled, .modelUnavailable: return .secondary
        }
    }

    /// The notice's button: "View Models" when the setting is off or the
    /// model is missing, on both apps (the owner's 2026-11-08 decision s2,
    /// the iPhone's button). None for a failure (its issue decides) or the
    /// review reminders.
    public var action: Action? {
        switch self {
        case .featureDisabled, .modelUnavailable: .openModels
        case .unchanged, .failure, .stale, .unverifiedEvidence: nil
        }
    }

    /// The title's copy key, or nil for a failure, whose title comes from
    /// its issue record.
    public var titleKey: String? {
        switch self {
        case .unchanged: return "The new summary is the same as the current one."
        case .failure: return nil
        case .stale: return "Transcript changed after this summary was generated."
        case .unverifiedEvidence: return "Some evidence could not be verified."
        case .featureDisabled: return "Meeting Summary is off"
        case .modelUnavailable: return "Summary model is unavailable."
        }
    }

    /// The detail's copy key, or nil for a failure.
    public var detailKey: String? {
        switch self {
        case .unchanged: return "The summary text didn't change."
        case .failure: return nil
        case .stale: return "Regenerate to align the draft with the current transcript."
        case .unverifiedEvidence: return "Review the summary before sharing it."
        case .featureDisabled:
            return "This saved summary is still available. Turn the feature on to regenerate it."
        case .modelUnavailable: return "This saved summary remains available for review and copying."
        }
    }

    /// The notice as every device dismisses it, or nil when it can't sync:
    /// the same-summary notice syncs as its own marker, and a notice whose
    /// condition the app can't read can't be dismissed for that condition.
    ///
    /// - Parameters:
    ///   - failedAttemptAt: When the failed attempt happened.
    ///   - sourceFingerprint: The current transcript's summary fingerprint.
    ///   - summaryGeneratedAt: When the saved summary was made.
    public func syncedDismissal(
        failedAttemptAt: Date?,
        sourceFingerprint: String?,
        summaryGeneratedAt: Date?
    ) -> NoteNoticeDismissals.Notice? {
        switch self {
        case .unchanged: return nil
        case .failure: return failedAttemptAt.map { .summaryFailure(attemptAt: $0) }
        case .stale: return sourceFingerprint.map { .summaryStale(sourceFingerprint: $0) }
        case .unverifiedEvidence: return summaryGeneratedAt.map { .summaryUnverifiedEvidence(generatedAt: $0) }
        case .featureDisabled: return summaryGeneratedAt.map { .summaryFeatureDisabled(generatedAt: $0) }
        case .modelUnavailable: return summaryGeneratedAt.map { .summaryModelUnavailable(generatedAt: $0) }
        }
    }
}
