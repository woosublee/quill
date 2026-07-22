import Foundation

@main
struct LocalAIServerManagerTests {
    static func main() async throws {
        try await testLazyStartForwardsPrimaryShardAndExactContextSize()
        try await testSecondRequestForSameModelReusesRunningProcess()
        try await testConcurrentSameModelRequestsCoalesceOneStartup()
        try await testDifferentModelDuringStartupCleansFirstBeforeLaunchingSecond()
        try await testRequestForDifferentRunningModelStopsFirstBeforeLaunchingSecond()
        try await testLateOldTerminationCallbackDoesNotClearNewSameModelLaunch()
        try await testHealthSuccessAfterProcessExitThrowsAndDoesNotPublishProcess()
        try await testUnhealthyStartupTerminatesProcess()
        try await testCrashedProcessRestartsOnNextRequest()
        try await testStopTerminatesRunningProcess()
        try await testStopDuringStartupCancelsAndCleansProcess()
        try await testIdleShutdownTerminatesAfterTimeout()
        try await testIdleShutdownDoesNothingBeforeTimeout()
        try await testSuccessfulStartupRefreshesIdleTimestampAfterHealthWait()
        print("LocalAIServerManagerTests passed")
    }

    private static func testLazyStartForwardsPrimaryShardAndExactContextSize() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAIModelStore(rootDirectory: root)
        let process = FakeProcess()
        let launch = LockedBox<[LaunchRecord]>([])
        let healthChecks = LockedBox(0)
        let manager = LocalAIServerManager(
            store: store,
            idleTimeout: 300,
            contextSize: 12_345,
            launchProcess: { model, modelURL, port, contextSize in
                launch.withValue { $0.append(LaunchRecord(modelID: model.id, modelURL: modelURL, port: port, contextSize: contextSize)) }
                return (process, port)
            },
            pollHealth: { _ in
                healthChecks.withValue { $0 += 1 }
                return true
            },
            now: { Date(timeIntervalSince1970: 0) }
        )

        let baseURL = try await manager.baseURL(for: multiArtifactModel)

