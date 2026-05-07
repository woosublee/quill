import Foundation

enum TranscriptionModelCacheError: LocalizedError {
    case builtInModelCannotBeDownloaded
    case builtInModelCannotBeDeleted
    case downloaderNotFound(String)
    case downloadFailed(exitCode: Int32, output: String)
    case unsafeCachePath(String)
    case deleteFailed(String)

    var errorDescription: String? {
        switch self {
        case .builtInModelCannotBeDownloaded:
            return "Apple Speech is built in and does not need downloading."
        case .builtInModelCannotBeDeleted:
            return "Apple Speech is built in and cannot be deleted."
        case .downloaderNotFound(let path):
            return "Unable to find a Python environment for mlx_whisper at \(path). Install mlx-whisper with pipx or update the mlx_whisper path."
        case .downloadFailed(let exitCode, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "Model download failed with exit code \(exitCode)."
                : "Model download failed with exit code \(exitCode): \(detail)"
        case .unsafeCachePath(let path):
            return "Refusing to delete unexpected model cache path: \(path)"
        case .deleteFailed(let message):
            return "Unable to delete model cache: \(message)"
        }
    }
}

struct TranscriptionModel: Identifiable, Hashable, Codable {
    let id: String           // mlx-whisper에 넘기는 모델 ID (또는 "apple-speech" 센티넬)
    let displayName: String  // UI에 표시되는 이름
    let description: String  // 설명

    struct PythonInvocation: Equatable {
        let executableURL: URL
        let arguments: [String]
    }

    struct DownloadProgress: Equatable {
        let downloadedBytes: Int64
        let totalBytes: Int64?

        var fractionCompleted: Double? {
            guard let totalBytes, totalBytes > 0 else { return nil }
            return min(Double(downloadedBytes) / Double(totalBytes), 1)
        }

        var displayText: String {
            guard downloadedBytes > 0 else { return "Starting..." }
            let sizeText = ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
            if let fractionCompleted {
                return "\(Int((fractionCompleted * 100).rounded()))% · \(sizeText)"
            }
            return sizeText
        }
    }

    final class DownloadTask {
        private let process: Process
        private let lock = NSLock()
        private var cancelled = false

        init(process: Process) {
            self.process = process
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
            guard process.isRunning else { return }
            process.terminate()
        }

        deinit {
            cancel()
        }
    }

    static let all: [TranscriptionModel] = [
        TranscriptionModel(
            id: "apple-speech",
            displayName: "Apple Speech",
            description: "시스템 내장 · 온디바이스 · 빠름"
        ),
        TranscriptionModel(
            id: "mlx-community/whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            description: "빠름 · 정확도 높음 (추천)"
        ),
        TranscriptionModel(
            id: "mlx-community/whisper-large-v3-mlx",
            displayName: "Whisper Large v3",
            description: "최고 정확도 · 느림"
        ),
        TranscriptionModel(
            id: "mlx-community/whisper-medium-mlx",
            displayName: "Whisper Medium",
            description: "중간 속도 · 중간 정확도"
        ),
        TranscriptionModel(
            id: "mlx-community/whisper-small-mlx",
            displayName: "Whisper Small",
            description: "빠름 · 정확도 낮음"
        ),
    ]

    var isAppleSpeech: Bool { id == "apple-speech" }

    var estimatedDownloadBytes: Int64? {
        switch id {
        case "mlx-community/whisper-large-v3-turbo":
            return 810_000_000
        case "mlx-community/whisper-large-v3-mlx":
            return 3_100_000_000
        case "mlx-community/whisper-medium-mlx":
            return 1_600_000_000
        case "mlx-community/whisper-small-mlx":
            return 520_000_000
        default:
            return nil
        }
    }

    static let `default` = all[0]

    static func find(id: String) -> TranscriptionModel {
        all.first { $0.id == id } ?? .default
    }

    var cacheDirectoryName: String {
        "models--" + id.replacingOccurrences(of: "/", with: "--")
    }

    static func huggingFaceHubCacheRoot(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let hubCache = nonEmptyEnvironmentValue("HUGGINGFACE_HUB_CACHE", in: environment) {
            return expandedPathURL(hubCache, homeDirectory: homeDirectory)
        }
        if let hubCache = nonEmptyEnvironmentValue("HF_HUB_CACHE", in: environment) {
            return expandedPathURL(hubCache, homeDirectory: homeDirectory)
        }
        if let hfHome = nonEmptyEnvironmentValue("HF_HOME", in: environment) {
            return expandedPathURL(hfHome, homeDirectory: homeDirectory).appendingPathComponent("hub")
        }
        return homeDirectory.appendingPathComponent(".cache/huggingface/hub")
    }

