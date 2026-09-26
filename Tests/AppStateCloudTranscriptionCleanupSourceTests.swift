import Foundation

@main
struct AppStateCloudTranscriptionCleanupSourceTests {
    static func main() throws {
        let source = try String(
            contentsOfFile: "Sources/AppState.swift",
            encoding: .utf8
        )

        try verifiesCommonCleanupOrder(source)
        try verifiesDeleteUsesCommonCleanup(source)
        try verifiesClearUsesCommonCleanup(source)
        try verifiesTrimmedAssetsUseCommonCleanup(source)
        try verifiesActiveCloudTasksAreInstalled(source)
        try verifiesLateCloudCallbacksCannotWriteHistory(source)
        print("AppStateCloudTranscriptionCleanupSourceTests passed")
    }

    private static func verifiesCommonCleanupOrder(_ source: String) throws {
        let cleanup = block(
            source,
            from: "private func cleanupDeletedPipelineHistoryAssets(",
            to: "static func normalizeInterruptedHistoryItem("
        )
        try expectOrdered(
            [
                "transcriptionRetryWorkflow.forget(noteID: assets.historyID)",
                "cloudTranscriptionHistoryCoordinator.cancelAndInvalidate(",
                "retryingItemIDs.remove(assets.historyID)",
                "try? noteAssetStore.deleteAssets(",
                "cloudTranscriptionJobStore.delete("
            ],
            in: cleanup,
            label: "cancel, invalidate, progress, permanent assets, sidecar cleanup order"
        )
    }

    private static func verifiesDeleteUsesCommonCleanup(_ source: String) throws {
        let deletion = block(
            source,
            from: "func deleteHistoryEntry(id: UUID)",
            to: "@MainActor\n    func updateHistoryItemTitle"
        )
        try expectOrdered(
            [
                "transcriptionRetryWorkflow.cancel(noteID: id)",
                "cloudTranscriptionHistoryCoordinator.cancelAndInvalidate(",
                "pipelineHistoryStore.delete(",
                "beforeDeleting:",
                "cloudTranscriptionHistoryCoordinator.cancelAndInvalidate(",
                "cleanupDeletedPipelineHistoryAssets("
            ],
            in: deletion,
            label: "single delete cleanup order"
        )
    }

    private static func verifiesClearUsesCommonCleanup(_ source: String) throws {
        let clear = block(
            source,
            from: "func clearPipelineHistory()",
            to: "func deleteHistoryEntry(id: UUID)"
        )
        try expectOrdered(
            [
                "transcriptionRetryWorkflow.cancel(noteID: historyID)",
                "cloudTranscriptionHistoryCoordinator.cancelAndInvalidate(",
                "pipelineHistoryStore.clearAll(",
                "beforeDeleting:",
                "cloudTranscriptionHistoryCoordinator.cancelAndInvalidate(",
                "cleanupDeletedPipelineHistoryAssets("
            ],
            in: clear,
            label: "clear cleanup order"
        )
    }

    private static func verifiesTrimmedAssetsUseCommonCleanup(_ source: String) throws {
        let initializer = block(
            source,
            from: "init(dependencies: AppStateDependencies = .live) {",
            to: "private static func loadShortcutConfiguration"
        )
        try expectOrdered(
            [
                "let startupNoteAssetStore = NoteAssetStore(",
                "pipelineHistoryStore.trim(to: maxPipelineHistoryCount)",
                "cloudTranscriptionJobStore.invalidateSession(",
                "try? startupNoteAssetStore.deleteAssets(",
                "cloudTranscriptionJobStore.delete("
            ],
            in: initializer,
            label: "startup trim invalidates then deletes permanent assets and sidecar"
        )

        for marker in [
            "pipelineHistoryStore.append(item, maxCount: maxPipelineHistoryCount)",
            "pipelineHistoryStore.upsert("
        ] {
            guard let operation = source.range(of: marker),
                  let cleanup = source.range(
                    of: "cleanupDeletedPipelineHistoryAssets(",
                    range: operation.upperBound..<source.endIndex
                  ) else {
                throw TestFailure("trimmed history assets use common cleanup after \(marker)")
            }
            let distance = source.distance(
                from: operation.upperBound,
                to: cleanup.lowerBound
            )
            try expect(
                distance < 2_000,
                "trimmed history assets use nearby common cleanup after \(marker)"
            )
        }
    }

    private static func verifiesActiveCloudTasksAreInstalled(
        _ source: String
    ) throws {
        let importFlow = block(
            source,
            from: "func importAudioFile(_ fileURL: URL, choice: TranscriptionBackendChoice)",
            to: "func retryTranscription(item: PipelineHistoryItem)"
        )
        try expectOrdered(
            [
                "let task = Task",
                "installCloudTranscriptionTask(",
                "context: cloudExecutionContext"
            ],
            in: importFlow,
            label: "initial import cloud task installation"
        )

        let recordingFlow = block(
            source,
            from: "private func stopAndTranscribe()",
            to: "private func scheduleCloudTranscriptionAutoResume("
        )
        try expectOrdered(
            [
                "let task = Task",
                "installCloudTranscriptionTask(",
                "context: cloudExecutionContext"
            ],
            in: recordingFlow,
            label: "initial recording cloud task installation"
        )
    }

    private static func verifiesLateCloudCallbacksCannotWriteHistory(
        _ source: String
    ) throws {
        let importFlow = block(
            source,
            from: "func importAudioFile(_ fileURL: URL, choice: TranscriptionBackendChoice)",
            to: "func retryTranscription(item: PipelineHistoryItem)"
        )
        try expect(
            importFlow.components(
                separatedBy: "guard isCurrentCloudTranscriptionExecution("
            ).count >= 3,
            "import success and failure callbacks require the active cloud session"
        )
        try expect(
            importFlow.components(
                separatedBy: "requiresCloudExecution: configuration.usesJobStore"
            ).count >= 3,
            "import cloud callbacks reject a missing invalidated context"
        )

        let recordingFlow = block(
            source,
            from: "private func stopAndTranscribe()",
            to: "private func scheduleCloudTranscriptionAutoResume("
        )
        try expect(
            recordingFlow.components(
                separatedBy: "isCurrentCloudTranscriptionExecution("
            ).count >= 3,
            "recording success and failure callbacks require the active cloud session"
        )
        try expect(
            recordingFlow.components(
                separatedBy: "requiresCloudExecution: capturedUsesJobStore"
            ).count >= 2,
            "recording cloud callbacks reject a missing invalidated context"
        )

        let completion = block(
            source,
            from: "private func completeCloudTranscriptionHistory(",
            to: "private func finishCloudTranscriptionJob("
        )
        try expect(
            completion.contains("isCurrentCloudTranscriptionExecution("),
            "late completion cannot delete a newer cloud job"
        )

        let finish = block(
            source,
            from: "private func finishCloudTranscriptionJob(",
            to: "// 라이브 전사 시작 시 Note Browser"
        )
        try expect(
            finish.contains("isCurrentCloudTranscriptionExecution("),
            "late finish cannot invalidate a newer cloud session"
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
