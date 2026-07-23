import Foundation

enum LocalAIServerManagerError: LocalizedError, Equatable {
    case modelUnavailable(String)
    case modelCorrupt(String)
    case startFailed(String)
    case processExited(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "The selected local AI model is unavailable or incomplete."
        case .modelCorrupt:
            return "The selected local AI model is corrupt."
        case .startFailed:
            return "Could not start the local AI runtime."
        case .processExited:
            return localizedCatalogString("The local AI runtime stopped unexpectedly.")
        }
    }
}

struct LocalAIHealthPoller: Sendable {
    typealias Probe = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias MonotonicNow = @Sendable () -> TimeInterval
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    let overallTimeout: TimeInterval
    let probeTimeout: TimeInterval
    let cadence: TimeInterval
    let maxAttempts: Int
    let probe: Probe
    let now: MonotonicNow
    let sleep: Sleep

    static let `default` = LocalAIHealthPoller(
        overallTimeout: 10,
        probeTimeout: 1,
        cadence: 0.2,
        maxAttempts: 50,
        probe: { request in
            try await LLMAPITransport.data(for: request)
        },
        now: { ProcessInfo.processInfo.systemUptime },
        sleep: { duration in
            let nanoseconds = UInt64(max(0, duration) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    )

    func poll(port: UInt16) async -> Bool {
        guard overallTimeout > 0, probeTimeout > 0, maxAttempts > 0 else { return false }
        let deadline = now() + overallTimeout
        let url = URL(string: "http://127.0.0.1:\(port)/health")!

        for attempt in 0..<maxAttempts {
            if Task.isCancelled { return false }
            let remaining = deadline - now()
            guard remaining > 0 else { return false }

            var request = URLRequest(url: url)
            request.timeoutInterval = min(probeTimeout, remaining)
            do {
                let (_, response) = try await probe(request)
                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode == 200 {
                    return true
                }
            } catch is CancellationError {
                return false
            } catch {
                if Task.isCancelled { return false }
            }

            guard attempt + 1 < maxAttempts else { return false }
            let sleepDuration = min(cadence, deadline - now())
            guard sleepDuration > 0 else { return false }
            do {
                try await sleep(sleepDuration)
            } catch {
                return false
            }
        }
        return false
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
    typealias ValidateModel = @Sendable (_ model: LocalAIModel) throws -> LocalAIInstallStatus
    typealias WaitForProcessExit = @Sendable (_ process: LocalAIServerProcess, _ timeout: TimeInterval) async -> Bool
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
        let activeRequestCount: Int
        let isWaitingForActiveRequests: Bool
        let isMaintenanceActive: Bool
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

    private struct ResolvedBaseURL {
        let launchToken: UUID
        let modelID: String
        let process: LocalAIServerProcess
        let url: URL
    }

    private struct RequestLease {
        let launchToken: UUID
        let modelID: String
        let process: LocalAIServerProcess
        let url: URL
    }

    private struct SwitchDrainState {
        let launchToken: UUID
        var switchWaiterIDs: Set<UUID>
        var transitionWaiters: [UUID: ActiveRequestWaiter]
        var isClaimed: Bool
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
    private let validateModel: ValidateModel
    private let terminationGracePeriod: TimeInterval
    private let waitForProcessExit: WaitForProcessExit
    private let now: @Sendable () -> Date
    private let observeLifecycle: ObserveLifecycle

    private var state: LifecycleState = .idle
    private var isMaintenanceActive = false
    private var lastRequestAt: Date?
    private var activeRequestCounts: [UUID: Int] = [:]
    private var activeDrainWaiters: [UUID: [UUID: ActiveRequestWaiter]] = [:]
    private var switchDrain: SwitchDrainState?

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
        validateModel: ValidateModel? = nil,
        terminationGracePeriod: TimeInterval = 2,
        waitForProcessExit: @escaping WaitForProcessExit = { process, timeout in
            await LocalAIServerManager.defaultWaitForProcessExit(process: process, timeout: timeout)
        },
        now: @escaping @Sendable () -> Date = { Date() },
        observeLifecycle: @escaping ObserveLifecycle = { _ in }
    ) {
        self.store = store
        self.idleTimeout = idleTimeout
        self.contextSize = contextSize
        self.launchProcess = launchProcess
        self.pollHealth = pollHealth
        self.validateModel = validateModel ?? { model in
            try store.recoverInterruptedReplacement(for: model)
            return store.installStatus(for: model)
        }
        self.terminationGracePeriod = terminationGracePeriod
        self.waitForProcessExit = waitForProcessExit
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

    /// Runs an operation against an OpenAI-compatible base URL while keeping
    /// the selected process alive for the full operation lifetime.
    func withBaseURL<Result>(
        for model: LocalAIModel,
        operation: @escaping @Sendable (URL) async throws -> Result
    ) async throws -> Result {
        try ensureMaintenanceIsInactive()
        let lease = try await acquireLease(for: model)
        do {
            let result = try await operation(lease.url)
            releaseLease(lease)
            return result
        } catch {
            let processExited = !lease.process.isRunning
            releaseLease(lease)
            if processExited {
                clearExitedLaunchIfCurrent(lease)
                throw LocalAIServerManagerError.processExited(
                    "Process exited during an active request for model \(lease.modelID)"
                )
            }
            throw error
        }
    }

    private func acquireLease(for model: LocalAIModel) async throws -> RequestLease {
        let waiter = StartupWaiter()
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let resolved = try await resolveBaseURL(for: model, waiter: waiter)
                try Task.checkCancellation()
                try ensureMaintenanceIsInactive()
                activeRequestCounts[resolved.launchToken, default: 0] += 1
                lastRequestAt = now()
                return RequestLease(
                    launchToken: resolved.launchToken,
                    modelID: resolved.modelID,
                    process: resolved.process,
                    url: resolved.url
                )
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

    private func releaseLease(_ lease: RequestLease) {
        guard let currentCount = activeRequestCounts[lease.launchToken], currentCount > 0 else { return }
        if currentCount == 1 {
            activeRequestCounts.removeValue(forKey: lease.launchToken)
            let waiters = activeDrainWaiters.removeValue(forKey: lease.launchToken).map { Array($0.values) } ?? []
            for waiter in waiters {
                waiter.resolve(.ready)
            }
        } else {
            activeRequestCounts[lease.launchToken] = currentCount - 1
        }
        lastRequestAt = now()
    }

    private func clearExitedLaunchIfCurrent(_ lease: RequestLease) {
        switch state {
        case let .running(launch) where launch.token == lease.launchToken:
            lastRequestAt = nil
            clearSwitchDrain(launchToken: launch.token)
            setState(.idle)
        case let .starting(startup) where startup.launch.token == lease.launchToken:
            startup.healthTask.cancel()
            lastRequestAt = nil
            setState(.idle)
        case .idle, .starting, .running, .stopping:
            break
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
        guard activeRequestCounts[launch.token, default: 0] == 0 else { return }
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

    /// Stops the runtime and runs a synchronous model-maintenance operation
    /// while preventing new inference startups. Existing active operations are
    /// allowed to drain before the resident process is stopped.
    func withExclusiveMaintenance<Result: Sendable>(
        _ operation: @Sendable () throws -> Result
    ) async throws -> Result {
        try ensureMaintenanceIsInactive()
        isMaintenanceActive = true
        defer { isMaintenanceActive = false }

        await stopForMaintenance()
        return try operation()
    }

    /// Internal deterministic observation seam for lifecycle race tests.
    func lifecycleSnapshot() -> LifecycleSnapshot {
        snapshot(for: state)
    }

    private func ensureMaintenanceIsInactive() throws {
        guard !isMaintenanceActive else {
            throw LocalAIServerManagerError.modelUnavailable(
                "Local AI maintenance is in progress."
            )
        }
    }

    private func stopForMaintenance() async {
        lastRequestAt = nil
        while true {
            switch state {
            case .idle:
                return
            case let .starting(startup):
                await stopStartup(startup)
            case let .running(launch):
                await waitForMaintenanceActiveRequestsToDrain(
                    launchToken: launch.token
                )
                guard case let .running(current) = state,
                      current.token == launch.token else {
                    continue
                }
                await stopRunning(current)
            case let .stopping(stopping):
                await finishStopping(stopping)
            }
        }
    }

    private func waitForMaintenanceActiveRequestsToDrain(
        launchToken: UUID
    ) async {
        guard activeRequestCounts[launchToken, default: 0] > 0 else { return }
        let waiter = ActiveRequestWaiter()
        activeDrainWaiters[launchToken, default: [:]][waiter.id] = waiter
        _ = await waiter.wait()
        activeDrainWaiters[launchToken]?.removeValue(forKey: waiter.id)
        if activeDrainWaiters[launchToken]?.isEmpty == true {
            activeDrainWaiters.removeValue(forKey: launchToken)
        }
    }

    private func resolveBaseURL(for model: LocalAIModel, waiter: StartupWaiter) async throws -> ResolvedBaseURL {
        try Task.checkCancellation()

        while true {
            try ensureMaintenanceIsInactive()
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
                    if switchDrain?.launchToken == launch.token {
                        try await waitForSwitchTransition(launchToken: launch.token)
                        try Task.checkCancellation()
                        continue
                    }
                    try Task.checkCancellation()
                    lastRequestAt = now()
                    return ResolvedBaseURL(
                        launchToken: launch.token,
                        modelID: launch.modelID,
                        process: launch.process,
                        url: Self.baseURL(port: launch.port)
                    )
                }
                if activeRequestCounts[launch.token, default: 0] > 0 {
                    try await waitForActiveRequestsToDrain(launchToken: launch.token)
                    guard case let .running(current) = state, current.token == launch.token else { continue }
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

    private func waitForActiveRequestsToDrain(launchToken: UUID) async throws {
        guard activeRequestCounts[launchToken, default: 0] > 0 else { return }
        let waiter = ActiveRequestWaiter()
        if switchDrain == nil {
            switchDrain = SwitchDrainState(
                launchToken: launchToken,
                switchWaiterIDs: [waiter.id],
                transitionWaiters: [:],
                isClaimed: false
            )
        } else if switchDrain?.launchToken == launchToken {
            switchDrain?.switchWaiterIDs.insert(waiter.id)
        } else {
            throw CancellationError()
        }
        activeDrainWaiters[launchToken, default: [:]][waiter.id] = waiter

        let outcome = await withTaskCancellationHandler {
            await waiter.wait()
        } onCancel: {
            waiter.resolve(.cancelled)
        }

        if outcome == .cancelled || Task.isCancelled {
            cancelActiveDrainWaiter(waiterID: waiter.id, launchToken: launchToken)
            throw CancellationError()
        }

        activeDrainWaiters[launchToken]?.removeValue(forKey: waiter.id)
        if activeDrainWaiters[launchToken]?.isEmpty == true {
            activeDrainWaiters.removeValue(forKey: launchToken)
        }
        if switchDrain?.launchToken == launchToken {
            switchDrain?.switchWaiterIDs.remove(waiter.id)
            switchDrain?.isClaimed = true
        }
    }

    private func waitForSwitchTransition(launchToken: UUID) async throws {
        guard switchDrain?.launchToken == launchToken else { return }
        let waiter = ActiveRequestWaiter()
        switchDrain?.transitionWaiters[waiter.id] = waiter
        let outcome = await withTaskCancellationHandler {
            await waiter.wait()
        } onCancel: {
            waiter.resolve(.cancelled)
        }
        if outcome == .cancelled || Task.isCancelled {
            switchDrain?.transitionWaiters.removeValue(forKey: waiter.id)
            throw CancellationError()
        }
    }

    private func cancelActiveDrainWaiter(waiterID: UUID, launchToken: UUID) {
        activeDrainWaiters[launchToken]?.removeValue(forKey: waiterID)
        if activeDrainWaiters[launchToken]?.isEmpty == true {
            activeDrainWaiters.removeValue(forKey: launchToken)
        }
        guard switchDrain?.launchToken == launchToken else { return }
        switchDrain?.switchWaiterIDs.remove(waiterID)
        if switchDrain?.switchWaiterIDs.isEmpty == true,
           switchDrain?.isClaimed == false {
            clearSwitchDrain(launchToken: launchToken)
        }
    }

    private func clearSwitchDrain(launchToken: UUID) {
        guard let drain = switchDrain, drain.launchToken == launchToken else { return }
        switchDrain = nil
        for waiter in drain.transitionWaiters.values {
            waiter.resolve(.ready)
        }
    }

    private func beginStartup(for model: LocalAIModel, waiterID: UUID) throws -> StartupState {
        lastRequestAt = nil
        let status: LocalAIInstallStatus
        do {
            status = try validateModel(model)
        } catch {
            throw LocalAIServerManagerError.modelCorrupt(
                "Validation failed for model \(model.id): \(error.localizedDescription)"
            )
        }
        switch status {
        case .notInstalled:
            throw LocalAIServerManagerError.modelUnavailable(
                "Model \(model.id) is not installed."
            )
        case let .partial(downloadedBytes, expectedBytes):
            let expectedDetail = expectedBytes.map(String.init) ?? "unknown"
            throw LocalAIServerManagerError.modelUnavailable(
                "Model \(model.id) is incomplete: \(downloadedBytes) of \(expectedDetail) bytes are present."
            )
        case let .corrupt(detail):
            throw LocalAIServerManagerError.modelCorrupt(
                "Model \(model.id) failed validation: \(detail)"
            )
        case .ready:
            break
        }

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

    private func waitForStartup(_ join: StartupJoin, waiter: StartupWaiter) async throws -> ResolvedBaseURL {
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
    ) async throws -> ResolvedBaseURL {
        switch state {
        case let .running(current) where current.token == launchToken:
            guard current.process.isRunning else {
                lastRequestAt = nil
                setState(.idle)
                throw startFailed(for: modelID, reason: "Process exited after startup")
            }
            try Task.checkCancellation()
            lastRequestAt = now()
            return ResolvedBaseURL(
                launchToken: current.token,
                modelID: current.modelID,
                process: current.process,
                url: Self.baseURL(port: current.port)
            )

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
            return ResolvedBaseURL(
                launchToken: current.launch.token,
                modelID: current.launch.modelID,
                process: current.launch.process,
                url: Self.baseURL(port: current.launch.port)
            )

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
            clearSwitchDrain(launchToken: current.token)
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
            let exitedGracefully = await waitForProcessExit(
                stopping.launch.process,
                terminationGracePeriod
            )
            if !exitedGracefully, stopping.launch.process.isRunning {
                stopping.launch.process.forceTerminate()
                _ = await waitForProcessExit(
                    stopping.launch.process,
                    terminationGracePeriod
                )
            }
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
            return LifecycleSnapshot(
                phase: .idle,
                modelID: nil,
                startupWaiterCount: 0,
                activeRequestCount: 0,
                isWaitingForActiveRequests: false,
                isMaintenanceActive: isMaintenanceActive
            )
        case let .starting(startup):
            return LifecycleSnapshot(
                phase: .starting,
                modelID: startup.launch.modelID,
                startupWaiterCount: startup.waiterIDs.count,
                activeRequestCount: activeRequestCounts[startup.launch.token, default: 0],
                isWaitingForActiveRequests: switchDrain?.launchToken == startup.launch.token,
                isMaintenanceActive: isMaintenanceActive
            )
        case let .running(launch):
            return LifecycleSnapshot(
                phase: .running,
                modelID: launch.modelID,
                startupWaiterCount: 0,
                activeRequestCount: activeRequestCounts[launch.token, default: 0],
                isWaitingForActiveRequests: switchDrain?.launchToken == launch.token,
                isMaintenanceActive: isMaintenanceActive
            )
        case let .stopping(stopping):
            return LifecycleSnapshot(
                phase: .stopping,
                modelID: stopping.launch.modelID,
                startupWaiterCount: 0,
                activeRequestCount: activeRequestCounts[stopping.launch.token, default: 0],
                isWaitingForActiveRequests: false,
                isMaintenanceActive: isMaintenanceActive
            )
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

    private static func defaultWaitForProcessExit(
        process: LocalAIServerProcess,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while process.isRunning {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            let interval = min(remaining, 0.05)
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return !process.isRunning
            }
        }
        return true
    }

    private static func defaultPollHealth(port: UInt16) async -> Bool {
        await LocalAIHealthPoller.default.poll(port: port)
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

private final class ActiveRequestWaiter: @unchecked Sendable {
    enum Outcome: Equatable {
        case ready
        case cancelled
    }

    let id = UUID()

    private let lock = NSLock()
    private var outcome: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?

    func wait() async -> Outcome {
        await withCheckedContinuation { continuation in
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

    func resolve(_ newOutcome: Outcome) {
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
