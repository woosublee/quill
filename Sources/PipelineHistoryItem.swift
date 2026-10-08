import Foundation

enum PipelineHistoryItemIntent: String, Codable {
    case dictation
    case commandAutomatic = "command:automatic"
    case commandManual = "command:manual"
}

enum PipelineHistoryMachineStatus: Equatable {
    case importing
    case liveRecording
    case cloudTranscribing
    case audioOnly
    case recovered(RecoveredRecordingContext)
    /// Startup recovery could not restore the recording's audio.
    case unrecovered(UnrecoveredRecordingContext)
    case failed(QuillUserIssueRecord)
    case completed
}

struct PipelineHistoryTranscriptionReplacement {
    let rawTranscript: String
    let postProcessedTranscript: String
    let postProcessingPrompt: String?
    let postProcessingStatus: String
    let aiProcessingOutcome: String
    let debugStatus: String
    let customVocabulary: String
    let customSystemPrompt: String
    let usedLocalTranscription: Bool
    let usedPostProcessing: Bool
    let transcriptionLanguageCode: String
    let spokenLanguage: SpokenLanguageResolution?
    let localTranscriptionModelID: String
    let transcriptFileName: String?
}

struct PipelineHistoryItem: Identifiable, Codable {
    static let transcriptionRecoveryPlaceholderStatus =
        RecoveredRecordingMode.complete.placeholderStatus
    static let recoveredRecordingStatus =
        RecoveredRecordingMode.complete.recoveredStatus
    static let cloudTranscribingStatus = "cloud-transcribing"
    /// Set on an imported file's note until transcription replaces it. It is
    /// the only mark of an import while a cloud model transcribes the file.
    static let importingDebugStatus = "Importing audio"
    static let audioOnlyStatus = "audio-only"

    var spokenLanguage: SpokenLanguageResolution? {
        guard let spokenLanguageResolution else { return nil }
        if spokenLanguageResolution == .unavailable {
            return SpokenLanguageResolution(
                languageCode: nil,
                source: .unavailable
            )
        }
        guard let languageCode = spokenLanguageCode?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !languageCode.isEmpty else {
            return nil
        }
        return SpokenLanguageResolution(
            languageCode: languageCode,
            source: spokenLanguageResolution
        )
    }

    var machineStatus: PipelineHistoryMachineStatus {
        if postProcessingStatus == "importing" { return .importing }
        if postProcessingStatus == "live-recording" { return .liveRecording }
        if postProcessingStatus == Self.cloudTranscribingStatus {
            return .cloudTranscribing
        }
        if postProcessingStatus == Self.audioOnlyStatus {
            return .audioOnly
        }
        if let context = unrecoveredRecordingContext {
            return .unrecovered(context)
        }
        if let context = recoveredRecordingContext {
            return .recovered(context)
        }
        if let userIssueRecord, userIssueRecord.severity == .error {
            return .failed(userIssueRecord)
        }
        return .completed
    }

    var userIssueRecord: QuillUserIssueRecord? {
        if postProcessingStatus.hasPrefix("user-issue:") {
            return (try? QuillUserIssueRecord.decodePersistedStatus(
                postProcessingStatus
            )) ?? QuillUserIssueRecord(code: .unknown)
        }
        if postProcessingStatus.hasPrefix("Error:") {
            return QuillUserIssueRecord(code: .legacy)
        }
        return nil
    }

