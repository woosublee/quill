import Foundation
import QuillNoteCore
import QuillUserIssueCore

/// How both apps read a note's post-processing status (QuillNoteCore): what
/// state the note is in, whether its transcription is still to come, and
/// whether an empty transcript keeps its editor. Synthetic statuses only.
@main
struct NoteMachineStatusTests {
    static func main() throws {
        testWorkTokens()
        testInterruptedTranscription()
        testTranscriptionPlaceholderCheck()
        testRecoveredRecording()
        testUnrecoveredRecording()
        try testUserIssues()
        testCompleted()
        testStatusesRoundTrip()
        print("NoteMachineStatusTests passed")
    }

    private static func status(_ value: String) -> NoteMachineStatus {
        NoteMachineStatus(postProcessingStatus: value)
    }

    private static func incomplete(_ value: String) -> Bool {
        NoteMachineStatus.isIncompleteTranscription(postProcessingStatus: value)
    }

    private static func keepsEditor(_ value: String) -> Bool {
        NoteMachineStatus.keepsTranscriptEditorWhenEmpty(postProcessingStatus: value)
    }

    private static func testWorkTokens() {
        precondition(status("importing") == .importing)
        precondition(status("live-recording") == .liveRecording)
        precondition(status("cloud-transcribing") == .cloudTranscribing)
        precondition(status("audio-only") == .audioOnly)
        for token in ["importing", "live-recording", "cloud-transcribing"] {
            precondition(incomplete(token), "\(token) has no transcript yet")
            precondition(!keepsEditor(token), "\(token) keeps its empty state")
        }
        precondition(!incomplete("audio-only"), "audio-only is a finished recording-only note")
        precondition(!keepsEditor("audio-only"), "audio-only shows its own empty state")

        // Only the exact tokens count.
        for near in ["Importing", "importing:", "live-recording ", "cloud-transcribing:x", "audio-only:partial"] {
            precondition(status(near) == .completed, "\(near) is not a work token")
            precondition(!incomplete(near))
            precondition(keepsEditor(near))
        }
    }

    private static func testInterruptedTranscription() {
        let complete = "transcription-interrupted"
        precondition(
            RecoveredRecordingContext.placeholderContext(for: complete)
                == RecoveredRecordingContext(mode: .complete, interruptionReason: nil)
        )
        for value in [
            complete,
            "transcription-interrupted:microphone-only",
            "transcription-interrupted:system-audio-only",
            "transcription-interrupted:partial",
            "transcription-interrupted:storage-full",
            "transcription-interrupted:permission-denied:partial",
            "transcription-interrupted:journal-io-failure:microphone-only",
        ] {
            precondition(RecoveredRecordingContext.placeholderContext(for: value) != nil, value)
            precondition(status(value) == .completed, "an interrupted transcription reads as completed")
            precondition(incomplete(value), "\(value) waits for transcription")
            precondition(!keepsEditor(value), "\(value) keeps its empty state")
        }
        precondition(
            RecoveredRecordingContext.placeholderContext(
                for: "transcription-interrupted:storage-full:system-audio-only"
            ) == RecoveredRecordingContext(mode: .systemAudioOnly, interruptionReason: .storageFull)
        )

        // Malformed forms are not interruptions, so the note is completed
        // and editable, as on the Mac before the move.
        for value in [
            "transcription-interrupted:",
            "transcription-interrupted:complete",
            "transcription-interrupted:storage-full:complete",
            "transcription-interrupted:storage-full:",
            "transcription-interrupted::partial",
            "transcription-interrupted:unknown",
            "transcription-interrupted:partial:storage-full",
            "transcription-interrupted:storage-full:partial:extra",
            "transcription-interruptedx",
        ] {
            precondition(RecoveredRecordingContext.placeholderContext(for: value) == nil, value)
            precondition(status(value) == .completed, value)
            precondition(!incomplete(value), value)
            precondition(keepsEditor(value), value)
        }
    }

