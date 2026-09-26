import Foundation

enum AIProcessingFeature: String, CaseIterable, Hashable, Sendable {
    case postProcessing
    case context
    case meetingSummary
}

enum AIProcessingBackendChoice: Codable, Hashable, Sendable {
    case cloud(modelID: String)
    case localAI(modelID: String)

    var id: String {
        switch self {
        case .cloud(let modelID): return "cloud:\(modelID)"
        case .localAI(let modelID): return "local-ai:\(modelID)"
        }
    }

    var modelID: String {
        switch self {
        case .cloud(let modelID), .localAI(let modelID): return modelID
        }
    }

    var isLocal: Bool {
        if case .localAI = self { return true }
        return false
    }
}

struct AIProcessingEndpoint: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case cloud
        case local
    }

    let kind: Kind
    let baseURL: URL
    let authorizationToken: String?
    let requestModelID: String
    let selectedModelID: String
    let supportsImages: Bool
}

enum AIProcessingBackendError: LocalizedError, Equatable {
    case invalidCloudBaseURL(String)
    case unknownLocalModel(String)
    case localRuntimeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidCloudBaseURL:
            return localizedCatalogString("The cloud AI base URL is invalid.")
        case .unknownLocalModel:
            return localizedCatalogString("The selected local AI model is unknown.")
        case .localRuntimeUnavailable:
            return localizedCatalogString("The local AI runtime is unavailable.")
        }
    }
}

struct AIProcessingBackendChoiceStore {
    static func load(
        defaults: UserDefaults,
        key: String,
        fallbackCloudModelID: String
    ) -> AIProcessingBackendChoice {
        guard let data = defaults.data(forKey: key),
              let choice = try? JSONDecoder().decode(
                  AIProcessingBackendChoice.self,
                  from: data
              ) else {
            return .cloud(modelID: fallbackCloudModelID)
        }
        return choice
    }

    static func save(
        _ choice: AIProcessingBackendChoice,
        defaults: UserDefaults,
        key: String
    ) {
        guard let data = try? JSONEncoder().encode(choice) else { return }
        defaults.set(data, forKey: key)
    }
}

struct LocalAIProcessingAvailability: Equatable, Sendable {
    let isAppleSilicon: Bool
    let runnerIsExecutable: Bool
    let physicalMemory: UInt64

    init(
        isAppleSilicon: Bool,
        runnerIsExecutable: Bool,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        self.isAppleSilicon = isAppleSilicon
        self.runnerIsExecutable = runnerIsExecutable
        self.physicalMemory = physicalMemory
    }

    var isSupported: Bool {
        isAppleSilicon && runnerIsExecutable
    }

    func isModelSupported(_ model: LocalAIModel) -> Bool {
        isSupported && physicalMemory >= model.minimumPhysicalMemoryBytes
    }

    var availableModels: [LocalAIModel] {
        LocalAIModelCatalog.all.filter(isModelSupported)
    }

    /// The model recommended for AI processing (cleanup, summaries,
    /// Context). Transcription-only models are never recommended here.
    var recommendedModel: LocalAIModel? {
        let processingModels = availableModels.filter {
            !$0.capabilities.features.isDisjoint(
                with: [.postProcessing, .meetingSummary, .contextCapture]
            )
        }
        return processingModels.first { $0.id == LocalAIModelCatalog.quality.id }
            ?? processingModels.first
    }

    static func live(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> LocalAIProcessingAvailability {
        #if arch(arm64)
        let isAppleSilicon = true
        #else
        let isAppleSilicon = false
        #endif
        let runnerURL = RealLocalAIServerProcess.defaultRunnerURL(bundle: bundle)
        let executable = runnerURL.map {
            fileManager.isExecutableFile(atPath: $0.path)
        } ?? false
        return LocalAIProcessingAvailability(
            isAppleSilicon: isAppleSilicon,
            runnerIsExecutable: executable,
            physicalMemory: ProcessInfo.processInfo.physicalMemory
        )
    }
}

struct AIProcessingChoiceDisplay: Identifiable, Equatable {
    let choice: AIProcessingBackendChoice
    let section: String
    let title: String
    let subtitle: String?
    let isAvailable: Bool
    let unavailableReason: String?
    let isRecommended: Bool

