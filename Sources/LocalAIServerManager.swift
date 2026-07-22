import Foundation

enum LocalAIServerManagerError: LocalizedError, Equatable {
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .startFailed:
            return "Could not start the local AI runtime."
        }
    }
}

/// Owns the lifecycle of exactly one resident `llama-server` process. The
/// manager lazily starts the configured model, coalesces callers onto one
/// in-progress startup, switches models without overlapping processes, and
/// releases the process after an idle period.
actor LocalAIServerManager {
    typealias LaunchProcess = @Sendable (
        _ model: LocalAIModel,
        _ modelURL: URL,
        _ port: UInt16,
        _ contextSize: Int
    ) throws -> (LocalAIServerProcess, UInt16)
    typealias PollHealth = @Sendable (_ port: UInt16) async -> Bool
    typealias ObserveLifecycle = @Sendable (_ snapshot: LifecycleSnapshot) -> Void

    struct LifecycleSnapshot: Equatable, Sendable {
        enum Phase: Equatable, Sendable {
            case idle
            case starting
            case running
            case stopping
        }

        let phase: Phase
        let modelID: String?
        let startupWaiterCount: Int
    }

    private struct LaunchState {
        let token: UUID
        let modelID: String
        let process: LocalAIServerProcess
        let port: UInt16
        let exitSignal: ProcessExitSignal
    }

    private struct StartupState {
        let launch: LaunchState
        let healthTask: Task<Bool, Never>
        var waiterIDs: Set<UUID>
    }

    private struct StartupJoin {
        let launchToken: UUID
        let modelID: String
        let healthTask: Task<Bool, Never>
    }

    private struct StoppingState {
        let launch: LaunchState
        let healthTask: Task<Bool, Never>?
    }

    private enum LifecycleState {
        case idle
        case starting(StartupState)
        case running(LaunchState)
        case stopping(StoppingState)
    }

    private let store: LocalAIModelStore
    private let idleTimeout: TimeInterval
    private let contextSize: Int
    private let launchProcess: LaunchProcess
    private let pollHealth: PollHealth
    private let now: @Sendable () -> Date
    private let observeLifecycle: ObserveLifecycle

    private var state: LifecycleState = .idle
    private var lastRequestAt: Date?

    init(
        store: LocalAIModelStore = LocalAIModelStore(),
        idleTimeout: TimeInterval = 300,
        contextSize: Int = 8192,
        launchProcess: @escaping LaunchProcess = { model, modelURL, port, contextSize in
            try LocalAIServerManager.defaultLaunchProcess(
                model: model,
                modelURL: modelURL,
                port: port,
                contextSize: contextSize
            )
        },
        pollHealth: @escaping PollHealth = { port in
            await LocalAIServerManager.defaultPollHealth(port: port)
        },
        now: @escaping @Sendable () -> Date = { Date() },
        observeLifecycle: @escaping ObserveLifecycle = { _ in }
    ) {
        self.store = store
        self.idleTimeout = idleTimeout
        self.contextSize = contextSize
        self.launchProcess = launchProcess
        self.pollHealth = pollHealth
        self.now = now
        self.observeLifecycle = observeLifecycle
    }

    deinit {
        switch state {
        case .idle:
            break
        case let .starting(startup):
            startup.healthTask.cancel()
            startup.launch.process.terminate()
        case let .running(launch):
            launch.process.terminate()
        case let .stopping(stopping):
            stopping.healthTask?.cancel()
            stopping.launch.process.terminate()
        }
    }

    /// Returns an OpenAI-compatible base URL, starting or switching the local
    /// process as needed. Concurrent requests for the same model share the
    /// same startup task while retaining independent cancellation.
    func baseURL(for model: LocalAIModel) async throws -> URL {
        let waiter = StartupWaiter()
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let url = try await serveBaseURL(for: model, waiter: waiter)
                try Task.checkCancellation()
                return url
            } catch {
                if Task.isCancelled || error is CancellationError {
                    await cancelStartupWaiter(
                        waiterID: waiter.id,
                        launchToken: waiter.launchToken
                    )
                    throw CancellationError()
                }
                throw error
            }
        } onCancel: {
            waiter.cancel()
            Task { [weak self] in
                await self?.cancelStartupWaiter(
                    waiterID: waiter.id,
                    launchToken: waiter.launchToken
                )
            }
        }
    }

    /// Releases an idle resident process. In-progress requests are never
    /// evaluated against the prior running launch's request timestamp.
    func shutdownIfIdle() async {
        guard case let .running(launch) = state else { return }
        guard launch.process.isRunning else {
            lastRequestAt = nil
            setState(.idle)
            return
        }
        guard let lastRequestAt else { return }
        guard now().timeIntervalSince(lastRequestAt) >= idleTimeout else { return }
        await stopRunning(launch)
    }

    /// Stops both a published process and any actor-reentrant startup. This
    /// waits for startup polling and process termination cleanup before return.
    func stop() async {
        lastRequestAt = nil
        while true {
            switch state {
            case .idle:
                return
            case let .starting(startup):
                await stopStartup(startup)
            case let .running(launch):
                await stopRunning(launch)
            case let .stopping(stopping):
                await finishStopping(stopping)
            }
        }
    }

    /// Internal deterministic observation seam for lifecycle race tests.
    func lifecycleSnapshot() -> LifecycleSnapshot {
        snapshot(for: state)
    }

    private func serveBaseURL(for model: LocalAIModel, waiter: StartupWaiter) async throws -> URL {
        try Task.checkCancellation()

        while true {
            switch state {
            case .idle:
                let startup = try beginStartup(for: model, waiterID: waiter.id)
                let join = makeJoin(startup)
                waiter.register(launchToken: join.launchToken)
                do {
                    try Task.checkCancellation()
                } catch {
                    await cancelStartupWaiter(waiterID: waiter.id, launchToken: join.launchToken)
                    throw CancellationError()
                }
                return try await waitForStartup(join, waiter: waiter)

            case var .starting(startup):
                if startup.launch.modelID == model.id {
                    startup.waiterIDs.insert(waiter.id)
                    setState(.starting(startup))
                    let join = makeJoin(startup)
                    waiter.register(launchToken: join.launchToken)
                    do {
                        try Task.checkCancellation()
                    } catch {
                        await cancelStartupWaiter(waiterID: waiter.id, launchToken: join.launchToken)
                        throw CancellationError()
                    }
                    return try await waitForStartup(join, waiter: waiter)
                }
                lastRequestAt = nil
                await stopStartup(startup)
                try Task.checkCancellation()

            case let .running(launch):
                guard launch.process.isRunning else {
                    lastRequestAt = nil
                    setState(.idle)
                    continue
                }
                if launch.modelID == model.id {
                    try Task.checkCancellation()
                    lastRequestAt = now()
                    return Self.baseURL(port: launch.port)
                }
                lastRequestAt = nil
                await stopRunning(launch)
                try Task.checkCancellation()

            case let .stopping(stopping):
                lastRequestAt = nil
                await finishStopping(stopping)
                try Task.checkCancellation()
            }
        }
    }

    private func beginStartup(for model: LocalAIModel, waiterID: UUID) throws -> StartupState {
        lastRequestAt = nil
        let modelURL = store.modelURL(for: model)
        let reservedPort = try reserveEphemeralLoopbackPort()
        let (process, launchedPort) = try launchProcess(model, modelURL, reservedPort, contextSize)
        let exitSignal = ProcessExitSignal()
        process.setTerminationHandler {
            exitSignal.signal()
        }

        let pollHealth = self.pollHealth
        let healthTask = Task {
            let isHealthy = await pollHealth(launchedPort)
            return isHealthy && !Task.isCancelled
        }
        let launch = LaunchState(
            token: UUID(),
            modelID: model.id,
            process: process,
            port: launchedPort,
            exitSignal: exitSignal
        )
        let startup = StartupState(
            launch: launch,
            healthTask: healthTask,
            waiterIDs: [waiterID]
        )
        setState(.starting(startup))
        return startup
    }

    private func makeJoin(_ startup: StartupState) -> StartupJoin {
        StartupJoin(
            launchToken: startup.launch.token,
            modelID: startup.launch.modelID,
            healthTask: startup.healthTask
        )
    }

    private func waitForStartup(_ join: StartupJoin, waiter: StartupWaiter) async throws -> URL {
        switch await waiter.wait(for: join.healthTask) {
        case .cancelled:
            await cancelStartupWaiter(waiterID: waiter.id, launchToken: join.launchToken)
            throw CancellationError()

        case let .health(isHealthy):
            do {
                try Task.checkCancellation()
            } catch {
                await cancelStartupWaiter(waiterID: waiter.id, launchToken: join.launchToken)
                throw CancellationError()
            }
            let url = try await finishStartup(
                launchToken: join.launchToken,
                modelID: join.modelID,
                waiterID: waiter.id,
                isHealthy: isHealthy
            )
            do {
                try Task.checkCancellation()
                return url
            } catch {
                await cancelStartupWaiter(waiterID: waiter.id, launchToken: join.launchToken)
                throw CancellationError()
            }
        }
    }

    private func finishStartup(
        launchToken: UUID,
        modelID: String,
        waiterID: UUID,
        isHealthy: Bool
    ) async throws -> URL {
        switch state {
        case let .running(current) where current.token == launchToken:
            guard current.process.isRunning else {
                lastRequestAt = nil
                setState(.idle)
                throw startFailed(for: modelID, reason: "Process exited after startup")
            }
            try Task.checkCancellation()
            lastRequestAt = now()
            return Self.baseURL(port: current.port)

        case let .starting(current) where current.launch.token == launchToken:
            guard current.waiterIDs.contains(waiterID) else {
                throw CancellationError()
            }
            guard isHealthy, current.launch.process.isRunning else {
                await stopStartup(current)
                throw startFailed(for: current.launch.modelID, reason: "Health check did not succeed")
            }
            try Task.checkCancellation()
            setState(.running(current.launch))
            lastRequestAt = now()
            return Self.baseURL(port: current.launch.port)

        case let .stopping(stopping) where stopping.launch.token == launchToken:
            await finishStopping(stopping)
            if Task.isCancelled { throw CancellationError() }
            throw startFailed(for: modelID, reason: "Startup was cancelled")

        default:
            if Task.isCancelled { throw CancellationError() }
            throw startFailed(for: modelID, reason: "Startup was superseded")
        }
    }

    private func cancelStartupWaiter(waiterID: UUID, launchToken: UUID?) async {
        switch state {
        case var .starting(startup):
            if let launchToken, startup.launch.token != launchToken { return }
            guard startup.waiterIDs.remove(waiterID) != nil else { return }
            setState(.starting(startup))
            if startup.waiterIDs.isEmpty {
                await stopStartup(startup)
            }

        case let .stopping(stopping):
            guard launchToken == stopping.launch.token else { return }
            await finishStopping(stopping)

        case .idle, .running:
            return
        }
    }

    private func stopStartup(_ startup: StartupState) async {
        lastRequestAt = nil
        let stopping: StoppingState
        switch state {
        case let .starting(current) where current.launch.token == startup.launch.token:
            stopping = StoppingState(launch: current.launch, healthTask: current.healthTask)
            setState(.stopping(stopping))
            current.healthTask.cancel()
            if current.launch.process.isRunning {
                current.launch.process.terminate()
            }
        case let .stopping(current) where current.launch.token == startup.launch.token:
            stopping = current
        default:
            return
        }
        await finishStopping(stopping)
    }

    private func stopRunning(_ launch: LaunchState) async {
        lastRequestAt = nil
        let stopping: StoppingState
        switch state {
        case let .running(current) where current.token == launch.token:
            stopping = StoppingState(launch: current, healthTask: nil)
            setState(.stopping(stopping))
            if current.process.isRunning {
                current.process.terminate()
            }
        case let .stopping(current) where current.launch.token == launch.token:
            stopping = current
        default:
            return
        }
        await finishStopping(stopping)
    }

    private func finishStopping(_ stopping: StoppingState) async {
        if let healthTask = stopping.healthTask {
            _ = await healthTask.value
        }
        if stopping.launch.process.isRunning {
            await stopping.launch.exitSignal.wait()
        }
        if case let .stopping(current) = state,
           current.launch.token == stopping.launch.token {
            setState(.idle)
        }
    }

    private func setState(_ newState: LifecycleState) {
        state = newState
        observeLifecycle(snapshot(for: newState))
    }

    private func snapshot(for state: LifecycleState) -> LifecycleSnapshot {
        switch state {
        case .idle:
            return LifecycleSnapshot(phase: .idle, modelID: nil, startupWaiterCount: 0)
        case let .starting(startup):
            return LifecycleSnapshot(
                phase: .starting,
                modelID: startup.launch.modelID,
                startupWaiterCount: startup.waiterIDs.count
            )
        case let .running(launch):
            return LifecycleSnapshot(phase: .running, modelID: launch.modelID, startupWaiterCount: 0)
        case let .stopping(stopping):
            return LifecycleSnapshot(phase: .stopping, modelID: stopping.launch.modelID, startupWaiterCount: 0)
        }
    }

    private func startFailed(for modelID: String, reason: String) -> LocalAIServerManagerError {
        .startFailed("\(reason) for model \(modelID)")
    }

    private static func baseURL(port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)/v1")!
    }

    private static func defaultLaunchProcess(
        model _: LocalAIModel,
        modelURL: URL,
        port: UInt16,
        contextSize: Int
    ) throws -> (LocalAIServerProcess, UInt16) {
        guard let runnerURL = RealLocalAIServerProcess.defaultRunnerURL() else {
            throw LocalAIServerProcessError.runnerNotFound("llama-server not found in app bundle")
        }
        let process = try RealLocalAIServerProcess(
            runnerURL: runnerURL,
            modelURL: modelURL,
            port: port,
            contextSize: contextSize
        )
        return (process, port)
    }

    private static func defaultPollHealth(port: UInt16) async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        for _ in 0..<50 {
            if Task.isCancelled { return false }
            if let (_, response) = try? await LLMAPITransport.data(for: URLRequest(url: url)),
               let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200 {
                return true
            }
            if Task.isCancelled { return false }
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return false
            }
        }
        return false
    }
}