    func cacheDirectory(in hubRoot: URL = TranscriptionModel.huggingFaceHubCacheRoot()) -> URL {
        hubRoot.appendingPathComponent(cacheDirectoryName)
    }

    func isInstalled(
        in hubRoot: URL = TranscriptionModel.huggingFaceHubCacheRoot(),
        fileManager: FileManager = .default
    ) -> Bool {
        if isAppleSpeech { return true }

        let cacheDir = cacheDirectory(in: hubRoot)
        let snapshotsDir = cacheDir.appendingPathComponent("snapshots")
        if let snapshots = try? fileManager.contentsOfDirectory(at: snapshotsDir, includingPropertiesForKeys: nil) {
            for snapshot in snapshots {
                if fileManager.fileExists(atPath: snapshot.appendingPathComponent("weights.npz").path) {
                    return true
                }
                if fileManager.fileExists(atPath: snapshot.appendingPathComponent("weights.safetensors").path) {
                    return true
                }
            }
        }

        let blobsDir = cacheDir.appendingPathComponent("blobs")
        if let blobs = try? fileManager.contentsOfDirectory(at: blobsDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for blob in blobs {
                let size = (try? blob.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if size > 100_000_000 {
                    return true
                }
            }
        }

        return false
    }

    var isInstalled: Bool {
        isInstalled()
    }

    func downloadProgress(
        in hubRoot: URL = TranscriptionModel.huggingFaceHubCacheRoot(),
        fileManager: FileManager = .default
    ) -> DownloadProgress {
        let blobsDir = cacheDirectory(in: hubRoot).appendingPathComponent("blobs")
        let blobs = (try? fileManager.contentsOfDirectory(at: blobsDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let downloadedBytes = blobs.reduce(Int64(0)) { total, blob in
            let size = Int64((try? blob.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            return total + size
        }
        return DownloadProgress(downloadedBytes: downloadedBytes, totalBytes: estimatedDownloadBytes)
    }

    func deleteCache(
        in hubRoot: URL = TranscriptionModel.huggingFaceHubCacheRoot(),
        fileManager: FileManager = .default
    ) throws {
        guard !isAppleSpeech else { throw TranscriptionModelCacheError.builtInModelCannotBeDeleted }

        let standardizedHubRoot = hubRoot.standardizedFileURL
        let target = cacheDirectory(in: standardizedHubRoot).standardizedFileURL
        guard target.deletingLastPathComponent().path == standardizedHubRoot.path,
              target.lastPathComponent == cacheDirectoryName else {
            throw TranscriptionModelCacheError.unsafeCachePath(target.path)
        }

        do {
            try fileManager.removeItem(at: target)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileNoSuchFileError {
                return
            }
            throw TranscriptionModelCacheError.deleteFailed(error.localizedDescription)
        }
    }

    @discardableResult
    func download(
        whisperBin: String,
        progress: @escaping (DownloadProgress) -> Void = { _ in },
        completion: @escaping (Result<Void, TranscriptionModelCacheError>) -> Void
    ) -> DownloadTask? {
        guard !isAppleSpeech else {
            DispatchQueue.main.async {
                completion(.failure(.builtInModelCannotBeDownloaded))
            }
            return nil
        }

        let process = Process()
        let task = DownloadTask(process: process)
        DispatchQueue.global(qos: .utility).async {
            let fileManager = FileManager.default
            let home = fileManager.homeDirectoryForCurrentUser
            let hubRoot = Self.huggingFaceHubCacheRoot(homeDirectory: home)
            guard let pythonInvocation = Self.pythonInvocation(for: whisperBin, homeDirectory: home, fileManager: fileManager) else {
                DispatchQueue.main.async {
                    completion(.failure(.downloaderNotFound(whisperBin)))
                }
                return
            }

            process.executableURL = pythonInvocation.executableURL
            process.arguments = pythonInvocation.arguments + [
                "-c",
                """
                import sys
                from huggingface_hub import snapshot_download
                snapshot_download(sys.argv[1])
                """,
                id
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = home.path
            environment["HUGGINGFACE_HUB_CACHE"] = hubRoot.path
            let existingPath = environment["PATH"] ?? "/usr/bin:/bin"
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home.path)/.local/bin:\(existingPath)"
            process.environment = environment

            let outputDirectory = fileManager.temporaryDirectory
            let outputID = UUID().uuidString
            let stdoutURL = outputDirectory.appendingPathComponent("quill-model-download-\(outputID).stdout")
            let stderrURL = outputDirectory.appendingPathComponent("quill-model-download-\(outputID).stderr")
            _ = fileManager.createFile(atPath: stdoutURL.path, contents: nil)
            _ = fileManager.createFile(atPath: stderrURL.path, contents: nil)
            defer {
                try? fileManager.removeItem(at: stdoutURL)
                try? fileManager.removeItem(at: stderrURL)
            }

            let stdoutHandle: FileHandle
            let stderrHandle: FileHandle
            do {
                stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
                stderrHandle = try FileHandle(forWritingTo: stderrURL)
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(.downloadFailed(exitCode: -1, output: error.localizedDescription)))
                }
                return
            }
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle

            guard !task.isCancelled else {
                try? stdoutHandle.close()
                try? stderrHandle.close()
                DispatchQueue.main.async {
                    completion(.failure(.downloadFailed(exitCode: -1, output: "Cancelled")))
                }
                return
            }

            do {
                try process.run()
            } catch {
                try? stdoutHandle.close()
                try? stderrHandle.close()
                DispatchQueue.main.async {
                    completion(.failure(.downloaderNotFound(pythonInvocation.executableURL.path)))
                }
                return
            }

            while process.isRunning {
                let currentProgress = self.downloadProgress(in: hubRoot)
                DispatchQueue.main.async {
                    progress(currentProgress)
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            process.waitUntilExit()
            try? stdoutHandle.close()
            try? stderrHandle.close()
            let stdoutText = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
            let stderrText = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
            let output = Self.summarizedOutput(stderrText.isEmpty ? stdoutText : stderrText)
            let installed = self.isInstalled(in: hubRoot)

            DispatchQueue.main.async {
                progress(self.downloadProgress(in: hubRoot))
                if process.terminationStatus == 0, installed {
                    completion(.success(()))
                } else {
                    completion(.failure(.downloadFailed(exitCode: process.terminationStatus, output: output)))
                }
            }
        }
        return task
    }

    private static func nonEmptyEnvironmentValue(_ key: String, in environment: [String: String]) -> String? {
        let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func expandedPathURL(_ path: String, homeDirectory: URL) -> URL {
        if path == "~" {
            return homeDirectory
        }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    static func pythonInvocation(
        for whisperBin: String,
        homeDirectory: URL,
        fileManager: FileManager
    ) -> PythonInvocation? {
        let expandedWhisperBin = expandedPathURL(whisperBin, homeDirectory: homeDirectory)
        let resolvedWhisperBin = expandedWhisperBin.resolvingSymlinksInPath()
        let candidates = [
            PythonInvocation(
                executableURL: expandedWhisperBin.deletingLastPathComponent().appendingPathComponent("python"),
                arguments: []
            ),
            PythonInvocation(
                executableURL: resolvedWhisperBin.deletingLastPathComponent().appendingPathComponent("python"),
                arguments: []
            ),
            shebangInvocation(for: expandedWhisperBin),
            PythonInvocation(
                executableURL: homeDirectory.appendingPathComponent(".local/pipx/venvs/mlx-whisper/bin/python"),
                arguments: []
            )
        ].compactMap { $0 }

        return candidates.first { fileManager.isExecutableFile(atPath: $0.executableURL.path) }
    }

    private static func shebangInvocation(for executable: URL) -> PythonInvocation? {
        guard let text = try? String(contentsOf: executable, encoding: .utf8),
              let firstLine = text.split(separator: "\n", maxSplits: 1).first,
              firstLine.hasPrefix("#!") else {
            return nil
        }
        let parts = firstLine.dropFirst(2).split(separator: " ").map(String.init)
        guard let command = parts.first,
              parts.contains(where: { $0.contains("python") }) || command.contains("python") else {
            return nil
        }
        return PythonInvocation(executableURL: URL(fileURLWithPath: command), arguments: Array(parts.dropFirst()))
    }

    private static func summarizedOutput(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lines = trimmed.split(separator: "\n").map(String.init)
        let head = lines.prefix(8).joined(separator: "\n")
        if lines.count > 8 {
            return head + "\n... (\(lines.count - 8) more lines)"
        }
        return head
    }
}
