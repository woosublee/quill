import Foundation

@main
struct NoteBrowserRecoveryTests {
    static func main() throws {
        testActionStateSeparatesAssetsFromRetryReadiness()
        testUnavailableMissingModelOpensSettings()
        testReadyMissingModelSwitchesToRetry()
        testMissingAudioKeepsGenericIssuePresentation()
        print("NoteBrowserRecoveryTests passed")
    }

    private static func testActionStateSeparatesAssetsFromRetryReadiness() {
        let unavailable = NoteBrowserActionState(
            hasStoredAudio: true,
            transcript: "",
            retryAvailability: .unavailable
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

    private static func testUnavailableMissingModelOpensSettings() {
        let state = NoteBrowserActionState(
            hasStoredAudio: true,
            transcript: "",
            retryAvailability: .unavailable
        )
        let presentation = NoteBrowserRecoveryPresentation.presentation(
            for: QuillUserIssueRecord(code: .localModelMissing),
            actionState: state,
            language: "en",
            bundle: .main
        )

        precondition(presentation.title == "A retranscription-capable model is required")
        precondition(presentation.body == "Your recording is safely stored.")
        precondition(presentation.recoveryAction == .openModelsSettings)
    }

    private static func testReadyMissingModelSwitchesToRetry() {
        let state = NoteBrowserActionState(
            hasStoredAudio: true,
            transcript: "",
            retryAvailability: .ready
        )
        let presentation = NoteBrowserRecoveryPresentation.presentation(
            for: QuillUserIssueRecord(code: .localModelMissing),
            actionState: state,
            language: "en",
            bundle: .main
        )

        precondition(presentation.title == "Ready to retry transcription")
        precondition(presentation.recoveryAction == .retryTranscription)
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
}
