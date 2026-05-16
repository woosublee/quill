import Combine
import Foundation
import os

final class SystemDefaultAndSystemAudioRecorder: ObservableObject {
    let microphoneRecorder: AudioRecorder
    let systemAudioRecorder: SystemAudioRecorder
    let mixdownService: AudioMixdownService

    @Published var audioLevel: Float = 0.0

    var onRecordingReady: (() -> Void)?
    var onRecordingFailure: ((Error) -> Void)?

    private enum RecordingSource: Hashable {
        case microphone
        case systemAudio
    }

    private struct RecordingState {
        var microphoneStarted = false
        var systemStarted = false
        var readyFired = false
        var activeSources: Set<RecordingSource> = []
        var failedSources: Set<RecordingSource> = []
        var overallFailureReported = false

        mutating func resetForStart() {
            microphoneStarted = false
            systemStarted = false
            readyFired = false
            activeSources = []
            failedSources = []
            overallFailureReported = false
        }

        mutating func resetIdle() {
            resetForStart()
        }
    }

    private struct StoppedRecordingURLs {
        var microphoneURL: URL?
        var systemAudioURL: URL?
    }

    private let stateLock = OSAllocatedUnfairLock(initialState: RecordingState())
    private var cancellables: Set<AnyCancellable> = []

    init(microphoneRecorder: AudioRecorder, systemAudioRecorder: SystemAudioRecorder, mixdownService: AudioMixdownService = AudioMixdownService()) {
        self.microphoneRecorder = microphoneRecorder
        self.systemAudioRecorder = systemAudioRecorder
        self.mixdownService = mixdownService
        configureChildCallbacks()
        subscribeToAudioLevelsIfNeeded()
    }

