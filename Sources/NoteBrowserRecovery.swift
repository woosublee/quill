import Foundation

enum NoteBrowserRetryAvailability: Equatable {
    case noAudio
    case needsModelSetup
    case needsModelSelection
    case ready
}

struct NoteBrowserActionState: Equatable {
    let hasStoredAudio: Bool
    let hasTranscriptText: Bool
    let retryAvailability: NoteBrowserRetryAvailability

    init(
        hasStoredAudio: Bool,
        transcript: String,
        retryAvailability: NoteBrowserRetryAvailability
    ) {
        self.hasStoredAudio = hasStoredAudio
        self.hasTranscriptText = !transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        self.retryAvailability = retryAvailability
    }

    var showsRetryButton: Bool { hasStoredAudio }
    var canCopy: Bool { hasTranscriptText }
    var canSaveFiles: Bool { hasStoredAudio || hasTranscriptText }
}

enum NoteBrowserRecoveryPresentation {
    static func presentation(
        for record: QuillUserIssueRecord,
        actionState: NoteBrowserActionState,
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> QuillUserIssuePresentation {
        let original = record.presentation(language: language, bundle: bundle)
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
                detailsRows: original.detailsRows,
                recoveryAction: .retryTranscription,
                severity: original.severity
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
                detailsRows: original.detailsRows,
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
                detailsRows: original.detailsRows,
                recoveryAction: .openModelsSettings,
                severity: original.severity
            )
        case .noAudio:
            return original
        }
    }
}
