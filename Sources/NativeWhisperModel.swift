import Foundation

struct NativeWhisperModel: Identifiable, Hashable, Codable {
    let id: String
    let displayName: String
    let description: String
    let downloadURL: URL
    let expectedFileName: String
    let approximateBytes: Int64
    let checksumSHA256: String?

    static var recommended: NativeWhisperModel { NativeWhisperModelCatalog.recommended }
}

struct NativeWhisperModelCatalog {
    static let recommended = NativeWhisperModel(
        id: "whisper-large-v3-turbo",
        displayName: "Whisper Large v3 Turbo",
        description: "Fast local transcription with high accuracy. Recommended.",
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
        expectedFileName: "ggml-large-v3-turbo.bin",
        approximateBytes: 1_620_000_000,
        checksumSHA256: nil
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
            if let checksum = model.checksumSHA256, !checksum.isEmpty {
                return .corrupt("Checksum verification is not implemented for this model yet.")
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

    private func fileSize(at url: URL) -> Int64 {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Int64(size)
    }
}
