import Foundation

@main
struct AppStateCloudTranscriptionIntegrationSourceTests {
    static func main() throws {
        let appState = try String(
            contentsOfFile: "Sources/AppState.swift",
            encoding: .utf8
        )
        let service = try String(
            contentsOfFile: "Sources/TranscriptionService.swift",
            encoding: .utf8
        )

        try verifiesDefaultedExecutionContext(service)
        try verifiesImportPlaceholderPrecedesCloudExecution(appState)
        try verifiesRecordingPlaceholderPrecedesCloudExecution(appState)
        try verifiesHistoryCommitPrecedesSidecarDeletion(appState)
        try verifiesPartialCloudTextStaysOutOfHistory(appState)
        try verifiesExplicitRetryPolicy(appState)
        try verifiesStartupReconciliationOrder(appState)
        try verifiesStartupResumeIsHistoryOnly(appState)
        print("AppStateCloudTranscriptionIntegrationSourceTests passed")
    }

    private static func verifiesDefaultedExecutionContext(_ source: String) throws {
        try expect(
            source.contains(
                "cloudExecutionContext: CloudTranscriptionExecutionContext? = nil"
            ),
            "existing TranscriptionService callers keep a nil context default"
        )
        let largePath = block(
            source,
            from: "private func transcribeLargeCanonicalWAV",
            to: "// Send audio file for transcription"
        )
        try expect(
            largePath.contains(
                "cloudExecutionContext?.checkpointStore\n            ?? cloudDependencies.checkpointStore"
            ),
            "large cloud path uses durable checkpoint adapter when provided"
        )
        try expect(
            largePath.contains(
                "cloudExecutionContext?.progress\n            ?? cloudDependencies.progress"
            ),
            "large cloud path publishes context progress"
        )
    }

    private static func verifiesImportPlaceholderPrecedesCloudExecution(
        _ source: String
    ) throws {
        let importFlow = block(
            source,
            from: "func importAudioFile(_ fileURL: URL, choice: TranscriptionBackendChoice)",
            to: "func retryTranscription(item: PipelineHistoryItem)"
        )
        try expectOrdered(
            [
                "try self.appendPipelineHistoryItem(placeholder)",
                "prepareCloudTranscriptionJob(",
                "configuration.makeTranscriptionService(\n                        cloudExecutionContext: cloudExecutionContext"
            ],
            in: importFlow,
            label: "import durable placeholder/context/provider order"
        )
        try expect(
            importFlow.contains(
                "postProcessingStatus: configuration.useLocalTranscription\n                    ? \"importing\"\n                    : PipelineHistoryItem.cloudTranscribingStatus"
            ),
            "cloud import uses stable cloud-transcribing machine status"
        )
    }

    private static func verifiesRecordingPlaceholderPrecedesCloudExecution(
        _ source: String
    ) throws {
        let recordingFlow = block(
            source,
            from: "private func stopAndTranscribe()",
            to: "// 라이브 전사 시작 시 Note Browser"
        )
        try expectOrdered(
            [
                "createTranscriptionRecoveryPlaceholder(",
                "prepareCloudTranscriptionJob(",
                "cloudExecutionContext: cloudExecutionContext"
            ],
            in: recordingFlow,
            label: "recording durable placeholder/context/provider order"
        )
        try expect(
            recordingFlow.contains(
                "postProcessingStatusOverride: capturedUseLocalTranscription\n                        ? nil\n                        : PipelineHistoryItem.cloudTranscribingStatus"
            ),
            "recording cloud placeholder uses stable machine status"
        )
    }

    private static func verifiesHistoryCommitPrecedesSidecarDeletion(
        _ source: String
    ) throws {
        let completionHelper = block(
            source,
            from: "private func completeCloudTranscriptionHistory(",
            to: "private func finishCloudTranscriptionJob("
        )
        try expectOrdered(
            [
                "guard historySaved",
                "cloudTranscriptionJobStore.deleteCompletedJob("
            ],
            in: completionHelper,
            label: "history commit before sidecar deletion"
        )
        let recordHistory = block(
            source,
            from: "private func recordPipelineHistoryEntry(",
            to: "// MCP notification"
        )
        try expect(
            recordHistory.contains("-> Bool"),
            "history persistence reports durable success"
        )
        try expect(
            source.contains(
                "context: cloudExecutionContext,\n                        historySaved: historySaved"
            ),
            "import history persistence result reaches cloud completion helper"
        )
        try expect(
            source.contains(
                "context: cloudContext,\n                historySaved: historySaved"
            ),
            "recording history persistence result reaches cloud completion helper"
        )
    }

    private static func verifiesPartialCloudTextStaysOutOfHistory(
        _ source: String
    ) throws {
        let progressHelper = block(
            source,
            from: "private func updateCloudTranscriptionProgress(",
            to: "private func completeCloudTranscriptionHistory("
        )
        try expect(
            !progressHelper.contains("rawTranscript"),
            "progress callback never writes partial raw transcript"
        )
        try expect(
            !progressHelper.contains("postProcessedTranscript"),
            "progress callback never writes partial processed transcript"
        )
        try expect(
            progressHelper.contains(
                "cloudTranscriptionProgressByHistoryID[historyID] = displayProgress"
            ),
            "progress callback updates only the dynamic map"
        )
    }

