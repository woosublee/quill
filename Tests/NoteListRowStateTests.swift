import Foundation
import QuillNoteCore
import QuillUserIssueCore

/// How both apps build a note list row from a note's synced status
/// (QuillNoteCore `NoteListRowState`): the status, dot, preview, badges, and
/// what VoiceOver reads. Synthetic statuses only.
@main
struct NoteListRowStateTests {
    static func main() {
        testSettledStatuses()
        testWorkingStatuses()
        testRetryWinsAndNamesTheStage()
        testStoppedCloudTranscriptionFails()
        testRecoveredPreviewKeepsItsContext()
        testBadgesAndAccessibility()
        testBulkSelection()
        print("NoteListRowStateTests passed")
    }

    private static func state(
        _ status: String,
        hasContent: Bool = false,
        hasSummary: Bool = false,
        isRetrying: Bool = false,
        isCloudTranscriptionStopped: Bool = false,
        isPostProcessing: Bool = false
    ) -> NoteListRowState {
        NoteListRowState(
            machineStatus: NoteMachineStatus(postProcessingStatus: status),
            isTranscriptionPlaceholder: NoteMachineStatus.isTranscriptionPlaceholder(
                postProcessingStatus: status
            ),
            hasContent: hasContent,
            hasSummary: hasSummary,
            isRetrying: isRetrying,
            isCloudTranscriptionStopped: isCloudTranscriptionStopped,
            isPostProcessing: isPostProcessing
        )
    }

    private static func testSettledStatuses() {
        let done = state("Post-processing disabled", hasContent: true)
        precondition(done.status == .done)
        precondition(done.dotRole == .done)
        precondition(done.preview == .content)
        precondition(done.statusKey == "Transcription complete")
        precondition(done.workStageKey == nil)

        let audioOnly = state(NoteMachineStatus.audioOnlyStatus)
        precondition(audioOnly.status == .audioOnly)
        precondition(audioOnly.dotRole == .done, "an audio-only note draws the done dot")
        precondition(audioOnly.preview == .key("Not transcribed"))
        precondition(audioOnly.statusKey == "Audio only")
        precondition(audioOnly.showsAudioOnlyBadge)

        let failed = state(QuillUserIssueRecord(code: .unknown).persistedStatus)
        precondition(failed.status == .fail)
        precondition(failed.dotRole == .failure)
        precondition(failed.preview == .key("Couldn't transcribe"))
        precondition(failed.statusKey == "Transcription failed")
        precondition(!failed.isUnrecoveredRecording)
        precondition(!failed.showsAudioOnlyBadge)

        let legacy = state("Error: synthetic failure")
        precondition(legacy.status == .fail)

        // A warning issue is a finished note, not a failure.
        let warning = state(
            QuillUserIssueRecord(code: .postProcessingFailed).persistedStatus,
            hasContent: true
        )
        precondition(warning.status == .done)

        let unrecovered = state(
            UnrecoveredRecordingContext(kind: .noAudio, cause: nil).status
        )
        precondition(unrecovered.status == .fail)
        precondition(unrecovered.isUnrecoveredRecording)
        precondition(unrecovered.preview == .key("Couldn't recover"))
        precondition(unrecovered.statusKey == "Couldn't recover")

        let recovered = state(RecoveredRecordingMode.complete.recoveredStatus)
        precondition(recovered.status == .recovered)
        precondition(recovered.dotRole == .recovered)
        precondition(recovered.statusKey == "Recovered recording")
        precondition(!recovered.showsAudioOnlyBadge)
    }

    private static func testWorkingStatuses() {
        let recording = state(NoteMachineStatus.liveRecordingStatus)
        precondition(recording.status == .recording)
        precondition(recording.dotRole == .recording)
        precondition(recording.workStageKey == "Recording...")
        precondition(recording.preview == .key("Recording..."))

        let recordingWithText = state(NoteMachineStatus.liveRecordingStatus, hasContent: true)
        precondition(recordingWithText.workStageKey == nil, "live text shows instead of the stage")
        precondition(recordingWithText.preview == .content)
        precondition(recordingWithText.statusKey == "Recording...")

        for status in [
            NoteMachineStatus.importingStatus,
            NoteMachineStatus.cloudTranscribingStatus,
            RecoveredRecordingMode.complete.placeholderStatus,
            RecoveredRecordingMode.partial.placeholderStatus,
        ] {
            let row = state(status)
            precondition(row.status == .transcribing, status)
            precondition(row.dotRole == .processing, status)
            precondition(row.workStageKey == "Transcribing...", status)
            precondition(row.preview == .key("Transcribing..."), status)
        }

        let postProcessing = state("Post-processing disabled", isRetrying: true, isPostProcessing: true)
        precondition(postProcessing.workStageKey == "Post-processing...")
    }

