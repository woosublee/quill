import Foundation

@main
struct LocalAIModelTests {
    static func main() throws {
        try testQualityModelMetadata()
        try testFastModelMetadata()
        try testCatalogArtifactsAreCompleteAndValid()
        try testCatalogContainsBothModelsWithQualityRecommended()
        try testFindReturnsMatchingModelOrFallsBackToRecommended()
        try testDownloadProgressDisplayText()
        print("LocalAIModelTests passed")
    }

    private static func testQualityModelMetadata() throws {
        let model = LocalAIModelCatalog.quality
        assert(model.id == "qwen2.5-7b-instruct")
        assert(model.displayName == "Qwen2.5 7B Instruct")
        assert(model.artifacts.count == 2)

        let first = model.artifacts[0]
        assert(first.downloadURL.absoluteString == "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf")
        assert(first.expectedFileName == "qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf")
        assert(first.approximateBytes == 3_993_201_344)
        assert(first.checksumSHA256 == "dfce12e3862a5283ccfb88221b48480e58745165de856439950d0f22590580db")

        let second = model.artifacts[1]
        assert(second.downloadURL.absoluteString == "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf")
        assert(second.expectedFileName == "qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf")
        assert(second.approximateBytes == 689_872_288)
        assert(second.checksumSHA256 == "539cf93f78e887edea1c04e2d7d8cdaca9d01dae9c9025bcb8accbe29df3d72a")

        assert(model.approximateBytes == 4_683_073_632)
        assert(model.primaryArtifact == first)
        assert(model.approximateResidentRAMBytes > model.approximateBytes)
    }

    private static func testFastModelMetadata() throws {
        let model = LocalAIModelCatalog.fast
        assert(model.id == "qwen2.5-1.5b-instruct")
        assert(model.displayName == "Qwen2.5 1.5B Instruct")
        assert(model.artifacts.count == 1)

        let artifact = model.artifacts[0]
        assert(artifact.downloadURL.absoluteString == "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")
        assert(artifact.expectedFileName == "qwen2.5-1.5b-instruct-q4_k_m.gguf")
        assert(artifact.approximateBytes == 1_117_320_736)
        assert(artifact.checksumSHA256 == "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e")

        assert(model.approximateBytes == 1_117_320_736)
        assert(model.approximateResidentRAMBytes == 2_500_000_000)
        assert(model.approximateResidentRAMBytes > model.approximateBytes)
        assert(model.approximateBytes < LocalAIModelCatalog.quality.approximateBytes)
        assert(model.primaryArtifact == artifact)
    }

    private static func testCatalogArtifactsAreCompleteAndValid() throws {
        for model in LocalAIModelCatalog.all {
            assert(!model.artifacts.isEmpty)
            assert(Set(model.artifacts.map(\.expectedFileName)).count == model.artifacts.count)
            for artifact in model.artifacts {
                assert(artifact.checksumSHA256.count == 64)
                assert(artifact.checksumSHA256.allSatisfy { $0.isHexDigit })
            }
        }
    }

    private static func testCatalogContainsBothModelsWithQualityRecommended() throws {
        assert(LocalAIModelCatalog.all.map(\.id) == ["qwen2.5-7b-instruct", "qwen2.5-1.5b-instruct"])
        assert(LocalAIModelCatalog.recommended.id == LocalAIModelCatalog.quality.id)
    }

    private static func testFindReturnsMatchingModelOrFallsBackToRecommended() throws {
        assert(LocalAIModelCatalog.find(id: "qwen2.5-1.5b-instruct").id == "qwen2.5-1.5b-instruct")
        assert(LocalAIModelCatalog.find(id: "does-not-exist").id == LocalAIModelCatalog.recommended.id)
    }

    private static func testDownloadProgressDisplayText() throws {
        assert(LocalAIDownloadProgress(downloadedBytes: 0, totalBytes: 100).displayText == "Starting...")
        assert(LocalAIDownloadProgress(downloadedBytes: 50, totalBytes: 100).displayText == "50% · 50 bytes")
        assert(LocalAIDownloadProgress(downloadedBytes: 100, totalBytes: 100, isCancelled: true).displayText == "Canceled")
    }
}