    private static func verifiesExplicitRetryPolicy(_ source: String) throws {
        let retrySnapshot = block(
            source,
            from: "private func makeRetrySnapshot(for item: PipelineHistoryItem)",
            to: "private func makeRetryHistoryItem("
        )
        try expect(
            retrySnapshot.contains("options.explicitRetryChoice"),
            "retry uses the explicitly selected backend without fallback"
        )
        try expect(
            !retrySnapshot.contains("options.defaultChoice"),
            "retry never silently selects a different backend"
        )
        try expect(
            retrySnapshot.contains("CanonicalPCM16WAV.validateFile(at: audioURL)"),
            "oversized cloud retry is allowed only for strict canonical WAV"
        )
        try expect(
            retrySnapshot.contains("execution = .local("),
            "local retry snapshots the full-source local execution"
        )
        try expect(
            retrySnapshot.contains("execution = .cloud("),
            "cloud retry snapshots the selected provider execution"
        )
        let retryFlow = block(
            source,
            from: "func retryTranscription(item: PipelineHistoryItem)",
            to: "private func copyRetryTranscriptToPasteboardIfNeeded"
        )
        try expect(
            retryFlow.contains("snapshot.execution\n                    .makeTranscriptionService("),
            "retry service is built only from the immutable snapshot"
        )
        try expect(
            retryFlow.contains("completeCloudTranscriptionHistory("),
            "successful cloud or local retry clears sidecar after history save"
        )
    }

    private static func verifiesStartupReconciliationOrder(_ source: String) throws {
        let initializer = block(
            source,
            from: "init() {",
            to: "private static func loadShortcutConfiguration"
        )
        try expectOrdered(
            [
                "recoverRecordingJournalsBeforeHistoryLoad(",
                "pipelineHistoryStore.trim(",
                "cloudTranscriptionJobStore.invalidateSession(",
                "cloudTranscriptionJobStore.reconcile(",
                "sweepOrphanStoredFiles(",
                "scheduleCloudTranscriptionAutoResume("
            ],
            in: initializer,
            label: "startup recording/history/cloud/sweep/deferred resume order"
        )
        let recordingRecovery = block(
            source,
            from: "private static func recoverRecordingJournalsBeforeHistoryLoad(",
            to: "private static func protectedInflightAudioFileNames("
        )
        for forbidden in [
            "TranscriptionService(",
            "cloudTranscriptionJobStore",
            "URLSession",
            "upload("
        ] {
            try expect(
                !recordingRecovery.contains(forbidden),
                "recording startup recovery remains network-free: \(forbidden)"
            )
        }
        try expect(
            source.contains("item.normalizedAfterProcessInterruption()"),
            "AppState delegates interruption normalization to the typed history item"
        )
        let historyItemSource = try String(
            contentsOfFile: "Sources/PipelineHistoryItem.swift",
            encoding: .utf8
        )
        try expect(
            historyItemSource.contains(
                "guard postProcessingStatus != Self.cloudTranscribingStatus"
            ),
            "cloud-transcribing rows are excluded from generic interruption normalization"
        )
    }

    private static func verifiesStartupResumeIsHistoryOnly(_ source: String) throws {
        let autoResume = block(
            source,
            from: "private func scheduleCloudTranscriptionAutoResume(",
            to: "private func resumeCloudTranscriptionAfterLaunch("
        )
        try expect(autoResume.contains("Task { @MainActor"), "auto-resume is deferred until initialization finishes")
        try expect(
            autoResume.contains("completionDelivery: .historyOnly"),
            "startup resume uses history-only completion delivery"
        )
        let resume = block(
            source,
            from: "private func resumeCloudTranscriptionAfterLaunch(",
            to: "private func prepareCloudTranscriptionJob("
        )
        try expect(
            resume.contains("guard completionDelivery == .historyOnly"),
            "resume helper enforces history-only delivery"
        )
        for forbidden in [
            "writeDictationStringToPasteboard",
            "pasteAtCursor",
            "shouldPressEnterAfterPaste",
            "copyRetryTranscriptToPasteboardIfNeeded"
        ] {
            try expect(
                !resume.contains(forbidden),
                "startup resume never performs interactive delivery: \(forbidden)"
            )
        }
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
            preconditionFailure(
                "Expected source block from \(startMarker) to \(endMarker)"
            )
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private static func expectOrdered(
        _ markers: [String],
        in source: String,
        label: String
    ) throws {
        var lowerBound = source.startIndex
        for marker in markers {
            guard let range = source.range(
                of: marker,
                range: lowerBound..<source.endIndex
            ) else {
                throw TestFailure("\(label): missing or misordered \(marker)")
            }
            lowerBound = range.upperBound
        }
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