    func userIssuePresentation(
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> QuillUserIssuePresentation? {
        userIssueRecord?.presentation(language: language, bundle: bundle)
    }

    var recoveredRecordingContext: RecoveredRecordingContext? {
        RecoveredRecordingContext.recoveredContext(for: postProcessingStatus)
    }

    var unrecoveredRecordingContext: UnrecoveredRecordingContext? {
        UnrecoveredRecordingContext.parse(postProcessingStatus)
    }

    /// The note stands for a recording whose pieces remain on disk after
    /// recovery failed. Deleting the note deletes the pieces.
    var hasUnrecoveredRecordingPieces: Bool {
        unrecoveredRecordingContext?.kind == .recoveryFailed
    }

    var recoveredRecordingMode: RecoveredRecordingMode? {
        recoveredRecordingContext?.mode
    }

    var recordingInterruptionReason: RecordingInterruptionReason? {
        recoveredRecordingContext?.interruptionReason
    }

    var isRecoveredRecording: Bool {
        recoveredRecordingContext != nil
    }

    /// A note created when recording started that never received a
    /// transcript or audio. Nothing in it is worth keeping.
    var isUnfinishedRecordingNote: Bool {
        postProcessingStatus == "live-recording"
            && rawTranscript.isEmpty
            && postProcessedTranscript.isEmpty
            && audioFileName == nil
            && transcriptFileName == nil
    }

    var isIncompleteTranscription: Bool {
        RecoveredRecordingContext.placeholderContext(for: postProcessingStatus) != nil
            || postProcessingStatus == "importing"
            || postProcessingStatus == "live-recording"
            || postProcessingStatus == Self.cloudTranscribingStatus
    }

    let intent: PipelineHistoryItemIntent
    let selectedText: String?
    let capturedSelection: String?
    let id: UUID
    let timestamp: Date
    let recordingStartedAt: Date?
    let recordingEndedAt: Date?
    let calendarMatch: CalendarEventMatch?
    let rawTranscript: String
    let postProcessedTranscript: String
    let postProcessingPrompt: String?
    let systemPrompt: String?
    let contextSummary: String
    let contextSystemPrompt: String?
    let contextPrompt: String?
    let contextScreenshotDataURL: String?
    let contextScreenshotStatus: String
    let postProcessingStatus: String
    private let storedAIProcessingOutcome: String?
    var aiProcessingOutcome: String {
        storedAIProcessingOutcome ?? "succeeded"
    }
    let debugStatus: String
    let customVocabulary: String
    let customSystemPrompt: String
    let audioFileName: String?
    let usedLocalTranscription: Bool
    let usedContextCapture: Bool
    let usedPostProcessing: Bool
    let transcriptionLanguageCode: String
    let spokenLanguageCode: String?
    let spokenLanguageResolution: SpokenLanguageResolutionSource?
    let meetingSummaryAttempt: MeetingSummaryAttempt?
    let localTranscriptionModelID: String
    let transcriptFileName: String?
    let contextAppName: String?
    let contextBundleIdentifier: String?
    let contextWindowTitle: String?
    let customTitle: String?
    let meetingSummaryJSON: Data?
    /// Set while the note is in Recently Deleted. Written only by
    /// `PipelineHistoryStore.setDeletedAt(_:id:)`.
    private(set) var deletedAt: Date?
    /// When each field group last changed. Maintained by the store.
    private(set) var fieldClock: NoteFieldClock?

    init(
        intent: PipelineHistoryItemIntent = .dictation,
        selectedText: String? = nil,
        capturedSelection: String? = nil,
        id: UUID = UUID(),
        timestamp: Date,
        recordingStartedAt: Date? = nil,
        recordingEndedAt: Date? = nil,
        calendarMatch: CalendarEventMatch? = nil,
        rawTranscript: String,
        postProcessedTranscript: String,
        postProcessingPrompt: String?,
        systemPrompt: String? = nil,
        contextSummary: String,
        contextSystemPrompt: String? = nil,
        contextPrompt: String? = nil,
        contextScreenshotDataURL: String?,
        contextScreenshotStatus: String,
        postProcessingStatus: String,
        aiProcessingOutcome: String = "succeeded",
        debugStatus: String,
        customVocabulary: String,
        customSystemPrompt: String = "",
        audioFileName: String? = nil,
        usedLocalTranscription: Bool = false,
        usedContextCapture: Bool = true,
        usedPostProcessing: Bool = true,
        transcriptionLanguageCode: String = "auto",
        spokenLanguageCode: String? = nil,
        spokenLanguageResolution: SpokenLanguageResolutionSource? = nil,
        meetingSummaryAttempt: MeetingSummaryAttempt? = nil,
        localTranscriptionModelID: String? = nil,
        transcriptFileName: String? = nil,
        contextAppName: String? = nil,
        contextBundleIdentifier: String? = nil,
        contextWindowTitle: String? = nil,
        customTitle: String? = nil,
        meetingSummaryJSON: Data? = nil,
        deletedAt: Date? = nil,
        fieldClock: NoteFieldClock? = nil
    ) {
        self.intent = intent
        self.selectedText = selectedText
        self.capturedSelection = capturedSelection
        self.id = id
        self.timestamp = timestamp
        self.recordingStartedAt = recordingStartedAt
        self.recordingEndedAt = recordingEndedAt
        self.calendarMatch = calendarMatch
        self.rawTranscript = rawTranscript
        self.postProcessedTranscript = postProcessedTranscript
        self.postProcessingPrompt = postProcessingPrompt
        self.systemPrompt = systemPrompt
        self.contextSummary = contextSummary
        self.contextSystemPrompt = contextSystemPrompt
        self.contextPrompt = contextPrompt
        self.contextScreenshotDataURL = contextScreenshotDataURL
        self.contextScreenshotStatus = contextScreenshotStatus
        self.postProcessingStatus = postProcessingStatus
        self.storedAIProcessingOutcome = aiProcessingOutcome
        self.debugStatus = debugStatus
        self.customVocabulary = customVocabulary
        self.customSystemPrompt = customSystemPrompt
        self.audioFileName = audioFileName
        self.usedLocalTranscription = usedLocalTranscription
        self.usedContextCapture = usedContextCapture
        self.usedPostProcessing = usedPostProcessing
        self.transcriptionLanguageCode = transcriptionLanguageCode
        self.spokenLanguageCode = spokenLanguageCode
        self.spokenLanguageResolution = spokenLanguageResolution
        self.meetingSummaryAttempt = meetingSummaryAttempt
        self.localTranscriptionModelID = localTranscriptionModelID ?? "mlx-community/whisper-large-v3-turbo"
        self.transcriptFileName = transcriptFileName
        self.contextAppName = contextAppName
        self.contextBundleIdentifier = contextBundleIdentifier
        self.contextWindowTitle = contextWindowTitle
        self.customTitle = customTitle
        self.meetingSummaryJSON = meetingSummaryJSON
        self.deletedAt = deletedAt
        self.fieldClock = fieldClock
    }

    static func transcriptionRecoveryPlaceholder(
        id: UUID = UUID(),
        timestamp: Date,
        recordingStartedAt: Date? = nil,
        recordingEndedAt: Date? = nil,
        calendarMatch: CalendarEventMatch? = nil,
        intent: PipelineHistoryItemIntent,
        selectedText: String?,
        capturedSelection: String?,
        contextSummary: String,
        contextSystemPrompt: String?,
        contextPrompt: String?,
        contextScreenshotDataURL: String?,
        contextScreenshotStatus: String,
        systemPrompt: String?,
        customVocabulary: String,
        customSystemPrompt: String,
        audioFileName: String,
        usedLocalTranscription: Bool,
        usedContextCapture: Bool,
        usedPostProcessing: Bool,
        transcriptionLanguageCode: String,
        localTranscriptionModelID: String,
        contextAppName: String?,
        contextBundleIdentifier: String?,
        contextWindowTitle: String?,
        recoveryMode: RecoveredRecordingMode = .complete,
        interruptionReason: RecordingInterruptionReason? = nil,
        postProcessingStatusOverride: String? = nil
    ) -> PipelineHistoryItem {
        let recoveryContext = RecoveredRecordingContext(
            mode: recoveryMode,
            interruptionReason: interruptionReason
        )
        return PipelineHistoryItem(
            intent: intent,
            selectedText: selectedText,
            capturedSelection: capturedSelection,
            id: id,
            timestamp: timestamp,
            recordingStartedAt: recordingStartedAt,
            recordingEndedAt: recordingEndedAt,
            calendarMatch: calendarMatch,
            rawTranscript: "",
            postProcessedTranscript: "",
            postProcessingPrompt: nil,
            systemPrompt: systemPrompt,
            contextSummary: contextSummary,
            contextSystemPrompt: contextSystemPrompt,
            contextPrompt: contextPrompt,
            contextScreenshotDataURL: contextScreenshotDataURL,
            contextScreenshotStatus: contextScreenshotStatus,
            postProcessingStatus: postProcessingStatusOverride
                ?? recoveryContext.placeholderStatus,
            debugStatus: "Transcription interrupted before completion",
            customVocabulary: customVocabulary,
            customSystemPrompt: customSystemPrompt,
            audioFileName: audioFileName,
            usedLocalTranscription: usedLocalTranscription,
            usedContextCapture: usedContextCapture,
            usedPostProcessing: usedPostProcessing,
            transcriptionLanguageCode: transcriptionLanguageCode,
            localTranscriptionModelID: localTranscriptionModelID,
            transcriptFileName: nil,
            contextAppName: contextAppName,
            contextBundleIdentifier: contextBundleIdentifier,
            contextWindowTitle: contextWindowTitle,
            customTitle: nil
        )
    }

    static func audioOnly(
        id: UUID = UUID(),
        timestamp: Date,
        recordingStartedAt: Date?,
        recordingEndedAt: Date?,
        calendarMatch: CalendarEventMatch?,
        audioFileName: String,
        transcriptionLanguageCode: String,
        localTranscriptionModelID: String
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            intent: .dictation,
            selectedText: nil,
            capturedSelection: nil,
            id: id,
            timestamp: timestamp,
            recordingStartedAt: recordingStartedAt,
            recordingEndedAt: recordingEndedAt,
            calendarMatch: calendarMatch,
            rawTranscript: "",
            postProcessedTranscript: "",
            postProcessingPrompt: nil,
            systemPrompt: nil,
            contextSummary: "",
            contextSystemPrompt: nil,
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: Self.audioOnlyStatus,
            debugStatus: "Audio only",
            customVocabulary: "",
            customSystemPrompt: "",
            audioFileName: audioFileName,
            usedLocalTranscription: false,
            usedContextCapture: false,
            usedPostProcessing: false,
            transcriptionLanguageCode: transcriptionLanguageCode,
            localTranscriptionModelID: localTranscriptionModelID,
            transcriptFileName: nil,
            contextAppName: nil,
            contextBundleIdentifier: nil,
            contextWindowTitle: nil,
            customTitle: nil
        )
    }