    func startRecording() async throws {
        configureChildCallbacks()
        subscribeToAudioLevelsIfNeeded()

        stateLock.withLock { state in
            state.resetForStart()
        }

        var startErrors: [Error] = []

        do {
            try microphoneRecorder.startRecording(deviceUID: AudioInputDevice.defaultMicrophoneID)
            stateLock.withLock { state in
                state.microphoneStarted = true
                state.activeSources.insert(.microphone)
            }
        } catch {
            startErrors.append(error)
        }

        do {
            try await systemAudioRecorder.startRecording()
            stateLock.withLock { state in
                state.systemStarted = true
                state.activeSources.insert(.systemAudio)
            }
        } catch {
            startErrors.append(error)
        }

        let (microphoneStarted, systemStarted) = stateLock.withLock { state in
            (state.microphoneStarted, state.systemStarted)
        }
        guard microphoneStarted || systemStarted else {
            throw SystemDefaultAndSystemAudioRecorderError.failedToStartAnyRecorder(startErrors)
        }
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        let (shouldStopMicrophone, shouldStopSystemAudio) = stateLock.withLock { state in
            let result = (state.microphoneStarted, state.systemStarted)
            state.resetIdle()
            return result
        }

        guard shouldStopMicrophone || shouldStopSystemAudio else {
            completion(nil)
            return
        }

        let group = DispatchGroup()
        let stoppedURLs = OSAllocatedUnfairLock(initialState: StoppedRecordingURLs())

        if shouldStopMicrophone {
            group.enter()
            microphoneRecorder.stopRecording { url in
                stoppedURLs.withLock { urls in
                    urls.microphoneURL = url
                }
                group.leave()
            }
        }

        if shouldStopSystemAudio {
            group.enter()
            systemAudioRecorder.stopRecording { url in
                stoppedURLs.withLock { urls in
                    urls.systemAudioURL = url
                }
                group.leave()
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            let urls = stoppedURLs.withLock { $0 }
            let finalURL = self.finalRecordingURL(microphoneURL: urls.microphoneURL, systemAudioURL: urls.systemAudioURL)
            DispatchQueue.main.async {
                completion(finalURL)
            }
        }
    }

    func cancelRecording() {
        let (shouldCancelMicrophone, shouldCancelSystemAudio) = stateLock.withLock { state in
            let result = (state.microphoneStarted, state.systemStarted)
            state.resetIdle()
            return result
        }

        if shouldCancelMicrophone {
            microphoneRecorder.cancelRecording()
        }
        if shouldCancelSystemAudio {
            systemAudioRecorder.cancelRecording()
        }
        audioLevel = 0.0
    }

    func cleanup() {
        cancellables.removeAll()
        stateLock.withLock { state in
            state.resetIdle()
        }
        audioLevel = 0.0
        microphoneRecorder.onRecordingReady = nil
        microphoneRecorder.onRecordingFailure = nil
        microphoneRecorder.onPCM16Samples = nil
        systemAudioRecorder.onRecordingReady = nil
        systemAudioRecorder.onRecordingFailure = nil
        systemAudioRecorder.onPCM16Samples = nil
    }

    private func configureChildCallbacks() {
        microphoneRecorder.onRecordingReady = { [weak self] in
            self?.fireRecordingReadyOnce()
        }
        systemAudioRecorder.onRecordingReady = { [weak self] in
            self?.fireRecordingReadyOnce()
        }
        microphoneRecorder.onRecordingFailure = { [weak self] failure in
            self?.handleSourceFailure(.microphone, error: failure)
        }
        systemAudioRecorder.onRecordingFailure = { [weak self] failure in
            self?.handleSourceFailure(.systemAudio, error: failure)
        }
    }

    private func subscribeToAudioLevelsIfNeeded() {
        guard cancellables.isEmpty else { return }

        Publishers.CombineLatest(microphoneRecorder.$audioLevel, systemAudioRecorder.$audioLevel)
            .map { microphoneLevel, systemAudioLevel in
                max(microphoneLevel, systemAudioLevel)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.audioLevel = level
            }
            .store(in: &cancellables)
    }

    private func handleSourceFailure(_ source: RecordingSource, error failure: Error) {
        let shouldReportOverallFailure = stateLock.withLock { state in
            guard state.activeSources.contains(source), !state.failedSources.contains(source), !state.overallFailureReported else {
                return false
            }

            state.failedSources.insert(source)
            let sourceFailuresExhaustedRecording = !state.activeSources.isEmpty && state.activeSources.isSubset(of: state.failedSources)
            if sourceFailuresExhaustedRecording {
                state.overallFailureReported = true
            }
            return sourceFailuresExhaustedRecording
        }

        if shouldReportOverallFailure {
            onRecordingFailure?(failure)
        }
    }

    private func fireRecordingReadyOnce() {
        let shouldFire = stateLock.withLock { state in
            guard !state.readyFired else { return false }
            state.readyFired = true
            return true
        }
        if shouldFire {
            onRecordingReady?()
        }
    }

    private func finalRecordingURL(microphoneURL: URL?, systemAudioURL: URL?) -> URL? {
        switch (microphoneURL, systemAudioURL) {
        case let (microphoneURL?, systemAudioURL?):
            do {
                let mixedURL = try mixdownService.mix(microphoneURL: microphoneURL, systemAudioURL: systemAudioURL)
                try? FileManager.default.removeItem(at: microphoneURL)
                try? FileManager.default.removeItem(at: systemAudioURL)
                return mixedURL
            } catch {
                try? FileManager.default.removeItem(at: systemAudioURL)
                return microphoneURL
            }
        case let (microphoneURL?, nil):
            return microphoneURL
        case let (nil, systemAudioURL?):
            return systemAudioURL
        case (nil, nil):
            return nil
        }
    }
}

enum SystemDefaultAndSystemAudioRecorderError: LocalizedError {
    case failedToStartAnyRecorder([Error])

    var errorDescription: String? {
        switch self {
        case .failedToStartAnyRecorder(let errors):
            let details = errors.map(\.localizedDescription).joined(separator: "; ")
            return details.isEmpty ? "Could not start System Default + System Audio recording." : "Could not start System Default + System Audio recording: \(details)"
        }
    }
}