    /// #720: `isTranscriptionPlaceholder` is the one placeholder check. It
    /// must say exactly what the parse said before it existed, for every
    /// form, every malformed form, and every other status, and
    /// `isIncompleteTranscription` must not change.
    private static func testTranscriptionPlaceholderCheck() {
        func placeholder(_ value: String) -> Bool {
            NoteMachineStatus.isTranscriptionPlaceholder(postProcessingStatus: value)
        }
        // What `isIncompleteTranscription` read before #720.
        func incompleteBefore(_ value: String) -> Bool {
            RecoveredRecordingContext.placeholderContext(for: value) != nil
                || value == "importing"
                || value == "live-recording"
                || value == "cloud-transcribing"
        }

        let reasons: [RecordingInterruptionReason?] = [nil] + RecordingInterruptionReason.allCases
        var placeholders: [String] = []
        for reason in reasons {
            for mode in RecoveredRecordingMode.allCases {
                placeholders.append(
                    RecoveredRecordingContext(mode: mode, interruptionReason: reason)
                        .placeholderStatus
                )
            }
        }
        // 4 reasons (none + 3) x 4 modes, all distinct.
        precondition(Set(placeholders).count == 16)
        precondition(placeholders.contains("transcription-interrupted"))
        precondition(placeholders.contains("transcription-interrupted:journal-io-failure:system-audio-only"))

        let malformed = [
            "transcription-interrupted:",
            "transcription-interrupted:complete",
            "transcription-interrupted:storage-full:complete",
            "transcription-interrupted:storage-full:",
            "transcription-interrupted::partial",
            "transcription-interrupted:unknown",
            "transcription-interrupted:partial:storage-full",
            "transcription-interrupted:partial:microphone-only",
            "transcription-interrupted:storage-full:permission-denied",
            "transcription-interrupted:storage-full:partial:extra",
            "transcription-interruptedx",
            "Transcription-interrupted",
            " transcription-interrupted",
            "transcription-interrupted ",
            "transcription-interrupted:Partial",
        ]
        let others = [
            "", "importing", "live-recording", "cloud-transcribing", "audio-only",
            "succeeded", "Post-processing succeeded", "Error: synthetic failure",
            "user-issue:", "user-issue:v1:!!",
            "recording-recovered", "recording-recovered:partial",
            "recording-recovered:storage-full:microphone-only",
            "recording-unrecovered:no-audio", "recording-unrecovered:recovery-failed:save-error",
        ]

        for value in placeholders {
            precondition(placeholder(value), "\(value) is a placeholder")
        }
        for value in malformed + others {
            precondition(!placeholder(value), "\(value) is not a placeholder")
        }
        for value in placeholders + malformed + others {
            let parsed = RecoveredRecordingContext.placeholderContext(for: value)
            precondition(placeholder(value) == (parsed != nil), value)
            precondition(
                RecoveredRecordingMode.placeholderMode(for: value) == parsed?.mode,
                "placeholderMode reads the same parse: \(value)"
            )
            precondition(incomplete(value) == incompleteBefore(value), "no change: \(value)")
        }
    }

    private static func testRecoveredRecording() {
        let cases: [(String, RecoveredRecordingContext)] = [
            ("recording-recovered", .init(mode: .complete, interruptionReason: nil)),
            ("recording-recovered:microphone-only", .init(mode: .microphoneOnly, interruptionReason: nil)),
            ("recording-recovered:system-audio-only", .init(mode: .systemAudioOnly, interruptionReason: nil)),
            ("recording-recovered:partial", .init(mode: .partial, interruptionReason: nil)),
            ("recording-recovered:storage-full", .init(mode: .complete, interruptionReason: .storageFull)),
            ("recording-recovered:permission-denied:partial", .init(mode: .partial, interruptionReason: .permissionDenied)),
            ("recording-recovered:journal-io-failure:microphone-only", .init(mode: .microphoneOnly, interruptionReason: .journalIOFailure)),
        ]
        for (value, context) in cases {
            precondition(status(value) == .recovered(context), value)
            precondition(!incomplete(value), "a recovered recording isn't being transcribed")
            precondition(!keepsEditor(value), "a recovered recording shows its recovery state")
            precondition(context.recoveredStatus == value, "\(value) encodes back the same")
        }
        for value in [
            "recording-recovered:",
            "recording-recovered:complete",
            "recording-recovered:storage-full:complete",
            "recording-recovered:storage-full:partial:extra",
            "recording-recovered:unknown",
            "recording-recovered::",
        ] {
            precondition(status(value) == .completed, value)
            precondition(keepsEditor(value), value)
        }
    }

    private static func testUnrecoveredRecording() {
        let cases: [(String, UnrecoveredRecordingContext)] = [
            ("recording-unrecovered:no-audio", .init(kind: .noAudio, cause: nil)),
            ("recording-unrecovered:recovery-failed", .init(kind: .recoveryFailed, cause: nil)),
            ("recording-unrecovered:no-audio:storage-full", .init(kind: .noAudio, cause: .storageFull)),
            ("recording-unrecovered:recovery-failed:storage-unavailable", .init(kind: .recoveryFailed, cause: .storageUnavailable)),
            ("recording-unrecovered:recovery-failed:save-error", .init(kind: .recoveryFailed, cause: .saveError)),
        ]
        for (value, context) in cases {
            precondition(status(value) == .unrecovered(context), value)
            precondition(!incomplete(value))
            precondition(!keepsEditor(value))
            precondition(context.status == value, "\(value) encodes back the same")
        }
        for value in [
            "recording-unrecovered",
            "recording-unrecovered:",
            "recording-unrecovered:unknown",
            "recording-unrecovered:no-audio:",
            "recording-unrecovered:no-audio:permission-denied",
            "recording-unrecovered:no-audio:storage-full:extra",
        ] {
            precondition(status(value) == .completed, value)
            precondition(keepsEditor(value), value)
        }
        precondition(UnrecoveredRecordingCause(interruptionReason: .storageFull) == .storageFull)
        precondition(UnrecoveredRecordingCause(interruptionReason: .permissionDenied) == .storageUnavailable)
        precondition(UnrecoveredRecordingCause(interruptionReason: .journalIOFailure) == .saveError)
    }

