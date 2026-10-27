import CryptoKit
import Foundation
import QuillAITextCore
import QuillUserIssueCore

public enum MeetingSummaryBackendKind: String, Codable, Equatable, Sendable {
    case cloud
    case local
}

public struct MeetingSummaryLanguageContext: Codable, Equatable, Sendable {
    public let requestedOutputLanguage: String
    public let appliedLanguageCode: String
    public let resolutionSource: SpokenLanguageResolutionSource

    public init(
        requestedOutputLanguage: String,
        appliedLanguageCode: String,
        resolutionSource: SpokenLanguageResolutionSource
    ) {
        self.requestedOutputLanguage = requestedOutputLanguage
        self.appliedLanguageCode = appliedLanguageCode
        self.resolutionSource = resolutionSource
    }
}

public enum MeetingSummaryEvidenceVerification: String, Codable, Equatable, Sendable {
    case verified
    case unverified
}

public enum MeetingSummaryAttemptOutcome: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
}

public struct MeetingSummaryAttempt: Codable, Equatable, Sendable {
    public let occurredAt: Date
    public let outcome: MeetingSummaryAttemptOutcome
    public let backendKind: MeetingSummaryBackendKind
    public let modelID: String
    public let providerHost: String?
    public let language: MeetingSummaryLanguageContext?
    public let issue: QuillUserIssueRecord?
    public let sourceFingerprint: String?

    public init(
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

    public func isCurrent(for source: MeetingSummarySource) -> Bool {
        sourceFingerprint == source.fingerprint
    }
}

public struct MeetingSummaryCalendarContext: Codable, Equatable, Sendable {
    public let title: String
    public let start: Date
    public let end: Date
    public let attendees: [String]

    public init(
        title: String,
        start: Date,
        end: Date,
        attendees: [String]
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
    }
}

public extension MeetingSummaryCalendarContext {
    /// How an attendee appears in a summary source: their name, or their
    /// email when the name is blank. Nil when both are blank.
    static func attendeeLabel(displayName: String?, email: String?) -> String? {
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        let email = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return email.isEmpty ? nil : email
    }
}

public struct MeetingSummarySource: Equatable, Sendable {
    public static let fingerprintVersion = 1

    /// The transcript a summary reads: the edited one without surrounding
    /// whitespace, or the raw one when the edited one is blank.
    public static func transcript(raw: String, edited: String) -> String {
        let trimmed = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? raw : trimmed
    }

    public let transcript: String
    public let calendar: MeetingSummaryCalendarContext?
    public let languageContext: MeetingSummaryLanguageContext

    public init(
        transcript: String,
        calendar: MeetingSummaryCalendarContext?,
        languageContext: MeetingSummaryLanguageContext
    ) {
        self.transcript = transcript
        self.calendar = calendar
        self.languageContext = languageContext
    }

    public var normalizedTranscript: String {
        transcript
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var withoutCalendar: MeetingSummarySource {
        MeetingSummarySource(transcript: transcript, calendar: nil, languageContext: languageContext)
    }

    // One formatter for every fingerprint. The lock makes sharing it across
    // threads safe without relying on Foundation's own thread safety.
    nonisolated(unsafe) private static let fingerprintDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        return formatter
    }()
    private static let fingerprintDateFormatterLock = NSLock()

    private static func fingerprintDateText(_ date: Date) -> String {
        fingerprintDateFormatterLock.withLock {
            fingerprintDateFormatter.string(from: date)
        }
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    public var fingerprint: String {
        let calendarText: String
        if let calendar {
            calendarText = [
                calendar.title,
                Self.fingerprintDateText(calendar.start),
                Self.fingerprintDateText(calendar.end),
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

        var hex: [UInt8] = []
        hex.reserveCapacity(64)
        for byte in SHA256.hash(data: Data(canonical.utf8)) {
            hex.append(Self.hexDigits[Int(byte >> 4)])
            hex.append(Self.hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: hex, as: UTF8.self)
    }
}

public struct MeetingSummaryEvidenceText: Codable, Equatable, Sendable {
    public var text: String
    public let sourceQuotes: [String]

    public init(
        text: String,
        sourceQuotes: [String]
    ) {
        self.text = text
        self.sourceQuotes = sourceQuotes
    }
}

public struct MeetingSummaryEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 4

    public let schemaVersion: Int
    public let promptVersion: Int
    public let generatedAt: Date
    public let sourceFingerprint: String
    public let modelID: String
    public let backendKind: MeetingSummaryBackendKind
    public let languageContext: MeetingSummaryLanguageContext?
    /// Nil is legacy verified evidence. New unverified envelopes persist .unverified.
    public let evidenceVerification: MeetingSummaryEvidenceVerification?
    public var content: MeetingSummaryContent
    /// When the person last changed the summary text. Nil means the content
    /// is still what the model generated.
    public var editedAt: Date?
    /// The generated content from before the first edit, kept so the person
    /// can revert. Nil until the summary is edited (#262).
    public var originalContent: MeetingSummaryContent?

    public var effectiveEvidenceVerification: MeetingSummaryEvidenceVerification {
        evidenceVerification ?? .verified
    }

    public init(
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

    public func preservingCompletion(
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

public struct MeetingSummaryContent: Codable, Equatable, Sendable {
    public var overview: MeetingSummaryEvidenceText
    public var keyPoints: [MeetingSummaryPoint]
    public var decisions: [MeetingSummaryPoint]
    public var actionItems: [MeetingSummaryActionItem]
    public var openQuestions: [MeetingSummaryPoint]

    private enum CodingKeys: String, CodingKey {
        case overview
        case keyPoints
        case decisions
        case actionItems
        case openQuestions
    }

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

    public init(from decoder: Decoder) throws {
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

public struct MeetingSummaryPoint: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var text: String
    public let sourceQuote: String?

    public init(
        id: UUID,
        text: String,
        sourceQuote: String?
    ) {
        self.id = id
        self.text = text
        self.sourceQuote = sourceQuote
    }
}

public struct MeetingSummaryActionItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var task: String
    public var owner: String?
    public var dueDate: String?
    public let sourceQuote: String?
    public var isCompleted: Bool

    public init(
        id: UUID,
        task: String,
        owner: String?,
        dueDate: String?,
        sourceQuote: String?,
        isCompleted: Bool
    ) {
        self.id = id
        self.task = task
        self.owner = owner
        self.dueDate = dueDate
        self.sourceQuote = sourceQuote
        self.isCompleted = isCompleted
    }
}


public enum MeetingSummaryMarkdownRenderer {
    public static func render(_ envelope: MeetingSummaryEnvelope) -> String {
        render(envelope.content)
    }

    public static func render(_ content: MeetingSummaryContent) -> String {
        [
            section(title: "Overview", body: content.overview.text),
            listSection(title: "Key Points", points: content.keyPoints),
            listSection(title: "Decisions", points: content.decisions),
            actionSection(content.actionItems),
            listSection(title: "Open Questions", points: content.openQuestions)
        ].joined(separator: "\n\n")
    }

    public static func renderActionItem(
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

public struct SummarySourceData: Codable, Equatable, Sendable {
    public let transcript: String
    public let calendar: MeetingSummaryCalendarContext?

    public init(
        transcript: String,
        calendar: MeetingSummaryCalendarContext?
    ) {
        self.transcript = transcript
        self.calendar = calendar
    }
}
