import Foundation

enum PipelineHistoryItemIntent: String, Codable {
    case dictation
    case commandAutomatic = "command:automatic"
    case commandManual = "command:manual"
}

struct PipelineHistoryItem: Identifiable, Codable {
    static let transcriptionRecoveryPlaceholderStatus =
        RecoveredRecordingMode.complete.placeholderStatus
    static let recoveredRecordingStatus =
        RecoveredRecordingMode.complete.recoveredStatus

    var recoveredRecordingContext: RecoveredRecordingContext? {
        RecoveredRecordingContext.recoveredContext(for: postProcessingStatus)
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

    var isIncompleteTranscription: Bool {
        RecoveredRecordingContext.placeholderContext(for: postProcessingStatus) != nil
            || postProcessingStatus == "importing"
            || postProcessingStatus == "live-recording"
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
    let debugStatus: String
    let customVocabulary: String
    let customSystemPrompt: String
    let audioFileName: String?
    let usedLocalTranscription: Bool
    let usedContextCapture: Bool
    let usedPostProcessing: Bool
    let transcriptionLanguageCode: String
    let localTranscriptionModelID: String
    let transcriptFileName: String?
    let contextAppName: String?
    let contextBundleIdentifier: String?
    let contextWindowTitle: String?
    let customTitle: String?

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
        debugStatus: String,
        customVocabulary: String,
        customSystemPrompt: String = "",
        audioFileName: String? = nil,
        usedLocalTranscription: Bool = false,
        usedContextCapture: Bool = true,
        usedPostProcessing: Bool = true,
        transcriptionLanguageCode: String = "auto",
        localTranscriptionModelID: String? = nil,
        transcriptFileName: String? = nil,
        contextAppName: String? = nil,
        contextBundleIdentifier: String? = nil,
        contextWindowTitle: String? = nil,
        customTitle: String? = nil
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
        self.debugStatus = debugStatus
        self.customVocabulary = customVocabulary
        self.customSystemPrompt = customSystemPrompt
        self.audioFileName = audioFileName
        self.usedLocalTranscription = usedLocalTranscription
        self.usedContextCapture = usedContextCapture
        self.usedPostProcessing = usedPostProcessing
        self.transcriptionLanguageCode = transcriptionLanguageCode
        self.localTranscriptionModelID = localTranscriptionModelID ?? "mlx-community/whisper-large-v3-turbo"
        self.transcriptFileName = transcriptFileName
        self.contextAppName = contextAppName
        self.contextBundleIdentifier = contextBundleIdentifier
        self.contextWindowTitle = contextWindowTitle
        self.customTitle = customTitle
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
        interruptionReason: RecordingInterruptionReason? = nil
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
            postProcessingStatus: recoveryContext.placeholderStatus,
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

    func withCustomTitle(_ customTitle: String?) -> PipelineHistoryItem {
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
            customTitle: customTitle
        )
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
            debugStatus: recoveryContext?.mode.recoveredDebugStatus
                ?? "Interrupted before completion",
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
            customTitle: customTitle
        )
    }
}
