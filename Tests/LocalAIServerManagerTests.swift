import CryptoKit
import Foundation

@main
struct LocalAIServerManagerTests {
    static func main() async throws {
        try await testLazyStartForwardsPrimaryShardAndExactContextSize()
        try await testIncompletePackageRefusesLaunch()
        try await testCorruptPackageRefusesLaunch()
        try await testRuntimeValidationRecoversInterruptedReplacementBeforeLaunch()
        try await testDefaultHealthPollUsesExplicitShortRequestTimeout()
        try await testHealthPollCannotExceedOverallDeadline()
        try await testHealthPollCancellationExitsPromptly()
        try await testSecondRequestForSameModelReusesRunningProcess()
        try await testConcurrentSameModelRequestsCoalesceOneStartup()
        try await testCancellingOneOfTwoSameModelWaitersKeepsSharedStartup()
        try await testCancellingSoleStartupWaiterCleansProcessAndThrowsCancellation()
        try await testDifferentModelDuringStartupWaitsForDelayedExitBeforeLaunchingSecond()
        try await testRequestForDifferentRunningModelWaitsForDelayedExitBeforeLaunchingSecond()
        try await testLateOldTerminationCallbackDoesNotClearNewSameModelLaunch()
        try await testHealthSuccessAfterProcessExitThrowsAndDoesNotPublishProcess()
        try await testUnhealthyStartupTerminatesProcess()
        try await testCrashedProcessRestartsOnNextRequest()
        try await testStopTerminatesRunningProcess()
        try await testStopForceTerminatesAfterGraceTimeout()
        try await testStopDuringStartupWaitsForDelayedExitCleanup()
        try await testIdleShutdownTerminatesAfterTimeout()
        try await testIdleShutdownDoesNothingBeforeTimeout()
        try await testIdleShutdownDoesNotCancelNewStartupUsingOldTimestamp()
        try await testSuccessfulStartupRefreshesIdleTimestampAfterHealthWait()
        try await testHeldOpenOperationBlocksDifferentModelLaunchUntilRelease()
        try await testCancellingPendingSwitchUnblocksSameModelOperations()
        try await testIdleShutdownDoesNotTerminateHeldOpenOperation()
        try await testThrownOperationReleasesLease()
        try await testCancelledOperationReleasesLease()
        try await testOperationErrorIsPreservedWhileProcessLives()
        try await testOperationErrorBecomesProcessExitedAfterCrash()
        try await testManagerDeinitTerminatesRunningProcess()
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
            validateModel: { _ in .ready },
            now: { Date(timeIntervalSince1970: 0) }
        )

        let baseURL = try await manager.withBaseURL(for: multiArtifactModel) { $0 }

