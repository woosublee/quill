import Foundation
import QuillUserIssueCore

struct LocalAIModelWorkflowState: Equatable, Sendable {
    var installStates: [String: LocalAIModelInstallViewState] = [:]
    var hasCompletedInitialStatusRefresh = false
}

enum LocalAIModelWorkflowInstallOutcome: Equatable, Sendable {
    case readyAndAvailable
    case succeededButUnavailable(QuillUserIssueRecord)
    case cancelled
    case failed(QuillUserIssueRecord)
}

enum LocalAIModelWorkflowEvent {
    case stateChanged(LocalAIModelWorkflowState)
    case installOutcome(LocalAIModel, LocalAIModelWorkflowInstallOutcome)
    case deletionOutcome(LocalAIModel, errorDescription: String?)
    case initialStatusRefreshCompleted(deferredModelIDs: Set<String>)
}

private struct LocalAIModelDeletionOutcome: Sendable {
    let status: LocalAIInstallStatus
    let errorDescription: String?
}

@MainActor
final class LocalAIModelWorkflow: @unchecked Sendable {
    private let dependencies: AppStateLocalAIDependencies
    private let serverManager: LocalAIServerManager

    // AppState.init is nonisolated, so production assigns this callback during
    // construction before workflow activity. Callback delivery remains
    // MainActor-isolated.
    nonisolated(unsafe) var onEvent:
        (@MainActor (LocalAIModelWorkflowEvent) -> Void)?
    var onStatusRefreshDeliveryForTesting:
        (@MainActor (_ model: LocalAIModel, _ generation: Int) -> Void)?
    private(set) var state = LocalAIModelWorkflowState()

    private var installTasks: [String: LocalAIInstallTask] = [:]
    private var progressCoalescers: [String: LatestValueProgressCoalescer<LocalAIDownloadProgress>] = [:]
    private var installTokens: [String: UUID] = [:]
    private var cancellingModelIDs: Set<String> = []
    private var restartAfterCancellationModelIDs: Set<String> = []
    private var deferredInstallModelIDs: Set<String> = []
    private var deletionRequestedModelIDs: Set<String> = []
    private var statusRefreshGenerations: [String: Int] = [:]
    private var statusRefreshPendingModelIDs: Set<String> = []
    private var statusRefreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var installQuiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var idleShutdownTask: Task<Void, Never>?
    private var isTerminationCleanupPending = false

    nonisolated init(
        dependencies: AppStateLocalAIDependencies,
        serverManager: LocalAIServerManager
    ) {
        self.dependencies = dependencies
        self.serverManager = serverManager
    }

    deinit {
        idleShutdownTask?.cancel()
    }

    var hasActiveInstalls: Bool { !installTasks.isEmpty }

    // MARK: - Idle shutdown monitoring

