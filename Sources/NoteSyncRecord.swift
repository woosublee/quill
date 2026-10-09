import Foundation

/// One synced field value. Absence of a key means `nil`.
enum NoteSyncValue: Codable, Equatable, Sendable {
    case string(String)
    case date(Date)
    case bool(Bool)
    case data(Data)
    case int(Int)
    /// A value from a newer build, kept as its JSON and written back unchanged.
    case raw(Data)
}

/// The note fields that sync, each in the field group it merges with. Raw
/// values are the record keys, so they never change once shipped.
enum NoteSyncField: String, CaseIterable, Sendable {
    case customTitle
    case rawTranscript
    case transcriptFileName
    case postProcessedTranscript
    case meetingSummaryJSON
    case meetingSummaryAttempt
    case calendarMatch
    case timestamp
    case recordingStartedAt
    case recordingEndedAt
    case transcriptionLanguageCode
    case spokenLanguageCode
    case spokenLanguageResolution
    case intent
    case postProcessingStatus
    case aiProcessingOutcome
    case localTranscriptionModelID
    case usedLocalTranscription
    case usedPostProcessing
    case audioFileName

    /// Fields every record carries. A record missing one (a malformed or
    /// partial record) never overwrites the local value with a default.
    var isRequired: Bool {
        switch self {
        case .rawTranscript, .postProcessedTranscript, .timestamp, .transcriptionLanguageCode,
             .intent, .postProcessingStatus, .aiProcessingOutcome, .localTranscriptionModelID,
             .usedLocalTranscription, .usedPostProcessing:
            return true
        default:
            return false
        }
    }

    var group: NoteFieldGroup {
        switch self {
        case .customTitle: return .title
        case .rawTranscript, .transcriptFileName: return .rawTranscript
        case .postProcessedTranscript: return .editedTranscript
        case .meetingSummaryJSON, .meetingSummaryAttempt: return .summary
        case .calendarMatch: return .calendar
        case .timestamp, .recordingStartedAt, .recordingEndedAt: return .recordingTime
        case .transcriptionLanguageCode, .spokenLanguageCode, .spokenLanguageResolution: return .language
        case .intent, .postProcessingStatus, .aiProcessingOutcome, .localTranscriptionModelID,
             .usedLocalTranscription, .usedPostProcessing: return .status
        case .audioFileName: return .audio
        }
    }

    enum ValueKind { case string, date, bool, data }

    /// The kind of value this field always carries.
    var valueKind: ValueKind {
        switch self {
        case .meetingSummaryJSON, .meetingSummaryAttempt, .calendarMatch: return .data
        case .timestamp, .recordingStartedAt, .recordingEndedAt: return .date
        case .usedLocalTranscription, .usedPostProcessing: return .bool
        default: return .string
        }
    }

    /// The `PipelineHistoryItem` coding key this field comes from.
    var itemKey: String {
        self == .aiProcessingOutcome ? "storedAIProcessingOutcome" : rawValue
    }
}

/// A note as it travels between Macs: only fields a person sees, the field
/// clock, and the deletion time. Unknown keys from newer builds are kept.
struct NoteSyncRecord: Equatable, Sendable {
    static let schemaVersion = 1
    static let schemaVersionKey = "schemaVersion"

    /// Item fields that never leave the Mac that made the note.
    static let localOnlyItemKeys: Set<String> = [
        "contextScreenshotDataURL", "contextScreenshotStatus", "contextWindowTitle",
        "contextAppName", "contextBundleIdentifier", "selectedText", "capturedSelection",
        "postProcessingPrompt", "systemPrompt", "contextSystemPrompt", "contextPrompt",
        "contextSummary", "debugStatus", "customSystemPrompt", "customVocabulary",
        "usedContextCapture"
    ]

    let noteID: UUID
    var fields: [String: NoteSyncValue]
    var clock: NoteFieldClock
    var deletedAt: Date?

    init(noteID: UUID, fields: [String: NoteSyncValue], clock: NoteFieldClock, deletedAt: Date?) {
        self.noteID = noteID
        self.fields = fields
        self.clock = clock
        self.deletedAt = deletedAt
    }

