import Foundation

@main
struct NativeWhisperRuntimeTests {
    static func main() async throws {
        try await testRuntimeReturnsStdoutTranscript()
        try await testRuntimeReadsOutputJSONTextField()
        try await testRuntimeKeepsGPUEnabledAndDisablesTextContext()
        try await testRuntimeRejectsMissingRunner()
        try await testRuntimeRejectsMissingModel()
        try await testRuntimeRejectsMissingAudio()
        try testRuntimePreflightsRunnerAndModel()
        try await testRuntimeReportsNonZeroExitWithTailDetails()
        try await testRuntimeTerminatesHelperOnCancellation()
        print("NativeWhisperRuntimeTests passed")
    }

    private static func testRuntimeReturnsStdoutTranscript() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = try writeHelper(root: root, body: """
        #!/bin/sh
        echo "hello from native whisper"
        """)
        let model = try writeFile(root.appendingPathComponent("model.bin"), data: Data([1]))
        let audio = try writeFile(root.appendingPathComponent("audio.wav"), data: Data([2]))
        let runtime = NativeWhisperRuntime(runnerURL: helper)

        let transcript = try await runtime.transcribe(audioURL: audio, modelURL: model, languageCode: "en")

        assert(transcript == "hello from native whisper")
    }

    private static func testRuntimeReadsOutputJSONTextField() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = try writeHelper(root: root, body: """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-of" ]; then
            shift
            printf '{"text":"json transcript"}' > "$1.json"
            exit 0
          fi
          shift
        done
        exit 2
        """)
        let model = try writeFile(root.appendingPathComponent("model.bin"), data: Data([1]))
        let audio = try writeFile(root.appendingPathComponent("audio.wav"), data: Data([2]))
        let runtime = NativeWhisperRuntime(runnerURL: helper)

        let transcript = try await runtime.transcribe(audioURL: audio, modelURL: model, languageCode: "ko")

        assert(transcript == "json transcript")
    }

    private static func testRuntimeKeepsGPUEnabledAndDisablesTextContext() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let argsFile = root.appendingPathComponent("args.txt")
        let helper = try writeHelper(root: root, body: """
        #!/bin/sh
        printf '%s\n' "$@" > "\(argsFile.path)"
        echo "ok"
        """)
        let model = try writeFile(root.appendingPathComponent("model.bin"), data: Data([1]))
        let audio = try writeFile(root.appendingPathComponent("audio.wav"), data: Data([2]))
        let runtime = NativeWhisperRuntime(runnerURL: helper)

        _ = try await runtime.transcribe(audioURL: audio, modelURL: model, languageCode: nil)

        let args = try String(contentsOf: argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        let maxContextIndex = args.firstIndex(of: "-mc")
        assert(maxContextIndex != nil, "Expected native whisper runtime to set max context")
        assert(args.dropFirst(maxContextIndex! + 1).first == "0", "Expected native whisper runtime to disable previous text conditioning")
        assert(!args.contains("-ng"), "Expected Native Whisper to keep GPU enabled")
        assert(!args.contains("--no-gpu"), "Expected Native Whisper to keep GPU enabled")
        assert(!args.contains("-ngl"), "Expected whisper-cli GPU policy, not generic layer offload")
    }

    private static func testRuntimeRejectsMissingRunner() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try writeFile(root.appendingPathComponent("model.bin"), data: Data([1]))
        let audio = try writeFile(root.appendingPathComponent("audio.wav"), data: Data([2]))
        let runtime = NativeWhisperRuntime(runnerURL: root.appendingPathComponent("missing-helper"))

        do {
            _ = try await runtime.transcribe(audioURL: audio, modelURL: model, languageCode: nil)
            assertionFailure("Expected missing runner error")
        } catch let error as NativeWhisperRuntimeError {
            assert(error == .runnerNotFound(runtime.runnerURL.path))
        }
    }

    private static func testRuntimeRejectsMissingModel() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = try writeHelper(root: root, body: "#!/bin/sh\necho should-not-run\n")
        let audio = try writeFile(root.appendingPathComponent("audio.wav"), data: Data([2]))
        let runtime = NativeWhisperRuntime(runnerURL: helper)

        do {
            _ = try await runtime.transcribe(audioURL: audio, modelURL: root.appendingPathComponent("missing.bin"), languageCode: nil)
            assertionFailure("Expected missing model error")
        } catch let error as NativeWhisperRuntimeError {
            assert(error == .modelNotFound(root.appendingPathComponent("missing.bin").path))
        }
    }

    private static func testRuntimeRejectsMissingAudio() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = try writeHelper(root: root, body: "#!/bin/sh\necho should-not-run\n")
        let model = try writeFile(root.appendingPathComponent("model.bin"), data: Data([1]))
        let runtime = NativeWhisperRuntime(runnerURL: helper)

        do {
            _ = try await runtime.transcribe(audioURL: root.appendingPathComponent("missing.wav"), modelURL: model, languageCode: nil)
            assertionFailure("Expected missing audio error")
        } catch let error as NativeWhisperRuntimeError {
            assert(error == .audioNotReadable(root.appendingPathComponent("missing.wav").path))
        }
    }

    private static func testRuntimePreflightsRunnerAndModel() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = try writeHelper(root: root, body: "#!/bin/sh\necho should-not-run\n")
        let model = try writeFile(root.appendingPathComponent("model.bin"), data: Data([1]))
        let runtime = NativeWhisperRuntime(runnerURL: helper)

        try runtime.validateRunnerAndModel(modelURL: model)

        do {
            try NativeWhisperRuntime(runnerURL: root.appendingPathComponent("missing-helper"))
                .validateRunnerAndModel(modelURL: model)
            assertionFailure("Expected missing runner error")
        } catch let error as NativeWhisperRuntimeError {
            assert(error == .runnerNotFound(root.appendingPathComponent("missing-helper").path))
        }

        do {
            try runtime.validateRunnerAndModel(modelURL: root.appendingPathComponent("missing.bin"))
            assertionFailure("Expected missing model error")
        } catch let error as NativeWhisperRuntimeError {
            assert(error == .modelNotFound(root.appendingPathComponent("missing.bin").path))
        }
    }

    private static func testRuntimeReportsNonZeroExitWithTailDetails() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = try writeHelper(root: root, body: """
        #!/bin/sh
        echo "first line" >&2
        echo "second line" >&2
        echo "final cause" >&2
        exit 7
        """)
        let model = try writeFile(root.appendingPathComponent("model.bin"), data: Data([1]))
        let audio = try writeFile(root.appendingPathComponent("audio.wav"), data: Data([2]))
        let runtime = NativeWhisperRuntime(runnerURL: helper)

        do {
            _ = try await runtime.transcribe(audioURL: audio, modelURL: model, languageCode: nil)
            assertionFailure("Expected process failure")
        } catch let error as NativeWhisperRuntimeError {
            guard case .processFailed(let exitCode, let output) = error else {
                assertionFailure("Unexpected error: \(error)")
                return
            }
            assert(exitCode == 7)
            assert(output.contains("final cause"))
        }
    }

    private static func testRuntimeTerminatesHelperOnCancellation() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("helper.pid")
        let helper = try writeHelper(root: root, body: """
        #!/bin/sh
        echo $$ > "\(pidFile.path)"
        while true; do sleep 1; done
        """)
        let model = try writeFile(root.appendingPathComponent("model.bin"), data: Data([1]))
        let audio = try writeFile(root.appendingPathComponent("audio.wav"), data: Data([2]))
        let runtime = NativeWhisperRuntime(runnerURL: helper)
        let task = Task {
            try await runtime.transcribe(audioURL: audio, modelURL: model, languageCode: nil)
        }
        assert(waitForFile(pidFile, timeout: 5), "Expected helper to write its pid")
        let pid = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

        task.cancel()
        do {
            _ = try await task.value
            assertionFailure("Expected cancellation")
        } catch is CancellationError {
        } catch {
            assertionFailure("Expected cancellation, got \(error)")
        }

        assert(waitForProcessExit(pid: pid, timeout: 5), "Expected helper process to exit on cancellation")
    }

    private static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-native-whisper-runtime-tests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private static func writeFile(_ url: URL, data: Data) throws -> URL {
        FileManager.default.createFile(atPath: url.path, contents: data)
        return url
    }

    private static func writeHelper(root: URL, body: String) throws -> URL {
        let helper = root.appendingPathComponent("fake-whisper-cli")
        try body.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return helper
    }

    private static func waitForFile(_ url: URL, timeout seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func waitForProcessExit(pid: String, timeout seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/kill")
            process.arguments = ["-0", pid]
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }
}