    func startIdleShutdownMonitoring() {
        guard idleShutdownTask == nil else { return }
        let manager = serverManager
        let sleep = dependencies.idleShutdownSleep
        idleShutdownTask = Task {
            while !Task.isCancelled {
                do {
                    try await sleep(30_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await manager.shutdownIfIdle()
            }
        }
    }

    func stopIdleShutdownMonitoring() {
        idleShutdownTask?.cancel()
        idleShutdownTask = nil
    }

    func beginTerminationCleanup() {
        isTerminationCleanupPending = true
    }

    // MARK: - Queries

    func installState(for model: LocalAIModel) -> LocalAIModelInstallViewState {
        state.installStates[model.id] ?? .initial(model: model, status: .notInstalled)
    }

    func isModelAvailable(_ model: LocalAIModel) -> Bool {
        dependencies.processingAvailability().isModelSupported(model)
    }

    func canonicalModel(for model: LocalAIModel) -> LocalAIModel? {
        guard let canonical = LocalAIModelCatalog.model(id: model.id),
              canonical == model else {
            return nil
        }
        return canonical
    }

    func isDeletionRequested(_ modelID: String) -> Bool {
        deletionRequestedModelIDs.contains(modelID)
    }

    @discardableResult
    func markUnavailable(_ model: LocalAIModel) -> QuillUserIssueRecord {
        let issue = unavailableIssue(for: model)
        var modelState = installState(for: model)
        modelState.issue = issue
        state.installStates[model.id] = modelState
        emitStateChanged()
        return issue
    }

    // MARK: - Status refresh

    func refreshAllInstallStates() {
        state.hasCompletedInitialStatusRefresh = false
        statusRefreshPendingModelIDs = Set(LocalAIModelCatalog.all.map(\.id))
        for model in LocalAIModelCatalog.all {
            if state.installStates[model.id] == nil {
                state.installStates[model.id] = .initial(model: model, status: .notInstalled)
            }
            let generation = nextStatusRefreshGeneration(for: model)
            let statusProvider = dependencies.installStatus
            let workflowReference = WeakLocalAIModelWorkflowReference(self)
            Task.detached(priority: .utility) {
                let status = statusProvider(model)
                await MainActor.run {
                    workflowReference.value?.applyStatusRefresh(
                        status,
                        for: model,
                        generation: generation
                    )
                }
            }
        }
        emitStateChanged()
    }

    func waitForInitialStatusRefresh() async {
        guard !state.hasCompletedInitialStatusRefresh else { return }
        await withCheckedContinuation { continuation in
            statusRefreshWaiters.append(continuation)
        }
    }

    private func nextStatusRefreshGeneration(for model: LocalAIModel) -> Int {
        let generation = statusRefreshGenerations[model.id, default: 0] + 1
        statusRefreshGenerations[model.id] = generation
        return generation
    }

    private func applyStatusRefresh(
        _ status: LocalAIInstallStatus,
        for model: LocalAIModel,
        generation: Int
    ) {
        defer { onStatusRefreshDeliveryForTesting?(model, generation) }
        guard statusRefreshGenerations[model.id] == generation,
              installTasks[model.id] == nil,
              !deletionRequestedModelIDs.contains(model.id) else {
            return
        }
        var modelState = installState(for: model)
        modelState.status = status
        state.installStates[model.id] = modelState
        statusRefreshPendingModelIDs.remove(model.id)
        emitStateChanged()
        finishStatusRefreshIfReady()
    }

    private func completeStatusOperation(
        _ status: LocalAIInstallStatus,
        for model: LocalAIModel
    ) {
        _ = nextStatusRefreshGeneration(for: model)
        let completedRefresh = statusRefreshPendingModelIDs.remove(model.id) != nil
        var modelState = installState(for: model)
        modelState.status = status
        state.installStates[model.id] = modelState
        if completedRefresh {
            finishStatusRefreshIfReady()
        }
    }

    private func finishStatusRefreshIfReady() {
        guard statusRefreshPendingModelIDs.isEmpty else { return }
        state.hasCompletedInitialStatusRefresh = true
        let deferredModelIDs = deferredInstallModelIDs
        deferredInstallModelIDs.removeAll()
        emitStateChanged()
        onEvent?(.initialStatusRefreshCompleted(deferredModelIDs: deferredModelIDs))
        let waiters = statusRefreshWaiters
        statusRefreshWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func unavailableIssue(for model: LocalAIModel) -> QuillUserIssueRecord {
        QuillUserIssueRecord(
            code: .localAIModelUnavailable,
            severity: .error,
            context: QuillUserIssueContext(
                modelID: model.id,
                localBackend: "Local AI"
            )
        )
    }

    // MARK: - Install

    func startInstall(_ model: LocalAIModel) {
        guard !isTerminationCleanupPending,
              let canonical = canonicalModel(for: model),
              isModelAvailable(canonical),
              !deletionRequestedModelIDs.contains(model.id) else {
            return
        }
        guard state.hasCompletedInitialStatusRefresh else {
            deferredInstallModelIDs.insert(model.id)
            return
        }
        if installState(for: canonical).status == .ready {
            onEvent?(.installOutcome(canonical, .readyAndAvailable))
            return
        }
        if cancellingModelIDs.contains(model.id) {
            restartAfterCancellationModelIDs.insert(model.id)
            return
        }
        startInstallIfPossible(canonical)
    }

    private func startInstallIfPossible(_ model: LocalAIModel) {
        guard !isTerminationCleanupPending,
              installTasks[model.id] == nil,
              !cancellingModelIDs.contains(model.id),
              !deletionRequestedModelIDs.contains(model.id),
              isModelAvailable(model) else {
            return
        }

        let token = UUID()
        installTokens[model.id] = token
        _ = nextStatusRefreshGeneration(for: model)
        var modelState = installState(for: model)
        modelState.isInstalling = true
        modelState.issue = nil
        modelState.progress = LocalAIDownloadProgress(
            downloadedBytes: 0,
            totalBytes: model.approximateBytes
        )
        state.installStates[model.id] = modelState
        emitStateChanged()

        let progressCoalescer = LatestValueProgressCoalescer<LocalAIDownloadProgress>(
            schedule: dependencies.progressSchedule
        ) { [weak self] progress in
            MainActor.assumeIsolated {
                guard let self,
                      self.installTokens[model.id] == token,
                      !self.cancellingModelIDs.contains(model.id),
                      !self.deletionRequestedModelIDs.contains(model.id) else {
                    return
                }
                var progressState = self.installState(for: model)
                progressState.progress = progress
                self.state.installStates[model.id] = progressState
                self.emitStateChanged()
            }
        }
        progressCoalescers[model.id] = progressCoalescer

        let statusProvider = dependencies.installStatus
        let partialModelDelete = dependencies.deletePartialModel
        let startInstall = dependencies.startInstall
        installTasks[model.id] = startInstall(
            model,
            { progress in progressCoalescer.submit(progress) },
            { [weak self] result in
                guard let workflow = self else { return }
                Task.detached(priority: .utility) {
                    let cleanupErrorDescription: String? = {
                        guard case .failure(.cancelled) = result else { return nil }
                        do {
                            try partialModelDelete(model)
                            return nil
                        } catch {
                            return error.localizedDescription
                        }
                    }()
                    let status = statusProvider(model)
                    await MainActor.run {
                        workflow.finishInstall(
                            model: model,
                            token: token,
                            result: result,
                            status: status,
                            cleanupErrorDescription: cleanupErrorDescription
                        )
                    }
                }
            }
        )
    }

    private func finishInstall(
        model: LocalAIModel,
        token: UUID,
        result: Result<Void, LocalAIInstallerError>,
        status: LocalAIInstallStatus,
        cleanupErrorDescription: String?
    ) {
        guard installTokens[model.id] == token,
              installTasks.removeValue(forKey: model.id) != nil else {
            return
        }
        progressCoalescers.removeValue(forKey: model.id)?.invalidate()
        defer { resumeInstallQuiescenceWaitersIfNeeded() }
        installTokens.removeValue(forKey: model.id)
        let wasCancelling = cancellingModelIDs.remove(model.id) != nil
        let shouldDelete = deletionRequestedModelIDs.contains(model.id)
        let shouldRestart = restartAfterCancellationModelIDs.remove(model.id) != nil

        var modelState = installState(for: model)
        modelState.isInstalling = false
        modelState.status = status

        var outcomeToEmit: LocalAIModelWorkflowInstallOutcome?
        if let cleanupErrorDescription {
            modelState.issue = unavailableIssue(for: model)
            print("Local AI partial cleanup failed: \(cleanupErrorDescription)")
        } else if shouldDelete {
            modelState.issue = nil
        } else if wasCancelling {
            modelState.issue = nil
        } else {
            switch result {
            case .success where status == .ready && isModelAvailable(model):
                modelState.issue = nil
                outcomeToEmit = .readyAndAvailable
            case .success:
                let issue = unavailableIssue(for: model)
                modelState.issue = issue
                outcomeToEmit = .succeededButUnavailable(issue)
            case .failure(.cancelled):
                modelState.issue = nil
                outcomeToEmit = .cancelled
            case .failure(let error):
                let issue = unavailableIssue(for: model)
                modelState.issue = issue
                outcomeToEmit = .failed(issue)
                print("Local AI install failed: \(error.localizedDescription)")
            }
        }
        state.installStates[model.id] = modelState
        emitStateChanged()
        if let outcomeToEmit {
            onEvent?(.installOutcome(model, outcomeToEmit))
        }
        completeStatusOperation(status, for: model)

        if shouldDelete {
            beginDeletion(model)
            return
        }
        guard wasCancelling, shouldRestart else { return }
        guard cleanupErrorDescription == nil, isModelAvailable(model) else {
            let issue = markUnavailable(model)
            onEvent?(.installOutcome(model, .succeededButUnavailable(issue)))
            return
        }
        if status == .ready {
            onEvent?(.installOutcome(model, .readyAndAvailable))
        } else {
            startInstallIfPossible(model)
        }
    }

    func waitForInstallsToQuiesce() async {
        guard !installTasks.isEmpty else { return }
        await withCheckedContinuation { continuation in
            installQuiescenceWaiters.append(continuation)
        }
    }

    private func resumeInstallQuiescenceWaitersIfNeeded() {
        guard installTasks.isEmpty else { return }
        let waiters = installQuiescenceWaiters
        installQuiescenceWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    // MARK: - Cancel

    @discardableResult
    func cancelInstall(_ model: LocalAIModel) -> Bool {
        guard let canonical = canonicalModel(for: model),
              let task = installTasks[canonical.id] else {
            return false
        }
        progressCoalescers.removeValue(forKey: canonical.id)?.invalidate()
        cancellingModelIDs.insert(canonical.id)
        restartAfterCancellationModelIDs.remove(canonical.id)
        task.cancel()
        var modelState = installState(for: canonical)
        modelState.progress = LocalAIDownloadProgress(
            downloadedBytes: modelState.progress.downloadedBytes,
            totalBytes: modelState.progress.totalBytes,
            isCancelled: true
        )
        state.installStates[canonical.id] = modelState
        emitStateChanged()
        return true
    }

    // MARK: - Delete

    @discardableResult
    func deleteModel(_ model: LocalAIModel) -> Bool {
        guard let canonical = canonicalModel(for: model),
              !deletionRequestedModelIDs.contains(canonical.id) else {
            return false
        }
        deletionRequestedModelIDs.insert(canonical.id)
        deferredInstallModelIDs.remove(canonical.id)
        restartAfterCancellationModelIDs.remove(canonical.id)

        if let task = installTasks[canonical.id] {
            cancellingModelIDs.insert(canonical.id)
            task.cancel()
            var modelState = installState(for: canonical)
            modelState.progress = LocalAIDownloadProgress(
                downloadedBytes: modelState.progress.downloadedBytes,
                totalBytes: modelState.progress.totalBytes,
                isCancelled: true
            )
            state.installStates[canonical.id] = modelState
            emitStateChanged()
            return true
        }
        beginDeletion(canonical)
        return true
    }

    private func beginDeletion(_ model: LocalAIModel) {
        guard deletionRequestedModelIDs.contains(model.id),
              installTasks[model.id] == nil else {
            return
        }
        state.hasCompletedInitialStatusRefresh = false
        statusRefreshPendingModelIDs.insert(model.id)
        _ = nextStatusRefreshGeneration(for: model)
        let manager = serverManager
        let modelDelete = dependencies.deleteModel
        let statusProvider = dependencies.installStatus
        Task { [weak self] in
            let outcome: LocalAIModelDeletionOutcome
            do {
                outcome = try await manager.withExclusiveMaintenance {
                    do {
                        try modelDelete(model)
                        return LocalAIModelDeletionOutcome(
                            status: statusProvider(model),
                            errorDescription: nil
                        )
                    } catch {
                        return LocalAIModelDeletionOutcome(
                            status: statusProvider(model),
                            errorDescription: error.localizedDescription
                        )
                    }
                }
            } catch {
                guard let self else { return }
                outcome = LocalAIModelDeletionOutcome(
                    status: self.installState(for: model).status,
                    errorDescription: error.localizedDescription
                )
            }
            guard let self else { return }
            self.finishDeletion(model, outcome: outcome)
        }
    }

    private func finishDeletion(
        _ model: LocalAIModel,
        outcome: LocalAIModelDeletionOutcome
    ) {
        guard deletionRequestedModelIDs.remove(model.id) != nil else {
            return
        }
        if let errorDescription = outcome.errorDescription {
            var modelState = installState(for: model)
            modelState.isInstalling = false
            modelState.status = outcome.status
            modelState.issue = unavailableIssue(for: model)
            state.installStates[model.id] = modelState
            print("Local AI model deletion failed: \(errorDescription)")
        } else {
            state.installStates[model.id] = .initial(model: model, status: outcome.status)
        }
        emitStateChanged()
        onEvent?(.deletionOutcome(model, errorDescription: outcome.errorDescription))
        completeStatusOperation(outcome.status, for: model)
    }

    // MARK: - Testing seams

    func markInitialRefreshCompletedForTesting() {
        state.hasCompletedInitialStatusRefresh = true
    }

    private func emitStateChanged() {
        onEvent?(.stateChanged(state))
    }
}

private final class WeakLocalAIModelWorkflowReference: @unchecked Sendable {
    weak var value: LocalAIModelWorkflow?

    init(_ value: LocalAIModelWorkflow) {
        self.value = value
    }
}
