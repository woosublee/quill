import Foundation
import QuillUserIssueCore

struct NativeWhisperModelWorkflowState: Equatable, Sendable {
    var installStatus: NativeWhisperInstallStatus
    var installProgress: NativeWhisperDownloadProgress
    var isInstalling: Bool
    var installError: String?
    var installIssue: QuillUserIssueRecord?

    static func initial(for model: NativeWhisperModel) -> NativeWhisperModelWorkflowState {
        NativeWhisperModelWorkflowState(
            installStatus: .notInstalled,
            installProgress: NativeWhisperDownloadProgress(
                downloadedBytes: 0,
                totalBytes: model.approximateBytes
            ),
            isInstalling: false,
            installError: nil,
            installIssue: nil
        )
    }
}

enum NativeWhisperModelWorkflowOutcome: Equatable, Sendable {
    case succeeded
    case cancelled
    case failed(QuillUserIssueRecord)
}

enum NativeWhisperModelWorkflowEvent {
    case stateChanged(NativeWhisperModelWorkflowState)
    case installCompleted(NativeWhisperModelWorkflowOutcome)
}

@MainActor
final class NativeWhisperModelWorkflow: @unchecked Sendable {
    private let dependencies: AppStateNativeWhisperDependencies
    private let model: NativeWhisperModel

    // AppState.init is nonisolated, so it reads this immutable snapshot and
    // assigns the callback before workflow activity. Callback delivery remains
    // MainActor-isolated.
    nonisolated let initialState: NativeWhisperModelWorkflowState
    nonisolated(unsafe) var onEvent:
        (@MainActor (NativeWhisperModelWorkflowEvent) -> Void)?
    private(set) var state: NativeWhisperModelWorkflowState

    private var installTask: NativeWhisperInstallTask?
    private var progressCoalescer: LatestValueProgressCoalescer<NativeWhisperDownloadProgress>?
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationMessage: String?
    private var isTerminationCleanupPending = false

    nonisolated init(
        dependencies: AppStateNativeWhisperDependencies,
        model: NativeWhisperModel = .recommended
    ) {
        self.dependencies = dependencies
        self.model = model
        var initialState = NativeWhisperModelWorkflowState.initial(for: model)
        initialState.installStatus = dependencies.installStatus(model)
        self.initialState = initialState
        state = initialState
    }

    func refreshInstallStatus() {
        state.installStatus = dependencies.installStatus(model)
        emitStateChanged()
    }

    func startInstall() {
        guard !isTerminationCleanupPending, !state.isInstalling else { return }
        state.installError = nil
        state.installIssue = nil
        cancellationMessage = nil
        state.isInstalling = true
        state.installProgress = NativeWhisperDownloadProgress(
            downloadedBytes: 0,
            totalBytes: model.approximateBytes
        )
        emitStateChanged()

        let coalescer = LatestValueProgressCoalescer<NativeWhisperDownloadProgress>(
            schedule: dependencies.progressSchedule
        ) { [weak self] progress in
            MainActor.assumeIsolated {
                self?.applyProgress(progress)
            }
        }
        progressCoalescer = coalescer
        let startInstall = dependencies.startInstall
        installTask = startInstall(
            model,
            { progress in coalescer.submit(progress) },
            { [weak self] result in
                DispatchQueue.main.async {
                    self?.finishInstall(result: result)
                }
            }
        )
    }

    func cancelInstall() {
        guard installTask != nil else { return }
        cancellationMessage = nil
        progressCoalescer?.invalidate()
        progressCoalescer = nil
        installTask?.cancel()
        state.installProgress = NativeWhisperDownloadProgress(
            downloadedBytes: state.installProgress.downloadedBytes,
            totalBytes: state.installProgress.totalBytes,
            isCancelled: true
        )
        emitStateChanged()
    }

    func deleteModel() {
        do {
            try dependencies.deleteModel(model)
            state.installError = nil
            state.installIssue = nil
        } catch {
            state.installIssue = QuillUserIssueRecord(
                code: .localModelMissing,
                context: QuillUserIssueContext(
                    modelID: model.id,
                    localBackend: "Native Whisper"
                )
            )
        }
        refreshInstallStatus()
    }

    func waitUntilQuiesced() async {
        guard installTask != nil else { return }
        await withCheckedContinuation { continuation in
            quiescenceWaiters.append(continuation)
        }
    }

    func beginTerminationCleanup() {
        isTerminationCleanupPending = true
    }

    private func applyProgress(_ progress: NativeWhisperDownloadProgress) {
        state.installProgress = progress
        emitStateChanged()
    }

    private func finishInstall(result: Result<Void, NativeWhisperInstallerError>) {
        progressCoalescer?.invalidate()
        progressCoalescer = nil
        installTask = nil
        defer { resumeQuiescenceWaitersIfNeeded() }
        state.isInstalling = false
        state.installStatus = dependencies.installStatus(model)

        switch result {
        case .success:
            emitStateChanged()
            onEvent?(.installCompleted(.succeeded))
        case .failure(.cancelled):
            state.installError = cancellationMessage
            cancellationMessage = nil
            emitStateChanged()
            onEvent?(.installCompleted(.cancelled))
        case .failure:
            let issue = QuillUserIssueRecord(
                code: .localModelMissing,
                context: QuillUserIssueContext(
                    modelID: model.id,
                    localBackend: "Native Whisper"
                )
            )
            state.installIssue = issue
            emitStateChanged()
            onEvent?(.installCompleted(.failed(issue)))
        }
    }

    private func resumeQuiescenceWaitersIfNeeded() {
        guard installTask == nil else { return }
        let waiters = quiescenceWaiters
        quiescenceWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func emitStateChanged() {
        onEvent?(.stateChanged(state))
    }
}
