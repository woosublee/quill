import AVFoundation
import CoreMedia
import os.log
import Speech

private let speechLog = OSLog(subsystem: "com.woosublee.quill", category: "AppleSpeech")

// 실시간 전사를 지원하는 모든 백엔드가 따르는 프로토콜
protocol LiveTranscriber: AnyObject, Sendable {
    var onPartialResult: (@Sendable (String) -> Void)? { get set }
    var onAudioLevel: (@Sendable (Float) -> Void)? { get set }
    /// true이면 이 트랜스크라이버가 마이크 캡처와 파일 저장을 직접 처리 (AudioRecorder 불필요)
    var handlesRecording: Bool { get }
    /// finalize() 후 저장된 오디오 파일 URL (handlesRecording == true일 때만 유효)
    var recordedAudioURL: URL? { get }
    func start(locale: Locale) async throws
    func appendPCM16(_ data: Data)
    func finalize() async throws -> String
    func cancel()
}

// LiveTranscriber를 지원하는 모델인지 확인하고 인스턴스를 반환하는 팩토리
extension TranscriptionModel {
    func makeLiveTranscriber() -> (any LiveTranscriber)? {
        if isAppleSpeech { return AppleSpeechLiveTranscriber() }
        return nil
    }
}

// MARK: - Apple Speech

