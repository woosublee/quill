import Foundation
import Speech
import QuillAITextCore
import QuillUserIssueCore

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct TranscriptionServiceLocalIssueTests {
    static func main() async throws {
        try await testMissingLegacyRuntimeUsesStableSafeIssue()
        try await testMissingFFmpegUsesDependencyIssue()
        try await testLegacyProcessFailureKeepsOutputPrivate()
        try await testLegacySuccessWithoutTranscriptTextFails()
        try await testNativeWhisperPreflightStopsBeforeAudioPreparation()
        try await testNativeWhisperAudioPreparationPreservesCancellation()
        try await testNativeWhisperUsesOneSnapshotForPreflightAndTranscription()
        try await testNativeWhisperServicesKeepIndependentExecutionEnvironments()
        try await testNativeWhisperMissingModelKeepsExistingIssue()
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

    private static func testLegacySuccessWithoutTranscriptTextFails() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try writeExecutable(
            in: root,
            body: """
            #!/bin/sh
            output_dir=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "--output-dir" ]; then
                output_dir="$2"
                break
              fi
              shift
            done
            printf '%s\n' '{"error":"model load failed"}' > "$output_dir/recording.json"
            exit 0
            """
        )
        let service = try makeLegacyService(runtimeURL: runtime)

        do {
            _ = try await service.transcribe(fileURL: try writeAudio(in: root))
            throw TestFailure("Legacy response without transcript text must fail")
        } catch let issue as QuillUserIssueError {
            try expect(
                issue.record.code == .localTranscriptionFailed,
                "legacy response without text uses transcription failure issue"
            )
        }
    }

    private static func testNativeWhisperPreflightStopsBeforeAudioPreparation()
        async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = NativeWhisperExecutionHarness(
            modelID: "preflight-model",
            modelURL: root.appendingPathComponent("model.bin"),
            preflightError: NativeWhisperRuntimeError.runnerNotFound(
                root.appendingPathComponent("whisper-cli").path
            )
        )
        let service = try makeNativeService(snapshot: harness.snapshot())

        do {
            _ = try await service.transcribe(fileURL: try writeAudio(in: root))
            throw TestFailure("Native Whisper preflight must fail")
        } catch let issue as QuillUserIssueError {
            try expect(issue.record.code == .localRuntimeMissing, "preflight issue code")
            try expect(
                harness.recordedEventNames() == ["preflight"],
                "audio preparation does not run after preflight failure"
            )
        }
    }

    private static func testNativeWhisperAudioPreparationPreservesCancellation()
        async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = NativeWhisperExecutionHarness(
            modelID: "cancelled-model",
            modelURL: root.appendingPathComponent("model.bin"),
            preparationError: CancellationError()
        )
        let service = try makeNativeService(snapshot: harness.snapshot())

        do {
            _ = try await service.transcribe(fileURL: try writeAudio(in: root))
            throw TestFailure("Native Whisper audio preparation cancellation must propagate")
        } catch is CancellationError {
            try expect(
                harness.recordedEventNames() == ["preflight", "prepare"],
                "cancellation stops before transcription"
            )
        }
    }

    private static func testNativeWhisperUsesOneSnapshotForPreflightAndTranscription()
        async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let modelURL = root.appendingPathComponent("origin-model.bin")
        let preparedAudioURL = root.appendingPathComponent("prepared.wav")
        let harness = NativeWhisperExecutionHarness(
            modelID: "origin-model",
            modelURL: modelURL,
            preparedAudioURL: preparedAudioURL,
            resultText: "origin transcript"
        )
        let audioURL = try writeAudio(in: root)

        let result = try await makeNativeService(
            snapshot: harness.snapshot()
        ).transcribe(fileURL: audioURL)

        try expect(result.text == "origin transcript", "origin transcript result")
        try expect(
            harness.recordedEventNames() == ["preflight", "prepare", "transcribe"],
            "preflight, preparation, and transcription order"
        )
        try expect(
            harness.recordedModelURLs() == [modelURL, modelURL],
            "preflight and transcription share one model URL"
        )
        try expect(
            harness.recordedTranscriptionAudioURLs() == [preparedAudioURL],
            "transcription uses the prepared audio URL"
        )
        try expect(
            harness.recordedCleanupCount() == 1,
            "prepared audio is cleaned after transcription"
        )
    }

    private static func testNativeWhisperServicesKeepIndependentExecutionEnvironments()
        async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = NativeWhisperExecutionHarness(
            modelID: "first",
            modelURL: root.appendingPathComponent("first.bin"),
            resultText: "first transcript"
        )
        let second = NativeWhisperExecutionHarness(
            modelID: "second",
            modelURL: root.appendingPathComponent("second.bin"),
            resultText: "second transcript"
        )
        let firstService = try makeNativeService(snapshot: first.snapshot())
        let secondService = try makeNativeService(snapshot: second.snapshot())
        let audioURL = try writeAudio(in: root)

        let firstResult = try await firstService.transcribe(fileURL: audioURL)
        let secondResult = try await secondService.transcribe(fileURL: audioURL)

        try expect(firstResult.text == "first transcript", "first service result")
        try expect(secondResult.text == "second transcript", "second service result")
        try expect(
            first.recordedModelURLs().allSatisfy { $0 == first.modelURL },
            "first service stays in first environment"
        )
        try expect(
            second.recordedModelURLs().allSatisfy { $0 == second.modelURL },
            "second service stays in second environment"
        )
    }

    private static func testNativeWhisperMissingModelKeepsExistingIssue()
        async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = NativeWhisperExecutionHarness(
            modelID: "missing-model",
            modelURL: root.appendingPathComponent("missing.bin"),
            isReady: false
        )
        let service = try makeNativeService(snapshot: harness.snapshot())

        do {
            _ = try await service.transcribe(fileURL: try writeAudio(in: root))
            throw TestFailure("Missing Native Whisper model must fail")
        } catch let issue as QuillUserIssueError {
            try expect(issue.record.code == .localModelMissing, "missing model code")
            try expect(
                issue.record.context.modelID == "missing-model",
                "missing model context"
            )
            try expect(
                harness.recordedEventNames().isEmpty,
                "missing model stops before preflight"
            )
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

    private static func makeNativeService(
        snapshot: NativeWhisperExecutionSnapshot
    ) throws -> TranscriptionService {
        try TranscriptionService(
            apiKey: "",
            useLocalTranscription: true,
            transcriptionLanguage: .auto,
            localTranscriptionModel: .find(
                id: "mlx-community/whisper-large-v3-turbo"
            ),
            nativeWhisperExecution: snapshot
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

private final class NativeWhisperExecutionHarness: @unchecked Sendable {
    private let lock = NSLock()
    let modelID: String
    let modelURL: URL
    private var isReady: Bool
    private let preflightError: Error?
    private let preparationError: Error?
    private let preparedAudioURL: URL?
    private let resultText: String
    private var events: [Event] = []
    private var cleanupCount = 0

    private enum Event {
        case preflight(URL)
        case prepare(URL)
        case transcribe(audioURL: URL, modelURL: URL)

        var name: String {
            switch self {
            case .preflight: return "preflight"
            case .prepare: return "prepare"
            case .transcribe: return "transcribe"
            }
        }

        var modelURL: URL? {
            switch self {
            case .preflight(let url): return url
            case .prepare: return nil
            case .transcribe(_, let modelURL): return modelURL
            }
        }
    }

    init(
        modelID: String,
        modelURL: URL,
        isReady: Bool = true,
        preflightError: Error? = nil,
        preparationError: Error? = nil,
        preparedAudioURL: URL? = nil,
        resultText: String = "native transcript"
    ) {
        self.modelID = modelID
        self.modelURL = modelURL
        self.isReady = isReady
        self.preflightError = preflightError
        self.preparationError = preparationError
        self.preparedAudioURL = preparedAudioURL
        self.resultText = resultText
    }

    func snapshot() -> NativeWhisperExecutionSnapshot {
        NativeWhisperExecutionSnapshot(
            modelID: modelID,
            modelIsReady: { self.lock.withLock { self.isReady } },
            modelURL: { self.modelURL },
            validateRunnerAndModel: { url in
                try self.lock.withLock {
                    self.events.append(.preflight(url))
                    if let error = self.preflightError { throw error }
                }
            },
            prepareAudio: { url in
                let preparedURL = try self.lock.withLock {
                    self.events.append(.prepare(url))
                    if let error = self.preparationError { throw error }
                    return self.preparedAudioURL ?? url
                }
                return .init(
                    fileURL: preparedURL,
                    cleanup: {
                        self.lock.withLock { self.cleanupCount += 1 }
                    }
                )
            },
            transcribe: { audioURL, modelURL, _ in
                let text = self.lock.withLock {
                    self.events.append(
                        .transcribe(audioURL: audioURL, modelURL: modelURL)
                    )
                    return self.resultText
                }
                return TranscriptionResult(
                    text: text,
                    spokenLanguage: SpokenLanguageResolver.resolve(
                        requestedLanguageCode: "auto",
                        engineLanguageCode: nil,
                        transcript: text
                    )
                )
            }
        )
    }

    func recordedEventNames() -> [String] {
        lock.withLock { events.map(\.name) }
    }

    func recordedModelURLs() -> [URL] {
        lock.withLock { events.compactMap(\.modelURL) }
    }

    func recordedTranscriptionAudioURLs() -> [URL] {
        lock.withLock {
            events.compactMap { event in
                guard case .transcribe(let audioURL, _) = event else { return nil }
                return audioURL
            }
        }
    }

    func recordedCleanupCount() -> Int {
        lock.withLock { cleanupCount }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
