import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct PostProcessingBackendTests {
    static func main() async throws {
        try await testLocalRequestUsesLoopbackWithoutAuthorization()
        try await testLocalFailureDoesNotInvokeCloudFallback()
        try testLocalManagerErrorsMapToDedicatedIssues()
        print("PostProcessingBackendTests passed")
    }

    private static func testLocalRequestUsesLoopbackWithoutAuthorization() async throws {
        let process = PostProcessingFakeProcess()
        let manager = LocalAIServerManager(
            launchProcess: { _, _, port, _ in (process, port) },
            pollHealth: { _ in true },
            validateModel: { _ in .ready }
        )
        let recorder = PostProcessingRequestRecorder()
        let service = PostProcessingService(
            backendExecutor: AIProcessingBackendExecutor(
                choice: .localAI(modelID: LocalAIModelCatalog.fast.id),
                cloudBaseURL: "https://api.example.com/openai/v1",
                cloudAPIKey: "cloud-secret",
                localServerManager: manager
            ),
            cloudFallbackModelID: "cloud/fallback",
            instructionExecutionGuardEnabled: false,
            transport: { request in
                recorder.record(request)
                return try successResponse(
                    request: request,
                    content: "Cleaned local result."
                )
            }
        )

        let result = try await service.postProcess(
            transcript: "clean this",
            context: testContext,
            customVocabulary: ""
        )

        let capturedRequest = try recorder.request()
        try expect(result.transcript == "Cleaned local result.", "local result")
        try expect(capturedRequest.url?.host == "127.0.0.1", "local loopback host")
        try expect(
            capturedRequest.value(forHTTPHeaderField: "Authorization") == nil,
            "local request omits authorization"
        )
        let body = try JSONSerialization.jsonObject(with: capturedRequest.httpBody!) as! [String: Any]
        try expect(body["model"] as? String == "local", "local request model")
    }

    private static func testLocalFailureDoesNotInvokeCloudFallback() async throws {
        let manager = LocalAIServerManager(
            launchProcess: { _, _, port, _ in (PostProcessingFakeProcess(), port) },
            pollHealth: { _ in true },
            validateModel: { _ in .ready }
        )
        let counter = PostProcessingRequestCounter()
        let service = PostProcessingService(
            backendExecutor: AIProcessingBackendExecutor(
                choice: .localAI(modelID: LocalAIModelCatalog.fast.id),
                cloudBaseURL: "https://api.example.com/openai/v1",
                cloudAPIKey: "cloud-secret",
                localServerManager: manager
            ),
            cloudFallbackModelID: "cloud/fallback",
            instructionExecutionGuardEnabled: false,
            transport: { request in
                counter.increment()
                return (
                    Data(#"{"error":{"code":"rate_limit"}}"#.utf8),
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 429,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )

        do {
            _ = try await service.postProcess(
                transcript: "clean this",
                context: testContext,
                customVocabulary: ""
            )
            throw PostProcessingBackendTestFailure("Expected local failure")
        } catch let failure as PostProcessingBackendTestFailure {
            throw failure
        } catch {
            try expect(counter.value() == 1, "local failure executes one request")
        }
    }

    private static func testLocalManagerErrorsMapToDedicatedIssues() throws {
        let service = PostProcessingService(
            backendExecutor: AIProcessingBackendExecutor(
                choice: .localAI(modelID: LocalAIModelCatalog.fast.id),
                cloudBaseURL: AppState.defaultAPIBaseURL,
                cloudAPIKey: ""
            ),
            cloudFallbackModelID: nil,
            instructionExecutionGuardEnabled: true
        )
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

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else { throw PostProcessingBackendTestFailure(label) }
    }
}

private final class PostProcessingRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequest: URLRequest?

    func record(_ request: URLRequest) {
        lock.lock()
        capturedRequest = request
        lock.unlock()
    }

    func request() throws -> URLRequest {
        lock.lock()
        defer { lock.unlock() }
        guard let capturedRequest else {
            throw PostProcessingBackendTestFailure("Expected a captured request")
        }
        return capturedRequest
    }
}

private final class PostProcessingRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
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
