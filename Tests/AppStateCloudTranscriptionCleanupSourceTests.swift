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
        try verifiesIncompatibleRetryInvalidatesBeforeReplacement(source)
        print("AppStateCloudTranscriptionCleanupSourceTests passed")
    }

    private static func verifiesCommonCleanupOrder(_ source: String) throws {
        let cleanup = block(
            source,
            from: "private func cleanupDeletedPipelineHistoryAssets(",
            to: "private static func deleteAudioFile("
        )
        try expectOrdered(
            [
                "cloudTranscriptionHistoryCoordinator.cancelAndInvalidate(",
                "retryingItemIDs.remove(assets.historyID)",
                "Self.deleteStoredFiles(assets)",
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
            from: "init() {",
            to: "private static func loadShortcutConfiguration"
        )
        try expectOrdered(
            [
                "pipelineHistoryStore.trim(to: maxPipelineHistoryCount)",
                "cloudTranscriptionJobStore.invalidateSession(",
                "Self.deleteStoredFiles(removedAssets)",
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
                distance < 1_500,
                "trimmed history assets use nearby common cleanup after \(marker)"
            )
        }
    }

    private static func verifiesIncompatibleRetryInvalidatesBeforeReplacement(
        _ source: String
    ) throws {
        let retry = block(
            source,
            from: "private func prepareCloudRetryContext(",
            to: "private func makeCloudExecutionContext("
        )
        try expectOrdered(
            [
                "cloudTranscriptionHistoryCoordinator.cancelAndInvalidate(",
                "cloudTranscriptionJobStore.beginSession(",
                "cloudTranscriptionJobStore.replaceForIncompatibleRetry("
            ],
            in: retry,
            label: "incompatible retry invalidates old runtime before replacement"
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
