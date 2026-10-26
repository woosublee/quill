import Foundation
import QuillProviderCore

@main
struct ModelConfigurationTests {
    static func main() {
        testProviderlessAliasesMatchCanonicalModels()
        testKnownModelSettingsRemainStable()
        testModelListsAreConsistent()
        testThinkTagStripping()
        print("ModelConfigurationTests passed")
    }

    private static func testProviderlessAliasesMatchCanonicalModels() {
        assertSameConfig(" GPT-OSS-20B ", "openai/gpt-oss-20b")
        assertSameConfig("gpt-oss-120b", "openai/gpt-oss-120b")
        assertSameConfig("gpt-oss-safeguard-20b", "openai/gpt-oss-safeguard-20b")
        assertSameConfig("qwen3-32b", "qwen/qwen3-32b")
        assertSameConfig(" QWEN3.6-27B ", "qwen/qwen3.6-27b")
    }

    private static func testKnownModelSettingsRemainStable() {
        let gptOSS = ModelConfiguration.config(for: "openai/gpt-oss-20b")
        expectEqual(gptOSS.maxCompletionTokens, 4096)
        expectEqual(gptOSS.reasoningEffort, "low")
        expectEqual(gptOSS.includeReasoning, false)
        expectEqual(gptOSS.shouldStripThinkTags, false)

        let qwen = ModelConfiguration.config(for: "qwen/qwen3.6-27b")
        expectEqual(qwen.reasoningEffort, "none")
        expectEqual(qwen.includeReasoning, false)
        expectEqual(qwen.shouldStripThinkTags, true)

        let unknown = ModelConfiguration.config(for: "example/unknown-model")
        expectEqual(unknown.maxCompletionTokens, nil)
        expectEqual(unknown.reasoningEffort, nil)
        expectEqual(unknown.includeReasoning, nil)
        expectEqual(unknown.shouldStripThinkTags, false)
    }

    private static func testModelListsAreConsistent() {
        expectEqual(Set(ModelConfiguration.llmModels).count, ModelConfiguration.llmModels.count)
        expectEqual(Set(ModelConfiguration.visionModels).count, ModelConfiguration.visionModels.count)
        expectEqual(Set(ModelConfiguration.transcriptionModels).count, ModelConfiguration.transcriptionModels.count)
        expect(
            Set(ModelConfiguration.visionModels).isSubset(of: Set(ModelConfiguration.llmModels)),
            "Every vision model must also be selectable as an LLM"
        )
    }

    private static func testThinkTagStripping() {
        expectEqual(
            ModelConfiguration.stripThinkTags("<think>hidden</think> Visible output"),
            "Visible output"
        )
        expectEqual(
            ModelConfiguration.stripThinkTags("<think>one</think>\n<think>two</think>\nResult"),
            "Result"
        )
        expectEqual(ModelConfiguration.stripThinkTags("<think>unfinished"), "")
        expectEqual(
            ModelConfiguration.stripThinkTags("Ordinary output with a later <think> marker"),
            "Ordinary output with a later"
        )
    }

    private static func assertSameConfig(_ alias: String, _ canonical: String) {
        let aliasConfig = ModelConfiguration.config(for: alias)
        let canonicalConfig = ModelConfiguration.config(for: canonical)
        expectEqual(aliasConfig.maxCompletionTokens, canonicalConfig.maxCompletionTokens)
        expectEqual(aliasConfig.reasoningEffort, canonicalConfig.reasoningEffort)
        expectEqual(aliasConfig.includeReasoning, canonicalConfig.includeReasoning)
        expectEqual(aliasConfig.shouldStripThinkTags, canonicalConfig.shouldStripThinkTags)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T) {
        precondition(
            actual == expected,
            "Expected \(String(describing: expected)), got \(String(describing: actual))"
        )
    }
}
