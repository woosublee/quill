import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct AppContextBackendTests {
    static func main() async throws {
        try await testLocalContextOmitsScreenshotAndAuthorization()
        try await testCloudContextRetriesWithoutScreenshot()
        try await testCloudThrownTransportRetriesWithoutScreenshot()
        try await testCancellationStopsRetryAndDoesNotRecordIssue()
        try await testLocalRequestUsesEndpointRequestAndSelectedModelIDs()
        try await testLocalFailureReturnsNilAndRecordsPrivateIssue()
        try await testLocalProcessExitRecordsDedicatedIssue()
        print("AppContextBackendTests passed")
    }

    private static func testLocalContextOmitsScreenshotAndAuthorization() async throws {
        let recorder = ContextRequestRecorder()
        let service = AppContextService(
            backendExecutor: localExecutor(manager: readyManager()),
            customContextPrompt: "",
            contextModel: LocalAIModelCatalog.fast.id,
            screenshotMaxDimension: 1024,
            transport: { request in
                recorder.record(request)
                return try successResponse(
                    request,
                    "User is writing a test. They likely want to verify local context."
                )
            }
        )

        let result = await service.inferActivityWithLLM(
            appName: "Editor",
            bundleIdentifier: "test.editor",
            windowTitle: "Document",
            selectedText: "Selected",
            screenshotDataURL: "data:image/jpeg;base64,SECRET_IMAGE",
            contextSystemPrompt: AppContextService.defaultContextPrompt
        )

        try expect(result != nil, "local context result")
        let request = try recorder.request(at: 0)
        try expect(request.url?.host == "127.0.0.1", "local loopback host")
        try expect(request.value(forHTTPHeaderField: "Authorization") == nil, "local authorization")
        let bodyText = try bodyText(for: request)
        try expect(!bodyText.contains("image_url"), "local omits image payload")
        try expect(!bodyText.contains("SECRET_IMAGE"), "local omits screenshot data")
        try expect(bodyText.contains("Selected"), "local includes selected text")
        try expect(recorder.count() == 1, "local sends one text-only request")
    }

    private static func testCloudContextRetriesWithoutScreenshot() async throws {
        let recorder = ContextRequestRecorder()
        let service = AppContextService(
            apiKey: "cloud-key",
            baseURL: "https://api.example.com/openai/v1",
            customContextPrompt: "",
            contextModel: "provider/context",
            transport: { request in
                recorder.record(request)
                if recorder.count() == 1 {
                    return (
                        Data(),
                        HTTPURLResponse(
                            url: request.url!,
                            statusCode: 500,
                            httpVersion: nil,
                            headerFields: nil
                        )!
                    )
                }
                return try successResponse(
                    request,
                    "User is editing a document. They likely want writing help."
                )
            }
        )

        let result = await service.inferActivityWithLLM(
            appName: "Editor",
            bundleIdentifier: "test.editor",
            windowTitle: "Document",
            selectedText: nil,
            screenshotDataURL: "data:image/jpeg;base64,IMAGE",
            contextSystemPrompt: AppContextService.defaultContextPrompt
        )

        try expect(result != nil, "cloud context result")
        try expect(recorder.count() == 2, "cloud retries once without screenshot")
        let firstBody = try bodyText(for: recorder.request(at: 0))
        let secondBody = try bodyText(for: recorder.request(at: 1))
        try expect(firstBody.contains("image_url"), "cloud first request includes image")
        try expect(!secondBody.contains("image_url"), "cloud retry omits image")
    }

    private static func testCloudThrownTransportRetriesWithoutScreenshot() async throws {
        let recorder = ContextRequestRecorder()
        let service = AppContextService(
            apiKey: "cloud-key",
            baseURL: "https://api.example.com/openai/v1",
            customContextPrompt: "",
            contextModel: "provider/context",
            transport: { request in
                recorder.record(request)
                if recorder.count() == 1 {
                    throw URLError(.cannotConnectToHost)
                }
                return try successResponse(
                    request,
                    "User is editing a document. They likely want writing help."
                )
            }
        )

        let result = await service.inferActivityWithLLM(
            appName: "Editor",
            bundleIdentifier: "test.editor",
            windowTitle: "Document",
            selectedText: nil,
            screenshotDataURL: "data:image/jpeg;base64,IMAGE",
            contextSystemPrompt: AppContextService.defaultContextPrompt
        )

        try expect(result != nil, "cloud thrown transport retry result")
        try expect(recorder.count() == 2, "cloud thrown transport retries once")
        let firstBody = try bodyText(for: recorder.request(at: 0))
        let secondBody = try bodyText(for: recorder.request(at: 1))
        try expect(firstBody.contains("image_url"), "cloud thrown first request includes image")
        try expect(!secondBody.contains("image_url"), "cloud thrown retry omits image")
    }

    private static func testCancellationStopsRetryAndDoesNotRecordIssue() async throws {
        let recorder = ContextRequestRecorder()
        let issues = ContextIssueRecorder()
        let gate = ContextCancellationGate()
        let service = AppContextService(
            backendExecutor: AIProcessingBackendExecutor(
                choice: .cloud(modelID: "provider/context"),
                cloudBaseURL: "https://api.example.com/openai/v1",
                cloudAPIKey: "cloud-key"
            ),
            customContextPrompt: "",
            contextModel: "provider/context",
            transport: { request in
                recorder.record(request)
                await gate.waitForRelease()
                return try successResponse(
                    request,
                    "User is editing a document. They likely want writing help."
                )
            },
            issueSink: { issue in issues.record(issue) }
        )

        let task = Task {
            await service.inferActivityWithLLM(
                appName: "Editor",
                bundleIdentifier: "test.editor",
                windowTitle: "Document",
                selectedText: nil,
                screenshotDataURL: "data:image/jpeg;base64,IMAGE",
                contextSystemPrompt: AppContextService.defaultContextPrompt
            )
        }
        await gate.waitForRequest()
        task.cancel()
        await gate.release()
        let result = await task.value

        try expect(result == nil, "cancelled context returns nil")
        try expect(recorder.count() == 1, "cancelled context does not retry")
        try expect(issues.count() == 0, "cancelled context does not record issue")
    }

    private static func testLocalRequestUsesEndpointRequestAndSelectedModelIDs() async throws {
        let recorder = ContextRequestRecorder()
        let selectedModelID = LocalAIModelCatalog.quality.id
        let service = AppContextService(
            backendExecutor: AIProcessingBackendExecutor(
                choice: .localAI(modelID: selectedModelID),
                cloudBaseURL: "https://api.example.com/openai/v1",
                cloudAPIKey: "cloud-key",
                localServerManager: readyManager()
            ),
            customContextPrompt: "",
            contextModel: selectedModelID,
            transport: { request in
                recorder.record(request)
                return try successResponse(
                    request,
                    "User is writing a document. They likely want editing help."
                )
            }
        )

        let result = await service.inferActivityWithLLM(
            appName: "Editor",
            bundleIdentifier: "test.editor",
            windowTitle: "Document",
            selectedText: nil,
            screenshotDataURL: "data:image/jpeg;base64,SECRET_IMAGE",
            contextSystemPrompt: AppContextService.defaultContextPrompt
        )

        let request = try recorder.request(at: 0)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        try expect(result?.prompt.contains("Model: \(selectedModelID)") == true, "selected model stays in prompt identity")
        let bodyText = try bodyText(for: request)
        try expect(body["model"] as? String == "local", "local request model uses endpoint request identity")
        try expect(request.value(forHTTPHeaderField: "Authorization") == nil, "local endpoint has no authorization")
        try expect(!bodyText.contains("image_url"), "local endpoint omits image")
    }

    private static func testLocalFailureReturnsNilAndRecordsPrivateIssue() async throws {
        let issues = ContextIssueRecorder()
        let service = AppContextService(
            backendExecutor: localExecutor(manager: readyManager()),
            customContextPrompt: "",
            contextModel: LocalAIModelCatalog.fast.id,
            screenshotMaxDimension: 1024,
            transport: { _ in throw URLError(.cannotConnectToHost) },
            issueSink: { issue in issues.record(issue) }
        )

        let result = await service.inferActivityWithLLM(
            appName: "Editor",
            bundleIdentifier: "test.editor",
            windowTitle: "Document",
            selectedText: nil,
            screenshotDataURL: nil,
            contextSystemPrompt: AppContextService.defaultContextPrompt
        )

        try expect(result == nil, "local failure returns metadata fallback signal")
        try expect(issues.last()?.record.code == .postProcessingFailed, "local failure records private issue")
    }

    private static func testLocalProcessExitRecordsDedicatedIssue() async throws {
        let process = ContextFakeProcess()
        let issues = ContextIssueRecorder()
        let service = AppContextService(
            backendExecutor: localExecutor(manager: readyManager(process: process)),
            customContextPrompt: "",
            contextModel: LocalAIModelCatalog.fast.id,
            screenshotMaxDimension: 1024,
            transport: { _ in
                process.simulateExit()
                throw URLError(.networkConnectionLost)
            },
            issueSink: { issue in issues.record(issue) }
        )

        let result = await service.inferActivityWithLLM(
            appName: "Editor",
            bundleIdentifier: "test.editor",
            windowTitle: "Document",
            selectedText: nil,
            screenshotDataURL: nil,
            contextSystemPrompt: AppContextService.defaultContextPrompt
        )

        try expect(result == nil, "process exit returns metadata fallback signal")
        try expect(issues.last()?.record.code == .localAIProcessExited, "process exit records dedicated issue")
    }

    private static func localExecutor(manager: LocalAIServerManager) -> AIProcessingBackendExecutor {
        AIProcessingBackendExecutor(
            choice: .localAI(modelID: LocalAIModelCatalog.fast.id),
            cloudBaseURL: AppState.defaultAPIBaseURL,
            cloudAPIKey: "cloud-secret",
            localServerManager: manager
        )
    }

    private static func readyManager(process: ContextFakeProcess = ContextFakeProcess()) -> LocalAIServerManager {
        LocalAIServerManager(
            launchProcess: { _, _, port, _ in (process, port) },
            pollHealth: { _ in true },
            validateModel: { _ in .ready }
        )
    }

    private static func successResponse(
        _ request: URLRequest,
        _ content: String
    ) throws -> (Data, URLResponse) {
        let data = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": content]]]
        ])
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    private static func bodyText(for request: URLRequest) throws -> String {
        guard let body = request.httpBody,
              let text = String(data: body, encoding: .utf8) else {
            throw AppContextBackendTestFailure("request body")
        }
        return text
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else { throw AppContextBackendTestFailure(label) }
    }
}

