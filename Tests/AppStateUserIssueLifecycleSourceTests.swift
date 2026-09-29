import Foundation

@main
struct AppStateUserIssueLifecycleSourceTests {
    static func main() throws {
        let source = try String(
            contentsOfFile: "Sources/AppState.swift",
            encoding: .utf8
        )

        try testImportPersistsVersionedIssuesAndRetryUsesSafeAdapterPresentation(source)
        try testRetryWorkflowPersistedEffectsDriveWarningInvalidation(source)
        try testStoppedRecordingPersistsAndPresentsOneIssue(source)
        try testPostProcessingFallbackPersistsWarningRecord(source)
        try testCorePreparationAndSaveFailuresUseSafePresentation(source)
        try testAudioInputSwitchFailureUsesSafePresentation(source)
        try testResolveRawTranscriptBoundsRealtimeCommitWait(source)
        try testScopedFlowsDoNotPersistRawLocalizedDescriptions(source)
        print("AppStateUserIssueLifecycleSourceTests passed")
    }

    private static func testImportPersistsVersionedIssuesAndRetryUsesSafeAdapterPresentation(
        _ source: String
    ) throws {
        let importFlow = block(
            source,
            from: "func importAudioFile(_ fileURL: URL, choice: TranscriptionBackendChoice)",
            to: "func retryTranscription(item: PipelineHistoryItem)"
        )
        let retryAdapter = block(
            source,
            from: "func retryTranscription(item: PipelineHistoryItem)",
            to: "private func copyRetryTranscriptToPasteboardIfNeeded"
        )

        try expect(importFlow.contains("let issue = self.userIssue("), "import classifies one issue")
        try expect(importFlow.contains("processingStatus: issue.persistedStatus"), "import persists v1 issue")
        try expect(
            retryAdapter.contains("let issue = userIssue("),
            "retry preparation uses the common issue classifier"
        )
        try expect(
            retryAdapter.contains("issue.record.presentation().compactMessage"),
            "retry preparation exposes only safe compact issue copy"
        )
    }

    private static func testRetryWorkflowPersistedEffectsDriveWarningInvalidation(
        _ source: String
    ) throws {
        let eventAdapter = block(
            source,
            from: "private func applyTranscriptionRetryWorkflowEvent(",
            to: "private func applyTranscriptionRetryWorkflowState("
        )
        let persistedHandler = block(
            eventAdapter,
            from: "case .itemPersisted(let item, let effects):",
            to: "case .completed(let noteID, let outcome):"
        )
        try expect(
            persistedHandler.contains("pipelineHistory[index] = item"),
            "persisted Retry results refresh the AppState history mirror"
        )
        try expect(
            persistedHandler.contains("if effects.advancesWarningGeneration"),
            "warning invalidation follows the workflow's persisted effects"
        )
        try expect(
            persistedHandler.contains("incrementNoteRetryGeneration(for: item.id)"),
            "persisted Manual Retry results invalidate stale warning dismissals"
        )
    }

    private static func testStoppedRecordingPersistsAndPresentsOneIssue(
        _ source: String
    ) throws {
        let recordingFlow = block(
            source,
            from: "private func stopAndTranscribe()",
            to: "private func scheduleCloudTranscriptionAutoResume("
        )

        try expect(
            recordingFlow.components(separatedBy: "let issue = self.userIssue(").count >= 3,
            "live and file recording failures use the common issue classifier"
        )
        try expect(
            recordingFlow.components(separatedBy: "processingStatus: issue.persistedStatus").count >= 3,
            "recording failures persist v1 records"
        )
        try expect(
            recordingFlow.components(separatedBy: "issue.record.presentation().compactMessage").count >= 3,
            "recording overlay uses compact localized issue copy"
        )
        try expect(
            recordingFlow.components(separatedBy: "lastPostProcessingStatus = issue.persistedStatus").count >= 3,
            "last run status keeps the same machine record"
        )
    }

    private static func testPostProcessingFallbackPersistsWarningRecord(
        _ source: String
    ) throws {
        let processing = block(
            source,
            from: "private static func processTranscript(",
            to: "private static func resolveRawTranscript("
        )
        let completion = block(
            source,
            from: "private func makeStoppedTranscriptionCompletionSummary(",
            to: "private func runSuccessfulStoppedTranscriptionCompletionPipeline("
        )

        try expect(
            processing.contains("userIssueRecord: QuillUserIssueRecord?"),
            "processing result carries a warning record"
        )
        try expect(
            processing.contains("let issue = postProcessingService.userIssue(for: error)"),
            "post-processing errors become typed warnings"
        )
        try expect(
            completion.contains("result.userIssueRecord?.persistedStatus"),
            "stopped completion persists warning status"
        )
    }

