import Foundation

@main
struct AIProcessingBackendTests {
    static func main() async throws {
        try testChoiceStorageRoundTripAndFallback()
        try testAvailabilityAndRAMRecommendation()
        try await testCloudExecutorPreservesProviderConfiguration()
        try await testLocalExecutorUsesLeaseAndLocalRequestContract()
        try await testUnknownLocalModelFailsWithoutCatalogFallback()
        print("AIProcessingBackendTests passed")
    }

    private static func testChoiceStorageRoundTripAndFallback() throws {
        let suite = "quill-ai-processing-choice-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let stored = AIProcessingBackendChoice.localAI(
            modelID: LocalAIModelCatalog.fast.id
        )
        AIProcessingBackendChoiceStore.save(stored, defaults: defaults, key: "choice")
        assert(
            AIProcessingBackendChoiceStore.load(
                defaults: defaults,
                key: "choice",
                fallbackCloudModelID: "cloud/default"
            ) == stored
        )

        defaults.set(Data("not-json".utf8), forKey: "choice")
        assert(
            AIProcessingBackendChoiceStore.load(
                defaults: defaults,
                key: "choice",
                fallbackCloudModelID: "cloud/default"
            ) == .cloud(modelID: "cloud/default")
        )
    }

    private static func testAvailabilityAndRAMRecommendation() throws {
        let supported8GB = LocalAIProcessingAvailability(
            isAppleSilicon: true,
            runnerIsExecutable: true,
            physicalMemory: 8 * 1_024 * 1_024 * 1_024
        )
        let supported16GB = LocalAIProcessingAvailability(
            isAppleSilicon: true,
            runnerIsExecutable: true,
            physicalMemory: 16 * 1_024 * 1_024 * 1_024
        )
        assert(supported8GB.isSupported)
        assert(supported8GB.recommendedModel.id == LocalAIModelCatalog.fast.id)
        assert(supported16GB.recommendedModel.id == LocalAIModelCatalog.quality.id)
        assert(
            !LocalAIProcessingAvailability(
                isAppleSilicon: false,
                runnerIsExecutable: true,
                physicalMemory: UInt64.max
            ).isSupported
        )
    }

    private static func testCloudExecutorPreservesProviderConfiguration() async throws {
        let executor = AIProcessingBackendExecutor(
            choice: .cloud(modelID: "provider/custom-model"),
            cloudBaseURL: "https://api.example.com/openai/v1/",
            cloudAPIKey: "secret-key"
        )
        let endpoint = try await executor.withEndpoint { $0 }
        assert(endpoint.kind == .cloud)
        assert(endpoint.baseURL.absoluteString == "https://api.example.com/openai/v1")
        assert(endpoint.authorizationToken == "secret-key")
        assert(endpoint.requestModelID == "provider/custom-model")
        assert(endpoint.selectedModelID == "provider/custom-model")
        assert(endpoint.supportsImages)
    }

    private static func testLocalExecutorUsesLeaseAndLocalRequestContract() async throws {
        let process = FakeLocalAIServerProcess()
        let observedModelIDs = ObservedModelIDs()
        let manager = LocalAIServerManager(
            launchProcess: { model, _, port, _ in
                observedModelIDs.append(model.id)
                return (process, port)
            },
            pollHealth: { _ in true },
            validateModel: { _ in .ready }
        )
        let executor = AIProcessingBackendExecutor(
            choice: .localAI(modelID: LocalAIModelCatalog.fast.id),
            cloudBaseURL: "https://api.example.com/openai/v1",
            cloudAPIKey: "cloud-key",
            localServerManager: manager
        )

        let endpoint = try await executor.withEndpoint { $0 }
        assert(observedModelIDs.values == [LocalAIModelCatalog.fast.id])
        assert(endpoint.kind == .local)
        assert(endpoint.baseURL.host == "127.0.0.1")
        assert(endpoint.authorizationToken == nil)
        assert(endpoint.requestModelID == "local")
        assert(endpoint.selectedModelID == LocalAIModelCatalog.fast.id)
        assert(!endpoint.supportsImages)
    }

    private static func testUnknownLocalModelFailsWithoutCatalogFallback() async throws {
        let executor = AIProcessingBackendExecutor(
            choice: .localAI(modelID: "missing-model"),
            cloudBaseURL: "https://api.example.com/openai/v1",
            cloudAPIKey: "",
            localServerManager: LocalAIServerManager(validateModel: { _ in .ready })
        )
        do {
            _ = try await executor.withEndpoint { $0 }
            assertionFailure("Expected unknown model failure")
        } catch AIProcessingBackendError.unknownLocalModel(let modelID) {
            assert(modelID == "missing-model")
        }
    }
}

private final class ObservedModelIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var modelIDs: [String] = []

    func append(_ modelID: String) {
        lock.lock()
        defer { lock.unlock() }
        modelIDs.append(modelID)
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return modelIDs
    }
}

private final class FakeLocalAIServerProcess: LocalAIServerProcess, @unchecked Sendable {
    var isRunning = true
    func terminate() { isRunning = false }
    func forceTerminate() { isRunning = false }
    func setTerminationHandler(_ handler: @escaping () -> Void) {}
}
