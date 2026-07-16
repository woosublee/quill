import CryptoKit
import Foundation

struct NativeWhisperModel: Identifiable, Hashable, Codable {
    let id: String
    let displayName: String
    let description: String
    let downloadURL: URL
    let expectedFileName: String
    let approximateBytes: Int64
    let checksumSHA256: String

    static var recommended: NativeWhisperModel { NativeWhisperModelCatalog.recommended }

    /// Resolves only user-facing copy. Download metadata and file identity stay unchanged.
    func localizedDescription(language: String = Locale.current.language.languageCode?.identifier ?? "en") -> String {
        guard id == "whisper-large-v3-turbo" else { return description }
        return language.lowercased().hasPrefix("ko")
            ? "빠르고 정확한 로컬 받아쓰기. 추천."
            : "Fast local transcription with high accuracy. Recommended."
    }
}

struct NativeWhisperModelCatalog {
    static let recommended = NativeWhisperModel(
        id: "whisper-large-v3-turbo",
        displayName: "Whisper Large v3 Turbo",
        description: "Fast local transcription with high accuracy. Recommended.",
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
        expectedFileName: "ggml-large-v3-turbo.bin",
        approximateBytes: 1_624_555_275,
        checksumSHA256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
    )

    static let all: [NativeWhisperModel] = [recommended]

    static func find(id: String) -> NativeWhisperModel {
        all.first { $0.id == id } ?? recommended
    }
}

enum NativeWhisperInstallStatus: Equatable {
    case notInstalled
    case partial(downloadedBytes: Int64, expectedBytes: Int64?)
    case ready
    case corrupt(String)
}

struct NativeWhisperDownloadProgress: Equatable {
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

struct NativeWhisperModelStore {
    let rootDirectory: URL
    let fileManager: FileManager

    init(
        rootDirectory: URL = NativeWhisperModelStore.defaultRootDirectory(),
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    var modelsDirectory: URL {
        rootDirectory
            .appendingPathComponent("LocalWhisper", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    static func defaultRootDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Quill"
        return appSupport.appendingPathComponent(appName, isDirectory: true)
    }

    func modelURL(for model: NativeWhisperModel) -> URL {
        modelsDirectory.appendingPathComponent(model.expectedFileName, isDirectory: false)
    }

    func partialModelURL(for model: NativeWhisperModel) -> URL {
        modelsDirectory.appendingPathComponent("\(model.expectedFileName).download", isDirectory: false)
    }

    func installStatus(for model: NativeWhisperModel) -> NativeWhisperInstallStatus {
        let finalURL = modelURL(for: model)
        if fileManager.fileExists(atPath: finalURL.path) {
            if let error = validationError(for: model, at: finalURL) {
                return .corrupt(error)
            }
            return .ready
        }

        let partialURL = partialModelURL(for: model)
        if fileManager.fileExists(atPath: partialURL.path) {
            let bytes = fileSize(at: partialURL)
            return .partial(downloadedBytes: bytes, expectedBytes: model.approximateBytes)
        }

        return .notInstalled
    }

    func ensureModelsDirectoryExists() throws {
        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    func deleteModel(_ model: NativeWhisperModel) throws {
        let paths = [modelURL(for: model), partialModelURL(for: model)]
        for url in paths where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func deletePartialModel(_ model: NativeWhisperModel) throws {
        let partialURL = partialModelURL(for: model)
        if fileManager.fileExists(atPath: partialURL.path) {
            try fileManager.removeItem(at: partialURL)
        }
    }

    func validationError(for model: NativeWhisperModel, at url: URL) -> String? {
        guard fileManager.fileExists(atPath: url.path) else {
            return "Model file is missing."
        }
        guard ((try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true) else {
            return "Model path is not a regular file."
        }
        let bytes = fileSize(at: url)
        let minimumBytes = minimumReadyBytes(for: model)
        guard bytes >= minimumBytes else {
            let actual = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            let minimum = ByteCountFormatter.string(fromByteCount: minimumBytes, countStyle: .file)
            return "Model file is too small (\(actual)); expected at least \(minimum)."
        }
        if let checksumError = checksumValidationError(for: model, at: url) {
            return checksumError
        }
        return nil
    }

    private func minimumReadyBytes(for model: NativeWhisperModel) -> Int64 {
        guard model.approximateBytes > 0 else { return 1 }
        return max(1, Int64((Double(model.approximateBytes) * 0.95).rounded()))
    }

    private func checksumValidationError(for model: NativeWhisperModel, at url: URL) -> String? {
        let expected = model.checksumSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !expected.isEmpty else {
            return "Model checksum is missing."
        }
        guard let actual = sha256HexDigest(at: url) else {
            return "Could not read model file for checksum verification."
        }
        guard actual == expected else {
            return "Model checksum mismatch."
        }
        return nil
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
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Int64(size)
    }
}
