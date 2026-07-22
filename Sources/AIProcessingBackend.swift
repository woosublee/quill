import Foundation

#if canImport(Darwin)
import Darwin
#endif

enum AIProcessingFeature: String, CaseIterable, Hashable, Sendable {
    case postProcessing
    case context
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

struct LocalAIProcessingAvailability: Equatable {
    static let qualityMemoryThreshold: UInt64 = 16 * 1_024 * 1_024 * 1_024

    let isAppleSilicon: Bool
    let runnerIsExecutable: Bool
    let physicalMemory: UInt64

    var isSupported: Bool {
        isAppleSilicon && runnerIsExecutable
    }

    var recommendedModel: LocalAIModel {
        physicalMemory < Self.qualityMemoryThreshold
            ? LocalAIModelCatalog.fast
            : LocalAIModelCatalog.quality
    }

    static func live(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        processInfo: ProcessInfo = ProcessInfo.processInfo
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
            physicalMemory: processInfo.physicalMemory
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

struct LocalAIModelInstallViewState: Equatable {
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

    init(
        choice: AIProcessingBackendChoice,
        cloudBaseURL: String,
        cloudAPIKey: String,
        localServerManager: LocalAIServerManager? = nil
    ) {
        self.choice = choice
        self.cloudBaseURL = cloudBaseURL
        self.cloudAPIKey = cloudAPIKey
        self.localServerManager = localServerManager
    }

    var isConfigured: Bool {
        switch choice {
        case .cloud:
            return !cloudAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .localAI:
            return localServerManager != nil
        }
    }

    func replacingChoice(_ choice: AIProcessingBackendChoice) -> Self {
        AIProcessingBackendExecutor(
            choice: choice,
            cloudBaseURL: cloudBaseURL,
            cloudAPIKey: cloudAPIKey,
            localServerManager: localServerManager
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
            return try await operation(
                AIProcessingEndpoint(
                    kind: .cloud,
                    baseURL: baseURL,
                    authorizationToken: cloudAPIKey,
                    requestModelID: modelID,
                    selectedModelID: modelID,
                    supportsImages: true
                )
            )

        case .localAI(let modelID):
            guard let model = LocalAIModelCatalog.model(id: modelID) else {
                throw AIProcessingBackendError.unknownLocalModel(modelID)
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
                        supportsImages: false
                    )
                )
            }
        }
    }
}
