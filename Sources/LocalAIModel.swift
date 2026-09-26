import CryptoKit
import Foundation

struct LocalAIModelArtifact: Identifiable, Hashable, Codable, Sendable {
    var id: String { expectedFileName }
    let downloadURL: URL
    let expectedFileName: String
    let approximateBytes: Int64
    let checksumSHA256: String
}

struct LocalAIModel: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let displayName: String
    let description: String
    let artifacts: [LocalAIModelArtifact]
    let approximateResidentRAMBytes: Int64
    let minimumPhysicalMemoryBytes: UInt64
    let capabilities: AIModelCapabilities
    let runtime: LocalAIRuntime
    /// Extra `llama-server` arguments this model needs, appended after the shared ones.
    let serverArguments: [String]
    /// Set when the model can transcribe audio; nil for text and vision models.
    let transcriptionRequestFormat: LocalASRRequestFormat?

    init(
        id: String,
        displayName: String,
        description: String,
        artifacts: [LocalAIModelArtifact],
        approximateResidentRAMBytes: Int64,
        minimumPhysicalMemoryBytes: UInt64 = 0,
        capabilities: AIModelCapabilities = AIModelCapabilityCatalog.qwenTextCapabilities,
        runtime: LocalAIRuntime = .textChat,
        serverArguments: [String] = [],
        transcriptionRequestFormat: LocalASRRequestFormat? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.artifacts = artifacts
        self.approximateResidentRAMBytes = approximateResidentRAMBytes
        self.minimumPhysicalMemoryBytes = minimumPhysicalMemoryBytes
        self.capabilities = capabilities
        self.runtime = runtime
        self.serverArguments = serverArguments
        self.transcriptionRequestFormat = transcriptionRequestFormat
    }

    var supportsTranscription: Bool {
        capabilities.supportsTranscription && transcriptionRequestFormat != nil
    }

    var approximateBytes: Int64 {
        artifacts.reduce(0) { $0 + $1.approximateBytes }
    }

    /// The first GGUF shard passed to `llama-server --model`.
    var primaryArtifact: LocalAIModelArtifact { artifacts[0] }

    func localizedDescription(
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> String {
        localizedCatalogString(description, language: language, bundle: bundle)
    }
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
        approximateResidentRAMBytes: 6_400_000_000,
        minimumPhysicalMemoryBytes: 16 * 1024 * 1024 * 1024,
        capabilities: AIModelCapabilityCatalog.qwenTextCapabilities,
        runtime: .textChat
    )

    static let gemma4E4B = LocalAIModel(
        id: "gemma-4-e4b-it",
        displayName: "Gemma 4 E4B",
        description: "Also reads screen context. One download covers every local feature it supports.",
        artifacts: [
            LocalAIModelArtifact(
                downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_K_M.gguf")!,
                expectedFileName: "gemma-4-E4B-it-Q4_K_M.gguf",
                approximateBytes: 4_977_171_584,
                checksumSHA256: "85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87"
            ),
            // BF16 is recommended for Gemma 4; F16 and Q8_0 projectors are
            // reported to cause repetition. Stored under a model-specific name
            // so another model's projector cannot collide in the shared folder.
            LocalAIModelArtifact(
                downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/mmproj-BF16.gguf")!,
                expectedFileName: "gemma-4-e4b-it-mmproj-BF16.gguf",
                approximateBytes: 991_552_320,
                checksumSHA256: "ee01cba03fd9c71ea2ea722225d24a84f72e7197714367e550ef705ef8851bc6"
            )
        ],
        // Measured about 6.4 GB resident with the projector loaded (llama.cpp
        // b11046, 16K context, one slot); rounded up for headroom.
        approximateResidentRAMBytes: 7_000_000_000,
        minimumPhysicalMemoryBytes: 16 * 1024 * 1024 * 1024,
        capabilities: AIModelCapabilityCatalog.gemma4LocalCapabilities,
        runtime: .visionChat(projectorArtifactFileName: "gemma-4-e4b-it-mmproj-BF16.gguf"),
        // Gemma 4 can emit its reasoning before the answer; Quill needs only the answer.
        serverArguments: ["--chat-template-kwargs", #"{"enable_thinking":false}"#],
        transcriptionRequestFormat: .chatCompletionsInputAudio
    )

    static let all: [LocalAIModel] = [quality, gemma4E4B]

    static var transcriptionModels: [LocalAIModel] {
        all.filter(\.supportsTranscription)
    }

    static func model(id: String) -> LocalAIModel? {
        all.first { $0.id == id }
    }

    static func capabilities(for id: String) -> AIModelCapabilities? {
        model(id: id)?.capabilities
    }
}

