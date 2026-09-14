import Foundation

@main
struct NoteBrowserRecoveryTests {
    static func main() throws {
        testActionStateSeparatesAssetsFromRetryReadiness()
        testSummaryOnlyEnablesFileSaving()
        testNoContentDisablesFileSaving()
        testModelSetupPresentationOpensSettings()
        testModelSelectionPresentationOpensSettings()
        testProviderConfigurationPresentationOpensProviderSettings()
        testReadyMissingModelSwitchesToRetry()
        testMissingAudioKeepsGenericIssuePresentation()
        testLocalTranscriptionFailedHidesDebugDetails()
        testPostProcessingDisabledHidesRetryGuidance()
        testPostProcessingEnabledKeepsRetryGuidance()
        testPostProcessingDisabledDoesNotAffectUnrelatedIssues()
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

    private static func testSummaryOnlyEnablesFileSaving() {
        let state = NoteBrowserActionState(
            hasStoredAudio: false,
            transcript: " \n ",
            retryAvailability: .noAudio,
            hasSummary: true
        )
        precondition(state.canSaveFiles)
        precondition(!state.canCopy)
        precondition(!state.showsRetryButton)
    }

    private static func testNoContentDisablesFileSaving() {
        let state = NoteBrowserActionState(
            hasStoredAudio: false,
            transcript: " \n ",
            retryAvailability: .noAudio
        )
        precondition(!state.canSaveFiles)
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

    // A historical post-processing warning must stop offering retry/cleanup
    // guidance once the user has disabled post-processing, since retrying
    // will intentionally skip cleanup. The warning stays informational.
    private static func testPostProcessingDisabledHidesRetryGuidance() {
        for code: QuillUserIssueCode in [
            .postProcessingFailed,
            .postProcessingRateLimited,
            .postProcessingGuardFallback,
            .postProcessingPayloadTooLarge
        ] {
            let record = QuillUserIssueRecord(code: code)
            let original = record.presentation(language: "en")
            let state = NoteBrowserActionState(
                hasStoredAudio: true,
                transcript: "kept transcript",
                retryAvailability: .ready,
                postProcessingEnabled: false
            )
            let presentation = NoteBrowserRecoveryPresentation.presentation(
                for: record,
                actionState: state,
                language: "en",
                bundle: .main
            )

            precondition(
                presentation.recoveryAction == .none,
                "\(code.rawValue) hides its action once post-processing is disabled"
            )
            precondition(
                presentation.title == original.title,
                "\(code.rawValue) keeps its informational title"
            )
            precondition(
                presentation.body == original.body,
                "\(code.rawValue) keeps its informational body"
            )
        }
    }

    private static func testPostProcessingEnabledKeepsRetryGuidance() {
        let record = QuillUserIssueRecord(code: .postProcessingFailed)
        let state = NoteBrowserActionState(
            hasStoredAudio: true,
            transcript: "",
            retryAvailability: .ready,
            postProcessingEnabled: true
        )
        let presentation = NoteBrowserRecoveryPresentation.presentation(
            for: record,
            actionState: state,
            language: "en",
            bundle: .main
        )

        precondition(
            presentation.recoveryAction == .retryTranscription,
            "retry guidance remains while post-processing is still enabled"
        )
    }

    private static func testPostProcessingDisabledDoesNotAffectUnrelatedIssues() {
        let record = QuillUserIssueRecord(code: .networkUnavailable)
        let state = NoteBrowserActionState(
            hasStoredAudio: true,
            transcript: "",
            retryAvailability: .ready,
            postProcessingEnabled: false
        )
        let presentation = NoteBrowserRecoveryPresentation.presentation(
            for: record,
            actionState: state,
            language: "en",
            bundle: .main
        )

        precondition(
            presentation.recoveryAction == .retryTranscription,
            "disabling post-processing does not suppress unrelated recovery actions"
        )
    }
}
