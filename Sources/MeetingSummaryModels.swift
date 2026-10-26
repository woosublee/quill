import Foundation
import QuillAITextCore
import QuillSummaryFormatCore
import QuillUserIssueCore

extension MeetingSummaryAttempt {
    func issuePresentation(
        language presentationLanguage: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> QuillUserIssuePresentation? {
        guard let issue else { return nil }
        let presentation = issue.presentation(
            language: presentationLanguage,
            bundle: bundle
        )
        return QuillUserIssuePresentation(
            title: presentation.title,
            body: presentation.body,
            suggestion: presentation.suggestion,
            compactMessage: presentation.compactMessage,
            detailsRows: presentation.detailsRows
                + self.language.detailsRows(
                    language: presentationLanguage,
                    bundle: bundle
                ),
            recoveryAction: presentation.recoveryAction,
            severity: presentation.severity
        )
    }
}

private extension Optional where Wrapped == MeetingSummaryLanguageContext {
    func detailsRows(
        language: String,
        bundle: Bundle
    ) -> [QuillUserIssueDetailsRow] {
        guard let context = self,
              let localizedLanguage = TranscriptionLanguage
                .localizedSummaryLanguageName(
                    for: context.appliedLanguageCode,
                    language: language,
                    bundle: bundle
                ) else {
            return []
        }
        let sourceKey: String
        switch context.resolutionSource {
        case .configured:
            sourceKey = "Explicitly selected"
        case .engineDetected:
            sourceKey = "Detected by transcription engine"
        case .transcriptInferred:
            sourceKey = "Inferred from transcript"
        case .unavailable:
            sourceKey = "Unavailable"
        }
        return [
            QuillUserIssueDetailsRow(
                label: localizedCatalogString(
                    "Summary language",
                    language: language,
                    bundle: bundle
                ),
                value: "\(localizedLanguage) (\(context.appliedLanguageCode))"
            ),
            QuillUserIssueDetailsRow(
                label: localizedCatalogString(
                    "Language source",
                    language: language,
                    bundle: bundle
                ),
                value: localizedCatalogString(
                    sourceKey,
                    language: language,
                    bundle: bundle
                )
            )
        ]
    }
}