    private static func testUserIssues() throws {
        let error = QuillUserIssueRecord(code: .unknown, severity: .error)
        let errorStatus = try error.encodedStatus()
        precondition(status(errorStatus) == .failed(error))
        precondition(NoteMachineStatus.userIssueRecord(postProcessingStatus: errorStatus) == error)
        precondition(!incomplete(errorStatus))
        precondition(!keepsEditor(errorStatus), "a failed note shows its issue")

        let warning = QuillUserIssueRecord(code: .unknown, severity: .warning)
        let warningStatus = try warning.encodedStatus()
        precondition(status(warningStatus) == .completed, "a warning does not fail the note")
        precondition(NoteMachineStatus.userIssueRecord(postProcessingStatus: warningStatus) == warning)
        precondition(keepsEditor(warningStatus), "a warned note is finished and editable")

        // An unreadable issue status is an unknown error.
        for value in ["user-issue:", "user-issue:v1:", "user-issue:v1:!!", "user-issue:v99:abc", "user-issue:x"] {
            let unknown = QuillUserIssueRecord(code: .unknown)
            precondition(NoteMachineStatus.userIssueRecord(postProcessingStatus: value) == unknown, value)
            precondition(status(value) == .failed(unknown), "\(value) fails the note")
            precondition(!keepsEditor(value), value)
        }

        let legacy = QuillUserIssueRecord(code: .legacy)
        precondition(NoteMachineStatus.userIssueRecord(postProcessingStatus: "Error: synthetic failure") == legacy)
        precondition(status("Error: synthetic failure") == .failed(legacy), "an old error status fails the note")
        precondition(!keepsEditor("Error: synthetic failure"))
        precondition(NoteMachineStatus.userIssueRecord(postProcessingStatus: "error: lower case") == nil)
        precondition(NoteMachineStatus.userIssueRecord(postProcessingStatus: " Error: leading space") == nil)
    }

    private static func testCompleted() {
        for value in ["", "succeeded", "Post-processing succeeded", "ok", "Skipped"] {
            precondition(status(value) == .completed, value)
            precondition(NoteMachineStatus.userIssueRecord(postProcessingStatus: value) == nil, value)
            precondition(!incomplete(value), value)
            precondition(keepsEditor(value), "a finished note keeps its editor when cleared")
        }
    }

    private static func testStatusesRoundTrip() {
        precondition(NoteMachineStatus.importingStatus == "importing")
        precondition(NoteMachineStatus.liveRecordingStatus == "live-recording")
        precondition(NoteMachineStatus.cloudTranscribingStatus == "cloud-transcribing")
        precondition(NoteMachineStatus.audioOnlyStatus == "audio-only")
        precondition(UnrecoveredRecordingContext.statusPrefix == "recording-unrecovered")
        precondition(RecoveredRecordingMode.complete.placeholderStatus == "transcription-interrupted")
        precondition(RecoveredRecordingMode.partial.placeholderStatus == "transcription-interrupted:partial")
        precondition(RecoveredRecordingMode.complete.recoveredStatus == "recording-recovered")
        precondition(RecoveredRecordingMode.systemAudioOnly.recoveredStatus == "recording-recovered:system-audio-only")
        precondition(RecoveredRecordingMode.placeholderMode(for: "transcription-interrupted:microphone-only") == .microphoneOnly)
        precondition(RecoveredRecordingMode.recoveredMode(for: "recording-recovered:partial") == .partial)
        precondition(RecoveredRecordingMode.recoveredMode(for: "transcription-interrupted") == nil)

        for reason in RecordingInterruptionReason.allCases {
            for mode in RecoveredRecordingMode.allCases {
                let context = RecoveredRecordingContext(mode: mode, interruptionReason: reason)
                precondition(RecoveredRecordingContext.placeholderContext(for: context.placeholderStatus) == context)
                precondition(RecoveredRecordingContext.recoveredContext(for: context.recoveredStatus) == context)
            }
        }
    }
}
