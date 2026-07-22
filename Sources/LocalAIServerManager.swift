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
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.idleTimeout = idleTimeout
        self.contextSize = contextSize
        self.launchProcess = launchProcess
        self.pollHealth = pollHealth
        self.now = now
    }

    /// Returns an OpenAI-compatible base URL, starting or switching the local
    /// process as needed. Concurrent requests for the same model share the
    /// same startup task.
    func baseURL(for model: LocalAIModel) async throws -> URL {
        while true {
            switch state {
            case .idle:
                let startup = try beginStartup(for: model)
                return try await finishStartup(startup)

            case let .starting(startup):
                if startup.launch.modelID == model.id {
                    return try await finishStartup(startup)
                }
                await stopStartup(startup)

            case let .running(launch):
                guard launch.process.isRunning else {
                    state = .idle
                    continue
                }
                if launch.modelID == model.id {
                    lastRequestAt = now()
                    return Self.baseURL(port: launch.port)
                }
                await stopRunning(launch)

            case let .stopping(stopping):
                await finishStopping(stopping)
            }
        }
    }

    /// Releases the resident process after the configured period with no
    /// successfully served or reused endpoint.
    func shutdownIfIdle() async {
        guard let lastRequestAt else { return }
        guard now().timeIntervalSince(lastRequestAt) >= idleTimeout else { return }
        await stop()
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

    private func beginStartup(for model: LocalAIModel) throws -> StartupState {
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
        let startup = StartupState(launch: launch, healthTask: healthTask)
        state = .starting(startup)
        return startup
    }

    private func finishStartup(_ startup: StartupState) async throws -> URL {
        let isHealthy = await startup.healthTask.value

        switch state {
        case let .running(current) where current.token == startup.launch.token:
            guard current.process.isRunning else {
                state = .idle
                throw startFailed(for: startup.launch.modelID, reason: "Process exited after startup")
            }
            lastRequestAt = now()
            return Self.baseURL(port: current.port)

        case let .starting(current) where current.launch.token == startup.launch.token:
            guard isHealthy, current.launch.process.isRunning else {
                await stopStartup(current)
                throw startFailed(for: current.launch.modelID, reason: "Health check did not succeed")
            }
            state = .running(current.launch)
            lastRequestAt = now()
            return Self.baseURL(port: current.launch.port)

        case let .stopping(stopping) where stopping.launch.token == startup.launch.token:
            await finishStopping(stopping)
            throw startFailed(for: startup.launch.modelID, reason: "Startup was cancelled")

        default:
            throw startFailed(for: startup.launch.modelID, reason: "Startup was superseded")
        }
    }

    private func stopStartup(_ startup: StartupState) async {
        let stopping: StoppingState
        switch state {
        case let .starting(current) where current.launch.token == startup.launch.token:
            stopping = StoppingState(launch: current.launch, healthTask: current.healthTask)
            state = .stopping(stopping)
            current.healthTask.cancel()
            current.launch.process.terminate()
        case let .stopping(current) where current.launch.token == startup.launch.token:
            stopping = current
        default:
            return
        }
        await finishStopping(stopping)
    }

    private func stopRunning(_ launch: LaunchState) async {
        let stopping: StoppingState
        switch state {
        case let .running(current) where current.token == launch.token:
            stopping = StoppingState(launch: current, healthTask: nil)
            state = .stopping(stopping)
            current.process.terminate()
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
            state = .idle
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