private final class StartupWaiter: @unchecked Sendable {
    enum Outcome: Sendable {
        case health(Bool)
        case cancelled
    }

    let id = UUID()

    private let lock = NSLock()
    private var storedLaunchToken: UUID?
    private var outcome: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var observationTask: Task<Void, Never>?

    var launchToken: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return storedLaunchToken
    }

    func register(launchToken: UUID) {
        lock.lock()
        storedLaunchToken = launchToken
        lock.unlock()
    }

    func wait(for healthTask: Task<Bool, Never>) async -> Outcome {
        startObserving(healthTask)
        return await withCheckedContinuation { continuation in
            let immediateOutcome: Outcome?
            lock.lock()
            if let outcome {
                immediateOutcome = outcome
            } else {
                self.continuation = continuation
                immediateOutcome = nil
            }
            lock.unlock()
            if let immediateOutcome {
                continuation.resume(returning: immediateOutcome)
            }
        }
    }

    func cancel() {
        resolve(.cancelled)
    }

    private func startObserving(_ healthTask: Task<Bool, Never>) {
        lock.lock()
        guard outcome == nil, observationTask == nil else {
            lock.unlock()
            return
        }
        observationTask = Task { [weak self] in
            let isHealthy = await healthTask.value
            self?.resolve(.health(isHealthy))
        }
        lock.unlock()
    }

    private func resolve(_ newOutcome: Outcome) {
        let continuationToResume: CheckedContinuation<Outcome, Never>?
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = newOutcome
        continuationToResume = continuation
        continuation = nil
        lock.unlock()
        continuationToResume?.resume(returning: newOutcome)
    }
}

private final class ProcessExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var hasExited = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let continuationsToResume: [CheckedContinuation<Void, Never>]
        lock.lock()
        guard !hasExited else {
            lock.unlock()
            return
        }
        hasExited = true
        continuationsToResume = continuations
        continuations.removeAll()
        lock.unlock()
        for continuation in continuationsToResume {
            continuation.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResumeImmediately: Bool
            lock.lock()
            if hasExited {
                shouldResumeImmediately = true
            } else {
                continuations.append(continuation)
                shouldResumeImmediately = false
            }
            lock.unlock()
            if shouldResumeImmediately {
                continuation.resume()
            }
        }
    }
}
