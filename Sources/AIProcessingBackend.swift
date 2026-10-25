import Foundation
import QuillUserIssueCore

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

/// What post-processing or meeting summary retries with when the main model
/// fails (#580). It is encoded like `AIProcessingBackendChoice`, so a saved
/// `.cloud` fallback goes through the same Groq model migration.
enum AIProcessingFallbackChoice: Codable, Hashable, Sendable {
    case none
    case cloud(modelID: String)
    case localAI(modelID: String)

    init(_ choice: AIProcessingBackendChoice) {
        switch choice {
        case .cloud(let modelID): self = .cloud(modelID: modelID)
        case .localAI(let modelID): self = .localAI(modelID: modelID)
        }
    }

    var backendChoice: AIProcessingBackendChoice? {
        switch self {
        case .none: return nil
        case .cloud(let modelID): return .cloud(modelID: modelID)
        case .localAI(let modelID): return .localAI(modelID: modelID)
        }
    }

    var modelID: String? { backendChoice?.modelID }

    /// The model ID only when it names a cloud model, for records whose
    /// readers treat a fallback model ID as a cloud model.
    var cloudModelID: String? {
        if case .cloud(let modelID) = self { return modelID }
        return nil
    }

    var isCloud: Bool {
        if case .cloud = self { return true }
        return false
    }

    var isLocal: Bool {
        if case .localAI = self { return true }
        return false
    }

    /// The fallback a primary starts with when the person hasn't picked one:
    /// a local primary never sends text to the cloud on its own, and a
    /// cloud primary never gets its own model.
    static func automatic(
        for primary: AIProcessingBackendChoice,
        defaultCloudModelID: String
    ) -> AIProcessingFallbackChoice {
        if primary.isLocal { return .none }
        if primary == .cloud(modelID: defaultCloudModelID) {
            // The default primary and fallback swap, as before #580.
            return .cloud(modelID: ModelConfiguration.defaultLLMModelID)
        }
        return .cloud(modelID: defaultCloudModelID)
    }

    /// Whether this fallback may run for `primary`. A cloud fallback for a
    /// local primary runs only with consent given for that same local model
    /// and the cloud provider in use.
    func mayRun(
        for primary: AIProcessingBackendChoice,
        cloudConsent: AIProcessingCloudConsent?,
        apiBaseURL: String
    ) -> Bool {
        guard let choice = backendChoice, choice != primary else { return false }
        guard isCloud, primary.isLocal else { return true }
        return cloudConsent?.covers(primary: primary, apiBaseURL: apiBaseURL) == true
    }
}

/// What the person approved when they picked a cloud fallback while the
/// primary shown in Settings was local: that local model, and the cloud
/// provider then configured. It covers nothing else (#580).
struct AIProcessingCloudConsent: Codable, Equatable, Sendable {
    let localModelID: String
    let apiBaseURL: String

    init(localModelID: String, apiBaseURL: String) {
        self.localModelID = localModelID
        self.apiBaseURL = Self.normalizedBaseURL(apiBaseURL)
    }

    func covers(primary: AIProcessingBackendChoice, apiBaseURL: String) -> Bool {
        primary == .localAI(modelID: localModelID) && matches(apiBaseURL: apiBaseURL)
    }

    func matches(apiBaseURL: String) -> Bool {
        self.apiBaseURL == Self.normalizedBaseURL(apiBaseURL)
    }

    static func normalizedBaseURL(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}

/// A saved fallback with how it was chosen (#580).
struct AIProcessingFallbackState: Equatable, Sendable {
    var choice: AIProcessingFallbackChoice
    /// The person picked this fallback; otherwise it follows the primary.
    var isUserSelected: Bool
    /// Set only when the person picked this cloud fallback in Settings while
    /// the primary shown there was local, after the caption said what text
    /// goes to the cloud. It lets that local model, with that cloud
    /// provider, fall back to the cloud; nothing else does.
    var cloudConsent: AIProcessingCloudConsent?

    init(
        choice: AIProcessingFallbackChoice,
        isUserSelected: Bool,
        cloudConsent: AIProcessingCloudConsent? = nil
    ) {
        self.choice = choice
        self.isUserSelected = isUserSelected
        self.cloudConsent = choice.isCloud ? cloudConsent : nil
    }

    /// Keeps a fallback the person picked, follows the primary otherwise,
    /// and never keeps the primary's own model as its fallback.
    ///
    /// Privacy: consent that no longer matches (another local model, or
    /// another cloud provider) is dropped, and a cloud fallback without
    /// consent never stays on a local primary. A fallback dropped this way
    /// is no longer treated as picked, so the default cloud fallback returns
    /// when the primary goes back to the cloud.
    func reconciled(
        primary: AIProcessingBackendChoice,
        apiBaseURL: String,
        defaultCloudModelID: String
    ) -> AIProcessingFallbackState {
        if choice.isLocal, choice.backendChoice == primary {
            return AIProcessingFallbackState(choice: .none, isUserSelected: false)
        }
        var consent = cloudConsent
        if let current = consent,
           !current.matches(apiBaseURL: apiBaseURL)
            || (primary.isLocal && primary.modelID != current.localModelID) {
            consent = nil
        }
        if choice.isCloud, primary.isLocal, consent == nil {
            return AIProcessingFallbackState(choice: .none, isUserSelected: false)
        }
        // A cloud fallback equal to the primary never runs; it follows the
        // primary like one nobody picked.
        guard isUserSelected, choice.backendChoice != primary else {
            return AIProcessingFallbackState(
                choice: AIProcessingFallbackChoice.automatic(
                    for: primary,
                    defaultCloudModelID: defaultCloudModelID
                ),
                isUserSelected: false
            )
        }
        return AIProcessingFallbackState(
            choice: choice,
            isUserSelected: true,
            cloudConsent: consent
        )
    }
}

struct AIProcessingFallbackChoiceStore {
    typealias Loaded = AIProcessingFallbackState

