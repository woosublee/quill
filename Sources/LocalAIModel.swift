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