        let records = launch.value
        try require(records.count == 1, "expected one launch")
        try require(records[0].modelURL == store.modelURL(for: multiArtifactModel), "manager must pass the store's primary-shard model URL")
        try require(records[0].contextSize == 12_345, "configured context size was not forwarded exactly")
        try require(healthChecks.value == 1, "expected one health check")
        try require(baseURL.absoluteString.hasPrefix("http://127.0.0.1:"), "base URL must use loopback")
        try require(baseURL.absoluteString.hasSuffix("/v1"), "base URL must use the OpenAI-compatible /v1 path")
    }

    private static func testSecondRequestForSameModelReusesRunningProcess() async throws {
        let process = FakeProcess()
        let launchCount = LockedBox(0)
        let manager = makeManager(
            launchProcess: { _, _, port, _ in
                launchCount.withValue { $0 += 1 }
                return (process, port)
            }
        )

        let firstURL = try await manager.baseURL(for: testModel)
        let secondURL = try await manager.baseURL(for: testModel)

        try require(launchCount.value == 1, "same running model should be reused")
        try require(firstURL == secondURL, "reused process should return the same base URL")
    }

    private static func testConcurrentSameModelRequestsCoalesceOneStartup() async throws {
        let process = FakeProcess()
        let healthGate = ControlledHealthPoll()
        let launchCount = LockedBox(0)
        let launchEvent = DispatchSemaphore(value: 0)
        let secondCallStarted = DispatchSemaphore(value: 0)
        let manager = makeManager(
            launchProcess: { _, _, port, _ in
                launchCount.withValue { $0 += 1 }
                launchEvent.signal()
                return (process, port)
            },
            pollHealth: { _ in await healthGate.poll() }
        )

        let first = Task { try await manager.baseURL(for: testModel) }
        try wait(launchEvent, "first launch did not start")
        try healthGate.waitUntilEntered()

        let second = Task {
            secondCallStarted.signal()
            return try await manager.baseURL(for: testModel)
        }
        try wait(secondCallStarted, "second request task did not start")
        try require(
            launchEvent.wait(timeout: .now() + 0.5) == .timedOut,
            "concurrent same-model request launched a second process"
        )

        healthGate.finish(true)
        let firstURL = try await first.value
        let secondURL = try await second.value

        try require(launchCount.value == 1, "concurrent same-model requests must share one startup")
        try require(firstURL == secondURL, "coalesced callers should receive the same URL")
    }

    private static func testDifferentModelDuringStartupCleansFirstBeforeLaunchingSecond() async throws {
        let firstProcess = FakeProcess()
        let secondProcess = FakeProcess()
        let firstHealth = ControlledHealthPoll()
        let launches = LockedBox<[String]>([])
        let secondLaunchObservedCleanup = LockedBox(false)
        let launchEvent = DispatchSemaphore(value: 0)
        let healthCallCount = LockedBox(0)
        let manager = makeManager(
            launchProcess: { model, _, port, _ in
                let launchIndex = launches.withValue { records -> Int in
                    records.append(model.id)
                    return records.count
                }
                if launchIndex == 2 {
                    secondLaunchObservedCleanup.withValue {
                        $0 = !firstProcess.isRunning && firstProcess.terminateCallCount == 1
                    }
                }
                launchEvent.signal()
                return (launchIndex == 1 ? firstProcess : secondProcess, port)
            },
            pollHealth: { _ in
                let call = healthCallCount.withValue { count -> Int in
                    count += 1
                    return count
                }
                return call == 1 ? await firstHealth.poll() : true
            }
        )

        let first = resultTask { try await manager.baseURL(for: testModel) }
        try wait(launchEvent, "first model launch did not start")
        try firstHealth.waitUntilEntered()

        let second = Task { try await manager.baseURL(for: otherModel) }
        try wait(launchEvent, "second model launch did not start after cancelling the first")
        let secondURL = try await second.value
        let firstResult = await first.value

        try requireFailure(firstResult, "superseded startup should fail")
        try require(launches.value == [testModel.id, otherModel.id], "models launched in the wrong order")
        try require(secondLaunchObservedCleanup.value, "first startup was not cleaned before second launch")
        try require(!firstProcess.isRunning, "first process must not remain resident")
        try require(secondProcess.isRunning, "second process should remain active")
        try require(secondURL.absoluteString.hasSuffix("/v1"), "second startup should return a base URL")
    }

    private static func testRequestForDifferentRunningModelStopsFirstBeforeLaunchingSecond() async throws {
        let firstProcess = FakeProcess()
        let secondProcess = FakeProcess()
        let launchCount = LockedBox(0)
        let secondLaunchObservedCleanup = LockedBox(false)
        let manager = makeManager(
            launchProcess: { _, _, port, _ in
                let count = launchCount.withValue { value -> Int in
                    value += 1
                    return value
                }
                if count == 2 {
                    secondLaunchObservedCleanup.withValue { $0 = !firstProcess.isRunning }
                }
                return (count == 1 ? firstProcess : secondProcess, port)
            }
        )

        _ = try await manager.baseURL(for: testModel)
        _ = try await manager.baseURL(for: otherModel)

        try require(firstProcess.terminateCallCount == 1, "switching models should terminate the old process")
        try require(secondLaunchObservedCleanup.value, "new process launched before old process cleanup")
        try require(secondProcess.isRunning, "new model process should remain running")
    }

    private static func testLateOldTerminationCallbackDoesNotClearNewSameModelLaunch() async throws {
        let oldProcess = FakeProcess()
        let newProcess = FakeProcess()
        let launchCount = LockedBox(0)
        let manager = makeManager(
            launchProcess: { _, _, port, _ in
                let count = launchCount.withValue { value -> Int in
                    value += 1
                    return value
                }
                return (count == 1 ? oldProcess : newProcess, port)
            }
        )

        _ = try await manager.baseURL(for: testModel)
        oldProcess.simulateCrash(invokeHandler: false)
        let replacementURL = try await manager.baseURL(for: testModel)

        oldProcess.invokeTerminationHandler()
        let reusedURL = try await manager.baseURL(for: testModel)

        try require(launchCount.value == 2, "late old callback cleared the newer same-model launch")
        try require(reusedURL == replacementURL, "newer launch should survive the old callback")
        try require(newProcess.isRunning, "new process should still be running")
    }

    private static func testHealthSuccessAfterProcessExitThrowsAndDoesNotPublishProcess() async throws {
        let exitedProcess = FakeProcess()
        let freshProcess = FakeProcess()
        let launchCount = LockedBox(0)
        let healthCallCount = LockedBox(0)
        let manager = makeManager(
            launchProcess: { _, _, port, _ in
                let count = launchCount.withValue { value -> Int in
                    value += 1
                    return value
                }
                return (count == 1 ? exitedProcess : freshProcess, port)
            },
            pollHealth: { _ in
                let count = healthCallCount.withValue { value -> Int in
                    value += 1
                    return value
                }
                if count == 1 {
                    exitedProcess.simulateCrash()
                }
                return true
            }
        )

        let firstResult = await resultTask { try await manager.baseURL(for: testModel) }.value
        try requireStartFailed(firstResult, "health success from an exited process must fail startup")

        _ = try await manager.baseURL(for: testModel)
        try require(launchCount.value == 2, "exited process must not be published as running")
        try require(freshProcess.isRunning, "fresh retry should remain running")
    }

    private static func testUnhealthyStartupTerminatesProcess() async throws {
        let process = FakeProcess()
        let manager = makeManager(
            launchProcess: { _, _, port, _ in (process, port) },
            pollHealth: { _ in false }
        )

        let result = await resultTask { try await manager.baseURL(for: testModel) }.value

        try requireStartFailed(result, "unhealthy startup should throw startFailed")
        try require(process.terminateCallCount == 1, "unhealthy startup should terminate its process")
        try require(!process.isRunning, "unhealthy process should be cleaned up")
    }

    private static func testCrashedProcessRestartsOnNextRequest() async throws {
        let crashedProcess = FakeProcess()
        let freshProcess = FakeProcess()
        let launchCount = LockedBox(0)
        let manager = makeManager(
            launchProcess: { _, _, port, _ in
                let count = launchCount.withValue { value -> Int in
                    value += 1
                    return value
                }
                return (count == 1 ? crashedProcess : freshProcess, port)
            }
        )

        _ = try await manager.baseURL(for: testModel)
        crashedProcess.simulateCrash()
        _ = try await manager.baseURL(for: testModel)

        try require(launchCount.value == 2, "crashed process should be restarted")
        try require(freshProcess.isRunning, "replacement process should be running")
    }

    private static func testStopTerminatesRunningProcess() async throws {
        let process = FakeProcess()
        let manager = makeManager(launchProcess: { _, _, port, _ in (process, port) })

        _ = try await manager.baseURL(for: testModel)
        await manager.stop()

        try require(process.terminateCallCount == 1, "stop should terminate the running process")
        try require(!process.isRunning, "stop should leave no running process")
    }

    private static func testStopDuringStartupCancelsAndCleansProcess() async throws {
        let process = FakeProcess()
        let healthGate = ControlledHealthPoll()
        let manager = makeManager(
            launchProcess: { _, _, port, _ in (process, port) },
            pollHealth: { _ in await healthGate.poll() }
        )
        let startup = resultTask { try await manager.baseURL(for: testModel) }
        try healthGate.waitUntilEntered()

        await manager.stop()
        let result = await startup.value

        try requireFailure(result, "stopped startup should not return a URL")
        try require(process.terminateCallCount == 1, "stop should terminate the startup process")
        try require(!process.isRunning, "startup process should be cleaned before stop returns")
    }

    private static func testIdleShutdownTerminatesAfterTimeout() async throws {
        let process = FakeProcess()
        let clock = LockedBox(Date(timeIntervalSince1970: 0))
        let manager = makeManager(
            idleTimeout: 300,
            launchProcess: { _, _, port, _ in (process, port) },
            now: { clock.value }
        )

        _ = try await manager.baseURL(for: testModel)
        clock.withValue { $0 = $0.addingTimeInterval(301) }
        await manager.shutdownIfIdle()

        try require(process.terminateCallCount == 1, "idle process should be terminated after timeout")
    }

    private static func testIdleShutdownDoesNothingBeforeTimeout() async throws {
        let process = FakeProcess()
        let clock = LockedBox(Date(timeIntervalSince1970: 0))
        let manager = makeManager(
            idleTimeout: 300,
            launchProcess: { _, _, port, _ in (process, port) },
            now: { clock.value }
        )

        _ = try await manager.baseURL(for: testModel)
        clock.withValue { $0 = $0.addingTimeInterval(299) }
        await manager.shutdownIfIdle()

        try require(process.terminateCallCount == 0, "process should stay running before idle timeout")
    }

    private static func testSuccessfulStartupRefreshesIdleTimestampAfterHealthWait() async throws {
        let process = FakeProcess()
        let healthGate = ControlledHealthPoll()
        let clock = LockedBox(Date(timeIntervalSince1970: 0))
        let manager = makeManager(
            idleTimeout: 300,
            launchProcess: { _, _, port, _ in (process, port) },
            pollHealth: { _ in await healthGate.poll() },
            now: { clock.value }
        )
        let startup = Task { try await manager.baseURL(for: testModel) }
        try healthGate.waitUntilEntered()
        clock.withValue { $0 = $0.addingTimeInterval(600) }

        healthGate.finish(true)
        _ = try await startup.value
        await manager.shutdownIfIdle()

        try require(process.terminateCallCount == 0, "successful startup must refresh idle time after health completes")
    }

    private static func makeManager(
        idleTimeout: TimeInterval = 300,
        contextSize: Int = 8192,
        launchProcess: @escaping LocalAIServerManager.LaunchProcess,
        pollHealth: @escaping LocalAIServerManager.PollHealth = { _ in true },
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 0) }
    ) -> LocalAIServerManager {
        LocalAIServerManager(
            store: LocalAIModelStore(rootDirectory: temporaryRoot()),
            idleTimeout: idleTimeout,
            contextSize: contextSize,
            launchProcess: launchProcess,
            pollHealth: pollHealth,
            now: now
        )
    }

    private static func resultTask(
        _ operation: @escaping @Sendable () async throws -> URL
    ) -> Task<Result<URL, Error>, Never> {
        Task {
            do {
                return .success(try await operation())
            } catch {
                return .failure(error)
            }
        }
    }

    private static func requireStartFailed(_ result: Result<URL, Error>, _ message: String) throws {
        guard case let .failure(error) = result,
              case LocalAIServerManagerError.startFailed = error else {
            throw TestFailure(message)
        }
    }

    private static func requireFailure(_ result: Result<URL, Error>, _ message: String) throws {
        guard case .failure = result else { throw TestFailure(message) }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(message) }
    }

    private static func wait(_ semaphore: DispatchSemaphore, _ message: String) throws {
        guard semaphore.wait(timeout: .now() + 2) == .success else { throw TestFailure(message) }
    }

    private static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private static let testModel = model(id: "test-model", artifactNames: ["test-model.gguf"])
    private static let otherModel = model(id: "other-model", artifactNames: ["other-model.gguf"])
    private static let multiArtifactModel = model(
        id: "multi-model",
        artifactNames: ["multi-model-00001-of-00002.gguf", "multi-model-00002-of-00002.gguf"]
    )

    private static func model(id: String, artifactNames: [String]) -> LocalAIModel {
        LocalAIModel(
            id: id,
            displayName: id,
            description: "Test model",
            artifacts: artifactNames.map { name in
                LocalAIModelArtifact(
                    downloadURL: URL(string: "https://example.com/\(name)")!,
                    expectedFileName: name,
                    approximateBytes: 16,
                    checksumSHA256: String(repeating: "0", count: 64)
                )
            },
            approximateResidentRAMBytes: 32
        )
    }
}

