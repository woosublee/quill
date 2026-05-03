import Foundation

@main
struct TranscriptionRecoveryPlaceholderTests {
    static func main() {
        testPlaceholderKeepsSavedAudioReferenceForRetryAfterInterruption()
        testInterruptedPlaceholderBecomesFailedButKeepsAudioReference()
        testImportingItemIsIncompleteAndBecomesFailedButKeepsAudioReference()
        testLiveRecordingItemIsIncompleteAndBecomesFailedWithoutRetryAudio()
        testCompletedItemIsNotIncomplete()
        print("TranscriptionRecoveryPlaceholderTests passed")
    }

    private static func testPlaceholderKeepsSavedAudioReferenceForRetryAfterInterruption() {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

        let item = PipelineHistoryItem.transcriptionRecoveryPlaceholder(
            id: id,
            timestamp: timestamp,
            intent: .commandManual,
            selectedText: "original text",
            capturedSelection: "captured text",
            contextSummary: "Editing Notes",
            contextSystemPrompt: "context system",
            contextPrompt: "context prompt",
            contextScreenshotDataURL: "data:image/jpeg;base64,abc",
            contextScreenshotStatus: "available (image/jpeg)",
            systemPrompt: "system",
            customVocabulary: "terms",
            customSystemPrompt: "custom",
            audioFileName: "recording.wav",
            usedLocalTranscription: true,
            usedContextCapture: true,
            usedPostProcessing: false,
            transcriptionLanguageCode: "ko",
            localTranscriptionModelID: "local-model",
            contextAppName: "Notes",
            contextBundleIdentifier: "com.apple.Notes",
            contextWindowTitle: "Daily"
        )

        assert(item.id == id)
        assert(item.timestamp == timestamp)
        assert(item.intent == .commandManual)
        assert(item.selectedText == "original text")
        assert(item.capturedSelection == "captured text")
        assert(item.audioFileName == "recording.wav")
        assert(item.postProcessingStatus == PipelineHistoryItem.transcriptionRecoveryPlaceholderStatus)
        assert(item.debugStatus == "Transcription interrupted before completion")
        assert(item.rawTranscript.isEmpty)
        assert(item.postProcessedTranscript.isEmpty)
        assert(item.usedLocalTranscription)
        assert(item.usedPostProcessing == false)
        assert(item.transcriptionLanguageCode == "ko")
        assert(item.localTranscriptionModelID == "local-model")
        assert(item.contextAppName == "Notes")
        assert(item.contextBundleIdentifier == "com.apple.Notes")
        assert(item.contextWindowTitle == "Daily")
    }

    private static func testImportingItemIsIncompleteAndBecomesFailedButKeepsAudioReference() {
        let item = makeHistoryItem(postProcessingStatus: "importing", audioFileName: "imported.m4a")

        let interrupted = item.markInterruptedBeforeCompletion()

        assert(item.isIncompleteTranscription)
        assert(interrupted.audioFileName == "imported.m4a")
        assert(interrupted.postProcessingStatus == "Error: Interrupted before transcription completed")
        assert(interrupted.debugStatus == "Interrupted before completion")
    }

    private static func testLiveRecordingItemIsIncompleteAndBecomesFailedWithoutRetryAudio() {
        let item = makeHistoryItem(postProcessingStatus: "live-recording", audioFileName: nil)

        let interrupted = item.markInterruptedBeforeCompletion()

        assert(item.isIncompleteTranscription)
        assert(interrupted.audioFileName == nil)
        assert(interrupted.postProcessingStatus == "Error: Interrupted before transcription completed")
        assert(interrupted.debugStatus == "Interrupted before completion")
    }

    private static func testCompletedItemIsNotIncomplete() {
        let item = makeHistoryItem(postProcessingStatus: "Post-processing succeeded", audioFileName: "recording.wav")

        assert(!item.isIncompleteTranscription)
    }

    private static func makeHistoryItem(postProcessingStatus: String, audioFileName: String?) -> PipelineHistoryItem {
        PipelineHistoryItem(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            rawTranscript: "raw",
            postProcessedTranscript: "final",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: postProcessingStatus,
            debugStatus: "",
            customVocabulary: "",
            audioFileName: audioFileName,
            usedContextCapture: false
        )
    }

    private static func testInterruptedPlaceholderBecomesFailedButKeepsAudioReference() {
        let item = PipelineHistoryItem.transcriptionRecoveryPlaceholder(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            intent: .dictation,
            selectedText: nil,
            capturedSelection: nil,
            contextSummary: "",
            contextSystemPrompt: nil,
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            systemPrompt: nil,
            customVocabulary: "",
            customSystemPrompt: "",
            audioFileName: "recording.wav",
            usedLocalTranscription: false,
            usedContextCapture: false,
            usedPostProcessing: true,
            transcriptionLanguageCode: "auto",
            localTranscriptionModelID: "mlx-community/whisper-large-v3-turbo",
            contextAppName: nil,
            contextBundleIdentifier: nil,
            contextWindowTitle: nil
        )

        let interrupted = item.markInterruptedBeforeCompletion()

        assert(interrupted.id == item.id)
        assert(interrupted.audioFileName == "recording.wav")
        assert(interrupted.postProcessingStatus == "Error: Interrupted before transcription completed")
        assert(interrupted.debugStatus == "Interrupted before completion")
        assert(interrupted.transcriptFileName == item.transcriptFileName)
    }
}
