import Foundation

enum NoteBrowserRetryAvailability: Equatable {
    case noAudio
    case needsModelSetup
    case needsModelSelection
    case needsProviderConfiguration
    case ready
}

struct NoteBrowserActionState: Equatable {
    let hasStoredAudio: Bool
    let hasTranscriptText: Bool
    let retryAvailability: NoteBrowserRetryAvailability
    let postProcessingEnabled: Bool
    let hasSummary: Bool

    init(
        hasStoredAudio: Bool,
        transcript: String,
        retryAvailability: NoteBrowserRetryAvailability,
        postProcessingEnabled: Bool = true,
        hasSummary: Bool = false
    ) {
        self.hasStoredAudio = hasStoredAudio
        self.hasTranscriptText = !transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        self.retryAvailability = retryAvailability
        self.postProcessingEnabled = postProcessingEnabled
        self.hasSummary = hasSummary
    }

    var showsRetryButton: Bool { hasStoredAudio }
    var canCopy: Bool { hasTranscriptText }
    var canSaveFiles: Bool { hasStoredAudio || hasTranscriptText || hasSummary }
}

enum NoteBrowserRecoveryPresentation {
    private static let postProcessingIssueCodes: Set<QuillUserIssueCode> = [
        .postProcessingFailed,
        .postProcessingRateLimited,
        .postProcessingGuardFallback,
        .postProcessingPayloadTooLarge
    ]

    static func presentation(
        for record: QuillUserIssueRecord,
        actionState: NoteBrowserActionState,
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> QuillUserIssuePresentation {
        let original = record.presentation(language: language, bundle: bundle)

        // A historical post-processing warning no longer matches the current
        // configuration once post-processing is disabled: retrying will
        // intentionally skip cleanup, so offering that action is misleading.
        // Keep the warning informational instead of dropping it entirely.
        if postProcessingIssueCodes.contains(record.code), !actionState.postProcessingEnabled {
            return QuillUserIssuePresentation(
                title: original.title,
                body: original.body,
                suggestion: original.suggestion,
                compactMessage: original.compactMessage,
                detailsRows: original.detailsRows,
                recoveryAction: .none,
                severity: original.severity
            )
        }

        // Local backend/model IDs are debugging detail, not something a
        // typical user acts on for a plain transcription-process failure.
        if record.code == .localTranscriptionFailed {
            return QuillUserIssuePresentation(
                title: original.title,
                body: original.body,
                suggestion: original.suggestion,
                compactMessage: original.compactMessage,
                detailsRows: [],
                recoveryAction: original.recoveryAction,
                severity: original.severity
            )
        }

        guard record.code == .localModelMissing,
              actionState.hasStoredAudio else {
            return original
        }

        switch actionState.retryAvailability {
        case .ready:
            return QuillUserIssuePresentation(
                title: localizedCatalogString(
                    "Ready to retry transcription",
                    language: language,
                    bundle: bundle
                ),
                body: localizedCatalogString(
                    "Your recording is safely stored.",
                    language: language,
                    bundle: bundle
                ),
                suggestion: localizedCatalogString(
                    "Choose Retry Transcription to try again.",
                    language: language,
                    bundle: bundle
                ),
                compactMessage: localizedCatalogString(
                    "Ready to retry transcription",
                    language: language,
                    bundle: bundle
                ),
                detailsRows: [],
                recoveryAction: .retryTranscription,
                severity: .warning
            )
        case .needsModelSetup:
            return QuillUserIssuePresentation(
                title: localizedCatalogString(
                    "Set up a model for retranscription",
                    language: language,
                    bundle: bundle
                ),
                body: localizedCatalogString(
                    "Your recording is safely stored.",
                    language: language,
                    bundle: bundle
                ),
                suggestion: "",
                compactMessage: localizedCatalogString(
                    "Set up a model for retranscription",
                    language: language,
                    bundle: bundle
                ),
                detailsRows: [],
                recoveryAction: .openModelsSettings,
                severity: original.severity
            )
        case .needsModelSelection:
            return QuillUserIssuePresentation(
                title: localizedCatalogString(
                    "Choose a model for retranscription",
                    language: language,
                    bundle: bundle
                ),
                body: localizedCatalogString(
                    "Your recording is safely stored.",
                    language: language,
                    bundle: bundle
                ),
                suggestion: "",
                compactMessage: localizedCatalogString(
                    "Choose a model for retranscription",
                    language: language,
                    bundle: bundle
                ),
                detailsRows: [],
                recoveryAction: .openModelsSettings,
                severity: original.severity
            )
        case .needsProviderConfiguration:
            return QuillUserIssuePresentation(
                title: localizedCatalogString(
                    "Add an API key to retry transcription",
                    language: language,
                    bundle: bundle
                ),
                body: localizedCatalogString(
                    "Your recording is safely stored.",
                    language: language,
                    bundle: bundle
                ),
                suggestion: "",
                compactMessage: localizedCatalogString(
                    "Add an API key to retry transcription",
                    language: language,
                    bundle: bundle
                ),
                detailsRows: [],
                recoveryAction: .openProviderSettings,
                severity: original.severity
            )
        case .noAudio:
            return original
        }
    }
}