    /// Reads the saved fallback, or migrates the old bare cloud model ID
    /// once: a cloud primary keeps that model (or the default), and a local
    /// primary gets no fallback, which is what it effectively had.
    static func load(
        defaults: UserDefaults,
        key: String,
        userSelectedKey: String,
        cloudConsentKey: String,
        legacyModelKey: String,
        primary: AIProcessingBackendChoice,
        defaultCloudModelID: String
    ) -> Loaded {
        if let data = defaults.data(forKey: key),
           let choice = try? JSONDecoder().decode(
               AIProcessingFallbackChoice.self,
               from: data
           ) {
            return Loaded(
                choice: normalized(choice, defaultCloudModelID: defaultCloudModelID),
                isUserSelected: defaults.bool(forKey: userSelectedKey),
                cloudConsent: defaults.data(forKey: cloudConsentKey).flatMap {
                    try? JSONDecoder().decode(AIProcessingCloudConsent.self, from: $0)
                }
            )
        }
        guard !primary.isLocal else {
            return Loaded(choice: .none, isUserSelected: false)
        }
        let legacy = defaults.string(forKey: legacyModelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !legacy.isEmpty else {
            return Loaded(
                choice: .cloud(modelID: defaultCloudModelID),
                isUserSelected: false
            )
        }
        // A model other than the default was clearly picked by the person.
        return Loaded(
            choice: .cloud(modelID: legacy),
            isUserSelected: legacy != defaultCloudModelID
        )
    }

    static func save(
        _ state: AIProcessingFallbackState,
        defaults: UserDefaults,
        key: String,
        userSelectedKey: String,
        cloudConsentKey: String
    ) {
        guard let data = try? JSONEncoder().encode(state.choice) else { return }
        defaults.set(data, forKey: key)
        defaults.set(state.isUserSelected, forKey: userSelectedKey)
        if let consent = state.cloudConsent,
           let consentData = try? JSONEncoder().encode(consent) {
            defaults.set(consentData, forKey: cloudConsentKey)
        } else {
            defaults.removeObject(forKey: cloudConsentKey)
        }
    }

    private static func normalized(
        _ choice: AIProcessingFallbackChoice,
        defaultCloudModelID: String
    ) -> AIProcessingFallbackChoice {
        switch choice {
        case .none:
            return .none
        case .cloud(let modelID):
            let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            return .cloud(modelID: trimmed.isEmpty ? defaultCloudModelID : trimmed)
        case .localAI(let modelID):
            return LocalAIModelCatalog.model(id: modelID) == nil
                ? .none
                : .localAI(modelID: modelID)
        }
    }
}

/// When a failed run may be retried once with the fallback (#580).
enum AIProcessingFallbackPolicy {
    static let networkFailureCodes: Set<URLError.Code> = [
        .notConnectedToInternet,
        .networkConnectionLost,
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .dataNotAllowed,
        .timedOut
    ]

    /// The person or the app stopped the work; never retried.
    static func isCancellation(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        return false
    }

    static func isNetworkFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return networkFailureCodes.contains(urlError.code)
    }

    static func isServerError(statusCode: Int) -> Bool {
        (500...599).contains(statusCode)
    }

    /// The local runtime couldn't run the request: unknown or unsupported
    /// model, a server that didn't start or crashed, or a lost connection.
    static func isLocalRuntimeFailure(_ error: Error) -> Bool {
        if error is LocalAIServerManagerError { return true }
        if let backendError = error as? AIProcessingBackendError {
            switch backendError {
            case .unknownLocalModel, .localRuntimeUnavailable:
                return true
            case .invalidCloudBaseURL:
                return false
            }
        }
        return isNetworkFailure(error)
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

    /// Moves a saved cloud choice off a model Quill no longer lists for
    /// Groq. Local choices and other providers are left alone.
    static func migrateGroqSelection(
        key: String,
        baseURL: String,
        defaults: UserDefaults,
        includingDroppedModels: Bool = false
    ) {
        guard let data = defaults.data(forKey: key),
              let choice = try? JSONDecoder().decode(AIProcessingBackendChoice.self, from: data),
              case .cloud(let modelID) = choice,
              let replacement = ModelConfiguration.groqReplacement(
                for: modelID,
                baseURL: baseURL,
                includingDroppedModels: includingDroppedModels
              ) else {
            return
        }
        save(.cloud(modelID: replacement), defaults: defaults, key: key)
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
