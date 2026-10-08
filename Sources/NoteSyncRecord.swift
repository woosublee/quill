import Foundation

/// One synced field value. Absence of a key means `nil`.
enum NoteSyncValue: Codable, Equatable, Sendable {
    case string(String)
    case date(Date)
    case bool(Bool)
    case data(Data)
    case int(Int)
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
        put(.meetingSummaryAttempt, Self.encoded(item.meetingSummaryAttempt))
        put(.calendarMatch, Self.encoded(item.calendarMatch))
        put(.timestamp, .date(item.timestamp))
        put(.recordingStartedAt, item.recordingStartedAt.map(NoteSyncValue.date))
        put(.recordingEndedAt, item.recordingEndedAt.map(NoteSyncValue.date))
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
            clock: item.fieldClock ?? NoteFieldClock.uniform(item.timestamp),
            deletedAt: item.deletedAt
        )
    }

    /// The note this record describes. Local-only fields come from `base`
    /// (the note already on this Mac), or stay empty for a new note.
    func applied(onto base: PipelineHistoryItem?) -> PipelineHistoryItem {
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
            rawTranscript: string(.rawTranscript) ?? "",
            postProcessedTranscript: string(.postProcessedTranscript) ?? "",
            postProcessingPrompt: base?.postProcessingPrompt,
            systemPrompt: base?.systemPrompt,
            contextSummary: base?.contextSummary ?? "",
            contextSystemPrompt: base?.contextSystemPrompt,
            contextPrompt: base?.contextPrompt,
            contextScreenshotDataURL: base?.contextScreenshotDataURL,
            contextScreenshotStatus: base?.contextScreenshotStatus ?? "No screenshot",
            postProcessingStatus: string(.postProcessingStatus) ?? "",
            aiProcessingOutcome: string(.aiProcessingOutcome) ?? "succeeded",
            debugStatus: base?.debugStatus ?? "",
            customVocabulary: base?.customVocabulary ?? "",
            customSystemPrompt: base?.customSystemPrompt ?? "",
            audioFileName: string(.audioFileName),
            usedLocalTranscription: bool(.usedLocalTranscription) ?? false,
            usedContextCapture: base?.usedContextCapture ?? false,
            usedPostProcessing: bool(.usedPostProcessing) ?? false,
            transcriptionLanguageCode: string(.transcriptionLanguageCode) ?? "auto",
            spokenLanguageCode: string(.spokenLanguageCode),
            spokenLanguageResolution: string(.spokenLanguageResolution)
                .flatMap(SpokenLanguageResolutionSource.init(rawValue:)),
            meetingSummaryAttempt: decoded(.meetingSummaryAttempt),
            localTranscriptionModelID: string(.localTranscriptionModelID),
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
