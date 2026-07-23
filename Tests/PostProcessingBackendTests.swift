import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct PostProcessingBackendTests {
    static func main() async throws {
        try await testLocalRequestUsesLoopbackWithoutAuthorization()
        try await testLocalFailureDoesNotInvokeCloudFallbackOrSetCooldown()
        try await testLocalCommandTransformUsesEndpointWithoutCloudFallback()
        try testLocalManagerErrorsMapToDedicatedIssues()
        try testInvalidCloudBaseURLIsNotRelabeledAsLocal()
        try await testLeakedRawTranscriptionTemplateIsTreatedAsFailure()
        try await testStandaloneRawTranscriptionWordIsNotTreatedAsLeak()
        print("PostProcessingBackendTests passed")
    }

    private static func testLocalRequestUsesLoopbackWithoutAuthorization() async throws {
        let recorder = PostProcessingRequestRecorder()
        let service = makeLocalService { request in
            recorder.record(request)
            return try successResponse(
                request: request,
                content: "Cleaned local result."
            )
        }

        let result = try await service.postProcess(
            transcript: "clean this",
            context: testContext,
            customVocabulary: ""
        )

        try expect(result.transcript == "Cleaned local result.", "local result")
        try assertLocalRequestContract(recorder, label: "cleanup")
    }

    private static func testLocalFailureDoesNotInvokeCloudFallbackOrSetCooldown() async throws {
        let scenario = makeRateLimitedLocalScenario()
        try await assertNoCooldown(scenario, label: "precondition")
        try await expectFailure("cleanup local failure") {
            _ = try await scenario.service.postProcess(
                transcript: "clean this",
                context: testContext,
                customVocabulary: ""
            )
        }

        try await assertRateLimitedLocalScenario(scenario, label: "cleanup")
    }

    private static func testLocalCommandTransformUsesEndpointWithoutCloudFallback() async throws {
        let scenario = makeRateLimitedLocalScenario()
        try await assertNoCooldown(scenario, label: "precondition")
        try await expectFailure("command local failure") {
            _ = try await scenario.service.commandTransform(
                selectedText: "Original text",
                voiceCommand: "Make it concise",
                context: testContext,
                customVocabulary: ""
            )
        }

        try await assertRateLimitedLocalScenario(scenario, label: "command")
    }

    private static func testLeakedRawTranscriptionTemplateIsTreatedAsFailure() async throws {
        // instructionExecutionGuardEnabled is false here (see makeLocalService),
        // so this must be caught independently of that user-facing toggle.
        let service = makeLocalService { request in
            try successResponse(
                request: request,
                content: "<<<RAW_TRANSCRIPTION\nsome garbled echo\nRAW_TRANSCRIPTION"
            )
        }

        try await expectFailure("leaked RAW_TRANSCRIPTION template") {
            _ = try await service.postProcess(
                transcript: "clean this",
                context: testContext,
                customVocabulary: ""
            )
        }
    }

    private static func testStandaloneRawTranscriptionWordIsNotTreatedAsLeak() async throws {
        // Legit dictation that merely mentions the word "RAW_TRANSCRIPTION"
        // (without the template's `<<<` wrapper delimiter) must pass through.
        let cleaned = "The variable RAW_TRANSCRIPTION holds the raw text."
        let service = makeLocalService { request in
            try successResponse(request: request, content: cleaned)
        }

        let result = try await service.postProcess(
            transcript: "clean this",
            context: testContext,
            customVocabulary: ""
        )
        try expect(result.transcript == cleaned, "standalone RAW_TRANSCRIPTION word passes through")
    }

    private static func testLocalManagerErrorsMapToDedicatedIssues() throws {
        let service = makeLocalService { request in
            try successResponse(request: request, content: "unused")
        }
        try expect(
            service.userIssue(
                for: LocalAIServerManagerError.modelUnavailable("missing")
            ).record.code == .localAIModelUnavailable,
            "local model unavailable issue"
        )
        try expect(
            service.userIssue(
                for: LocalAIServerManagerError.startFailed("failed")
            ).record.code == .localAIStartFailed,
            "local start failed issue"
        )
        try expect(
            service.userIssue(
                for: LocalAIServerManagerError.processExited("crashed")
            ).record.code == .localAIProcessExited,
            "local process exited issue"
        )
    }

    private static func testInvalidCloudBaseURLIsNotRelabeledAsLocal() throws {
        let service = PostProcessingService(
            backendExecutor: AIProcessingBackendExecutor(
                choice: .localAI(modelID: LocalAIModelCatalog.fast.id),
                cloudBaseURL: "not a valid cloud URL",
                cloudAPIKey: ""
            ),
            cloudFallbackModelID: nil,
            instructionExecutionGuardEnabled: true
        )

        let issue = service.userIssue(
            for: AIProcessingBackendError.invalidCloudBaseURL("not a valid cloud URL")
        )
        try expect(
            issue.record.code == .providerConfigurationInvalid,
            "invalid cloud URL issue code"
        )
        try expect(
            issue.record.context.localBackend == nil,
            "invalid cloud URL is not labeled Local AI"
        )
        try expect(
            issue.record.recoveryAction == .openProviderSettings,
            "invalid cloud URL opens provider settings"
        )
    }

    private static func makeLocalService(
        cloudBaseURL: String = "https://api.example.com/openai/v1",
        transport: @escaping PostProcessingService.Transport
    ) -> PostProcessingService {
        let process = PostProcessingFakeProcess()
        let manager = LocalAIServerManager(
            launchProcess: { _, _, port, _ in (process, port) },
            pollHealth: { _ in true },
            validateModel: { _ in .ready }
        )
        return PostProcessingService(
            backendExecutor: AIProcessingBackendExecutor(
                choice: .localAI(modelID: LocalAIModelCatalog.fast.id),
                cloudBaseURL: cloudBaseURL,
                cloudAPIKey: "cloud-secret",
                localServerManager: manager
            ),
            cloudFallbackModelID: "cloud/fallback",
            instructionExecutionGuardEnabled: false,
            transport: transport
        )
    }

    private static func makeRateLimitedLocalScenario() -> RateLimitedLocalScenario {
        let cloudBaseURL = "https://api.example.com/openai/v1/\(UUID().uuidString)"
        let recorder = PostProcessingRequestRecorder()
        let service = makeLocalService(cloudBaseURL: cloudBaseURL) { request in
            recorder.record(request)
            return rateLimitedResponse(request: request)
        }
        return RateLimitedLocalScenario(
            service: service,
            recorder: recorder,
            cooldownIdentity: LLMCooldownIdentity(
                baseURL: cloudBaseURL,
                model: LocalAIModelCatalog.fast.id
            )
        )
    }

    private static func assertNoCooldown(
        _ scenario: RateLimitedLocalScenario,
        label: String
    ) async throws {
        let isInCooldown = await LLMCooldownManager.shared.isInCooldown(
            scenario.cooldownIdentity
        )
        try expect(!isInCooldown, "\(label) has no cloud cooldown")
    }

    private static func assertRateLimitedLocalScenario(
        _ scenario: RateLimitedLocalScenario,
        label: String
    ) async throws {
        try assertLocalRequestContract(scenario.recorder, label: label)
        try expect(scenario.recorder.count() == 1, "\(label) executes one local request")
        let createdCloudCooldown = await LLMCooldownManager.shared.isInCooldown(
            scenario.cooldownIdentity
        )
        try expect(!createdCloudCooldown, "\(label) local 429 does not set cloud cooldown")
    }

    private static func assertLocalRequestContract(
        _ recorder: PostProcessingRequestRecorder,
        label: String
    ) throws {
        let request = try recorder.request()
        try expect(request.url?.host == "127.0.0.1", "\(label) local loopback host")
        try expect(
            request.value(forHTTPHeaderField: "Authorization") == nil,
            "\(label) local request omits authorization"
        )
        guard let bodyData = request.httpBody,
              let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            throw PostProcessingBackendTestFailure("\(label) request body")
        }
        try expect(body["model"] as? String == "local", "\(label) local request model")
    }

    private static func expectFailure(
        _ label: String,
        operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
            throw PostProcessingBackendTestFailure("Expected \(label)")
        } catch let failure as PostProcessingBackendTestFailure {
            throw failure
        } catch {}
    }

    private static let testContext = AppContext(
        appName: "Test",
        bundleIdentifier: "test.bundle",
        windowTitle: "Window",
        selectedText: nil,
        currentActivity: "Testing",
        contextSystemPrompt: nil,
        contextPrompt: nil,
        screenshotDataURL: nil,
        screenshotMimeType: nil,
        screenshotError: nil
    )

    private static func successResponse(
        request: URLRequest,
        content: String
    ) throws -> (Data, URLResponse) {
        let data = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": content]]]
        ])
        return (
            data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    private static func rateLimitedResponse(
        request: URLRequest
    ) -> (Data, URLResponse) {
        (
            Data(#"{"error":{"code":"rate_limit"}}"#.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else { throw PostProcessingBackendTestFailure(label) }
    }
}

private struct RateLimitedLocalScenario {
    let service: PostProcessingService
    let recorder: PostProcessingRequestRecorder
    let cooldownIdentity: LLMCooldownIdentity
}

private final class PostProcessingRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    func request() throws -> URLRequest {
        lock.lock()
        defer { lock.unlock() }
        guard let request = requests.last else {
            throw PostProcessingBackendTestFailure("Expected a captured request")
        }
        return request
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }
}

private final class PostProcessingFakeProcess: LocalAIServerProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func terminate() {
        lock.lock()
        running = false
        lock.unlock()
    }

    func forceTerminate() {
        terminate()
    }

    func setTerminationHandler(_ handler: @escaping () -> Void) {}
}

private struct PostProcessingBackendTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
