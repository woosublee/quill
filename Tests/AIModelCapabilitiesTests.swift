import Foundation

@main
struct AIModelCapabilitiesTests {
    static func main() throws {
        try testContextRequiresImageModality()
        try testQualityQwenFeatures()
        try testTranscriptionRequiresAudioModality()
        try testRetiredQwenHasNoCapabilities()
        try testCloudCapabilitiesAreExplicit()
        try testCuratedCloudModelCatalog()
        try testProviderlessCloudVisionAliasIsCanonicalized()
        print("AIModelCapabilitiesTests passed")
    }

    private static func testContextRequiresImageModality() throws {
        let textOnly = AIModelCapabilities(
            features: [.contextCapture],
            modalities: [.text],
            recommendedContextWindow: 16_384
        )

        try expect(!textOnly.supportsContextCapture,
                   "text-only models cannot support Context")
    }

    private static func testTranscriptionRequiresAudioModality() throws {
        try expect(!AIModelCapabilityCatalog.qwenTextCapabilities.supportsTranscription,
                   "Qwen text cannot transcribe")
        try expect(AIModelCapabilityCatalog.gemma4LocalCapabilities.supportsTranscription,
                   "Gemma 4 local transcribes")
        try expect(!AIModelCapabilityCatalog.qwenCloudVisionCapabilities.supportsTranscription,
                   "cloud vision models are not transcription backends")
        let featureWithoutAudio = AIModelCapabilities(
            features: [.transcription],
            modalities: [.text],
            recommendedContextWindow: nil
        )
        try expect(!featureWithoutAudio.supportsTranscription,
                   "transcription needs audio modality")
    }

    private static func testQualityQwenFeatures() throws {
        let model = LocalAIModelCatalog.quality

        try expect(model.capabilities.supports(.postProcessing), "quality supports cleanup")
        try expect(model.capabilities.supports(.meetingSummary), "quality supports summary")
        try expect(!model.capabilities.supportsContextCapture, "quality excludes Context")
        try expect(model.capabilities.recommendedContextWindow == 16_384,
                   "quality uses 16K context")
    }

    private static func testRetiredQwenHasNoCapabilities() throws {
        try expect(
            LocalAIModelCatalog.capabilities(for: "qwen2.5-1.5b-instruct") == nil,
            "retired Qwen has no Local capability mapping"
        )
    }

    private static func testCloudCapabilitiesAreExplicit() throws {
        try expect(
            ModelConfiguration.capabilities(for: "qwen/qwen3.6-27b").supportsContextCapture,
            "the declared Cloud Qwen vision model supports Context"
        )
        for modelID in ModelConfiguration.llmModels where modelID != "qwen/qwen3.6-27b" {
            try expect(
                !ModelConfiguration.capabilities(for: modelID).supportsContextCapture,
                "\(modelID) is not Context-capable until explicitly declared"
            )
        }
    }

    private static func testCuratedCloudModelCatalog() throws {
        for retiredModelID in [
            "allam-2-7b",
            "canopylabs/orpheus-arabic-saudi",
            "canopylabs/orpheus-v1-english",
            "meta-llama/llama-prompt-guard-2-22m",
            "meta-llama/llama-prompt-guard-2-86m"
        ] {
            try expect(
                !ModelConfiguration.llmModels.contains(retiredModelID),
                "retired Cloud model \(retiredModelID) is not offered as a predefined choice"
            )
        }
        try expect(
            ModelConfiguration.visionModels == ["qwen/qwen3.6-27b"],
            "the predefined Context model list contains only the declared Cloud vision model"
        )
    }

    private static func testProviderlessCloudVisionAliasIsCanonicalized() throws {
        let canonical = ModelConfiguration.capabilities(
            for: "qwen/qwen3.6-27b"
        )
        for alias in ["qwen3.6-27b", " QWEN3.6-27B "] {
            try expect(
                ModelConfiguration.capabilities(for: alias) == canonical,
                "\(alias) shares the canonical Cloud vision capabilities"
            )
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw NSError(
                domain: "AIModelCapabilitiesTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}
