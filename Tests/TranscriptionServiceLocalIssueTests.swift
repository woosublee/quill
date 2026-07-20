import Foundation
import Speech

@main
struct TranscriptionServiceLocalIssueTests {
    static func main() async throws {
        try await testMissingLegacyRuntimeUsesStableSafeIssue()
        try await testMissingFFmpegUsesDependencyIssue()
        try await testLegacyProcessFailureKeepsOutputPrivate()
        try testAppleSpeechPermissionUsesPermissionIssue()
        print("TranscriptionServiceLocalIssueTests passed")
    }

    private static func testMissingLegacyRuntimeUsesStableSafeIssue() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingRuntime = root.appendingPathComponent("private-missing-mlx_whisper")
        let audio = try writeAudio(in: root)
        let service = try makeLegacyService(runtimeURL: missingRuntime)

        do {
            _ = try await service.transcribe(fileURL: audio)
            throw TestFailure("Missing legacy runtime must fail")
        } catch let issue as QuillUserIssueError {
            try expect(issue.record.code == .localRuntimeMissing, "missing runtime code")
            try expect(issue.record.context.localBackend == "Legacy mlx-whisper", "legacy backend context")
            try expect(issue.record.context.modelID == "mlx-community/whisper-large-v3-turbo", "legacy model context")
            let payload = try decodedPayloadString(issue.record.encodedStatus())
            try expect(!payload.contains(root.path), "persisted record excludes runtime path")
            try expect(issue.privateDiagnostic.contains(missingRuntime.path), "runtime path remains private diagnostic")
        }
    }

    private static func testMissingFFmpegUsesDependencyIssue() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try writeExecutable(
            in: root,
            body: "#!/bin/sh\necho \"No such file or directory: 'ffmpeg'\" >&2\nexit 1\n"
        )
        let service = try makeLegacyService(runtimeURL: runtime)

        do {
            _ = try await service.transcribe(fileURL: try writeAudio(in: root))
            throw TestFailure("Missing ffmpeg must fail")
        } catch let issue as QuillUserIssueError {
            try expect(issue.record.code == .localDependencyMissing, "missing ffmpeg code")
            try expect(issue.record.context.processExitCode == 1, "ffmpeg exit code")
            let payload = try decodedPayloadString(issue.record.encodedStatus())
            try expect(!payload.contains("ffmpeg"), "persisted record excludes stderr")
        }
    }

    private static func testLegacyProcessFailureKeepsOutputPrivate() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "STDERR_MARKER sk-secret-api-key"
        let runtime = try writeExecutable(
            in: root,
            body: "#!/bin/sh\necho \"\(marker)\" >&2\nexit 7\n"
        )
        let service = try makeLegacyService(runtimeURL: runtime)

        do {
            _ = try await service.transcribe(fileURL: try writeAudio(in: root))
            throw TestFailure("Legacy process failure must fail")
        } catch let issue as QuillUserIssueError {
            try expect(issue.record.code == .localTranscriptionFailed, "legacy process code")
            try expect(issue.record.context.processExitCode == 7, "legacy process exit code")
            let payload = try decodedPayloadString(issue.record.encodedStatus())
            try expect(!payload.contains(marker), "persisted record excludes process output")
            try expect(issue.privateDiagnostic.contains(marker), "process output remains private diagnostic")
        }
    }

    private static func testAppleSpeechPermissionUsesPermissionIssue() throws {
        let issue = TranscriptionService.appleSpeechAuthorizationIssue(for: .denied)
        try expect(issue?.record.code == .speechRecognitionPermissionDenied, "speech permission code")
        try expect(issue?.record.context.localBackend == "Apple Speech", "speech backend context")
        try expect(
            TranscriptionService.appleSpeechAuthorizationIssue(for: .authorized) == nil,
            "authorized speech has no issue"
        )
    }

    private static func makeLegacyService(runtimeURL: URL) throws -> TranscriptionService {
        try TranscriptionService(
            apiKey: "",
            useLocalTranscription: true,
            localWhisperPath: runtimeURL.path,
            useLegacyMlxWhisper: true,
            transcriptionLanguage: .auto,
            localTranscriptionModel: .find(id: "mlx-community/whisper-large-v3-turbo")
        )
    }

    private static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-local-issue-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func writeAudio(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("recording.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)
        return url
    }

    private static func writeExecutable(in root: URL, body: String) throws -> URL {
        let url = root.appendingPathComponent("fake-mlx-whisper")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }

    private static func decodedPayloadString(_ status: String) throws -> String {
        let encoded = String(status.dropFirst(QuillUserIssueRecord.persistedStatusPrefix.count))
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let text = String(data: data, encoding: .utf8) else {
            throw TestFailure("Unable to decode persisted payload")
        }
        return text
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