    init(item: PipelineHistoryItem) {
        var fields: [String: NoteSyncValue] = [Self.schemaVersionKey: .int(Self.schemaVersion)]
        func put(_ field: NoteSyncField, _ value: NoteSyncValue?) {
            if let value { fields[field.rawValue] = value }
        }
        put(.customTitle, item.customTitle.map(NoteSyncValue.string))
        put(.rawTranscript, .string(item.rawTranscript))
        put(.transcriptFileName, item.transcriptFileName.map(NoteSyncValue.string))
        put(.postProcessedTranscript, .string(item.postProcessedTranscript))
        put(.meetingSummaryJSON, item.meetingSummaryJSON.map(NoteSyncValue.data))
        put(.meetingSummaryAttempt, Self.encoded(item.meetingSummaryAttempt.map(Self.withoutProviderHost)))
        put(.calendarMatch, Self.encoded(item.calendarMatch))
        put(.timestamp, .date(item.timestamp.roundedToMilliseconds()))
        put(.recordingStartedAt, item.recordingStartedAt.map { .date($0.roundedToMilliseconds()) })
        put(.recordingEndedAt, item.recordingEndedAt.map { .date($0.roundedToMilliseconds()) })
        put(.transcriptionLanguageCode, .string(item.transcriptionLanguageCode))
        put(.spokenLanguageCode, item.spokenLanguageCode.map(NoteSyncValue.string))
        put(.spokenLanguageResolution, item.spokenLanguageResolution.map { .string($0.rawValue) })
        put(.intent, .string(item.intent.rawValue))
        put(.postProcessingStatus, .string(item.postProcessingStatus))
        put(.aiProcessingOutcome, .string(item.aiProcessingOutcome))
        put(.localTranscriptionModelID, .string(item.localTranscriptionModelID))
        put(.usedLocalTranscription, .bool(item.usedLocalTranscription))
        put(.usedPostProcessing, .bool(item.usedPostProcessing))
        put(.audioFileName, item.audioFileName.map(NoteSyncValue.string))
        self.init(
            noteID: item.id,
            fields: fields,
            clock: (item.fieldClock ?? NoteFieldClock.uniform(item.timestamp)).roundedToMilliseconds(),
            deletedAt: item.deletedAt?.roundedToMilliseconds()
        )
    }

    /// Whether a known field holds a value this build can't read: another
    /// value kind, or an intent or language source it doesn't know. Such a
    /// record is skipped rather than applied with values lost. Newer builds
    /// never change the shape of a shipped key; a new shape gets a new key.
    var hasUnreadableKnownFields: Bool {
        if let version = fields[Self.schemaVersionKey], case .int = version {} else if fields[Self.schemaVersionKey] != nil {
            return true
        }
        return NoteSyncField.allCases.contains { field in
            guard let value = fields[field.rawValue] else { return false }
            switch (field.valueKind, value) {
            case (.string, .string(let text)):
                switch field {
                case .intent: return PipelineHistoryItemIntent(rawValue: text) == nil
                case .spokenLanguageResolution: return SpokenLanguageResolutionSource(rawValue: text) == nil
                default: return false
                }
            case (.date, .date), (.bool, .bool), (.data, .data):
                return false
            default:
                return true
            }
        }
    }

    /// Whether every field a note needs is present. A record without them
    /// can update a note this Mac has, but never create one.
    var hasRequiredFields: Bool {
        NoteSyncField.allCases.allSatisfy { !$0.isRequired || fields[$0.rawValue] != nil }
    }

    /// The note this record describes, applied onto the note already on
    /// this Mac. Local-only fields and any missing required field keep
    /// their local values.
    func applied(onto base: PipelineHistoryItem) -> PipelineHistoryItem {
        note(base: base)
    }

    /// A note this Mac does not have yet, with local-only fields empty.
    /// Nil when a required field is missing, so a partial record never
    /// creates a note with made-up values.
    func newNote() -> PipelineHistoryItem? {
        hasRequiredFields ? note(base: nil) : nil
    }