    private static func testRetryWinsAndNamesTheStage() {
        let retriedDone = state("Post-processing disabled", hasContent: true, isRetrying: true)
        precondition(retriedDone.status == .transcribing)
        precondition(retriedDone.workStageKey == "Retranscribing...")

        let retriedFailure = state(QuillUserIssueRecord(code: .unknown).persistedStatus, isRetrying: true)
        precondition(retriedFailure.workStageKey == "Retranscribing...")

        // An audio-only note has never been transcribed, so it isn't "again".
        let firstTranscription = state(NoteMachineStatus.audioOnlyStatus, isRetrying: true)
        precondition(firstTranscription.status == .transcribing)
        precondition(firstTranscription.workStageKey == "Transcribing...")
        precondition(!firstTranscription.showsAudioOnlyBadge, "no badge while it transcribes")
    }

    private static func testStoppedCloudTranscriptionFails() {
        let stopped = state(NoteMachineStatus.cloudTranscribingStatus, isCloudTranscriptionStopped: true)
        precondition(stopped.status == .fail)
        precondition(stopped.preview == .key("Couldn't transcribe"))

        let retrying = state(
            NoteMachineStatus.cloudTranscribingStatus,
            isRetrying: true,
            isCloudTranscriptionStopped: true
        )
        precondition(retrying.status == .transcribing, "a retry wins over the stopped mark")

        // Only a cloud-transcribing note can be stopped.
        let finished = state("Post-processing disabled", hasContent: true, isCloudTranscriptionStopped: true)
        precondition(finished.status == .done)
    }

    private static func testRecoveredPreviewKeepsItsContext() {
        let context = RecoveredRecordingContext(
            mode: .microphoneOnly,
            interruptionReason: .storageFull
        )
        let row = state(context.recoveredStatus)
        precondition(row.preview == .recoveredRecording(context))

        // Both apps write the description from the same keys, joined with a space.
        precondition(RecoveredRecordingContext(mode: .complete, interruptionReason: nil).descriptionLocalizationKeys
            == ["Recovered after an unexpected shutdown. Not yet transcribed."])
        precondition(RecoveredRecordingContext(mode: .complete, interruptionReason: .storageFull).descriptionLocalizationKeys
            == [
                "Quill stopped recording because storage was full.",
                "Audio saved before the interruption is available for playback or transcription.",
            ])
        precondition(context.descriptionLocalizationKeys == [
            "Quill stopped recording because storage was full.",
            "System Audio could not be recovered. Microphone audio is available for playback or transcription.",
        ])
        precondition(RecoveredRecordingContext(mode: .partial, interruptionReason: nil).descriptionLocalizationKeys
            == ["Some parts of this recording may be missing. The recovered audio is available for playback or transcription."])
    }

    private static func testBadgesAndAccessibility() {
        let audioOnly = state(NoteMachineStatus.audioOnlyStatus, hasSummary: true)
        precondition(audioOnly.badgeKeys == ["Audio only", "Summary"])
        // The state already says "Audio only", so it is read once.
        precondition(audioOnly.accessibilityKeys == ["Audio only", "Summary"])

        let done = state("Post-processing disabled", hasContent: true, hasSummary: true)
        precondition(done.badgeKeys == ["Summary"])
        precondition(done.accessibilityKeys == ["Transcription complete", "Summary"])

        let working = state("Post-processing disabled", hasContent: true, isRetrying: true)
        precondition(working.badgeKeys.isEmpty)
        precondition(working.accessibilityKeys == ["Retranscribing..."])

        precondition(NoteListRowState.accessibilityKeys(
            status: .fail,
            isUnrecoveredRecording: true,
            hasSummary: false
        ) == ["Couldn't recover"])
    }

    private static func testBulkSelection() {
        precondition(NoteListRowStatus.done.isBulkSelectable)
        precondition(NoteListRowStatus.audioOnly.isBulkSelectable)
        precondition(NoteListRowStatus.recovered.isBulkSelectable)
        precondition(NoteListRowStatus.fail.isBulkSelectable)
        precondition(!NoteListRowStatus.recording.isBulkSelectable)
        precondition(!NoteListRowStatus.transcribing.isBulkSelectable)
    }
}