    private static func testCorePreparationAndSaveFailuresUseSafePresentation(
        _ source: String
    ) throws {
        let importAndRetry = block(
            source,
            from: "func importAudioFile(_ fileURL: URL, choice: TranscriptionBackendChoice)",
            to: "private func copyRetryTranscriptToPasteboardIfNeeded"
        )
        try expect(
            !importAndRetry.contains("LocalizedUserMessage.providerFailure"),
            "import and retry preparation/save errors use structured copy"
        )
        let historySave = block(
            source,
            from: "private func recordPipelineHistoryEntry(",
            to: "private func startRealtimeStreamingIfEnabled()"
        )
        try expect(
            historySave.contains("self.userIssue("),
            "history save errors use the common classifier"
        )
        try expect(
            !historySave.contains("providerDetail: error.localizedDescription"),
            "history save errors hide raw persistence details"
        )
        let recordingFailure = block(
            source,
            from: "private func handleRecordingFailure(",
            to: "private static func urlErrorCode("
        )
        try expect(
            recordingFailure.contains("fallbackCode: .recordingInputFailed"),
            "recording start errors use the recording input issue"
        )
        try expect(
            !recordingFailure.contains("return error.localizedDescription"),
            "recording start errors hide raw descriptions"
        )
    }

    private static func testAudioInputSwitchFailureUsesSafePresentation(
        _ source: String
    ) throws {
        let inputSwitchFailure = block(
            source,
            from: "private func finishAfterInputSwitchStartFailure(",
            to: "private func canAccessRecordingInput("
        )
        try expect(
            inputSwitchFailure.contains("fallbackCode: .recordingInputFailed"),
            "audio input switch failures use the recording input issue"
        )
        try expect(
            inputSwitchFailure.contains("issue.record.presentation().compactMessage"),
            "audio input switch failures show safe compact copy"
        )
        try expect(
            !inputSwitchFailure.contains("formattedRecordingStartError"),
            "audio input switch failures do not use removed raw formatter"
        )
    }

    // A Realtime server that accepts the commit but never emits the final
    // transcript must not hang the stop flow forever: resolveRawTranscript
    // must bound the wait and still fall back to file transcription.
    private static func testResolveRawTranscriptBoundsRealtimeCommitWait(
        _ source: String
    ) throws {
        let resolveBody = block(
            source,
            from: "private static func resolveRawTranscript(",
            to: "private func resolveStoppedRecordingContext("
        )
        try expect(
            resolveBody.contains("Self.raceRealtimeCommitAgainstTimeout("),
            "resolveRawTranscript bounds the Realtime commit wait with a timeout race"
        )
        try expect(
            !resolveBody.contains("try await realtimeService.commitAndAwaitFinal()\n                } onCancel:"),
            "resolveRawTranscript no longer awaits the Realtime commit unbounded"
        )
        try expect(
            resolveBody.contains("catch is CancellationError {\n                throw CancellationError()\n            } catch {"),
            "a timed-out commit still falls through to the existing catch block"
        )
        try expect(
            resolveBody.contains("return try await fileService.transcribe(fileURL: fileURL)"),
            "a timed-out commit still falls back to file transcription"
        )
    }

    private static func testScopedFlowsDoNotPersistRawLocalizedDescriptions(
        _ source: String
    ) throws {
        let importAndRetry = block(
            source,
            from: "func importAudioFile(_ fileURL: URL, choice: TranscriptionBackendChoice)",
            to: "private func copyRetryTranscriptToPasteboardIfNeeded"
        )
        let recordingFlow = block(
            source,
            from: "private func stopAndTranscribe()",
            to: "private func scheduleCloudTranscriptionAutoResume("
        )
        for flow in [importAndRetry, recordingFlow] {
            try expect(
                !flow.contains("Error: \\(error.localizedDescription)"),
                "scoped lifecycle does not persist raw localized descriptions"
            )
        }
        let formatter = block(
            source,
            from: "private func userIssue(",
            to: "func showMicrophonePermissionAlert()"
        )
        try expect(
            !formatter.contains("return error.localizedDescription"),
            "compact presentation never falls back to raw error text"
        )
    }

    private static func block(
        _ source: String,
        from startMarker: String,
        to endMarker: String
    ) -> String {
        guard let start = source.range(of: startMarker),
              let end = source.range(
                of: endMarker,
                range: start.upperBound..<source.endIndex
              ) else {
            preconditionFailure("Expected source block from \(startMarker) to \(endMarker)")
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else { throw TestFailure(label) }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