    private func note(base: PipelineHistoryItem?) -> PipelineHistoryItem {
        PipelineHistoryItem(
            intent: string(.intent).flatMap(PipelineHistoryItemIntent.init(rawValue:))
                ?? base?.intent ?? .dictation,
            selectedText: base?.selectedText,
            capturedSelection: base?.capturedSelection,
            id: noteID,
            timestamp: date(.timestamp) ?? base?.timestamp ?? Date(timeIntervalSince1970: 0),
            recordingStartedAt: date(.recordingStartedAt),
            recordingEndedAt: date(.recordingEndedAt),
            calendarMatch: decoded(.calendarMatch),
            rawTranscript: string(.rawTranscript) ?? base?.rawTranscript ?? "",
            postProcessedTranscript: string(.postProcessedTranscript) ?? base?.postProcessedTranscript ?? "",
            postProcessingPrompt: base?.postProcessingPrompt,
            systemPrompt: base?.systemPrompt,
            contextSummary: base?.contextSummary ?? "",
            contextSystemPrompt: base?.contextSystemPrompt,
            contextPrompt: base?.contextPrompt,
            contextScreenshotDataURL: base?.contextScreenshotDataURL,
            contextScreenshotStatus: base?.contextScreenshotStatus ?? "No screenshot",
            postProcessingStatus: string(.postProcessingStatus) ?? base?.postProcessingStatus ?? "",
            aiProcessingOutcome: string(.aiProcessingOutcome) ?? base?.aiProcessingOutcome ?? "succeeded",
            debugStatus: base?.debugStatus ?? "",
            customVocabulary: base?.customVocabulary ?? "",
            customSystemPrompt: base?.customSystemPrompt ?? "",
            audioFileName: string(.audioFileName),
            usedLocalTranscription: bool(.usedLocalTranscription) ?? base?.usedLocalTranscription ?? false,
            usedContextCapture: base?.usedContextCapture ?? false,
            usedPostProcessing: bool(.usedPostProcessing) ?? base?.usedPostProcessing ?? false,
            transcriptionLanguageCode: string(.transcriptionLanguageCode) ?? base?.transcriptionLanguageCode ?? "auto",
            spokenLanguageCode: string(.spokenLanguageCode),
            spokenLanguageResolution: string(.spokenLanguageResolution)
                .flatMap(SpokenLanguageResolutionSource.init(rawValue:)),
            meetingSummaryAttempt: decoded(.meetingSummaryAttempt),
            localTranscriptionModelID: string(.localTranscriptionModelID) ?? base?.localTranscriptionModelID,
            transcriptFileName: string(.transcriptFileName),
            contextAppName: base?.contextAppName,
            contextBundleIdentifier: base?.contextBundleIdentifier,
            contextWindowTitle: base?.contextWindowTitle,
            customTitle: string(.customTitle),
            meetingSummaryJSON: data(.meetingSummaryJSON),
            deletedAt: deletedAt,
            fieldClock: clock
        )
    }

    /// The provider host can name a private server; it never leaves the Mac.
    private static func withoutProviderHost(_ attempt: MeetingSummaryAttempt) -> MeetingSummaryAttempt {
        MeetingSummaryAttempt(
            occurredAt: attempt.occurredAt,
            outcome: attempt.outcome,
            backendKind: attempt.backendKind,
            modelID: attempt.modelID,
            providerHost: nil,
            language: attempt.language,
            issue: attempt.issue,
            sourceFingerprint: attempt.sourceFingerprint
        )
    }

    private func string(_ field: NoteSyncField) -> String? {
        if case .string(let value) = fields[field.rawValue] { return value }
        return nil
    }

    private func date(_ field: NoteSyncField) -> Date? {
        if case .date(let value) = fields[field.rawValue] { return value }
        return nil
    }

    private func bool(_ field: NoteSyncField) -> Bool? {
        if case .bool(let value) = fields[field.rawValue] { return value }
        return nil
    }

    private func data(_ field: NoteSyncField) -> Data? {
        if case .data(let value) = fields[field.rawValue] { return value }
        return nil
    }

    private func decoded<T: Decodable>(_ field: NoteSyncField) -> T? {
        data(field).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func encoded<T: Encodable>(_ value: T?) -> NoteSyncValue? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)).map(NoteSyncValue.data)
    }
}

/// Which notes are settled enough to send. A note still recording,
/// importing, transcribing in the cloud, waiting on recovery, or whose
/// recording couldn't be recovered stays on this Mac until it settles.
enum NoteSyncEligibility {
    static func isSyncable(_ item: PipelineHistoryItem) -> Bool {
        !item.isIncompleteTranscription && item.unrecoveredRecordingContext == nil
    }
}

extension NoteFieldClock {
    /// CloudKit keeps dates to the millisecond, so stamps are compared and
    /// sent at that precision; the same edit then reads equal on every Mac.
    func roundedToMilliseconds() -> NoteFieldClock {
        NoteFieldClock(stamps: stamps.mapValues { $0.roundedToMilliseconds() })
    }
}

extension Date {
    /// The date as the sync payload carries it.
    func roundedToMilliseconds() -> Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}