private final class ContextRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    func request(at index: Int) throws -> URLRequest {
        lock.lock()
        defer { lock.unlock() }
        guard requests.indices.contains(index) else {
            throw AppContextBackendTestFailure("captured request at index \(index)")
        }
        return requests[index]
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }
}

private final class ContextIssueRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var issues: [QuillUserIssueError] = []

    func record(_ issue: QuillUserIssueError) {
        lock.lock()
        issues.append(issue)
        lock.unlock()
    }

    func last() -> QuillUserIssueError? {
        lock.lock()
        defer { lock.unlock() }
        return issues.last
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return issues.count
    }
}

private actor ContextCancellationGate {
    private var requestStarted = false
    private var released = false
    private var requestContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitForRequest() async {
        if requestStarted { return }
        await withCheckedContinuation { requestContinuation = $0 }
    }

    func waitForRelease() async {
        requestStarted = true
        requestContinuation?.resume()
        requestContinuation = nil
        if released { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class ContextFakeProcess: LocalAIServerProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func terminate() { simulateExit() }
    func forceTerminate() { simulateExit() }
    func setTerminationHandler(_ handler: @escaping () -> Void) {}

    func simulateExit() {
        lock.lock()
        running = false
        lock.unlock()
    }
}

private struct AppContextBackendTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