    var id: String { choice.id }
}

struct LocalAIModelInstallViewState: Equatable, Sendable {
    var status: LocalAIInstallStatus
    var progress: LocalAIDownloadProgress
    var isInstalling: Bool
    var issue: QuillUserIssueRecord?

    static func initial(model: LocalAIModel, status: LocalAIInstallStatus) -> Self {
        LocalAIModelInstallViewState(
            status: status,
            progress: LocalAIDownloadProgress(
                downloadedBytes: 0,
                totalBytes: model.approximateBytes
            ),
            isInstalling: false,
            issue: nil
        )
    }
}

struct AIProcessingBackendExecutor: Sendable {
    let choice: AIProcessingBackendChoice
    let cloudBaseURL: String
    let cloudAPIKey: String
    let localServerManager: LocalAIServerManager?
    let localAIAvailability: LocalAIProcessingAvailability

    init(
        choice: AIProcessingBackendChoice,
        cloudBaseURL: String,
        cloudAPIKey: String,
        localServerManager: LocalAIServerManager? = nil,
        localAIAvailability: LocalAIProcessingAvailability = .live()
    ) {
        self.choice = choice
        self.cloudBaseURL = cloudBaseURL
        self.cloudAPIKey = cloudAPIKey
        self.localServerManager = localServerManager
        self.localAIAvailability = localAIAvailability
    }

    var isConfigured: Bool {
        switch choice {
        case .cloud:
            return !cloudAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .localAI(let modelID):
            guard let model = LocalAIModelCatalog.model(id: modelID) else {
                return false
            }
            return localServerManager != nil && localAIAvailability.isModelSupported(model)
        }
    }

    func replacingChoice(_ choice: AIProcessingBackendChoice) -> Self {
        AIProcessingBackendExecutor(
            choice: choice,
            cloudBaseURL: cloudBaseURL,
            cloudAPIKey: cloudAPIKey,
            localServerManager: localServerManager,
            localAIAvailability: localAIAvailability
        )
    }

    func withEndpoint<Result: Sendable>(
        _ operation: @escaping @Sendable (AIProcessingEndpoint) async throws -> Result
    ) async throws -> Result {
        switch choice {
        case .cloud(let modelID):
            let trimmed = cloudBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmed.hasSuffix("/")
                ? String(trimmed.dropLast())
                : trimmed
            guard let baseURL = URL(string: normalized),
                  baseURL.scheme != nil,
                  baseURL.host != nil else {
                throw AIProcessingBackendError.invalidCloudBaseURL(cloudBaseURL)
            }
            guard !cloudAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw QuillUserIssueError.missingProviderAPIKey(
                    providerHost: baseURL.host,
                    modelID: modelID
                )
            }
            return try await operation(
                AIProcessingEndpoint(
                    kind: .cloud,
                    baseURL: baseURL,
                    authorizationToken: cloudAPIKey,
                    requestModelID: modelID,
                    selectedModelID: modelID,
                    supportsImages: ModelConfiguration.capabilities(for: modelID)
                        .modalities.contains(.image)
                )
            )

        case .localAI(let modelID):
            guard let model = LocalAIModelCatalog.model(id: modelID) else {
                throw AIProcessingBackendError.unknownLocalModel(modelID)
            }
            guard localAIAvailability.isModelSupported(model) else {
                throw AIProcessingBackendError.localRuntimeUnavailable(modelID)
            }
            guard let localServerManager else {
                throw AIProcessingBackendError.localRuntimeUnavailable(modelID)
            }
            return try await localServerManager.withBaseURL(for: model) { baseURL in
                try await operation(
                    AIProcessingEndpoint(
                        kind: .local,
                        baseURL: baseURL,
                        authorizationToken: nil,
                        requestModelID: "local",
                        selectedModelID: model.id,
                        supportsImages: model.capabilities.modalities.contains(.image)
                    )
                )
            }
        }
    }
}