private struct LaunchRecord {
    let modelID: String
    let modelURL: URL
    let port: UInt16
    let contextSize: Int
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    @discardableResult
    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&storedValue)
    }
}

private final class ControlledHealthPoll: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private var continuation: CheckedContinuation<Bool, Never>?
    private var resolvedResult: Bool?

    func poll() async -> Bool {
        entered.signal()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediateResult: Bool?
                lock.lock()
                if let resolvedResult {
                    immediateResult = resolvedResult
                } else {
                    self.continuation = continuation
                    immediateResult = nil
                }
                lock.unlock()
                if let immediateResult {
                    continuation.resume(returning: immediateResult)
                }
            }
        } onCancel: {
            self.finish(false)
        }
    }

    func waitUntilEntered() throws {
        guard entered.wait(timeout: .now() + 2) == .success else {
            throw TestFailure("health poll did not start")
        }
    }

    func finish(_ result: Bool) {
        let continuationToResume: CheckedContinuation<Bool, Never>?
        lock.lock()
        if resolvedResult == nil {
            resolvedResult = result
            continuationToResume = continuation
            continuation = nil
        } else {
            continuationToResume = nil
        }
        lock.unlock()
        continuationToResume?.resume(returning: result)
    }
}

private final class FakeProcess: LocalAIServerProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var terminationHandler: (() -> Void)?
    private var storedTerminateCallCount = 0

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    var terminateCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedTerminateCallCount
    }

    func terminate() {
        let handler: (() -> Void)?
        lock.lock()
        storedTerminateCallCount += 1
        running = false
        handler = terminationHandler
        lock.unlock()
        handler?()
    }

    func setTerminationHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        terminationHandler = handler
        lock.unlock()
    }

    func simulateCrash(invokeHandler: Bool = true) {
        let handler: (() -> Void)?
        lock.lock()
        running = false
        handler = invokeHandler ? terminationHandler : nil
        lock.unlock()
        handler?()
    }

    func invokeTerminationHandler() {
        lock.lock()
        let handler = terminationHandler
        lock.unlock()
        handler?()
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }

    init(_ message: String) {
        self.message = message
    }
}
