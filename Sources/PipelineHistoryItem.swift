import Foundation

enum PipelineHistoryItemIntent: String, Codable {
    case dictation
    case commandAutomatic = "command:automatic"
    case commandManual = "command:manual"
}

struct PipelineHistoryItem: Identifiable, Codable {
    let intent: PipelineHistoryItemIntent
    let selectedText: String?
    let id: UUID
    let timestamp: Date
    let rawTranscript: String
    let postProcessedTranscript: String
    let postProcessingPrompt: String?
    let contextSummary: String
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

    init(
        intent: PipelineHistoryItemIntent = .dictation,
        selectedText: String? = nil,
        id: UUID = UUID(),
        timestamp: Date,
        rawTranscript: String,
        postProcessedTranscript: String,
        postProcessingPrompt: String?,
        contextSummary: String,
        contextPrompt: String?,
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
        localTranscriptionModelID: String = "mlx-community/whisper-large-v3-turbo",
        transcriptFileName: String? = nil
    ) {
        self.intent = intent
        self.selectedText = selectedText
        self.id = id
        self.timestamp = timestamp
        self.rawTranscript = rawTranscript
        self.postProcessedTranscript = postProcessedTranscript
        self.postProcessingPrompt = postProcessingPrompt
        self.contextSummary = contextSummary
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
        self.localTranscriptionModelID = localTranscriptionModelID
        self.transcriptFileName = transcriptFileName
    }
}
