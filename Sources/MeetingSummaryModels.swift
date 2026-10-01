import CryptoKit
import Foundation

enum MeetingSummaryBackendKind: String, Codable, Equatable, Sendable {
    case cloud
    case local
}

struct MeetingSummaryLanguageContext: Codable, Equatable, Sendable {
    let requestedOutputLanguage: String
    let appliedLanguageCode: String
    let resolutionSource: SpokenLanguageResolutionSource
}

enum MeetingSummaryEvidenceVerification: String, Codable, Equatable, Sendable {
    case verified
    case unverified
}

enum MeetingSummaryAttemptOutcome: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
}

struct MeetingSummaryAttempt: Codable, Equatable, Sendable {
    let occurredAt: Date
    let outcome: MeetingSummaryAttemptOutcome
    let backendKind: MeetingSummaryBackendKind
    let modelID: String
    let providerHost: String?
    let language: MeetingSummaryLanguageContext?
    let issue: QuillUserIssueRecord?
    let sourceFingerprint: String?

    init(
        occurredAt: Date,
        outcome: MeetingSummaryAttemptOutcome,
        backendKind: MeetingSummaryBackendKind,
        modelID: String,
        providerHost: String?,
        language: MeetingSummaryLanguageContext?,
        issue: QuillUserIssueRecord?,
        sourceFingerprint: String? = nil
    ) {
        self.occurredAt = occurredAt
        self.outcome = outcome
        self.backendKind = backendKind
        self.modelID = modelID
        self.providerHost = providerHost
        self.language = language
        self.issue = issue
        self.sourceFingerprint = sourceFingerprint
    }

    func isCurrent(for source: MeetingSummarySource) -> Bool {
        sourceFingerprint == source.fingerprint
    }

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

struct MeetingSummaryCalendarContext: Codable, Equatable, Sendable {
    let title: String
    let start: Date
    let end: Date
    let attendees: [String]
}

struct MeetingSummarySource: Equatable, Sendable {
    static let fingerprintVersion = 1

    let transcript: String
    let calendar: MeetingSummaryCalendarContext?
    let languageContext: MeetingSummaryLanguageContext

    var normalizedTranscript: String {
        transcript
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var fingerprint: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]

        let calendarText: String
        if let calendar {
            calendarText = [
                calendar.title,
                formatter.string(from: calendar.start),
                formatter.string(from: calendar.end),
                calendar.attendees.sorted().joined(separator: "\u{1F}")
            ].joined(separator: "\u{1E}")
        } else {
            calendarText = ""
        }

        let canonical = [
            "meeting-summary-source-v\(Self.fingerprintVersion)",
            normalizedTranscript,
            calendarText
        ].joined(separator: "\u{1D}")

        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct MeetingSummaryEvidenceText: Codable, Equatable, Sendable {
    var text: String
    let sourceQuotes: [String]
}

struct MeetingSummaryEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 4

    let schemaVersion: Int
    let promptVersion: Int
    let generatedAt: Date
    let sourceFingerprint: String
    let modelID: String
    let backendKind: MeetingSummaryBackendKind
    let languageContext: MeetingSummaryLanguageContext?
    /// Nil is legacy verified evidence. New unverified envelopes persist .unverified.
    let evidenceVerification: MeetingSummaryEvidenceVerification?
    var content: MeetingSummaryContent
    /// When the person last changed the summary text. Nil means the content
    /// is still what the model generated.
    var editedAt: Date?
    /// The generated content from before the first edit, kept so the person
    /// can revert. Nil until the summary is edited (#262).
    var originalContent: MeetingSummaryContent?

    var effectiveEvidenceVerification: MeetingSummaryEvidenceVerification {
        evidenceVerification ?? .verified
    }

    init(
        schemaVersion: Int,
        promptVersion: Int,
        generatedAt: Date,
        sourceFingerprint: String,
        modelID: String,
        backendKind: MeetingSummaryBackendKind,
        languageContext: MeetingSummaryLanguageContext? = nil,
        evidenceVerification: MeetingSummaryEvidenceVerification? = nil,
        content: MeetingSummaryContent,
        editedAt: Date? = nil,
        originalContent: MeetingSummaryContent? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.promptVersion = promptVersion
        self.generatedAt = generatedAt
        self.sourceFingerprint = sourceFingerprint
        self.modelID = modelID
        self.backendKind = backendKind
        self.languageContext = languageContext
        self.evidenceVerification = evidenceVerification
        self.content = content
        self.editedAt = editedAt
        self.originalContent = originalContent
    }

