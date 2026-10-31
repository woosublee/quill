import Foundation
import QuillNoteSyncCore
import QuillAITextCore
import QuillSummaryFormatCore
import QuillUserIssueCore

// The sync record and its fields are in QuillNoteSyncCore, shared with the
// iPhone app. This file converts them to and from this Mac's notes.

extension NoteSyncField {
    /// Kept by the store beside the note rather than on
    /// `PipelineHistoryItem`: the item never carries it.
    var isStoreLevel: Bool { self == .audioManifest || self == .dismissedNotices }

    /// The `PipelineHistoryItem` coding key this field comes from.
    var itemKey: String {
        self == .aiProcessingOutcome ? "storedAIProcessingOutcome" : rawValue
    }
}

extension NoteSyncRecord {
    /// Item fields that never leave the Mac that made the note.
    static let localOnlyItemKeys: Set<String> = [
        "contextScreenshotDataURL", "contextScreenshotStatus", "contextWindowTitle",
        "contextAppName", "contextBundleIdentifier", "selectedText", "capturedSelection",
        "postProcessingPrompt", "systemPrompt", "contextSystemPrompt", "contextPrompt",
        "contextSummary", "debugStatus", "customSystemPrompt", "customVocabulary",
        "usedContextCapture"
    ]

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
        put(.postProcessingStatus, .string(QuillUserIssueRecord.persistedStatusWithoutProviderHost(item.postProcessingStatus)))
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

    /// The provider host can name a private server; it never leaves the Mac,
    /// including the one in the attempt's issue.
    private static func withoutProviderHost(_ attempt: MeetingSummaryAttempt) -> MeetingSummaryAttempt {
        MeetingSummaryAttempt(
            occurredAt: attempt.occurredAt,
            outcome: attempt.outcome,
            backendKind: attempt.backendKind,
            modelID: attempt.modelID,
            providerHost: nil,
            language: attempt.language,
            issue: attempt.issue?.withoutProviderHost,
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
