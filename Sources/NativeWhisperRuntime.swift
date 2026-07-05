import Foundation

enum NativeWhisperRuntimeError: LocalizedError, Equatable {
    case runnerNotFound(String)
    case modelNotFound(String)
    case audioNotReadable(String)
    case processFailed(exitCode: Int32, output: String)
    case noTranscript(output: String)

    var errorDescription: String? {
        switch self {
        case .runnerNotFound:
            return "Local Whisper runtime is not available in this app build."
        case .modelNotFound:
            return "Local Whisper model is not installed yet."
        case .audioNotReadable:
            return "Local Whisper could not read this recording."
        case .processFailed:
            return "Local Whisper failed while transcribing this recording."
        case .noTranscript:
            return "Local Whisper produced no transcript."
        }
    }

    var technicalDetails: String {
        switch self {
        case .runnerNotFound(let path): return "Runner not found or not executable: \(path)"
        case .modelNotFound(let path): return "Model file not found: \(path)"
        case .audioNotReadable(let path): return "Audio file missing, empty, or unreadable: \(path)"
        case .processFailed(let exitCode, let output): return "Exit code \(exitCode). Output: \(output)"
        case .noTranscript(let output): return "No transcript. Output: \(output)"
        }
    }
}

struct NativeWhisperRuntime {
    let runnerURL: URL
    let fileManager: FileManager

    init(
        runnerURL: URL = NativeWhisperRuntime.defaultRunnerURL() ?? URL(fileURLWithPath: "/__missing_whisper_cli__"),
        fileManager: FileManager = .default
    ) {
        self.runnerURL = runnerURL
        self.fileManager = fileManager
    }

    static func defaultRunnerURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "whisper-cli", withExtension: nil, subdirectory: "whisper")
    }

    func transcribe(audioURL: URL, modelURL: URL, languageCode: String?) async throws -> String {
        let worker = Task.detached(priority: .userInitiated) {
            guard fileManager.isExecutableFile(atPath: runnerURL.path) else {
                throw NativeWhisperRuntimeError.runnerNotFound(runnerURL.path)
            }
            guard fileManager.fileExists(atPath: modelURL.path) else {
                throw NativeWhisperRuntimeError.modelNotFound(modelURL.path)
            }
            guard fileManager.isReadableFile(atPath: audioURL.path), fileSize(at: audioURL) > 0 else {
                throw NativeWhisperRuntimeError.audioNotReadable(audioURL.path)
            }

            let outputBase = fileManager.temporaryDirectory
                .appendingPathComponent("quill-native-whisper-\(UUID().uuidString)")
            defer {
                try? fileManager.removeItem(at: outputBase.appendingPathExtension("json"))
                try? fileManager.removeItem(at: outputBase.appendingPathExtension("txt"))
            }

            let process = Process()
            process.executableURL = runnerURL
            var arguments = [
                "-m", modelURL.path,
                "-f", audioURL.path,
                "-nt",
                "-oj",
                "-of", outputBase.path
            ]
            if let languageCode, !languageCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                arguments += ["-l", languageCode]
            }
            process.arguments = arguments
            process.environment = [
                "PATH": "/usr/bin:/bin",
                "HOME": fileManager.homeDirectoryForCurrentUser.path
            ]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let processLock = NSLock()
            try process.run()
            let stdoutReader = Task.detached {
                String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            }
            let stderrReader = Task.detached {
                String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            }
            await withTaskCancellationHandler {
                process.waitUntilExit()
            } onCancel: {
                processLock.lock()
                if process.isRunning {
                    process.terminate()
                }
                processLock.unlock()
            }
            try Task.checkCancellation()

            let stdoutText = await stdoutReader.value
            let stderrText = await stderrReader.value
            let combinedOutput = Self.summarizedOutput(stderrText.isEmpty ? stdoutText : stderrText)
            guard process.terminationStatus == 0 else {
                throw NativeWhisperRuntimeError.processFailed(exitCode: process.terminationStatus, output: combinedOutput)
            }

            if let jsonTranscript = Self.transcriptFromJSON(at: outputBase.appendingPathExtension("json")), !jsonTranscript.isEmpty {
                return jsonTranscript
            }
            let stdoutTranscript = Self.normalizedTranscript(stdoutText)
            if !stdoutTranscript.isEmpty {
                return stdoutTranscript
            }
            throw NativeWhisperRuntimeError.noTranscript(output: combinedOutput)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func fileSize(at url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    private static func transcriptFromJSON(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let text = object["text"] as? String {
            return normalizedTranscript(text)
        }
        if let transcription = object["transcription"] as? [[String: Any]] {
            let joined = transcription.compactMap { $0["text"] as? String }.joined(separator: " ")
            return normalizedTranscript(joined)
        }
        return nil
    }

    private static func normalizedTranscript(_ text: String) -> String {
        text
            .split(separator: "\n")
            .map { line in
                line.replacingOccurrences(of: #"^\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func summarizedOutput(_ text: String) -> String {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").map(String.init)
        guard !lines.isEmpty else { return "" }
        if lines.count <= 8 { return lines.joined(separator: "\n") }
        let head = lines.prefix(4)
        let tail = lines.suffix(4)
        return (head + ["... (\(lines.count - 8) more lines)"] + tail).joined(separator: "\n")
    }
}