final class AppleSpeechLiveTranscriber: LiveTranscriber, @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var onPartialResult: (@Sendable (String) -> Void)?
        var onAudioLevel: (@Sendable (Float) -> Void)?
        var recognizer: SFSpeechRecognizer?
        var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
        var recognitionTask: SFSpeechRecognitionTask?
        var cachedPCMFormat: AVAudioFormat?
        var cachedPCMBuffer: AVAudioPCMBuffer?
        var finalizeContinuations: [CheckedContinuation<String, Error>] = []
        var finalResult: Result<String, Error>?
        var latestTranscript = ""
        var cancelled = false
    }

    var onPartialResult: (@Sendable (String) -> Void)? {
        get { stateLock.withLock { $0.onPartialResult } }
        set { stateLock.withLock { $0.onPartialResult = newValue } }
    }

    var onAudioLevel: (@Sendable (Float) -> Void)? {
        get { stateLock.withLock { $0.onAudioLevel } }
        set { stateLock.withLock { $0.onAudioLevel = newValue } }
    }

    let handlesRecording = false
    var recordedAudioURL: URL? { nil }

    private let stateLock = OSAllocatedUnfairLock(initialState: State())
    private let levelNormalizerLock = OSAllocatedUnfairLock(initialState: LiveAudioLevelNormalizer())

    // endAudio() 후 결과가 돌아오지 않을 때 대기하는 최대 시간
    private static let finalizeTimeoutSeconds: TimeInterval = 10

    func start(locale: Locale) async throws {
        let authStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        os_log(.default, log: speechLog, "authStatus=%ld", authStatus.rawValue)
        guard authStatus == .authorized else {
            throw AppleSpeechError.notAuthorized
        }

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            os_log(.default, log: speechLog, "recognizer not available locale=%{public}@", locale.identifier)
            throw AppleSpeechError.notAvailable(locale.identifier)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.addsPunctuation = true
        request.shouldReportPartialResults = true

        let shouldStart = stateLock.withLock { state -> Bool in
            guard !state.cancelled else { return false }
            state.recognizer = recognizer
            state.recognitionRequest = request
            return true
        }
        guard shouldStart else { return }

        os_log(.default, log: speechLog,
               "recognition task starting locale=%{public}@ supportsOnDevice=%d",
               locale.identifier, recognizer.supportsOnDeviceRecognition)
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handleTaskResult(result, error: error)
        }

        let shouldKeepTask = stateLock.withLock { state -> Bool in
            guard !state.cancelled,
                  state.recognitionRequest === request else {
                return false
            }
            state.recognitionTask = task
            return true
        }
        if !shouldKeepTask {
            task.cancel()
        }
    }

    func appendPCM16(_ data: Data) {
        let appendResult = stateLock.withLock { state -> (level: Float, callback: @Sendable (Float) -> Void)? in
            guard let recognitionRequest = state.recognitionRequest,
                  let pcmBuffer = Self.fillPCMBuffer(
                    fromPCM16: data,
                    state: &state
                  ) else {
                return nil
            }
            recognitionRequest.append(pcmBuffer)
            guard let callback = state.onAudioLevel else { return nil }
            return (normalizedLevel(from: pcmBuffer), callback)
        }
        guard let appendResult else { return }
        appendResult.callback(appendResult.level)
    }

    func finalize() async throws -> String {
        os_log(.default, log: speechLog, "finalize() called")
        let request = stateLock.withLock { state -> SFSpeechAudioBufferRecognitionRequest? in
            defer { state.recognitionRequest = nil }
            return state.recognitionRequest
        }
        request?.endAudio()

        if let existing = stateLock.withLock({ $0.finalResult }) {
            return try existing.get()
        }

        // endAudio() 후 결과가 돌아오지 않으면 타임아웃 후 현재까지 누적된 텍스트 반환
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let result = self.stateLock.withLock { state -> Result<String, Error>? in
                        if let result = state.finalResult {
                            return result
                        }
                        state.finalizeContinuations.append(continuation)
                        return nil
                    }
                    if let result {
                        continuation.resume(with: result)
                    }
                }
            }
            group.addTask { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(Self.finalizeTimeoutSeconds * 1_000_000_000))
                guard let self else { return "" }
                let latest = self.stateLock.withLock { $0.latestTranscript }
                os_log(.default, log: speechLog, "finalize timeout — returning latestTranscript=%{private}@", latest)
                self.resumeAll(with: .success(latest))
                return latest
            }
            guard let result = try await group.next() else {
                return stateLock.withLock { $0.latestTranscript }
            }
            group.cancelAll()
            return result
        }
    }

    func cancel() {
        let cancellation = stateLock.withLock { state -> (
            task: SFSpeechRecognitionTask?,
            callback: (@Sendable (Float) -> Void)?,
            latestTranscript: String
        ) in
            state.cancelled = true
            let result = (
                state.recognitionTask,
                state.onAudioLevel,
                state.latestTranscript
            )
            state.recognizer = nil
            state.recognitionRequest = nil
            state.recognitionTask = nil
            state.cachedPCMBuffer = nil
            state.cachedPCMFormat = nil
            return result
        }
        cancellation.callback?(0)
        cancellation.task?.cancel()
        resumeAll(with: .success(cancellation.latestTranscript))
    }

    private func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return 0 }

        var sumOfSquares: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for index in 0..<frameLength {
                let sample = samples[index]
                sumOfSquares += sample * sample
            }
        }

        let sampleCount = Float(channelCount * frameLength)
        let rms = sqrtf(sumOfSquares / max(sampleCount, 1))
        return levelNormalizerLock.withLock {
            $0.normalizedLevel(forRMS: rms)
        }
    }

    private static func fillPCMBuffer(
        fromPCM16 data: Data,
        state: inout State
    ) -> AVAudioPCMBuffer? {
        let bytesPerFrame = MemoryLayout<Int16>.size
        guard !data.isEmpty, data.count % bytesPerFrame == 0 else { return nil }
        let frameCount = AVAudioFrameCount(data.count / bytesPerFrame)
        guard frameCount > 0 else { return nil }

        if state.cachedPCMFormat == nil {
            state.cachedPCMFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 24_000,
                channels: 1,
                interleaved: true
            )
        }
        guard let format = state.cachedPCMFormat else { return nil }
        if state.cachedPCMBuffer == nil
            || state.cachedPCMBuffer?.frameCapacity ?? 0 < frameCount {
            state.cachedPCMBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
            )
        }
        guard let pcmBuffer = state.cachedPCMBuffer,
              let channelData = pcmBuffer.int16ChannelData?[0] else {
            return nil
        }
        pcmBuffer.frameLength = frameCount
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            channelData.update(
                from: baseAddress.assumingMemoryBound(to: Int16.self),
                count: Int(frameCount)
            )
        }
        return pcmBuffer
    }

    private func handleTaskResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            let callback = stateLock.withLock { state -> (@Sendable (String) -> Void)? in
                state.latestTranscript = text
                return state.onPartialResult
            }
            os_log(.default, log: speechLog, "result isFinal=%d text=%{private}@", result.isFinal, text)
            callback?(text)
            if result.isFinal {
                resumeAll(with: .success(text))
            }
        } else if let error {
            let nsError = error as NSError
            os_log(.error, log: speechLog, "recognition error domain=%{public}@ code=%ld msg=%{public}@",
                   nsError.domain, nsError.code, nsError.localizedDescription)
            let assistantNoSpeechErrorCode = 1110
            let assistantRetryStoppedErrorCode = 203
            if nsError.code == assistantNoSpeechErrorCode || nsError.code == assistantRetryStoppedErrorCode {
                os_log(.default, log: speechLog, "handled Apple Speech non-fatal error code=%ld", nsError.code)
                resumeAll(with: .success(stateLock.withLock { $0.latestTranscript }))
            } else {
                resumeAll(with: .failure(error))
            }
        } else {
            os_log(.default, log: speechLog, "task completed with no result/error")
            resumeAll(with: .success(stateLock.withLock { $0.latestTranscript }))
        }
    }

    private func resumeAll(with result: Result<String, Error>) {
        let continuations = stateLock.withLock { state -> [CheckedContinuation<String, Error>] in
            guard state.finalResult == nil else { return [] }
            state.finalResult = result
            defer { state.finalizeContinuations.removeAll() }
            return state.finalizeContinuations
        }
        for continuation in continuations {
            continuation.resume(with: result)
        }
    }
}

enum AppleSpeechError: LocalizedError {
    case notAuthorized
    case notAvailable(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition permission denied. Enable it in System Settings > Privacy & Security > Speech Recognition."
        case .notAvailable(let locale):
            return "Apple Speech Recognizer not available for '\(locale)'."
        }
    }
}
