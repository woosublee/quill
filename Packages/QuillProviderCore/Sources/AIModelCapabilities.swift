public enum AIModelFeature: Hashable, Sendable, Codable {
    case postProcessing
    case contextCapture
    case meetingSummary
    case transcription
}

public enum AIModelModality: Hashable, Sendable, Codable {
    case text
    case image
    case audio
}

public struct AIModelCapabilities: Hashable, Sendable, Codable {
    public let features: Set<AIModelFeature>
    public let modalities: Set<AIModelModality>
    public let recommendedContextWindow: Int?

    public init(
        features: Set<AIModelFeature>,
        modalities: Set<AIModelModality>,
        recommendedContextWindow: Int?
    ) {
        self.features = features
        self.modalities = modalities
        self.recommendedContextWindow = recommendedContextWindow
    }

    public static let none = AIModelCapabilities(
        features: [],
        modalities: [],
        recommendedContextWindow: nil
    )

    public func supports(_ feature: AIModelFeature) -> Bool {
        features.contains(feature)
    }

    public var supportsContextCapture: Bool {
        supports(.contextCapture) && modalities.contains(.image)
    }

    public var supportsTranscription: Bool {
        supports(.transcription) && modalities.contains(.audio)
    }
}

public enum LocalAIRuntime: Hashable, Sendable, Codable {
    case textChat
    case visionChat(projectorArtifactFileName: String)
}

public enum AIModelIDNormalizer {
    public static func normalizedCloudModelID(_ modelID: String) -> String {
        let cleanModel = modelID.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        switch cleanModel {
        case "qwen3-32b":
            return "qwen/qwen3-32b"
        case "qwen3.6-27b":
            return "qwen/qwen3.6-27b"
        case "qwen3.8-27b":
            return "qwen/qwen3.8-27b"
        case "gpt-oss-20b":
            return "openai/gpt-oss-20b"
        case "gpt-oss-120b":
            return "openai/gpt-oss-120b"
        case "gpt-oss-safeguard-20b":
            return "openai/gpt-oss-safeguard-20b"
        default:
            return cleanModel
        }
    }
}

public enum AIModelCapabilityCatalog {
    public static let qwenTextCapabilities = AIModelCapabilities(
        features: [.postProcessing, .meetingSummary],
        modalities: [.text],
        recommendedContextWindow: 16_384
    )

    public static let gemma4LocalCapabilities = AIModelCapabilities(
        features: [.postProcessing, .meetingSummary, .contextCapture, .transcription],
        modalities: [.text, .image, .audio],
        recommendedContextWindow: 16_384
    )

    /// Speech recognition only; never offered for cleanup, summaries, or Context.
    public static let qwen3ASRCapabilities = AIModelCapabilities(
        features: [.transcription],
        modalities: [.audio],
        recommendedContextWindow: 4_096
    )

    public static let qwenCloudVisionCapabilities = AIModelCapabilities(
        features: [.postProcessing, .contextCapture, .meetingSummary],
        modalities: [.text, .image],
        recommendedContextWindow: nil
    )

    public static let cloudTextCapabilities = AIModelCapabilities(
        features: [.postProcessing, .meetingSummary],
        modalities: [.text],
        recommendedContextWindow: nil
    )

    /// Qwen 3.6 stays here for providers other than Groq that still serve it.
    public static let cloudVisionModelIDs: Set<String> = ["qwen/qwen3.8-27b", "qwen/qwen3.6-27b"]

    public static func capabilities(forCloudModelID modelID: String) -> AIModelCapabilities {
        cloudVisionModelIDs.contains(AIModelIDNormalizer.normalizedCloudModelID(modelID))
            ? qwenCloudVisionCapabilities
            : cloudTextCapabilities
    }

}
