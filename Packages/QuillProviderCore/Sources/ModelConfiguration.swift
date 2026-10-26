import Foundation

public struct ModelConfig {
    public let maxCompletionTokens: Int?
    public let reasoningEffort: String?
    public let includeReasoning: Bool?
    public let shouldStripThinkTags: Bool
}

public struct ModelConfiguration {
    public static let llmModels = [
        "openai/gpt-oss-20b",
        "openai/gpt-oss-120b",
        "openai/gpt-oss-safeguard-20b",
        "qwen/qwen3.8-27b"
    ]

    // MARK: - Vision-capable models

    /// Models that accept image input. The context model must support vision for screenshot analysis to work.
    public static let visionModels = [
        "qwen/qwen3.8-27b"
    ]

    /// Groq retired Qwen 3.6 and serves Qwen 3.8 in its place.
    public static let retiredGroqQwenModelID = "qwen/qwen3.6-27b"
    public static let groqQwenModelID = "qwen/qwen3.8-27b"
    /// The default primary model for post-processing and meeting summaries.
    public static let defaultLLMModelID = "openai/gpt-oss-20b"
    /// Models upstream dropped from the list in v1.2.0 (#577). Groq still
    /// serves them, so saved selections move to Qwen 3.8 only once; a model
    /// typed in later stays.
    public static let droppedGroqModelIDs: Set<String> = [
        "llama-3.3-70b-versatile",
        "llama-3.1-8b-instant",
        "meta-llama/llama-4-scout-17b-16e-instruct",
        "qwen/qwen3-32b"
    ]

    /// Only Groq's own endpoint is migrated. Other providers can still serve
    /// these models under the same names.
    public static func isGroqBaseURL(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "api.groq.com"
            && url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "openai/v1"
    }

    /// The Groq replacement for a retired model ID, or nil when it is kept.
    /// Dropped models are replaced only when `includingDroppedModels`.
    public static func groqReplacement(
        for modelID: String,
        baseURL: String,
        includingDroppedModels: Bool = false
    ) -> String? {
        let normalized = AIModelIDNormalizer.normalizedCloudModelID(modelID)
        guard isGroqBaseURL(baseURL),
              normalized == retiredGroqQwenModelID
                || (includingDroppedModels && droppedGroqModelIDs.contains(normalized)) else {
            return nil
        }
        return groqQwenModelID
    }

    public static func migrateGroqSelection(
        key: String,
        baseURL: String,
        defaults: UserDefaults,
        includingDroppedModels: Bool = false
    ) {
        guard let stored = defaults.string(forKey: key),
              let replacement = groqReplacement(
                for: stored,
                baseURL: baseURL,
                includingDroppedModels: includingDroppedModels
              ) else { return }
        defaults.set(replacement, forKey: key)
    }

    public static func capabilities(for modelID: String) -> AIModelCapabilities {
        AIModelCapabilityCatalog.capabilities(forCloudModelID: modelID)
    }

    public static let transcriptionModels = [
        "whisper-large-v3",
        "whisper-large-v3-turbo"
    ]

    public static func config(for model: String) -> ModelConfig {
        let cleanModel = AIModelIDNormalizer.normalizedCloudModelID(model)

        if cleanModel == "openai/gpt-oss-20b" {
            return ModelConfig(
                maxCompletionTokens: 4096,
                reasoningEffort: "low",
                includeReasoning: false,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "openai/gpt-oss-120b" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "openai/gpt-oss-safeguard-20b" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "qwen/qwen3-32b" {
            // Model that requires sanitization of thought tags
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: true
            )
        } else if cleanModel == "qwen/qwen3.8-27b" || cleanModel == "qwen/qwen3.6-27b" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: "none",
                includeReasoning: false,
                shouldStripThinkTags: true
            )
        } else if cleanModel == "llama-3.1-8b-instant" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "llama-3.3-70b-versatile" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "meta-llama/llama-4-scout-17b-16e-instruct" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "meta-llama/llama-prompt-guard-2-22m" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "meta-llama/llama-prompt-guard-2-86m" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "allam-2-7b" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "canopylabs/orpheus-arabic-saudi" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "canopylabs/orpheus-v1-english" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "groq/compound" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "groq/compound-mini" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "whisper-large-v3" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "whisper-large-v3-turbo" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        }

        // Generic fallback for any model not explicitly listed above
        return ModelConfig(
            maxCompletionTokens: nil,
            reasoningEffort: nil,
            includeReasoning: nil,
            shouldStripThinkTags: false
        )
    }

    /// Utility method to remove <think>...</think> tags and everything inside them.
    /// This also handles unclosed tags gracefully (e.g. if the model runs out of tokens).
    public static func stripThinkTags(_ text: String) -> String {
        var cleaned = text

        // First, replace fully closed tags: <think>...</think>
        // Match anywhere in the text so blocks after leading content are stripped too.
        let closedRegexPattern = "<think>[\\s\\S]*?</think>"
        if let regex = try? NSRegularExpression(pattern: closedRegexPattern, options: []) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }

        // Next, if there is an unclosed <think> tag remaining (meaning it started thinking but got truncated),
        // strip from the first remaining <think> tag to the very end of the string.
        let openRegexPattern = "<think>[\\s\\S]*$"
        if let regex = try? NSRegularExpression(pattern: openRegexPattern, options: []) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
