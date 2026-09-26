enum AIModelFeature: Hashable, Sendable, Codable {
    case postProcessing
    case contextCapture
    case meetingSummary
}

enum AIModelModality: Hashable, Sendable, Codable {
    case text
    case image
}

struct AIModelCapabilities: Hashable, Sendable, Codable {
    let features: Set<AIModelFeature>
    let modalities: Set<AIModelModality>
    let recommendedContextWindow: Int?

    static let none = AIModelCapabilities(
        features: [],
        modalities: [],
        recommendedContextWindow: nil
    )

    func supports(_ feature: AIModelFeature) -> Bool {
        features.contains(feature)
    }

    var supportsContextCapture: Bool {
        supports(.contextCapture) && modalities.contains(.image)
    }
}

enum LocalAIRuntime: Hashable, Sendable, Codable {
    case textChat
    case visionChat(projectorArtifactFileName: String)
}

enum AIModelIDNormalizer {
    static func normalizedCloudModelID(_ modelID: String) -> String {
        let cleanModel = modelID.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        switch cleanModel {
        case "qwen3-32b":
            return "qwen/qwen3-32b"
        case "qwen3.6-27b":
            return "qwen/qwen3.6-27b"
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

enum AIModelCapabilityCatalog {
    static let qwenTextCapabilities = AIModelCapabilities(
        features: [.postProcessing, .meetingSummary],
        modalities: [.text],
        recommendedContextWindow: 16_384
    )

    static let gemma4LocalCapabilities = AIModelCapabilities(
        features: [.postProcessing, .meetingSummary, .contextCapture],
        modalities: [.text, .image],
        recommendedContextWindow: 16_384
    )

    static let qwenCloudVisionCapabilities = AIModelCapabilities(
        features: [.postProcessing, .contextCapture, .meetingSummary],
        modalities: [.text, .image],
        recommendedContextWindow: nil
    )

    static let cloudTextCapabilities = AIModelCapabilities(
        features: [.postProcessing, .meetingSummary],
        modalities: [.text],
        recommendedContextWindow: nil
    )

    static func capabilities(forCloudModelID modelID: String) -> AIModelCapabilities {
        AIModelIDNormalizer.normalizedCloudModelID(modelID)
            == "qwen/qwen3.6-27b"
            ? qwenCloudVisionCapabilities
            : cloudTextCapabilities
    }

}