enum LocalAIInstallStatus: Equatable, Sendable {
    case notInstalled
    case partial(downloadedBytes: Int64, expectedBytes: Int64?)
    case ready
    case corrupt(String)
}

enum LocalAIModelStoreError: LocalizedError, Equatable {
    case recoveryFailed(String)

    var errorDescription: String? {
        switch self {
        case let .recoveryFailed(detail):
            return detail
        }
    }
}

struct LocalAIDownloadProgress: Equatable, Sendable {
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

    func localizedDisplayText(
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> String {
        if isCancelled {
            return localizedCatalogString("Canceled", language: language, bundle: bundle)
        }
        guard downloadedBytes > 0 else {
            return localizedCatalogString("Starting...", language: language, bundle: bundle)
        }
        let sizeText = ByteCountFormatter.string(
            fromByteCount: downloadedBytes,
            countStyle: .file
        )
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

    func backupArtifactURL(for artifact: LocalAIModelArtifact, token: String) -> URL {
        modelsDirectory.appendingPathComponent(
            "\(artifact.expectedFileName).backup-\(token)",
            isDirectory: false
        )
    }

    func modelURL(for model: LocalAIModel) -> URL {
        artifactURL(for: model.primaryArtifact)
    }

    func installStatus(for model: LocalAIModel) -> LocalAIInstallStatus {
        var downloadedBytes: Int64 = 0
        var hasArtifact = false

        for artifact in model.artifacts {
            let finalURL = artifactURL(for: artifact)
            if directoryEntryExists(at: finalURL) {
                hasArtifact = true
                if let error = validationError(for: artifact, at: finalURL) {
                    return .corrupt("\(artifact.expectedFileName): \(error)")
                }
                downloadedBytes += fileSize(at: finalURL)
                continue
            }

            let partialURL = partialArtifactURL(for: artifact)
            if directoryEntryExists(at: partialURL) {
                hasArtifact = true
                downloadedBytes += fileSize(at: partialURL)
            }
        }

        guard hasArtifact else { return .notInstalled }
        guard model.artifacts.allSatisfy({ directoryEntryExists(at: artifactURL(for: $0)) }) else {
            return .partial(downloadedBytes: downloadedBytes, expectedBytes: model.approximateBytes)
        }
        return .ready
    }

    func ensureModelsDirectoryExists() throws {
        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    func recoverInterruptedReplacement(for model: LocalAIModel) throws {
        try recoverInterruptedReplacement(
            for: model,
            copyItem: { try fileManager.copyItem(at: $0, to: $1) },
            removeItem: { try fileManager.removeItem(at: $0) }
        )
    }

    func recoverInterruptedReplacement(
        for model: LocalAIModel,
        copyItem: (URL, URL) throws -> Void,
        removeItem: (URL) throws -> Void
    ) throws {
        let transactions = try backupTransactions(for: model)
        guard !transactions.isEmpty else { return }

        if installStatus(for: model) == .ready {
            try cleanupBackups(for: model, removeItem: removeItem)
            return
        }

        let candidates = transactions.compactMap { token, artifactsByName -> (String, [String: URL], Date)? in
            guard model.artifacts.allSatisfy({ artifact in
                if validationError(for: artifact, at: artifactURL(for: artifact)) == nil {
                    return true
                }
                guard let backup = artifactsByName[artifact.expectedFileName] else { return false }
                return validationError(for: artifact, at: backup) == nil
            }) else { return nil }
            let latestDate = artifactsByName.values.compactMap {
                try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }.max() ?? .distantPast
            return (token, artifactsByName, latestDate)
        }
        guard let selected = candidates.max(by: { lhs, rhs in
            if lhs.2 == rhs.2 { return lhs.0 < rhs.0 }
            return lhs.2 < rhs.2
        }) else {
            return
        }

        for artifact in model.artifacts {
            let finalURL = artifactURL(for: artifact)
            if validationError(for: artifact, at: finalURL) == nil { continue }
            try removeIfPresent(finalURL, using: removeItem)
            guard let backupURL = selected.1[artifact.expectedFileName] else {
                throw LocalAIModelStoreError.recoveryFailed(
                    "Missing backup for \(artifact.expectedFileName) in transaction \(selected.0)."
                )
            }
            try copyItem(backupURL, finalURL)
        }

        guard installStatus(for: model) == .ready else {
            throw LocalAIModelStoreError.recoveryFailed(
                "Recovered package for model \(model.id) did not pass validation."
            )
        }
        try cleanupBackups(for: model, removeItem: removeItem)
    }

    func cleanupBackups(for model: LocalAIModel) throws {
        try cleanupBackups(for: model) { try fileManager.removeItem(at: $0) }
    }

    func cleanupBackups(
        for model: LocalAIModel,
        removeItem: (URL) throws -> Void
    ) throws {
        for url in try recognizedBackupURLs(for: model) {
            try removeIfPresent(url, using: removeItem)
        }
    }

    func deleteModel(_ model: LocalAIModel) throws {
        for artifact in model.artifacts {
            try removeIfPresent(artifactURL(for: artifact))
            try removeIfPresent(partialArtifactURL(for: artifact))
        }
        try cleanupBackups(for: model)
    }

    func deletePartialModel(_ model: LocalAIModel) throws {
        for artifact in model.artifacts {
            try removeIfPresent(partialArtifactURL(for: artifact))
        }
    }

    func validationError(for artifact: LocalAIModelArtifact, at url: URL) -> String? {
        guard directoryEntryExists(at: url) else {
            return "Model artifact is missing."
        }
        guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            return "Model artifact is not a regular file."
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

    private func backupTransactions(for model: LocalAIModel) throws -> [String: [String: URL]] {
        var transactions: [String: [String: URL]] = [:]
        for url in try recognizedBackupURLs(for: model) {
            let name = url.lastPathComponent
            guard let artifact = model.artifacts.first(where: { artifact in
                name.hasPrefix("\(artifact.expectedFileName).backup-")
            }) else { continue }
            let prefix = "\(artifact.expectedFileName).backup-"
            let token = String(name.dropFirst(prefix.count))
            transactions[token, default: [:]][artifact.expectedFileName] = url
        }
        return transactions
    }

    private func recognizedBackupURLs(for model: LocalAIModel) throws -> [URL] {
        guard directoryEntryExists(at: modelsDirectory) else { return [] }
        let contents = try fileManager.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        return contents.filter { url in
            let name = url.lastPathComponent
            return model.artifacts.contains { artifact in
                let prefix = "\(artifact.expectedFileName).backup-"
                guard name.hasPrefix(prefix) else { return false }
                let token = String(name.dropFirst(prefix.count))
                return UUID(uuidString: token) != nil
            }
        }
    }

    private func directoryEntryExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func removeIfPresent(_ url: URL) throws {
        try removeIfPresent(url) { try fileManager.removeItem(at: $0) }
    }

    private func removeIfPresent(
        _ url: URL,
        using removeItem: (URL) throws -> Void
    ) throws {
        if directoryEntryExists(at: url) {
            try removeItem(url)
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
