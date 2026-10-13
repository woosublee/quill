import AppKit
import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct AppStateDependenciesTests {
    static func main() throws {
        try verifiesStorageLayoutPreservesCanonicalPaths()
        try verifiesLiveDependenciesReturnFreshValues()
        try verifiesLocalAIDependenciesAreIndependentValues()
        try verifiesNativeWhisperDependenciesAreIndependentValues()
        try verifiesTestsCopyToTheirOwnPasteboard()
        print("AppStateDependenciesTests passed")
    }

    /// Dictation and retry results are copied for pasting. Test builds must
    /// copy to their own pasteboard, or `make check` replaces what the user
    /// copied with synthetic transcripts.
    private static func verifiesTestsCopyToTheirOwnPasteboard() throws {
        let pasteboard = AppStateDependencies.live.pasteboard
        precondition(pasteboard.name != NSPasteboard.general.name)
        precondition(pasteboard.name.rawValue.hasPrefix(AppStateDependencies.testPasteboardNamePrefix))
        precondition(!AppStateDependencies.live.postsKeyEvents)

        // AppState uses only its dependencies' pasteboard, and checks them
        // before sending Paste or Return.
        let appState = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        precondition(!appState.contains("NSPasteboard.general"))
        precondition(!appState.contains("NSPasteboard = .general"))
        for function in ["private func pasteAtCursor() {", "private func pressEnter() {"] {
            guard let start = appState.range(of: function) else { preconditionFailure(function) }
            let firstLine = appState[start.upperBound...].drop(while: \.isNewline).prefix(while: { !$0.isNewline })
            precondition(firstLine.trimmingCharacters(in: .whitespaces) == "guard dependencies.postsKeyEvents else { return }")
        }
        precondition(appState.components(separatedBy: ".post(tap: .cgSessionEventTap)").count - 1 == 4)
    }

    private static func verifiesStorageLayoutPreservesCanonicalPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-layout-contract", isDirectory: true)
        let layout = AppStateStorageLayout(rootDirectory: root)
        let bundleID = Bundle.main.bundleIdentifier ?? "com.woosublee.quill"

        try expect(layout.audioDirectory == root.appendingPathComponent("audio", isDirectory: true),
                   "audio remains below the AppState root")
        try expect(layout.transcriptDirectory == root.appendingPathComponent("transcripts", isDirectory: true),
                   "transcripts remain below the AppState root")
        try expect(layout.historyStoreURL == root.appendingPathComponent("PipelineHistory.sqlite"),
                   "history keeps its existing file name")
        try expect(layout.cloudTranscriptionJobsDirectory == root
            .appendingPathComponent("cloud-transcription/jobs", isDirectory: true),
                   "cloud jobs keep their existing relative path")
        try expect(layout.cloudTranscriptionTemporaryDirectory == FileManager.default.temporaryDirectory
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("cloud-transcription", isDirectory: true),
                   "cloud temporary files keep the bundle-scoped path")
    }

    private static func verifiesLiveDependenciesReturnFreshValues() throws {
        var first = AppStateDependencies.live
        let second = AppStateDependencies.live
        let overriddenRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-overridden-layout", isDirectory: true)
        first.storageLayout = AppStateStorageLayout(rootDirectory: overriddenRoot)

        try expect(second.storageLayout.rootDirectory == AppName.applicationSupportDirectory,
                   "mutating one dependency value does not alter a later live value")
    }

    private static func verifiesLocalAIDependenciesAreIndependentValues() throws {
        var first = AppStateDependencies.live
        let second = AppStateDependencies.live
        first.localAI.installStatus = { _ in .ready }
        first.localAI.processingAvailability = {
            LocalAIProcessingAvailability(
                isAppleSilicon: false,
                runnerIsExecutable: false,
                physicalMemory: 0
            )
        }

        try expect(
            first.localAI.installStatus(LocalAIModelCatalog.quality) == .ready,
            "the overridden Local AI value is used by the first dependency copy"
        )
        try expect(
            second.localAI.processingAvailability()
                != first.localAI.processingAvailability(),
            "mutating one Local AI dependency value does not alter another"
        )
    }

    private static func verifiesNativeWhisperDependenciesAreIndependentValues() throws {
        var first = AppStateDependencies.live
        let second = AppStateDependencies.live
        let originalSecondStatus = second.nativeWhisper.installStatus(.recommended)
        first.nativeWhisper.installStatus = { _ in .ready }
        first.nativeWhisper.makeExecutionSnapshot = {
            markerNativeWhisperExecution(modelID: "first-environment")
        }

        try expect(
            first.nativeWhisper.installStatus(.recommended) == .ready,
            "the overridden Native Whisper value is used by the first dependency copy"
        )
        try expect(
            second.nativeWhisper.installStatus(.recommended) == originalSecondStatus,
            "mutating one Native Whisper dependency value does not alter another"
        )
        try expect(
            first.nativeWhisper.makeExecutionSnapshot().modelID
                == "first-environment",
            "the first dependency copy uses its execution factory"
        )
        try expect(
            second.nativeWhisper.makeExecutionSnapshot().modelID
                == NativeWhisperModelCatalog.recommended.id,
            "the second dependency copy keeps its live execution factory"
        )
    }

    private static func markerNativeWhisperExecution(
        modelID: String
    ) -> NativeWhisperExecutionSnapshot {
        NativeWhisperExecutionSnapshot(
            modelID: modelID,
            modelIsReady: { true },
            modelURL: { URL(fileURLWithPath: "/tmp/\(modelID).bin") },
            validateRunnerAndModel: { _ in },
            prepareAudio: { .init(fileURL: $0, cleanup: {}) },
            transcribe: { _, _, _ in
                TranscriptionResult(
                    text: modelID,
                    spokenLanguage: SpokenLanguageResolver.resolve(
                        requestedLanguageCode: "auto",
                        engineLanguageCode: nil,
                        transcript: modelID
                    )
                )
            }
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw TestFailure(message) }
    }

    private struct TestFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
