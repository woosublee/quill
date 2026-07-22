import CryptoKit
import Foundation

struct LocalAIModelArtifact: Identifiable, Hashable, Codable {
    var id: String { expectedFileName }
    let downloadURL: URL
    let expectedFileName: String
    let approximateBytes: Int64
    let checksumSHA256: String
}

struct LocalAIModel: Identifiable, Hashable, Codable {
    let id: String
    let displayName: String
    let description: String
    let artifacts: [LocalAIModelArtifact]
    let approximateResidentRAMBytes: Int64

    var approximateBytes: Int64 {
        artifacts.reduce(0) { $0 + $1.approximateBytes }
    }

    /// The first GGUF shard passed to `llama-server --model`.
    var primaryArtifact: LocalAIModelArtifact { artifacts[0] }
}

struct LocalAIModelCatalog {
    static let quality = LocalAIModel(
        id: "qwen2.5-7b-instruct",
        displayName: "Qwen2.5 7B Instruct",
        description: "Best quality. Needs more memory.",
        artifacts: [
            LocalAIModelArtifact(
                downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf")!,
                expectedFileName: "qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf",
                approximateBytes: 3_993_201_344,
                checksumSHA256: "dfce12e3862a5283ccfb88221b48480e58745165de856439950d0f22590580db"
            ),
            LocalAIModelArtifact(
                downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf")!,
                expectedFileName: "qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf",
                approximateBytes: 689_872_288,
                checksumSHA256: "539cf93f78e887edea1c04e2d7d8cdaca9d01dae9c9025bcb8accbe29df3d72a"
            )
        ],
        approximateResidentRAMBytes: 6_400_000_000
    )

    static let fast = LocalAIModel(
        id: "qwen2.5-3b-instruct",
        displayName: "Qwen2.5 3B Instruct",
        description: "Faster and lighter. Good for lower-memory Macs.",
        artifacts: [
            LocalAIModelArtifact(
                downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf")!,
                expectedFileName: "qwen2.5-3b-instruct-q4_k_m.gguf",
                approximateBytes: 2_104_932_768,
                checksumSHA256: "626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d"
            )
        ],
        approximateResidentRAMBytes: 3_200_000_000
    )

    static let recommended = quality
    static let all: [LocalAIModel] = [quality, fast]

    static func find(id: String) -> LocalAIModel {
        all.first { $0.id == id } ?? recommended
    }
}

enum LocalAIInstallStatus: Equatable {
    case notInstalled
    case partial(downloadedBytes: Int64, expectedBytes: Int64?)
    case ready
    case corrupt(String)
}

struct LocalAIDownloadProgress: Equatable {
    let downloadedBytes: Int64
    let totalBytes: Int64?
    let isCancelled: Bool

    init(downloadedBytes: Int64, totalBytes: Int64?, isCancelled: Bool = false) {
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.isCancelled = isCancelled
    }

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(Double(downloadedBytes) / Double(totalBytes), 1)
    }

    var displayText: String {
        if isCancelled { return "Canceled" }
        guard downloadedBytes > 0 else { return "Starting..." }
        let sizeText = ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
        if let fractionCompleted {
            return "\(Int((fractionCompleted * 100).rounded()))% · \(sizeText)"
        }
        return sizeText
    }
}

struct LocalAIModelStore {
    let rootDirectory: URL
    let fileManager: FileManager

    init(
        rootDirectory: URL = LocalAIModelStore.defaultRootDirectory(),
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    var modelsDirectory: URL {
        rootDirectory
            .appendingPathComponent("LocalAI", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    static func defaultRootDirectory() -> URL {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Quill"
        return applicationSupportDirectory.appendingPathComponent(appName, isDirectory: true)
    }

    func artifactURL(for artifact: LocalAIModelArtifact) -> URL {
        modelsDirectory.appendingPathComponent(artifact.expectedFileName, isDirectory: false)
    }

    func partialArtifactURL(for artifact: LocalAIModelArtifact) -> URL {
        modelsDirectory.appendingPathComponent("\(artifact.expectedFileName).download", isDirectory: false)
    }

    func modelURL(for model: LocalAIModel) -> URL {
        artifactURL(for: model.primaryArtifact)
    }

    func installStatus(for model: LocalAIModel) -> LocalAIInstallStatus {
        var downloadedBytes: Int64 = 0
        var hasArtifact = false

        for artifact in model.artifacts {
            let finalURL = artifactURL(for: artifact)
            if fileManager.fileExists(atPath: finalURL.path) {
                hasArtifact = true
                if let error = validationError(for: artifact, at: finalURL) {
                    return .corrupt("\(artifact.expectedFileName): \(error)")
                }
                downloadedBytes += fileSize(at: finalURL)
                continue
            }

            let partialURL = partialArtifactURL(for: artifact)
            if fileManager.fileExists(atPath: partialURL.path) {
                hasArtifact = true
                downloadedBytes += fileSize(at: partialURL)
            }
        }

        guard hasArtifact else { return .notInstalled }
        guard model.artifacts.allSatisfy({ fileManager.fileExists(atPath: artifactURL(for: $0).path) }) else {
            return .partial(downloadedBytes: downloadedBytes, expectedBytes: model.approximateBytes)
        }
        return .ready
    }

    func ensureModelsDirectoryExists() throws {
        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    func deleteModel(_ model: LocalAIModel) throws {
        for artifact in model.artifacts {
            try removeIfPresent(artifactURL(for: artifact))
            try removeIfPresent(partialArtifactURL(for: artifact))
        }
    }

    func deletePartialModel(_ model: LocalAIModel) throws {
        for artifact in model.artifacts {
            try removeIfPresent(partialArtifactURL(for: artifact))
        }
    }

    func validationError(for artifact: LocalAIModelArtifact, at url: URL) -> String? {
        guard fileManager.fileExists(atPath: url.path) else {
            return "Model artifact is missing."
        }
        guard ((try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true) else {
            return "Model artifact is not a regular file."
        }

        let bytes = fileSize(at: url)
        let minimumBytes = minimumReadyBytes(for: artifact)
        guard bytes >= minimumBytes else {
            let actual = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            let minimum = ByteCountFormatter.string(fromByteCount: minimumBytes, countStyle: .file)
            return "Model artifact is too small (\(actual)); expected at least \(minimum)."
        }

        let expectedChecksum = artifact.checksumSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !expectedChecksum.isEmpty else {
            return "Model artifact checksum is missing."
        }
        guard let actualChecksum = sha256HexDigest(at: url) else {
            return "Could not read model artifact for checksum verification."
        }
        guard actualChecksum == expectedChecksum else {
            return "Model artifact checksum mismatch."
        }
        return nil
    }

    private func minimumReadyBytes(for artifact: LocalAIModelArtifact) -> Int64 {
        guard artifact.approximateBytes > 0 else { return 1 }
        return max(1, Int64((Double(artifact.approximateBytes) * 0.95).rounded()))
    }

    private func removeIfPresent(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func sha256HexDigest(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: 1_048_576)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func fileSize(at url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}
