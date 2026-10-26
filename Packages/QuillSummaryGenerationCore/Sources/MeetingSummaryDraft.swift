import Foundation
import QuillSummaryFormatCore

public struct MeetingSummaryDraftPoint: Codable, Equatable, Sendable {
    public let text: String
    public let sourceQuote: String?

    public init(
        text: String,
        sourceQuote: String?
    ) {
        self.text = text
        self.sourceQuote = sourceQuote
    }
}

public struct MeetingSummaryDraftActionItem: Codable, Equatable, Sendable {
    public let task: String
    public let owner: String?
    public let dueDate: String?
    public let sourceQuote: String?

    public init(
        task: String,
        owner: String?,
        dueDate: String?,
        sourceQuote: String?
    ) {
        self.task = task
        self.owner = owner
        self.dueDate = dueDate
        self.sourceQuote = sourceQuote
    }
}

public struct MeetingSummaryDraftContent: Codable, Equatable, Sendable {
    public let overview: String
    public let keyPoints: [MeetingSummaryDraftPoint]
    public let decisions: [MeetingSummaryDraftPoint]
    public let actionItems: [MeetingSummaryDraftActionItem]
    public let openQuestions: [MeetingSummaryDraftPoint]

    public init(
        overview: String,
        keyPoints: [MeetingSummaryDraftPoint],
        decisions: [MeetingSummaryDraftPoint],
        actionItems: [MeetingSummaryDraftActionItem],
        openQuestions: [MeetingSummaryDraftPoint]
    ) {
        self.overview = overview
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
    }

    public func materialized(
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

public struct MeetingSummaryDraftContentV2: Codable, Equatable, Sendable {
    public let overview: MeetingSummaryEvidenceText
    public let keyPoints: [MeetingSummaryPoint]
    public let decisions: [MeetingSummaryPoint]
    public let actionItems: [MeetingSummaryActionItem]
    public let openQuestions: [MeetingSummaryPoint]

    public init(
        overview: MeetingSummaryEvidenceText,
        keyPoints: [MeetingSummaryPoint],
        decisions: [MeetingSummaryPoint],
        actionItems: [MeetingSummaryActionItem],
        openQuestions: [MeetingSummaryPoint]
    ) {
        self.overview = overview
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
    }

    public func materialized() -> MeetingSummaryContent {
        MeetingSummaryContent(
            overview: overview,
            keyPoints: keyPoints,
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions
        )
    }

    public var validatedSourceTexts: [String] {
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
public enum PersistedMeetingSummaryDraft: Codable, Equatable, Sendable {
    case v1(MeetingSummaryDraftContent)
    case v2(MeetingSummaryDraftContentV2)

    private enum CodingKeys: String, CodingKey {
        case overview
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if (try? container.decode(MeetingSummaryEvidenceText.self, forKey: .overview)) != nil {
            self = .v2(try MeetingSummaryDraftContentV2(from: decoder))
        } else {
            self = .v1(try MeetingSummaryDraftContent(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .v1(let draft):
            try draft.encode(to: encoder)
        case .v2(let draft):
            try draft.encode(to: encoder)
        }
    }
}

public enum MeetingSummarySourceLocator {
    public static func range(
        of quote: String,
        in transcript: String
    ) -> Range<String.Index>? {
        let trimmed = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return transcript.range(of: trimmed, options: [.literal])
    }
}
