import Foundation

@main
struct LocalAIModelTests {
    static func main() throws {
        try testQualityModelMetadata()
        try testQwenIsTextOnly()
        try testGemmaModelMetadata()
        try testGemmaSupportsTranscriptionAndQwenDoesNot()
        try testCapabilityLookupUsesStoredModelDescriptors()
        try testCatalogArtifactsAreCompleteAndValid()
        try testCatalogListsQwenThenGemma()
        try testQwen3ASRModelMetadata()
        try testRetiredModelDoesNotHaveProductStorageMetadata()
        try testDownloadProgressDisplayText()
        try testLocalizedModelMetadataAndDownloadProgress()
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

    private static func testQwenIsTextOnly() throws {
        let model = LocalAIModelCatalog.quality
        assert(model.runtime == .textChat)
        assert(model.capabilities.supports(.postProcessing))
        assert(model.capabilities.supports(.meetingSummary))
        assert(!model.capabilities.supportsContextCapture)
        assert(model.serverArguments.isEmpty)
    }

    // One download serves post-processing, meeting summaries, and screen context.
    private static func testQwen3ASRModelMetadata() throws {
        let model = LocalAIModelCatalog.qwen3ASR06B
        assert(model.id == "qwen3-asr-0.6b")
        assert(model.displayName == "Qwen3-ASR 0.6B")
        assert(model.artifacts.count == 2)

        let weights = model.artifacts[0]
        assert(weights.downloadURL.absoluteString == "https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF/resolve/main/Qwen3-ASR-0.6B-Q8_0.gguf")
        assert(weights.expectedFileName == "Qwen3-ASR-0.6B-Q8_0.gguf")
        assert(weights.approximateBytes == 804_749_248)
        assert(weights.checksumSHA256 == "bca259818b50ca7c4c05e9bdb35a5dc04fa039653a6d6f3f0f331f96f6aa1971")

        let projector = model.artifacts[1]
        assert(projector.downloadURL.absoluteString == "https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF/resolve/main/mmproj-Qwen3-ASR-0.6B-Q8_0.gguf")
        assert(projector.expectedFileName == "qwen3-asr-0.6b-mmproj-Q8_0.gguf")
        assert(projector.approximateBytes == 214_392_480)
        assert(projector.checksumSHA256 == "41a342b5e4c514e968cb756de6cd1b7be39eff43c44c57a2ef5fc6522e36603d")

        assert(model.runtime == .visionChat(projectorArtifactFileName: "qwen3-asr-0.6b-mmproj-Q8_0.gguf"))
        // Transcription only: never offered for cleanup, summaries, or Context.
        assert(model.supportsTranscription)
        assert(model.transcriptionRequestFormat == .qwen3ASRChatCompletions)
        assert(!model.capabilities.supports(.postProcessing))
        assert(!model.capabilities.supports(.meetingSummary))
        assert(!model.capabilities.supportsContextCapture)
        assert(model.capabilities.recommendedContextWindow == 4_096)
        assert(model.minimumPhysicalMemoryBytes == 8 * 1024 * 1024 * 1024)
        assert(model.approximateResidentRAMBytes > model.approximateBytes)
        assert(model.serverArguments.isEmpty)
    }

    private static func testGemmaModelMetadata() throws {
        let model = LocalAIModelCatalog.gemma4E4B
        assert(model.id == "gemma-4-e4b-it")
        assert(model.displayName == "Gemma 4 E4B")
        assert(model.artifacts.count == 2)

        let weights = model.artifacts[0]
        assert(weights.downloadURL.absoluteString == "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_K_M.gguf")
        assert(weights.expectedFileName == "gemma-4-E4B-it-Q4_K_M.gguf")
        assert(weights.approximateBytes == 4_977_171_584)
        assert(weights.checksumSHA256 == "85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87")

        let projector = model.artifacts[1]
        assert(projector.downloadURL.absoluteString == "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/mmproj-BF16.gguf")
        assert(projector.expectedFileName == "gemma-4-e4b-it-mmproj-BF16.gguf")
        assert(projector.approximateBytes == 991_552_320)
        assert(projector.checksumSHA256 == "ee01cba03fd9c71ea2ea722225d24a84f72e7197714367e550ef705ef8851bc6")

        assert(model.primaryArtifact == weights)
        assert(model.runtime == .visionChat(projectorArtifactFileName: "gemma-4-e4b-it-mmproj-BF16.gguf"))
        assert(model.capabilities.supports(.postProcessing))
        assert(model.capabilities.supports(.meetingSummary))
        assert(model.capabilities.supportsContextCapture)
        assert(model.capabilities.recommendedContextWindow == 16_384)
        assert(model.minimumPhysicalMemoryBytes == 16 * 1024 * 1024 * 1024)
        assert(model.approximateResidentRAMBytes > model.approximateBytes)
        // Thinking output must never reach transcripts or summaries.
        assert(model.serverArguments == ["--chat-template-kwargs", #"{"enable_thinking":false}"#])
    }

    private static func testGemmaSupportsTranscriptionAndQwenDoesNot() throws {
        let gemma = LocalAIModelCatalog.gemma4E4B
        assert(gemma.capabilities.supports(.transcription))
        assert(gemma.capabilities.modalities.contains(.audio))
        assert(gemma.transcriptionRequestFormat == .chatCompletionsInputAudio)
        assert(gemma.supportsTranscription)

        let qwen = LocalAIModelCatalog.quality
        assert(!qwen.capabilities.supports(.transcription))
        assert(qwen.transcriptionRequestFormat == nil)
        assert(!qwen.supportsTranscription)

        assert(LocalAIModelCatalog.transcriptionModels.map(\.id) == ["gemma-4-e4b-it", "qwen3-asr-0.6b"])
    }

    private static func testCapabilityLookupUsesStoredModelDescriptors() throws {
        for model in LocalAIModelCatalog.all {
            assert(LocalAIModelCatalog.capabilities(for: model.id) == model.capabilities)
        }
        assert(LocalAIModelCatalog.capabilities(for: "does-not-exist") == nil)
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

    private static func testCatalogListsQwenThenGemma() throws {
        assert(LocalAIModelCatalog.all.map(\.id) == ["qwen2.5-7b-instruct", "gemma-4-e4b-it", "qwen3-asr-0.6b"])
        assert(LocalAIModelCatalog.model(id: "qwen3-asr-0.6b") == LocalAIModelCatalog.qwen3ASR06B)
        assert(LocalAIModelCatalog.model(id: "gemma-4-e4b-it") == LocalAIModelCatalog.gemma4E4B)
        assert(LocalAIModelCatalog.model(id: "qwen2.5-7b-instruct") == LocalAIModelCatalog.quality)
        assert(LocalAIModelCatalog.model(id: "does-not-exist") == nil)
    }

    private static func testRetiredModelDoesNotHaveProductStorageMetadata() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let retiredModelID = "qwen2.5-1.5b-instruct"
        let retiredArtifactName = "qwen2.5-1.5b-instruct-q4_k_m.gguf"
        let productSources = try [
            "Sources/LocalAIModel.swift",
            "Sources/AIModelCapabilities.swift",
            "Sources/LocalAIInstaller.swift",
            "Sources/LocalAIServerManager.swift"
        ].map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }

        assert(LocalAIModelCatalog.model(id: retiredModelID) == nil)
        assert(LocalAIModelCatalog.capabilities(for: retiredModelID) == nil)
        for source in productSources {
            assert(!source.contains(retiredModelID))
            assert(!source.contains(retiredArtifactName))
            assert(!source.contains("Qwen2.5-1.5B-Instruct-GGUF"))
        }
    }

    private static func testDownloadProgressDisplayText() throws {
        assert(LocalAIDownloadProgress(downloadedBytes: 0, totalBytes: 100).displayText == "Starting...")
        assert(LocalAIDownloadProgress(downloadedBytes: 50, totalBytes: 100).displayText == "50% · 50 bytes")
        assert(LocalAIDownloadProgress(downloadedBytes: 100, totalBytes: 100, isCancelled: true).displayText == "Canceled")
    }

    private static func testLocalizedModelMetadataAndDownloadProgress() throws {
        let bundle = try compiledLocalizationBundle()

        assert(
            LocalAIModelCatalog.quality.localizedDescription(
                language: "ko",
                bundle: bundle
            ) == "최고 품질입니다. 더 많은 메모리가 필요합니다."
        )
        assert(
            LocalAIDownloadProgress(
                downloadedBytes: 0,
                totalBytes: 100
            ).localizedDisplayText(language: "ko", bundle: bundle) == "시작하는 중..."
        )
        assert(
            LocalAIDownloadProgress(
                downloadedBytes: 100,
                totalBytes: 100,
                isCancelled: true
            ).localizedDisplayText(language: "ko", bundle: bundle) == "취소됨"
        )
        assert(
            LocalAIDownloadProgress(
                downloadedBytes: 50,
                totalBytes: 100
            ).localizedDisplayText(language: "ko", bundle: bundle) == "50% · 50 bytes"
        )
    }

    private static func compiledLocalizationBundle() throws -> Bundle {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let localizationRoot = root.appendingPathComponent("build/localization")
        guard let bundle = Bundle(path: localizationRoot.path) else {
            throw NSError(
                domain: "LocalAIModelTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing compiled localization bundle"]
            )
        }
        return bundle
    }
}