        let records = launch.value
        try require(records.count == 1, "expected one launch")
        try require(records[0].modelURL == store.modelURL(for: multiArtifactModel), "manager must pass the store's primary-shard model URL")
        try require(records[0].contextSize == 12_345, "configured context size was not forwarded exactly")
        try require(healthChecks.value == 1, "expected one health check")
        try require(baseURL.absoluteString.hasPrefix("http://127.0.0.1:"), "base URL must use loopback")
        try require(baseURL.absoluteString.hasSuffix("/v1"), "base URL must use the OpenAI-compatible /v1 path")
    }

    private static func testIncompletePackageRefusesLaunch() async throws {
        let launchCount = LockedBox(0)
        let manager = makeManager(
            launchProcess: { _, _, port, _ in
                launchCount.withValue { $0 += 1 }
                return (FakeProcess(), port)
            },
            validateModel: { _ in .partial(downloadedBytes: 16, expectedBytes: 32) }
        )

        let result = await resultTask {
            try await manager.withBaseURL(for: multiArtifactModel) { $0 }
        }.value

        try requireModelUnavailable(
            result,
            containing: multiArtifactModel.id,
            and: "16 of 32 bytes",
            message: "incomplete package should report a detailed unavailable error"
        )
        try require(launchCount.value == 0, "incomplete package must be rejected before process launch")
    }

    private static func testCorruptPackageRefusesLaunch() async throws {
        let launchCount = LockedBox(0)
        let corruptArtifact = multiArtifactModel.artifacts[1].expectedFileName
        let manager = makeManager(
            launchProcess: { _, _, port, _ in
                launchCount.withValue { $0 += 1 }
                return (FakeProcess(), port)
            },
            validateModel: { _ in .corrupt("\(corruptArtifact): Model artifact checksum mismatch.") }
        )

        let result = await resultTask {
            try await manager.withBaseURL(for: multiArtifactModel) { $0 }
        }.value

        try requireModelCorrupt(
            result,
            containing: corruptArtifact,
            and: "checksum mismatch",
            message: "corrupt package should preserve artifact diagnostics"
        )
        try require(launchCount.value == 0, "corrupt package must be rejected before process launch")
    }

    private static func testRuntimeValidationRecoversInterruptedReplacementBeforeLaunch() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = [Data(repeating: 41, count: 16), Data(repeating: 42, count: 20)]
        let model = validatedModel(id: "runtime-recovery", contents: contents)
        let store = LocalAIModelStore(rootDirectory: root)
        let token = UUID().uuidString
        try store.ensureModelsDirectoryExists()
        for (artifact, data) in zip(model.artifacts, contents) {
            try data.write(to: store.backupArtifactURL(for: artifact, token: token))
        }
        try Data([99]).write(to: store.artifactURL(for: model.artifacts[0]))
        let launchCount = LockedBox(0)
        let manager = LocalAIServerManager(
            store: store,
            launchProcess: { _, _, port, _ in
                launchCount.withValue { $0 += 1 }
                return (FakeProcess(), port)
            },
            pollHealth: { _ in true }
        )

        _ = try await manager.withBaseURL(for: model) { $0 }

        try require(launchCount.value == 1, "runtime recovery should restore the package before launch")
        try require(store.installStatus(for: model) == .ready, "runtime recovery did not restore a ready package")
        for artifact in model.artifacts {
            try require(
                !directoryEntryExists(at: store.backupArtifactURL(for: artifact, token: token)),
                "runtime recovery left a stale transaction backup"
            )
        }
    }

    private static func testDefaultHealthPollUsesExplicitShortRequestTimeout() async throws {
        let clock = FakeMonotonicClock()
        let observedTimeouts = LockedBox<[TimeInterval]>([])
        let poller = LocalAIHealthPoller(
            overallTimeout: 10,
            probeTimeout: 1,
            cadence: 0.2,
            maxAttempts: 50,
            probe: { request in
                observedTimeouts.withValue { $0.append(request.timeoutInterval) }
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(), response)
            },
            now: { clock.value },
            sleep: { duration in clock.advance(by: duration) }
        )

        let result = await poller.poll(port: 12_345)

        try require(result, "healthy response should complete polling")
        try require(observedTimeouts.value == [1], "health request should use an explicit one-second timeout")
    }

    private static func testHealthPollCannotExceedOverallDeadline() async throws {
        let clock = FakeMonotonicClock()
        let observedTimeouts = LockedBox<[TimeInterval]>([])
        let poller = LocalAIHealthPoller(
            overallTimeout: 10,
            probeTimeout: 1,
            cadence: 0.2,
            maxAttempts: 50,
            probe: { request in
                observedTimeouts.withValue { $0.append(request.timeoutInterval) }
                clock.advance(by: request.timeoutInterval)
                throw HealthProbeFailure.stalled
            },
            now: { clock.value },
            sleep: { duration in clock.advance(by: duration) }
        )

        let result = await poller.poll(port: 12_345)

        try require(!result, "stalled probes should fail health polling")
        try require(clock.value <= 10.000_001, "health polling exceeded its overall deadline")
        try require(observedTimeouts.value.count <= 50, "health polling exceeded the attempt limit")
        try require(
            observedTimeouts.value.allSatisfy { $0 > 0 && $0 <= 1 },
            "every health request timeout must be short and bounded by the remaining deadline"
        )
    }

    private static func testHealthPollCancellationExitsPromptly() async throws {
        let sleepStarted = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let result = LockedBox<Bool?>(nil)
        let poller = LocalAIHealthPoller(
            overallTimeout: 10,
            probeTimeout: 1,
            cadence: 0.2,
            maxAttempts: 50,
            probe: { _ in throw HealthProbeFailure.failed },
            now: { ProcessInfo.processInfo.systemUptime },
            sleep: { _ in
                sleepStarted.signal()
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        )
        let polling = Task {
            let value = await poller.poll(port: 12_345)
            result.withValue { $0 = value }
            completed.signal()
        }
        try wait(sleepStarted, "health poll did not enter its retry sleep")

        polling.cancel()
        try wait(completed, "cancelled health poll did not exit promptly")
        await polling.value

        try require(result.value == false, "cancelled health poll should report failure")
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

        let firstURL = try await manager.withBaseURL(for: testModel) { $0 }
        let secondURL = try await manager.withBaseURL(for: testModel) { $0 }

        try require(launchCount.value == 1, "same running model should be reused")
        try require(firstURL == secondURL, "reused process should return the same base URL")
    }

    private static func testConcurrentSameModelRequestsCoalesceOneStartup() async throws {
        let process = FakeProcess()
        let healthGate = ControlledHealthPoll()
        let launchCount = LockedBox(0)
        let twoWaitersRegistered = DispatchSemaphore(value: 0)
        let manager = makeManager(
            launchProcess: { _, _, port, _ in
                launchCount.withValue { $0 += 1 }
                return (process, port)
            },
            pollHealth: { _ in await healthGate.poll() },
            observeLifecycle: { snapshot in
                if snapshot.phase == .starting,
                   snapshot.modelID == testModel.id,
                   snapshot.startupWaiterCount == 2 {
                    twoWaitersRegistered.signal()
                }
            }
        )

        let first = Task { try await manager.withBaseURL(for: testModel) { $0 } }
        try healthGate.waitUntilEntered()
        let second = Task { try await manager.withBaseURL(for: testModel) { $0 } }
        try wait(twoWaitersRegistered, "second caller did not join the in-progress startup")

        try require(launchCount.value == 1, "concurrent same-model request launched a second process")
        healthGate.finish(true)
        let firstURL = try await first.value
        let secondURL = try await second.value

        try require(launchCount.value == 1, "concurrent same-model requests must share one startup")
        try require(firstURL == secondURL, "coalesced callers should receive the same URL")
    }

    private static func testCancellingOneOfTwoSameModelWaitersKeepsSharedStartup() async throws {
        let process = FakeProcess()
        let healthGate = ControlledHealthPoll()
        let twoWaitersRegistered = DispatchSemaphore(value: 0)
        let oneWaiterRemaining = DispatchSemaphore(value: 0)
        let sawTwoWaiters = LockedBox(false)
        let manager = makeManager(
            launchProcess: { _, _, port, _ in (process, port) },
            pollHealth: { _ in await healthGate.poll() },
            observeLifecycle: { snapshot in
                guard snapshot.phase == .starting, snapshot.modelID == testModel.id else { return }
                if snapshot.startupWaiterCount == 2 {
                    sawTwoWaiters.withValue { $0 = true }
                    twoWaitersRegistered.signal()
                } else if snapshot.startupWaiterCount == 1, sawTwoWaiters.value {
                    oneWaiterRemaining.signal()
                }
            }
        )

        let cancelledCaller = resultTask { try await manager.withBaseURL(for: testModel) { $0 } }
        try healthGate.waitUntilEntered()
        let survivingCaller = resultTask { try await manager.withBaseURL(for: testModel) { $0 } }
        try wait(twoWaitersRegistered, "two same-model waiters were not registered")

        cancelledCaller.cancel()
        try wait(oneWaiterRemaining, "cancelled waiter was not released from shared startup")
        try require(process.terminateCallCount == 0, "one cancelled waiter must not stop a startup needed by another waiter")

        healthGate.finish(true)
        try requireCancellation(await cancelledCaller.value, "cancelled waiter should receive CancellationError")
        let survivingResult = await survivingCaller.value
        guard case let .success(url) = survivingResult else {
            throw TestFailure("surviving waiter should receive the shared startup URL")
        }
        try require(url.absoluteString.hasSuffix("/v1"), "surviving waiter received an invalid base URL")
        try require(process.isRunning, "shared process should remain running for the surviving waiter")
    }

    private static func testCancellingSoleStartupWaiterCleansProcessAndThrowsCancellation() async throws {
        let process = DelayedExitProcess()
        let healthGate = ControlledHealthPoll()
        let waiterRegistered = DispatchSemaphore(value: 0)
        let manager = makeManager(
            launchProcess: { _, _, port, _ in (process, port) },
            pollHealth: { _ in await healthGate.poll() },
            observeLifecycle: { snapshot in
                if snapshot.phase == .starting,
                   snapshot.modelID == testModel.id,
                   snapshot.startupWaiterCount == 1 {
                    waiterRegistered.signal()
                }
            }
        )
        let caller = resultTask { try await manager.withBaseURL(for: testModel) { $0 } }
        try wait(waiterRegistered, "sole startup waiter was not registered")
        try healthGate.waitUntilEntered()

        caller.cancel()
        try process.waitForTerminateRequest()
        let stopping = await manager.lifecycleSnapshot()
        try require(stopping.phase == .stopping, "last waiter cancellation must remain in stopping until process exit")
        try require(stopping.modelID == testModel.id, "stopping snapshot should identify the cancelled launch")

        process.completeTermination()
        try requireCancellation(await caller.value, "sole cancelled waiter should receive CancellationError")
        try require(process.terminateCallCount == 1, "last waiter cancellation should terminate the startup process once")
        let idle = await manager.lifecycleSnapshot()
        try require(idle.phase == .idle, "last waiter cancellation should finish cleanup before returning")
    }

    private static func testDifferentModelDuringStartupWaitsForDelayedExitBeforeLaunchingSecond() async throws {
        let firstProcess = DelayedExitProcess()
        let secondProcess = FakeProcess()
        let firstHealth = ControlledHealthPoll()
        let launches = LockedBox<[String]>([])
        let secondLaunch = DispatchSemaphore(value: 0)
        let healthCallCount = LockedBox(0)
        let manager = makeManager(
            launchProcess: { model, _, port, _ in
                let launchIndex = launches.withValue { records -> Int in
                    records.append(model.id)
                    return records.count
                }
                if launchIndex == 2 { secondLaunch.signal() }
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

        let first = resultTask { try await manager.withBaseURL(for: testModel) { $0 } }
        try firstHealth.waitUntilEntered()
        let second = Task { try await manager.withBaseURL(for: otherModel) { $0 } }
        try firstProcess.waitForTerminateRequest()

        let stopping = await manager.lifecycleSnapshot()
        try require(stopping.phase == .stopping, "model switch should wait in stopping for delayed process exit")
        try require(stopping.modelID == testModel.id, "model switch should still own the first launch while stopping")
        try require(launches.value == [testModel.id], "replacement launched before first process exited")

        firstProcess.completeTermination()
        try wait(secondLaunch, "second model did not launch after first process exited")
        let secondURL = try await second.value
        let firstResult = await first.value

        try requireFailure(firstResult, "superseded startup should fail")
        try require(launches.value == [testModel.id, otherModel.id], "models launched in the wrong order")
        try require(!firstProcess.isRunning, "first process must not remain resident")
        try require(secondProcess.isRunning, "second process should remain active")
        try require(secondURL.absoluteString.hasSuffix("/v1"), "second startup should return a base URL")
    }

    private static func testRequestForDifferentRunningModelWaitsForDelayedExitBeforeLaunchingSecond() async throws {
        let firstProcess = DelayedExitProcess()
        let secondProcess = FakeProcess()
        let launchCount = LockedBox(0)
        let secondLaunch = DispatchSemaphore(value: 0)
        let manager = makeManager(
            launchProcess: { _, _, port, _ in
                let count = launchCount.withValue { value -> Int in
                    value += 1
                    return value
                }
                if count == 2 { secondLaunch.signal() }
                return (count == 1 ? firstProcess : secondProcess, port)
            }
        )

        _ = try await manager.withBaseURL(for: testModel) { $0 }
        let replacement = Task { try await manager.withBaseURL(for: otherModel) { $0 } }
        try firstProcess.waitForTerminateRequest()

        let stopping = await manager.lifecycleSnapshot()
        try require(stopping.phase == .stopping, "running model switch should wait for delayed process exit")
        try require(launchCount.value == 1, "replacement launched before running process exited")

        firstProcess.completeTermination()
        try wait(secondLaunch, "replacement did not launch after old process exit")
        _ = try await replacement.value

        try require(firstProcess.terminateCallCount == 1, "switching models should terminate the old process")
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

        _ = try await manager.withBaseURL(for: testModel) { $0 }
        oldProcess.simulateCrash(invokeHandler: false)
        let replacementURL = try await manager.withBaseURL(for: testModel) { $0 }

        oldProcess.invokeTerminationHandler()
        let reusedURL = try await manager.withBaseURL(for: testModel) { $0 }

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

        let firstResult = await resultTask { try await manager.withBaseURL(for: testModel) { $0 } }.value
        try requireStartFailed(firstResult, "health success from an exited process must fail startup")

        _ = try await manager.withBaseURL(for: testModel) { $0 }
        try require(launchCount.value == 2, "exited process must not be published as running")
        try require(freshProcess.isRunning, "fresh retry should remain running")
    }

    private static func testUnhealthyStartupTerminatesProcess() async throws {
        let process = FakeProcess()
        let manager = makeManager(
            launchProcess: { _, _, port, _ in (process, port) },
            pollHealth: { _ in false }
        )

        let result = await resultTask { try await manager.withBaseURL(for: testModel) { $0 } }.value

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

        _ = try await manager.withBaseURL(for: testModel) { $0 }
        crashedProcess.simulateCrash()
        _ = try await manager.withBaseURL(for: testModel) { $0 }

        try require(launchCount.value == 2, "crashed process should be restarted")
        try require(freshProcess.isRunning, "replacement process should be running")
    }

    private static func testStopTerminatesRunningProcess() async throws {
        let process = FakeProcess()
        let manager = makeManager(launchProcess: { _, _, port, _ in (process, port) })

        _ = try await manager.withBaseURL(for: testModel) { $0 }
        await manager.stop()

        try require(process.terminateCallCount == 1, "stop should terminate the running process")
        try require(!process.isRunning, "stop should leave no running process")
    }

    private static func testStopForceTerminatesAfterGraceTimeout() async throws {
        let process = DelayedExitProcess()
        let observedTimeouts = LockedBox<[TimeInterval]>([])
        let manager = makeManager(
            launchProcess: { _, _, port, _ in (process, port) },
            terminationGracePeriod: 0.5,
            waitForProcessExit: { process, timeout in
                observedTimeouts.withValue { $0.append(timeout) }
                return !process.isRunning
            }
        )

        _ = try await manager.withBaseURL(for: testModel) { $0 }
        await manager.stop()

        try require(process.terminateCallCount == 1, "stop should request graceful termination once")
        try require(process.forceTerminateCallCount == 1, "stop should force-terminate after the grace period expires")
        try require(observedTimeouts.value == [0.5, 0.5], "manager should use the configured timeout before and after force termination")
        try require(!process.isRunning, "force termination should leave no running process")
        let idle = await manager.lifecycleSnapshot()
        try require(idle.phase == .idle, "force-terminated process should leave the manager idle")
    }

    private static func testStopDuringStartupWaitsForDelayedExitCleanup() async throws {
        let process = DelayedExitProcess()
        let healthGate = ControlledHealthPoll()
        let manager = makeManager(
            launchProcess: { _, _, port, _ in (process, port) },
            pollHealth: { _ in await healthGate.poll() }
        )
        let startup = resultTask { try await manager.withBaseURL(for: testModel) { $0 } }
        try healthGate.waitUntilEntered()

        let stopTask = Task { await manager.stop() }
        try process.waitForTerminateRequest()
        let stopping = await manager.lifecycleSnapshot()
        try require(stopping.phase == .stopping, "stop should remain pending while startup process is still running")

        process.completeTermination()
        await stopTask.value
        let result = await startup.value

        try requireFailure(result, "stopped startup should not return a URL")
        try require(process.terminateCallCount == 1, "stop should terminate the startup process")
        try require(!process.isRunning, "startup process should be cleaned before stop returns")
        let idle = await manager.lifecycleSnapshot()
        try require(idle.phase == .idle, "stop should finish in idle after delayed exit cleanup")
    }

    private static func testIdleShutdownTerminatesAfterTimeout() async throws {
        let process = FakeProcess()
        let clock = LockedBox(Date(timeIntervalSince1970: 0))
        let manager = makeManager(
            idleTimeout: 300,
            launchProcess: { _, _, port, _ in (process, port) },
            now: { clock.value }
        )

        _ = try await manager.withBaseURL(for: testModel) { $0 }
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

        _ = try await manager.withBaseURL(for: testModel) { $0 }
        clock.withValue { $0 = $0.addingTimeInterval(299) }
        await manager.shutdownIfIdle()

        try require(process.terminateCallCount == 0, "process should stay running before idle timeout")
    }

    private static func testIdleShutdownDoesNotCancelNewStartupUsingOldTimestamp() async throws {
        let oldProcess = FakeProcess()
        let newProcess = FakeProcess()
        let newHealth = ControlledHealthPoll()
        let clock = LockedBox(Date(timeIntervalSince1970: 0))
        let launchCount = LockedBox(0)
        let healthCount = LockedBox(0)
        let manager = makeManager(
            idleTimeout: 300,
            launchProcess: { _, _, port, _ in
                let count = launchCount.withValue { value -> Int in
                    value += 1
                    return value
                }
                return (count == 1 ? oldProcess : newProcess, port)
            },
            pollHealth: { _ in
                let count = healthCount.withValue { value -> Int in
                    value += 1
                    return value
                }
                return count == 1 ? true : await newHealth.poll()
            },
            now: { clock.value }
        )

        _ = try await manager.withBaseURL(for: testModel) { $0 }
        clock.withValue { $0 = Date(timeIntervalSince1970: 299) }
        let newStartup = Task { try await manager.withBaseURL(for: otherModel) { $0 } }
        try newHealth.waitUntilEntered()
        clock.withValue { $0 = Date(timeIntervalSince1970: 301) }

        await manager.shutdownIfIdle()
        let starting = await manager.lifecycleSnapshot()
        try require(starting.phase == .starting, "idle check must not stop an actively requested startup")
        try require(starting.modelID == otherModel.id, "new model should remain the active startup")
        try require(newProcess.terminateCallCount == 0, "old timestamp must not terminate the new startup")

        newHealth.finish(true)
        _ = try await newStartup.value
        try require(newProcess.isRunning, "new startup should complete after idle check")
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
        let startup = Task { try await manager.withBaseURL(for: testModel) { $0 } }
        try healthGate.waitUntilEntered()
        clock.withValue { $0 = $0.addingTimeInterval(600) }

        healthGate.finish(true)
        _ = try await startup.value
        await manager.shutdownIfIdle()

        try require(process.terminateCallCount == 0, "successful startup must refresh idle time after health completes")
    }

    private static func testHeldOpenOperationBlocksDifferentModelLaunchUntilRelease() async throws {
        let firstProcess = FakeProcess()
        let secondProcess = FakeProcess()
        let operationGate = AsyncGate()
        let operationStarted = DispatchSemaphore(value: 0)
        let launchCount = LockedBox(0)
        let manager = makeManager(
            launchProcess: { _, _, port, _ in
                let count = launchCount.withValue { value -> Int in
                    value += 1
                    return value
                }
                return (count == 1 ? firstProcess : secondProcess, port)
            }
        )

        let heldOperation = resultTask {
            try await manager.withBaseURL(for: testModel) { url in
                operationStarted.signal()
                await operationGate.wait()
                return url
            }
        }
        try wait(operationStarted, "held operation did not start")

        let replacement = Task { try await manager.withBaseURL(for: otherModel) { $0 } }
        try await waitUntil("model switch did not begin draining the active operation") {
            await manager.lifecycleSnapshot().isWaitingForActiveRequests
        }

        try require(firstProcess.terminateCallCount == 0, "model switch terminated a process with an active operation")
        try require(launchCount.value == 1, "replacement launched before the active operation completed")

        operationGate.open()
        _ = try await heldOperation.value.get()
        _ = try await replacement.value

        try require(firstProcess.terminateCallCount == 1, "released operation should permit the old process to stop")
        try require(launchCount.value == 2, "released operation should permit the replacement launch")
    }

    private static func testCancellingPendingSwitchUnblocksSameModelOperations() async throws {
        let process = FakeProcess()
        let operationGate = AsyncGate()
        let operationStarted = DispatchSemaphore(value: 0)
        let launchCount = LockedBox(0)
        let manager = makeManager(
            launchProcess: { _, _, port, _ in
                launchCount.withValue { $0 += 1 }
                return (process, port)
            }
        )
        let heldOperation = resultTask {
            try await manager.withBaseURL(for: testModel) { url in
                operationStarted.signal()
                await operationGate.wait()
                return url
            }
        }
        try wait(operationStarted, "held operation did not start")
        let replacement = resultTask {
            try await manager.withBaseURL(for: otherModel) { $0 }
        }
        try await waitUntil("model switch did not begin waiting for active requests") {
            await manager.lifecycleSnapshot().isWaitingForActiveRequests
        }

        replacement.cancel()
        try requireCancellation(await replacement.value, "cancelled model switch should exit promptly")
        try await waitUntil("cancelled model switch left the current launch draining") {
            !(await manager.lifecycleSnapshot().isWaitingForActiveRequests)
        }

        _ = try await manager.withBaseURL(for: testModel) { $0 }
        try require(launchCount.value == 1, "same-model operation should reuse the held process")
        try require(process.terminateCallCount == 0, "cancelled switch must not terminate the held process")

        operationGate.open()
        _ = try await heldOperation.value.get()
    }

    private static func testIdleShutdownDoesNotTerminateHeldOpenOperation() async throws {
        let process = FakeProcess()
        let operationGate = AsyncGate()
        let operationStarted = DispatchSemaphore(value: 0)
        let clock = LockedBox(Date(timeIntervalSince1970: 0))
        let manager = makeManager(
            idleTimeout: 300,
            launchProcess: { _, _, port, _ in (process, port) },
            now: { clock.value }
        )
        let heldOperation = resultTask {
            try await manager.withBaseURL(for: testModel) { url in
                operationStarted.signal()
                await operationGate.wait()
                return url
            }
        }
        try wait(operationStarted, "held operation did not start")
        clock.withValue { $0 = $0.addingTimeInterval(301) }

        await manager.shutdownIfIdle()

        try require(process.terminateCallCount == 0, "idle shutdown terminated a held-open operation")
        operationGate.open()
        _ = try await heldOperation.value.get()
    }

    private static func testThrownOperationReleasesLease() async throws {
        let firstProcess = FakeProcess()
        let secondProcess = FakeProcess()
        let launchCount = LockedBox(0)
        let manager = makeManager(
            launchProcess: { _, _, port, _ in
                let count = launchCount.withValue { value -> Int in
                    value += 1
                    return value
                }
                return (count == 1 ? firstProcess : secondProcess, port)
            }
        )

        let result = await resultTask {
            try await manager.withBaseURL(for: testModel) { _ in
                throw TestFailure("expected operation failure")
            }
        }.value
        try requireFailure(result, "throwing operation should propagate its error")

        _ = try await manager.withBaseURL(for: otherModel) { $0 }
        try require(firstProcess.terminateCallCount == 1, "throwing operation leaked its active request lease")
        try require(launchCount.value == 2, "throwing operation should allow a later model switch")
    }

    private static func testCancelledOperationReleasesLease() async throws {
        let firstProcess = FakeProcess()
        let secondProcess = FakeProcess()
        let operationStarted = DispatchSemaphore(value: 0)
        let launchCount = LockedBox(0)
        let manager = makeManager(
            launchProcess: { _, _, port, _ in
                let count = launchCount.withValue { value -> Int in
                    value += 1
                    return value
                }
                return (count == 1 ? firstProcess : secondProcess, port)
            }
        )
        let operation = resultTask {
            try await manager.withBaseURL(for: testModel) { url in
                operationStarted.signal()
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return url
            }
        }
        try wait(operationStarted, "cancellable operation did not start")

        operation.cancel()
        try requireCancellation(await operation.value, "cancelled operation should propagate cancellation")

        _ = try await manager.withBaseURL(for: otherModel) { $0 }
        try require(firstProcess.terminateCallCount == 1, "cancelled operation leaked its active request lease")
        try require(launchCount.value == 2, "cancelled operation should allow a later model switch")
    }

    private static func testOperationErrorIsPreservedWhileProcessLives() async throws {
        let process = FakeProcess()
        let manager = makeManager(
            launchProcess: { _, _, port, _ in (process, port) }
        )

        do {
            _ = try await manager.withBaseURL(for: testModel) { _ -> URL in
                throw OperationSentinel.failed
            }
            assertionFailure("Expected operation failure")
        } catch OperationSentinel.failed {
            // expected
        }
        let snapshot = await manager.lifecycleSnapshot()
        try require(
            snapshot.activeRequestCount == 0,
            "throwing operation must release its lease while the process lives"
        )
    }

    private static func testOperationErrorBecomesProcessExitedAfterCrash() async throws {
        let process = FakeProcess()
        let manager = makeManager(
            launchProcess: { _, _, port, _ in (process, port) }
        )

        do {
            _ = try await manager.withBaseURL(for: testModel) { _ -> URL in
                process.simulateCrash()
                throw OperationSentinel.failed
            }
            assertionFailure("Expected process-exited failure")
        } catch LocalAIServerManagerError.processExited(let detail) {
            try require(detail.contains(testModel.id), "process-exited detail must identify the model")
        }
        let snapshot = await manager.lifecycleSnapshot()
        try require(snapshot.phase == .idle, "crashed process must clear the matching launch")
        try require(snapshot.activeRequestCount == 0, "crashed operation must release its lease")
    }

    private static func testManagerDeinitTerminatesRunningProcess() async throws {
        let process = FakeProcess()
        var manager: LocalAIServerManager? = makeManager(
            launchProcess: { _, _, port, _ in (process, port) }
        )

        _ = try await manager?.withBaseURL(for: testModel) { $0 }
        manager = nil

        try process.waitForTerminateRequest()
        try require(process.terminateCallCount == 1, "manager deinit should terminate its running process")
    }

    private static func makeManager(
        idleTimeout: TimeInterval = 300,
        contextSize: Int = 8192,
        launchProcess: @escaping LocalAIServerManager.LaunchProcess,
        pollHealth: @escaping LocalAIServerManager.PollHealth = { _ in true },
        validateModel: @escaping LocalAIServerManager.ValidateModel = { _ in .ready },
        terminationGracePeriod: TimeInterval = 2,
        waitForProcessExit: @escaping LocalAIServerManager.WaitForProcessExit = { process, _ in
            while process.isRunning {
                await Task.yield()
            }
            return true
        },
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 0) },
        observeLifecycle: @escaping LocalAIServerManager.ObserveLifecycle = { _ in }
    ) -> LocalAIServerManager {
        LocalAIServerManager(
            store: LocalAIModelStore(rootDirectory: temporaryRoot()),
            idleTimeout: idleTimeout,
            contextSize: contextSize,
            launchProcess: launchProcess,
            pollHealth: pollHealth,
            validateModel: validateModel,
            terminationGracePeriod: terminationGracePeriod,
            waitForProcessExit: waitForProcessExit,
            now: now,
            observeLifecycle: observeLifecycle
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

    private static func requireModelUnavailable(
        _ result: Result<URL, Error>,
        containing firstDetail: String,
        and secondDetail: String,
        message: String
    ) throws {
        guard case let .failure(error) = result,
              case let LocalAIServerManagerError.modelUnavailable(detail) = error,
              detail.contains(firstDetail),
              detail.contains(secondDetail) else {
            throw TestFailure(message)
        }
    }

    private static func requireModelCorrupt(
        _ result: Result<URL, Error>,
        containing firstDetail: String,
        and secondDetail: String,
        message: String
    ) throws {
        guard case let .failure(error) = result,
              case let LocalAIServerManagerError.modelCorrupt(detail) = error,
              detail.contains(firstDetail),
              detail.contains(secondDetail) else {
            throw TestFailure(message)
        }
    }

    private static func requireCancellation(_ result: Result<URL, Error>, _ message: String) throws {
        guard case let .failure(error) = result, error is CancellationError else {
            throw TestFailure(message)
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(message) }
    }

    private static func wait(_ semaphore: DispatchSemaphore, _ message: String) throws {
        guard semaphore.wait(timeout: .now() + 2) == .success else { throw TestFailure(message) }
    }

    private static func waitUntil(
        _ message: String,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw TestFailure(message)
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

    private static func validatedModel(id: String, contents: [Data]) -> LocalAIModel {
        LocalAIModel(
            id: id,
            displayName: id,
            description: "Validated test model",
            artifacts: contents.enumerated().map { index, data in
                LocalAIModelArtifact(
                    downloadURL: URL(string: "https://example.com/\(id)-\(index).gguf")!,
                    expectedFileName: "\(id)-\(index).gguf",
                    approximateBytes: Int64(data.count),
                    checksumSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                )
            },
            approximateResidentRAMBytes: 32
        )
    }

    private static func directoryEntryExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

private enum OperationSentinel: Error, Equatable {
    case failed
}

private enum HealthProbeFailure: Error {
    case failed
    case stalled
}

private final class FakeMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: TimeInterval = 0

    var value: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func advance(by duration: TimeInterval) {
        lock.lock()
        storedValue += duration
        lock.unlock()
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

private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately: Bool
            lock.lock()
            if isOpen {
                resumeImmediately = true
            } else {
                continuations.append(continuation)
                resumeImmediately = false
            }
            lock.unlock()
            if resumeImmediately { continuation.resume() }
        }
    }

    func open() {
        let pending: [CheckedContinuation<Void, Never>]
        lock.lock()
        guard !isOpen else {
            lock.unlock()
            return
        }
        isOpen = true
        pending = continuations
        continuations.removeAll()
        lock.unlock()
        for continuation in pending { continuation.resume() }
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
    private let terminateRequested = DispatchSemaphore(value: 0)
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
        terminateRequested.signal()
        handler?()
    }

    func forceTerminate() {
        let handler: (() -> Void)?
        lock.lock()
        running = false
        handler = terminationHandler
        lock.unlock()
        handler?()
    }

    func waitForTerminateRequest() throws {
        guard terminateRequested.wait(timeout: .now() + 2) == .success else {
            throw TestFailure("process terminate was not requested")
        }
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

private final class DelayedExitProcess: LocalAIServerProcess, @unchecked Sendable {
    private let lock = NSLock()
    private let terminateRequested = DispatchSemaphore(value: 0)
    private var running = true
    private var terminationHandler: (() -> Void)?
    private var storedTerminateCallCount = 0
    private var storedForceTerminateCallCount = 0

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

    var forceTerminateCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedForceTerminateCallCount
    }

    func terminate() {
        lock.lock()
        storedTerminateCallCount += 1
        lock.unlock()
        terminateRequested.signal()
    }

    func forceTerminate() {
        let handler: (() -> Void)?
        lock.lock()
        storedForceTerminateCallCount += 1
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

    func waitForTerminateRequest() throws {
        guard terminateRequested.wait(timeout: .now() + 2) == .success else {
            throw TestFailure("delayed process terminate was not requested")
        }
    }

    func completeTermination() {
        let handler: (() -> Void)?
        lock.lock()
        running = false
        handler = terminationHandler
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
