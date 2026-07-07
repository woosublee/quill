import Foundation

@main
struct AudioImportFileCopyTests {
    static func main() async throws {
        try await testOffMainCopyPreservesExtensionAndContents()
        await testOffMainCopyReturnsNilForMissingFile()
        try testImportAudioFileUsesOffMainSecurityScopedCopy()
        try testImportAudioFileGroupsCapturedSettings()
        print("AudioImportFileCopyTests passed")
    }

    private static func testOffMainCopyPreservesExtensionAndContents() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-audio-import-copy-source-\(ProcessInfo.processInfo.globallyUniqueString)")
            .appendingPathExtension("m4a")
        let contents = Data("audio import copy test".utf8)
        try contents.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        guard let saved = await AppState.saveSecurityScopedAudioFileOffMain(from: sourceURL) else {
            preconditionFailure("Expected off-main audio copy to succeed")
        }
        defer { try? FileManager.default.removeItem(at: saved.fileURL) }

        precondition(saved.fileName.hasSuffix(".m4a"), "Expected copied file to preserve supported extension")
        let copied = try Data(contentsOf: saved.fileURL)
        precondition(copied == contents, "Expected copied file contents to match source")
    }

    private static func testOffMainCopyReturnsNilForMissingFile() async {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-missing-audio-import-\(ProcessInfo.processInfo.globallyUniqueString)")
            .appendingPathExtension("mp3")

        let saved = await AppState.saveSecurityScopedAudioFileOffMain(from: missingURL)

        precondition(saved == nil, "Expected missing source file to fail off-main copy")
    }

    private static func testImportAudioFileUsesOffMainSecurityScopedCopy() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)

        assertContains(source, "static func saveSecurityScopedAudioFileOffMain(from fileURL: URL) async -> SavedAudioFile?")
        assertContains(source, "await Task.detached(priority: .userInitiated)")
        assertContains(source, "let accessGranted = fileURL.startAccessingSecurityScopedResource()")
        assertContains(source, "fileURL.stopAccessingSecurityScopedResource()")
        assertContains(source, "guard let savedAudioFile = await Self.saveSecurityScopedAudioFileOffMain(from: fileURL)")
        assertDoesNotContain(importAudioFileBody(in: source), "Self.saveAudioFile(from: fileURL)")
        assertDoesNotContain(importAudioFileBody(in: source), "startAccessingSecurityScopedResource()")
    }

    private static func testImportAudioFileGroupsCapturedSettings() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let importBody = importAudioFileBody(in: source)

        assertContains(source, "private struct AudioImportTaskConfiguration")
        assertContains(source, "func makePostProcessingService() -> PostProcessingService")
        assertContains(source, "func makeTranscriptionService() throws -> TranscriptionService")
        assertContains(importBody, "let configuration = AudioImportTaskConfiguration(")
        assertContains(importBody, "let transcriptionService = try configuration.makeTranscriptionService()")
        assertContains(importBody, "postProcessingService: configuration.makePostProcessingService()")
        assertDoesNotContain(importBody, "let capturedApiKey")
        assertDoesNotContain(importBody, "let capturedCustomVocabulary")
        assertDoesNotContain(importBody, "let capturedPostProcessingEnabled")
        assertDoesNotContain(importBody, "capturedCustomSystemPrompt")
    }

    private static func importAudioFileBody(in source: String) -> String {
        guard let start = source.range(of: "func importAudioFile(_ fileURL: URL, choice: TranscriptionBackendChoice)"),
              let end = source.range(of: "\n    @MainActor\n    func retryTranscription", range: start.upperBound..<source.endIndex) else {
            preconditionFailure("Could not find importAudioFile body")
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private static func assertContains(_ text: String, _ expected: String) {
        precondition(text.contains(expected), "Expected content to contain \(expected)")
    }

    private static func assertDoesNotContain(_ text: String, _ unexpected: String) {
        precondition(!text.contains(unexpected), "Expected content not to contain \(unexpected)")
    }
}