    func withCustomTitle(_ customTitle: String?) -> PipelineHistoryItem {
        copying(
            meetingSummaryJSON: meetingSummaryJSON,
            spokenLanguageCode: spokenLanguageCode,
            spokenLanguageResolution: spokenLanguageResolution,
            meetingSummaryAttempt: meetingSummaryAttempt,
            customTitle: customTitle,
            postProcessedTranscript: postProcessedTranscript
        )
    }

    func withSpokenLanguage(
        _ spokenLanguage: SpokenLanguageResolution
    ) -> PipelineHistoryItem {
        copying(
            meetingSummaryJSON: meetingSummaryJSON,
            spokenLanguageCode: spokenLanguage.languageCode,
            spokenLanguageResolution: spokenLanguage.source,
            meetingSummaryAttempt: meetingSummaryAttempt,
            customTitle: customTitle,
            postProcessedTranscript: postProcessedTranscript
        )
    }

    func copying(
        meetingSummaryJSON: Data?,
        spokenLanguageCode: String?,
        spokenLanguageResolution: SpokenLanguageResolutionSource?,
        meetingSummaryAttempt: MeetingSummaryAttempt?,
        customTitle: String?,
        postProcessedTranscript: String
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            intent: intent,
            selectedText: selectedText,
            capturedSelection: capturedSelection,
            id: id,
            timestamp: timestamp,
            recordingStartedAt: recordingStartedAt,
            recordingEndedAt: recordingEndedAt,
            calendarMatch: calendarMatch,
            rawTranscript: rawTranscript,
            postProcessedTranscript: postProcessedTranscript,
            postProcessingPrompt: postProcessingPrompt,
            systemPrompt: systemPrompt,
            contextSummary: contextSummary,
            contextSystemPrompt: contextSystemPrompt,
            contextPrompt: contextPrompt,
            contextScreenshotDataURL: contextScreenshotDataURL,
            contextScreenshotStatus: contextScreenshotStatus,
            postProcessingStatus: postProcessingStatus,
            aiProcessingOutcome: aiProcessingOutcome,
            debugStatus: debugStatus,
            customVocabulary: customVocabulary,
            customSystemPrompt: customSystemPrompt,
            audioFileName: audioFileName,
            usedLocalTranscription: usedLocalTranscription,
            usedContextCapture: usedContextCapture,
            usedPostProcessing: usedPostProcessing,
            transcriptionLanguageCode: transcriptionLanguageCode,
            spokenLanguageCode: spokenLanguageCode,
            spokenLanguageResolution: spokenLanguageResolution,
            meetingSummaryAttempt: meetingSummaryAttempt,
            localTranscriptionModelID: localTranscriptionModelID,
            transcriptFileName: transcriptFileName,
            contextAppName: contextAppName,
            contextBundleIdentifier: contextBundleIdentifier,
            contextWindowTitle: contextWindowTitle,
            customTitle: customTitle,
            meetingSummaryJSON: meetingSummaryJSON,
            deletedAt: deletedAt,
            fieldClock: fieldClock
        )
    }

    func replacingTranscription(
        with replacement: PipelineHistoryTranscriptionReplacement
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            intent: intent,
            selectedText: selectedText,
            capturedSelection: capturedSelection,
            id: id,
            timestamp: timestamp,
            recordingStartedAt: recordingStartedAt,
            recordingEndedAt: recordingEndedAt,
            calendarMatch: calendarMatch,
            rawTranscript: replacement.rawTranscript,
            postProcessedTranscript: replacement.postProcessedTranscript,
            postProcessingPrompt: replacement.postProcessingPrompt,
            systemPrompt: systemPrompt,
            contextSummary: contextSummary,
            contextSystemPrompt: contextSystemPrompt,
            contextPrompt: contextPrompt,
            contextScreenshotDataURL: contextScreenshotDataURL,
            contextScreenshotStatus: contextScreenshotStatus,
            postProcessingStatus: replacement.postProcessingStatus,
            aiProcessingOutcome: replacement.aiProcessingOutcome,
            debugStatus: replacement.debugStatus,
            customVocabulary: replacement.customVocabulary,
            customSystemPrompt: replacement.customSystemPrompt,
            audioFileName: audioFileName,
            usedLocalTranscription: replacement.usedLocalTranscription,
            usedContextCapture: usedContextCapture,
            usedPostProcessing: replacement.usedPostProcessing,
            transcriptionLanguageCode: replacement.transcriptionLanguageCode,
            spokenLanguageCode: replacement.spokenLanguage?.languageCode,
            spokenLanguageResolution: replacement.spokenLanguage?.source,
            meetingSummaryAttempt: meetingSummaryAttempt,
            localTranscriptionModelID: replacement.localTranscriptionModelID,
            transcriptFileName: replacement.transcriptFileName,
            contextAppName: contextAppName,
            contextBundleIdentifier: contextBundleIdentifier,
            contextWindowTitle: contextWindowTitle,
            customTitle: customTitle,
            meetingSummaryJSON: meetingSummaryJSON,
            deletedAt: deletedAt,
            fieldClock: fieldClock
        )
    }

    func replacingAssetFileNames(
        audioFileName: String?,
        transcriptFileName: String?
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            intent: intent,
            selectedText: selectedText,
            capturedSelection: capturedSelection,
            id: id,
            timestamp: timestamp,
            recordingStartedAt: recordingStartedAt,
            recordingEndedAt: recordingEndedAt,
            calendarMatch: calendarMatch,
            rawTranscript: rawTranscript,
            postProcessedTranscript: postProcessedTranscript,
            postProcessingPrompt: postProcessingPrompt,
            systemPrompt: systemPrompt,
            contextSummary: contextSummary,
            contextSystemPrompt: contextSystemPrompt,
            contextPrompt: contextPrompt,
            contextScreenshotDataURL: contextScreenshotDataURL,
            contextScreenshotStatus: contextScreenshotStatus,
            postProcessingStatus: postProcessingStatus,
            aiProcessingOutcome: aiProcessingOutcome,
            debugStatus: debugStatus,
            customVocabulary: customVocabulary,
            customSystemPrompt: customSystemPrompt,
            audioFileName: audioFileName,
            usedLocalTranscription: usedLocalTranscription,
            usedContextCapture: usedContextCapture,
            usedPostProcessing: usedPostProcessing,
            transcriptionLanguageCode: transcriptionLanguageCode,
            localTranscriptionModelID: localTranscriptionModelID,
            transcriptFileName: transcriptFileName,
            contextAppName: contextAppName,
            contextBundleIdentifier: contextBundleIdentifier,
            contextWindowTitle: contextWindowTitle,
            customTitle: customTitle,
            meetingSummaryJSON: meetingSummaryJSON,
            deletedAt: deletedAt,
            fieldClock: fieldClock
        )
    }

    func isLogicallyEquivalentForHistoryRecovery(to other: PipelineHistoryItem) -> Bool {
        guard id == other.id else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Deletion and the field clock are bookkeeping, not note content.
        let normalized = replacingAssetFileNames(audioFileName: nil, transcriptFileName: nil)
            .withoutSyncBookkeeping()
        let otherNormalized = other.replacingAssetFileNames(
            audioFileName: nil,
            transcriptFileName: nil
        ).withoutSyncBookkeeping()
        guard let normalizedData = try? encoder.encode(normalized),
              let otherData = try? encoder.encode(otherNormalized) else {
            return false
        }
        return normalizedData == otherData
    }

    private func withoutSyncBookkeeping() -> PipelineHistoryItem {
        var copy = self
        copy.deletedAt = nil
        copy.fieldClock = nil
        return copy
    }

    func normalizedAfterProcessInterruption() -> PipelineHistoryItem {
        guard postProcessingStatus != Self.cloudTranscribingStatus,
              isIncompleteTranscription else {
            return self
        }
        return markInterruptedBeforeCompletion()
    }

    func markInterruptedBeforeCompletion() -> PipelineHistoryItem {
        let recoveryContext = RecoveredRecordingContext.placeholderContext(
            for: postProcessingStatus
        )
        return PipelineHistoryItem(
            intent: intent,
            selectedText: selectedText,
            capturedSelection: capturedSelection,
            id: id,
            timestamp: timestamp,
            recordingStartedAt: recordingStartedAt,
            recordingEndedAt: recordingEndedAt,
            calendarMatch: calendarMatch,
            rawTranscript: rawTranscript,
            postProcessedTranscript: postProcessedTranscript,
            postProcessingPrompt: postProcessingPrompt,
            systemPrompt: systemPrompt,
            contextSummary: contextSummary,
            contextSystemPrompt: contextSystemPrompt,
            contextPrompt: contextPrompt,
            contextScreenshotDataURL: contextScreenshotDataURL,
            contextScreenshotStatus: contextScreenshotStatus,
            postProcessingStatus: recoveryContext?.recoveredStatus
                ?? "Error: Interrupted before transcription completed",
            aiProcessingOutcome: aiProcessingOutcome,
            debugStatus: recoveryContext?.mode.recoveredDebugStatus
                ?? "Interrupted before completion",
            customVocabulary: customVocabulary,
            customSystemPrompt: customSystemPrompt,
            audioFileName: audioFileName,
            usedLocalTranscription: usedLocalTranscription,
            usedContextCapture: usedContextCapture,
            usedPostProcessing: usedPostProcessing,
            transcriptionLanguageCode: transcriptionLanguageCode,
            spokenLanguageCode: spokenLanguageCode,
            spokenLanguageResolution: spokenLanguageResolution,
            meetingSummaryAttempt: meetingSummaryAttempt,
            localTranscriptionModelID: localTranscriptionModelID,
            transcriptFileName: transcriptFileName,
            contextAppName: contextAppName,
            contextBundleIdentifier: contextBundleIdentifier,
            contextWindowTitle: contextWindowTitle,
            customTitle: customTitle,
            meetingSummaryJSON: meetingSummaryJSON,
            deletedAt: deletedAt,
            fieldClock: fieldClock
        )
    }
}