    func preservingCompletion(
        from previous: MeetingSummaryEnvelope?
    ) -> Self {
        guard let previous else { return self }

        let previousActions = Dictionary(
            previous.content.actionItems.map {
                (MeetingSummaryActionIdentity($0), $0)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var copy = self
        copy.content.actionItems = content.actionItems.map { action in
            guard let previousAction = previousActions[
                MeetingSummaryActionIdentity(action)
            ] else {
                return action
            }
            return MeetingSummaryActionItem(
                id: previousAction.id,
                task: action.task,
                owner: action.owner,
                dueDate: action.dueDate,
                sourceQuote: action.sourceQuote,
                isCompleted: previousAction.isCompleted
            )
        }
        return copy
    }
}

struct MeetingSummaryContent: Codable, Equatable, Sendable {
    var overview: MeetingSummaryEvidenceText
    var keyPoints: [MeetingSummaryPoint]
    var decisions: [MeetingSummaryPoint]
    var actionItems: [MeetingSummaryActionItem]
    var openQuestions: [MeetingSummaryPoint]

    private enum CodingKeys: String, CodingKey {
        case overview
        case keyPoints
        case decisions
        case actionItems
        case openQuestions
    }

    init(
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let evidence = try? container.decode(
            MeetingSummaryEvidenceText.self,
            forKey: .overview
        ) {
            overview = evidence
        } else {
            // Summary v1 stored overview as a plain string. Keep that text visible
            // while deliberately withholding any invented source evidence.
            overview = MeetingSummaryEvidenceText(
                text: try container.decode(String.self, forKey: .overview),
                sourceQuotes: []
            )
        }
        keyPoints = try container.decode([MeetingSummaryPoint].self, forKey: .keyPoints)
        decisions = try container.decode([MeetingSummaryPoint].self, forKey: .decisions)
        actionItems = try container.decode(
            [MeetingSummaryActionItem].self,
            forKey: .actionItems
        )
        openQuestions = try container.decode(
            [MeetingSummaryPoint].self,
            forKey: .openQuestions
        )
    }
}

struct MeetingSummaryPoint: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var text: String
    let sourceQuote: String?
}

struct MeetingSummaryActionItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var task: String
    var owner: String?
    var dueDate: String?
    let sourceQuote: String?
    var isCompleted: Bool
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

enum MeetingSummaryMarkdownRenderer {
    static func render(_ envelope: MeetingSummaryEnvelope) -> String {
        let content = envelope.content
        return [
            section(title: "Overview", body: content.overview.text),
            listSection(title: "Key Points", points: content.keyPoints),
            listSection(title: "Decisions", points: content.decisions),
            actionSection(content.actionItems),
            listSection(title: "Open Questions", points: content.openQuestions)
        ].joined(separator: "\n\n")
    }

    static func renderActionItem(
        _ item: MeetingSummaryActionItem
    ) -> String {
        var details: [String] = []
        if let owner = nonempty(item.owner) {
            details.append("Owner: \(owner)")
        }
        if let dueDate = nonempty(item.dueDate) {
            details.append("Due: \(dueDate)")
        }
        let suffix = details.isEmpty
            ? ""
            : " (\(details.joined(separator: ", ")))"
        return "- [\(item.isCompleted ? "x" : " ")] \(item.task)\(suffix)"
    }

    private static func section(title: String, body: String) -> String {
        "## \(title)\n\n\(body)"
    }

    private static func listSection(
        title: String,
        points: [MeetingSummaryPoint]
    ) -> String {
        let body = points.isEmpty
            ? "- None"
            : points.map { "- \($0.text)" }.joined(separator: "\n")
        return section(title: title, body: body)
    }

    private static func actionSection(
        _ items: [MeetingSummaryActionItem]
    ) -> String {
        let body = items.isEmpty
            ? "- None"
            : items.map(renderActionItem).joined(separator: "\n")
        return section(title: "Action Items", body: body)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

private struct MeetingSummaryActionIdentity: Hashable {
    let task: String
    let owner: String?
    let dueDate: String?

    init(_ item: MeetingSummaryActionItem) {
        task = Self.normalize(item.task)
        owner = Self.normalizeOptional(item.owner)
        dueDate = Self.normalizeOptional(item.dueDate)
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizeOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = normalize(value)
        return normalized.isEmpty ? nil : normalized
    }
}
