import Foundation

@main
struct AIProcessingBackendTests {
    static func main() async throws {
        try testChoiceStorageRoundTripAndFallback()
        try testAvailabilityIsModelSpecific()
        try await testCloudExecutorPreservesProviderConfiguration()
        try await testDeclaredCloudVisionModelSupportsImages()
        try await testCloudExecutorRejectsMissingKeyBeforeOperation()
        try await testLocalQwenExecutorUsesDescriptorAndLocalRequestContract()
        try await testLowMemoryLocalExecutorRejectsBeforeLaunch()
        try await testRetiredLocalModelFailsWithoutServerOrCloudFallback()
        print("AIProcessingBackendTests passed")
    }

    private static let successfulReadinessProbe: LocalAIServerManager.ReadinessProbe = { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data("{\"choices\":[{\"message\":{\"content\":\"OK\"}}]}".utf8), response)
    }

    private static func testChoiceStorageRoundTripAndFallback() throws {
        let suite = "quill-ai-processing-choice-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let stored = AIProcessingBackendChoice.localAI(
            modelID: LocalAIModelCatalog.quality.id
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

    private static func testAvailabilityIsModelSpecific() throws {
        let belowThreshold = LocalAIProcessingAvailability(
            isAppleSilicon: true,
            runnerIsExecutable: true,
            physicalMemory: 8 * 1024 * 1024 * 1024
        )
        assert(belowThreshold.isSupported)
        assert(!belowThreshold.isModelSupported(LocalAIModelCatalog.quality))
        assert(belowThreshold.availableModels.isEmpty)
        assert(belowThreshold.recommendedModel == nil)

        let atThreshold = LocalAIProcessingAvailability(
            isAppleSilicon: true,
            runnerIsExecutable: true,
            physicalMemory: 16 * 1024 * 1024 * 1024
        )
        assert(atThreshold.isSupported)
        assert(atThreshold.isModelSupported(LocalAIModelCatalog.quality))
        assert(atThreshold.availableModels == [LocalAIModelCatalog.quality, LocalAIModelCatalog.gemma4E4B])
        // Gemma is an additional choice; Qwen stays recommended.
        assert(atThreshold.recommendedModel == LocalAIModelCatalog.quality)

        let smallerFutureModel = LocalAIModel(
            id: "future-small-model",
            displayName: "Future small model",
            description: "Test model",
            artifacts: [],
            approximateResidentRAMBytes: 1,
            minimumPhysicalMemoryBytes: 1,
            capabilities: .none
        )
        assert(belowThreshold.isModelSupported(smallerFutureModel))

        assert(
            !LocalAIProcessingAvailability(
                isAppleSilicon: false,
                runnerIsExecutable: true,
                physicalMemory: 16 * 1024 * 1024 * 1024
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
        assert(!endpoint.supportsImages)
    }

    private static func testDeclaredCloudVisionModelSupportsImages() async throws {
        let executor = AIProcessingBackendExecutor(
            choice: .cloud(modelID: "qwen/qwen3.6-27b"),
            cloudBaseURL: "https://api.example.com/openai/v1",
            cloudAPIKey: "secret-key"
        )

        let endpoint = try await executor.withEndpoint { $0 }
        assert(endpoint.kind == .cloud)
        assert(endpoint.supportsImages)
    }

    private static func testCloudExecutorRejectsMissingKeyBeforeOperation() async throws {
        let operations = ObservedModelIDs()
        let executor = AIProcessingBackendExecutor(
            choice: .cloud(modelID: "provider/custom-model"),
            cloudBaseURL: "https://api.example.com/openai/v1",
            cloudAPIKey: "  "
        )

        do {
            _ = try await executor.withEndpoint { endpoint in
                operations.append(endpoint.selectedModelID)
                return endpoint
            }
            assertionFailure("Expected missing provider key failure")
        } catch let issue as QuillUserIssueError {
            assert(issue.record.code == .providerConfigurationInvalid)
            assert(issue.record.recoveryAction == .openProviderSettings)
            assert(issue.record.context.providerHost == "api.example.com")
            assert(issue.record.context.modelID == "provider/custom-model")
        }
        assert(operations.values.isEmpty)
    }

    private static func testLocalQwenExecutorUsesDescriptorAndLocalRequestContract() async throws {
        let process = FakeLocalAIServerProcess()
        let observedModelIDs = ObservedModelIDs()
        let manager = LocalAIServerManager(
            launchProcess: { model, _, port, _ in
                observedModelIDs.append(model.id)
                return (process, port)
            },
            pollHealth: { _ in true },
            readinessProbe: successfulReadinessProbe,
            validateModel: { _ in .ready }
        )
        let executor = AIProcessingBackendExecutor(
            choice: .localAI(modelID: LocalAIModelCatalog.quality.id),
            cloudBaseURL: "https://api.example.com/openai/v1",
            cloudAPIKey: "cloud-key",
            localServerManager: manager,
            localAIAvailability: LocalAIProcessingAvailability(
                isAppleSilicon: true,
                runnerIsExecutable: true,
                physicalMemory: 16 * 1024 * 1024 * 1024
            )
        )

        let endpoint = try await executor.withEndpoint { $0 }
        assert(observedModelIDs.values == [LocalAIModelCatalog.quality.id])
        assert(endpoint.kind == .local)
        assert(endpoint.baseURL.host == "127.0.0.1")
        assert(endpoint.authorizationToken == nil)
        assert(endpoint.requestModelID == "local")
        assert(endpoint.selectedModelID == LocalAIModelCatalog.quality.id)
        assert(!endpoint.supportsImages)
    }

    private static func testLowMemoryLocalExecutorRejectsBeforeLaunch() async throws {
        let process = FakeLocalAIServerProcess()
        let launchedModelIDs = ObservedModelIDs()
        let manager = LocalAIServerManager(
            launchProcess: { model, _, port, _ in
                launchedModelIDs.append(model.id)
                return (process, port)
            },
            pollHealth: { _ in true },
            readinessProbe: successfulReadinessProbe,
            validateModel: { _ in .ready }
        )
        let executor = AIProcessingBackendExecutor(
            choice: .localAI(modelID: LocalAIModelCatalog.quality.id),
            cloudBaseURL: "https://api.example.com/openai/v1",
            cloudAPIKey: "cloud-key",
            localServerManager: manager,
            localAIAvailability: LocalAIProcessingAvailability(
                isAppleSilicon: true,
                runnerIsExecutable: true,
                physicalMemory: 8 * 1024 * 1024 * 1024
            )
        )

        do {
            _ = try await executor.withEndpoint { $0 }
            assertionFailure("Expected low-memory Local AI failure")
        } catch AIProcessingBackendError.localRuntimeUnavailable(let modelID) {
            assert(modelID == LocalAIModelCatalog.quality.id)
        }
        assert(launchedModelIDs.values.isEmpty)
    }

    private static func testRetiredLocalModelFailsWithoutServerOrCloudFallback() async throws {
        let retiredModelID = "qwen2.5-1.5b-instruct"
        let process = FakeLocalAIServerProcess()
        let launchedModelIDs = ObservedModelIDs()
        let manager = LocalAIServerManager(
            launchProcess: { model, _, port, _ in
                launchedModelIDs.append(model.id)
                return (process, port)
            },
            pollHealth: { _ in true },
            readinessProbe: successfulReadinessProbe,
            validateModel: { _ in .ready }
        )
        let executor = AIProcessingBackendExecutor(
            choice: .localAI(modelID: retiredModelID),
            cloudBaseURL: "https://api.example.com/openai/v1",
            cloudAPIKey: "configured-cloud-key",
            localServerManager: manager
        )

        do {
            _ = try await executor.withEndpoint { $0 }
            assertionFailure("Expected retired local model failure")
        } catch AIProcessingBackendError.unknownLocalModel(let modelID) {
            assert(modelID == retiredModelID)
        }
        assert(launchedModelIDs.values.isEmpty)
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
