import Foundation

@main
struct TranscriptionRecoveryPlaceholderTests {
    static func main() {
        testPlaceholderKeepsSavedAudioReferenceForRetryAfterInterruption()
        testRecoveryModesPreserveStableStatusesAndAudio()
        testInterruptionReasonsPreserveStableStatusesAndAudio()
        testInterruptedPlaceholderBecomesRecoveredButKeepsAudioReference()
        testImportingItemIsIncompleteAndBecomesFailedButKeepsAudioReference()
        testLiveRecordingItemIsIncompleteAndBecomesFailedWithoutRetryAudio()
        testCloudTranscribingStatusIsTypedAndIncomplete()
        testCloudTranscribingPlaceholderIsNotNormalizedBeforeReconciliation()
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

    private static func testRecoveryModesPreserveStableStatusesAndAudio() {
        let cases: [(RecoveredRecordingMode, String, String)] = [
            (
                .complete,
                "transcription-interrupted",
                "recording-recovered"
            ),
            (
                .microphoneOnly,
                "transcription-interrupted:microphone-only",
                "recording-recovered:microphone-only"
            ),
            (
                .systemAudioOnly,
                "transcription-interrupted:system-audio-only",
                "recording-recovered:system-audio-only"
            ),
            (
                .partial,
                "transcription-interrupted:partial",
                "recording-recovered:partial"
            )
        ]
        for (mode, placeholderStatus, recoveredStatus) in cases {
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
                usedPostProcessing: false,
                transcriptionLanguageCode: "auto",
                localTranscriptionModelID: "local-model",
                contextAppName: nil,
                contextBundleIdentifier: nil,
                contextWindowTitle: nil,
                recoveryMode: mode
            )

            assert(item.postProcessingStatus == placeholderStatus)
            assert(item.isIncompleteTranscription)
            let recovered = item.markInterruptedBeforeCompletion()
            assert(recovered.postProcessingStatus == recoveredStatus)
            assert(recovered.isRecoveredRecording)
            assert(recovered.recoveredRecordingMode == mode)
            assert(recovered.audioFileName == "recording.wav")
        }
    }

    private static func testInterruptionReasonsPreserveStableStatusesAndAudio() {
        let cases: [(RecoveredRecordingContext, String, String)] = [
            (
                .init(mode: .complete, interruptionReason: .storageFull),
                "transcription-interrupted:storage-full",
                "recording-recovered:storage-full"
            ),
            (
                .init(mode: .partial, interruptionReason: .storageFull),
                "transcription-interrupted:storage-full:partial",
                "recording-recovered:storage-full:partial"
            ),
            (
                .init(mode: .microphoneOnly, interruptionReason: .permissionDenied),
                "transcription-interrupted:permission-denied:microphone-only",
                "recording-recovered:permission-denied:microphone-only"
            ),
            (
                .init(mode: .systemAudioOnly, interruptionReason: .journalIOFailure),
                "transcription-interrupted:journal-io-failure:system-audio-only",
                "recording-recovered:journal-io-failure:system-audio-only"
            )
        ]

        for (context, placeholderStatus, recoveredStatus) in cases {
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
                usedPostProcessing: false,
                transcriptionLanguageCode: "auto",
                localTranscriptionModelID: "local-model",
                contextAppName: nil,
                contextBundleIdentifier: nil,
                contextWindowTitle: nil,
                recoveryMode: context.mode,
                interruptionReason: context.interruptionReason
            )

            assert(item.postProcessingStatus == placeholderStatus)
            assert(item.isIncompleteTranscription)
            let recovered = item.markInterruptedBeforeCompletion()
            assert(recovered.postProcessingStatus == recoveredStatus)
            assert(recovered.recoveredRecordingContext == context)
            assert(recovered.recoveredRecordingMode == context.mode)
            assert(recovered.recordingInterruptionReason == context.interruptionReason)
            assert(recovered.audioFileName == "recording.wav")
        }

        assert(RecoveredRecordingContext.placeholderContext(
            for: "transcription-interrupted:storage-full:partial:extra"
        ) == nil)
        assert(RecoveredRecordingContext.recoveredContext(
            for: "recording-recovered:unknown"
        ) == nil)
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

    private static func testCloudTranscribingStatusIsTypedAndIncomplete() {
        let item = makeHistoryItem(
            postProcessingStatus: PipelineHistoryItem.cloudTranscribingStatus,
            audioFileName: "recording.wav"
        )

        assert(item.machineStatus == .cloudTranscribing)
        assert(item.isIncompleteTranscription)
        assert(!item.postProcessingStatus.hasPrefix("Error:"))
    }

    private static func testCloudTranscribingPlaceholderIsNotNormalizedBeforeReconciliation() {
        let item = makeHistoryItem(
            postProcessingStatus: PipelineHistoryItem.cloudTranscribingStatus,
            audioFileName: "recording.wav"
        )

        let normalized = item.normalizedAfterProcessInterruption()

        assert(normalized.postProcessingStatus == PipelineHistoryItem.cloudTranscribingStatus)
        assert(normalized.id == item.id)
        assert(normalized.audioFileName == item.audioFileName)
    }

    private static func testCompletedItemIsNotIncomplete() {
        let item = makeHistoryItem(postProcessingStatus: "Post-processing succeeded", audioFileName: "recording.wav")

        assert(!item.isIncompleteTranscription)
        assert(item.machineStatus == .completed)
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

    private static func testInterruptedPlaceholderBecomesRecoveredButKeepsAudioReference() {
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
        assert(interrupted.postProcessingStatus == PipelineHistoryItem.recoveredRecordingStatus)
        assert(interrupted.debugStatus == "Recovered after an unexpected shutdown; transcription has not started")
        assert(interrupted.isRecoveredRecording)
        assert(interrupted.transcriptFileName == item.transcriptFileName)
    }
}
