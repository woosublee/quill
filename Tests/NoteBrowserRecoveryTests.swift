import Foundation

@main
struct NoteBrowserRecoveryTests {
    static func main() throws {
        testActionStateSeparatesAssetsFromRetryReadiness()
        testModelSetupPresentationOpensSettings()
        testModelSelectionPresentationOpensSettings()
        testProviderConfigurationPresentationOpensProviderSettings()
        testReadyMissingModelSwitchesToRetry()
        testMissingAudioKeepsGenericIssuePresentation()
        testLocalTranscriptionFailedHidesDebugDetails()
        print("NoteBrowserRecoveryTests passed")
    }

    private static func testActionStateSeparatesAssetsFromRetryReadiness() {
        let unavailable = NoteBrowserActionState(
            hasStoredAudio: true,
            transcript: "",
            retryAvailability: .needsModelSetup
        )
        precondition(unavailable.showsRetryButton)
        precondition(!unavailable.canCopy)
        precondition(unavailable.canSaveFiles)

        let transcriptOnly = NoteBrowserActionState(
            hasStoredAudio: false,
            transcript: " transcript ",
            retryAvailability: .noAudio
        )
        precondition(!transcriptOnly.showsRetryButton)
        precondition(transcriptOnly.canCopy)
        precondition(transcriptOnly.canSaveFiles)
    }

    private static func testModelSetupPresentationOpensSettings() {
        let state = NoteBrowserActionState(
            hasStoredAudio: true,
            transcript: "",
            retryAvailability: .needsModelSetup
        )
        let presentation = NoteBrowserRecoveryPresentation.presentation(
            for: QuillUserIssueRecord(
                code: .localModelMissing,
                context: QuillUserIssueContext(
                    modelID: "removed-model",
                    localBackend: "native-whisper"
                )
            ),
            actionState: state,
            language: "en",
            bundle: .main
        )

        precondition(presentation.title == "Set up a model for retranscription")
        precondition(presentation.body == "Your recording is safely stored.")
        precondition(presentation.suggestion.isEmpty)
        precondition(presentation.detailsRows.isEmpty)
        precondition(presentation.recoveryAction == .openModelsSettings)
    }

    private static func testModelSelectionPresentationOpensSettings() {
        let state = NoteBrowserActionState(
            hasStoredAudio: true,
            transcript: "",
            retryAvailability: .needsModelSelection
        )
        let presentation = NoteBrowserRecoveryPresentation.presentation(
            for: QuillUserIssueRecord(code: .localModelMissing),
            actionState: state,
            language: "en",
            bundle: .main
        )

        precondition(presentation.title == "Choose a model for retranscription")
        precondition(presentation.body == "Your recording is safely stored.")
        precondition(presentation.suggestion.isEmpty)
        precondition(presentation.detailsRows.isEmpty)
        precondition(presentation.recoveryAction == .openModelsSettings)
    }

    private static func testProviderConfigurationPresentationOpensProviderSettings() {
        let state = NoteBrowserActionState(
            hasStoredAudio: true,
            transcript: "",
            retryAvailability: .needsProviderConfiguration
        )
        let presentation = NoteBrowserRecoveryPresentation.presentation(
            for: QuillUserIssueRecord(code: .localModelMissing),
            actionState: state,
            language: "en",
            bundle: .main
        )

        precondition(presentation.title == "Add an API key to retry transcription")
        precondition(presentation.body == "Your recording is safely stored.")
        precondition(presentation.suggestion.isEmpty)
        precondition(presentation.detailsRows.isEmpty)
        precondition(presentation.recoveryAction == .openProviderSettings)
    }

    private static func testReadyMissingModelSwitchesToRetry() {
        let state = NoteBrowserActionState(
            hasStoredAudio: true,
            transcript: "",
            retryAvailability: .ready
        )
        let presentation = NoteBrowserRecoveryPresentation.presentation(
            for: QuillUserIssueRecord(
                code: .localModelMissing,
                context: QuillUserIssueContext(
                    modelID: "removed-model",
                    localBackend: "native-whisper"
                )
            ),
            actionState: state,
            language: "en",
            bundle: .main
        )

        precondition(presentation.title == "Ready to retry transcription")
        precondition(presentation.detailsRows.isEmpty)
        precondition(presentation.recoveryAction == .retryTranscription)
        precondition(presentation.severity == .warning)
    }

    private static func testMissingAudioKeepsGenericIssuePresentation() {
        let record = QuillUserIssueRecord(code: .localModelMissing)
        let state = NoteBrowserActionState(
            hasStoredAudio: false,
            transcript: "",
            retryAvailability: .noAudio
        )
        let presentation = NoteBrowserRecoveryPresentation.presentation(
            for: record,
            actionState: state,
            language: "en",
            bundle: .main
        )

        precondition(presentation.title == record.presentation(language: "en").title)
        precondition(presentation.recoveryAction == .openModelsSettings)
    }

    private static func testLocalTranscriptionFailedHidesDebugDetails() {
        let record = QuillUserIssueRecord(
            code: .localTranscriptionFailed,
            context: QuillUserIssueContext(
                modelID: "whisper-large-v3-turbo",
                localBackend: "Apple Speech"
            )
        )
        let original = record.presentation(language: "en")
        precondition(!original.detailsRows.isEmpty, "precondition: original issue has debug details")

        let state = NoteBrowserActionState(
            hasStoredAudio: true,
            transcript: "",
            retryAvailability: .ready
        )
        let presentation = NoteBrowserRecoveryPresentation.presentation(
            for: record,
            actionState: state,
            language: "en",
            bundle: .main
        )

        precondition(presentation.title == original.title)
        precondition(presentation.body == original.body)
        precondition(presentation.suggestion == original.suggestion)
        precondition(presentation.detailsRows.isEmpty)
        precondition(presentation.recoveryAction == original.recoveryAction)
    }
}
