import Foundation

@main
struct UpstreamMergeBehaviorTests {
    static func main() throws {
        var failures: [String] = []

        func read(_ path: String) throws -> String {
            try String(contentsOfFile: path, encoding: .utf8)
        }

        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                failures.append(message)
            }
        }

        func checkContains(_ source: String, _ needle: String, _ message: String) {
            check(source.contains(needle), message)
        }

        func checkNotContains(_ source: String, _ needle: String, _ message: String) {
            check(!source.contains(needle), message)
        }

        let conflictPaths = [
            "CHANGELOG.md",
            "README.md",
            "Sources/AppState.swift",
            "Sources/RecordingOverlay.swift",
            "Sources/SettingsView.swift",
            "Sources/TranscriptionService.swift"
        ]

        for path in conflictPaths {
            let source = try read(path)
            checkNotContains(source, "<<<<<<<", "\(path) still contains conflict start markers")
            checkNotContains(source, "=======", "\(path) still contains conflict separator markers")
            checkNotContains(source, ">>>>>>>", "\(path) still contains conflict end markers")
        }

        let readme = try read("README.md")
        checkContains(readme, "<h1 align=\"center\">Quill</h1>", "README should keep Quill product heading")
        checkContains(readme, "https://github.com/woosublee/quill/releases/latest/download/Quill.dmg", "README should keep Quill release download link")
        checkNotContains(readme, "Download FreeFlow.dmg", "README should not regress to the upstream FreeFlow download copy")
        checkNotContains(readme, "com.zachlatta.freeflow", "README should not document FreeFlow defaults commands")

        let changelog = try read("CHANGELOG.md")
        checkContains(changelog, "All notable changes to Quill are documented here.", "CHANGELOG should keep Quill framing")
        checkNotContains(changelog, "All notable changes to FreeFlow are documented here.", "CHANGELOG should not regress to FreeFlow framing")

        let appState = try read("Sources/AppState.swift")
        checkContains(appState, "bootstrapLastTranscriptForPasteAgain(rawTranscript, pressEnterCommandEnabled: capturedPressEnterCommandEnabled)", "AppState should bootstrap Paste Again from parsed stopped transcript before post-processing")
        check(appState.components(separatedBy: "bootstrapLastTranscriptForPasteAgain(rawTranscript, pressEnterCommandEnabled: capturedPressEnterCommandEnabled)").count >= 3, "AppState should bootstrap Paste Again in both stopped transcription paths")
        checkContains(appState, "transcriptionRetryWorkflow.startManual(", "Manual Retry should delegate orchestration to the workflow")
        checkContains(appState, "copyRetryTranscriptToPasteboardIfNeeded(transcript)", "Retry completion should deliver the workflow transcript through the existing pasteboard helper")
        checkContains(appState, "screen recording permission not granted", "Screen recording permission detection should match explicit permission errors")
        checkContains(appState, "requires screen recording permission", "Screen recording permission detection should match explicit requirement errors")
        checkNotContains(appState, "return lowered.contains(\"permission\") || lowered.contains(\"screen recording\")", "Screen recording permission detection should not treat generic capture failures as permission errors")

        let transport = try read("Sources/LLMAPITransport.swift")
        checkContains(transport, "private static let requestSession", "LLMAPITransport should preserve shared-session reuse for short requests")
        checkContains(transport, "configuration.timeoutIntervalForRequest = timeout", "LLMAPITransport request timeout should honor the caller timeout")
        checkContains(transport, "configuration.timeoutIntervalForResource = timeout", "LLMAPITransport resource timeout should honor the caller timeout")
        checkContains(transport, "timeout(for: request.timeoutInterval)", "LLMAPITransport should normalize request-specific timeout overrides")

        let transcriptionService = try read("Sources/TranscriptionService.swift")
        checkContains(transcriptionService, "UserDefaults.standard.double(forKey: \"transcription_timeout_seconds\")", "TranscriptionService should support provider timeout overrides")
        checkContains(transcriptionService, "localTranscriptionTimeoutSeconds", "TranscriptionService should preserve Quill's local transcription timeout")
        checkContains(transcriptionService, "useLocalTranscription", "TranscriptionService should preserve Quill local transcription support")
        checkContains(transcriptionService, "func transcribe(fileURL: URL) async throws -> TranscriptionResult", "TranscriptionService should return a normalized transcription result")
        checkContains(transcriptionService, "if useLocalTranscription {", "Local transcription should remain an exclusive branch before cloud chunk planning")
        checkContains(transcriptionService, "transcribeLargeCanonicalWAV(fileURL: fileURL)", "Oversized canonical WAV should use the cloud chunking core")
        checkNotContains(transcriptionService, "body=%{public}@", "Cloud failures should not log raw provider response bodies")

        let transcriptTextCore = try read("Sources/TranscriptTextCore.swift")
        checkNotContains(
            transcriptTextCore,
            "Skipping hallucination filter for '%{public}@'",
            "Hallucination diagnostics should not log normalized user speech"
        )
        checkContains(
            transcriptTextCore,
            "Skipping hallucination filter: provider response has no segments/no_speech metadata",
            "Missing hallucination metadata should retain a static diagnostic"
        )
        checkContains(
            transcriptTextCore,
            "Skipping hallucination filter: provider response omitted no_speech_prob",
            "Missing no-speech probability should retain a static diagnostic"
        )

        checkContains(appState, "fileService.transcribe(fileURL: fileURL)", "Realtime file fallback should continue through TranscriptionService")

        let appContextService = try read("Sources/AppContextService.swift")
        checkContains(appContextService, "UserDefaults.standard.double(forKey: \"context_request_timeout_seconds\")", "AppContextService should support context timeout overrides")
        checkContains(appContextService, "Could not capture screenshot from the active window", "AppContextService should avoid permission-looking generic screenshot errors")

        let postProcessingService = try read("Sources/PostProcessingService.swift")
        checkContains(postProcessingService, "UserDefaults.standard.double(forKey: \"post_processing_timeout_seconds\")", "PostProcessingService should support post-processing timeout overrides")
        // Cleanup and Edit Mode share one fallback path since #580, so one
        // cooldown check guards the remaining cloud fallback retry.
        check(
            postProcessingService.components(separatedBy: "guard await LLMCooldownManager.shared.effectivePrimary(").count >= 2,
            "PostProcessingService should check cooldown before each remaining fallback retry"
        )
        checkContains(
            postProcessingService,
            "private func runWithFallback(",
            "Cleanup and Edit Mode should share one fallback path"
        )

        let recordingOverlay = try read("Sources/RecordingOverlay.swift")
        checkContains(recordingOverlay, "var displayID: CGDirectDisplayID?", "RecordingOverlay should expose screen display IDs for the picker")
        checkContains(recordingOverlay, "private var targetScreen: NSScreen?", "RecordingOverlay should resolve the configured target display")
        checkContains(recordingOverlay, "@Published var errorMessage: String?", "RecordingOverlayState should store in-pill error text")
        checkContains(recordingOverlay, "@Published var toastID: UUID?", "RecordingOverlayState should guard duplicate toast dismissals")
        checkContains(recordingOverlay, "func showError(_ message: String)", "RecordingOverlayManager should expose in-pill error toasts")
        checkContains(recordingOverlay, "hasErrorMessage:", "Recording overlay layout should account for long error toast messages")
        checkContains(recordingOverlay, "ErrorOverlayView(message: message)", "RecordingOverlayView should render in-pill error messages")

        let settingsView = try read("Sources/SettingsView.swift")
        checkContains(settingsView, "@AppStorage(\"overlay_display_id\")", "Settings should persist the selected overlay display")
        checkContains(settingsView, "overlayDisplaySection", "Settings should expose overlay display selection")
        checkContains(settingsView, ".accessibilityLabel(\"Show on\")", "Overlay display picker should have an accessibility label")
        checkContains(settingsView, "screen.displayID", "Overlay display picker should use the shared NSScreen displayID helper")

        if failures.isEmpty {
            print("UpstreamMergeBehaviorTests passed")
        } else {
            for failure in failures {
                print("FAIL: \(failure)")
            }
            exit(1)
        }
    }
}
