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

struct MeetingSummaryDraftPoint: Codable, Equatable, Sendable {
    let text: String
    let sourceQuote: String?
}

struct MeetingSummaryDraftActionItem: Codable, Equatable, Sendable {
    let task: String
    let owner: String?
    let dueDate: String?
    let sourceQuote: String?
}

struct MeetingSummaryDraftContent: Codable, Equatable, Sendable {
    let overview: String
    let keyPoints: [MeetingSummaryDraftPoint]
    let decisions: [MeetingSummaryDraftPoint]
    let actionItems: [MeetingSummaryDraftActionItem]
    let openQuestions: [MeetingSummaryDraftPoint]

    func materialized(
        id: () -> UUID = UUID.init
    ) -> MeetingSummaryContent {
        MeetingSummaryContent(
            overview: MeetingSummaryEvidenceText(
                text: overview,
                sourceQuotes: []
            ),
            keyPoints: keyPoints.map {
                MeetingSummaryPoint(
                    id: id(),
                    text: $0.text,
                    sourceQuote: $0.sourceQuote
                )
            },
            decisions: decisions.map {
                MeetingSummaryPoint(
                    id: id(),
                    text: $0.text,
                    sourceQuote: $0.sourceQuote
                )
            },
            actionItems: actionItems.map {
                MeetingSummaryActionItem(
                    id: id(),
                    task: $0.task,
                    owner: $0.owner,
                    dueDate: $0.dueDate,
                    sourceQuote: $0.sourceQuote,
                    isCompleted: false
                )
            },
            openQuestions: openQuestions.map {
                MeetingSummaryPoint(
                    id: id(),
                    text: $0.text,
                    sourceQuote: $0.sourceQuote
                )
            }
        )
    }
}

struct MeetingSummaryDraftContentV2: Codable, Equatable, Sendable {
    let overview: MeetingSummaryEvidenceText
    let keyPoints: [MeetingSummaryPoint]
    let decisions: [MeetingSummaryPoint]
    let actionItems: [MeetingSummaryActionItem]
    let openQuestions: [MeetingSummaryPoint]

    func materialized() -> MeetingSummaryContent {
        MeetingSummaryContent(
            overview: overview,
            keyPoints: keyPoints,
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions
        )
    }

    var validatedSourceTexts: [String] {
        var texts = overview.sourceQuotes
        for point in keyPoints + decisions + openQuestions {
            if let sourceQuote = point.sourceQuote {
                texts.append(sourceQuote)
            }
        }
        for action in actionItems {
            if let sourceQuote = action.sourceQuote {
                texts.append(sourceQuote)
            }
        }
        return texts
    }
}

/// Decodes both the pre-evidence draft shape and the evidence-bearing v2
/// shape. The application only creates and persists v2 drafts going forward.
enum PersistedMeetingSummaryDraft: Codable, Equatable, Sendable {
    case v1(MeetingSummaryDraftContent)
    case v2(MeetingSummaryDraftContentV2)

    private enum CodingKeys: String, CodingKey {
        case overview
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if (try? container.decode(MeetingSummaryEvidenceText.self, forKey: .overview)) != nil {
            self = .v2(try MeetingSummaryDraftContentV2(from: decoder))
        } else {
            self = .v1(try MeetingSummaryDraftContent(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .v1(let draft):
            try draft.encode(to: encoder)
        case .v2(let draft):
            try draft.encode(to: encoder)
        }
    }
}

enum MeetingSummarySourceLocator {
    static func range(
        of quote: String,
        in transcript: String
    ) -> Range<String.Index>? {
        let trimmed = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return transcript.range(of: trimmed, options: [.literal])
    }
}
