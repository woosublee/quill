import AVFoundation
import CoreMedia
import os.log
import Speech

private let speechLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "AppleSpeech")

// 실시간 전사를 지원하는 모든 백엔드가 따르는 프로토콜
protocol LiveTranscriber: AnyObject {
    var onPartialResult: ((String) -> Void)? { get set }
    var onAudioLevel: ((Float) -> Void)? { get set }
    /// true이면 이 트랜스크라이버가 마이크 캡처와 파일 저장을 직접 처리 (AudioRecorder 불필요)
    var handlesRecording: Bool { get }
    /// finalize() 후 저장된 오디오 파일 URL (handlesRecording == true일 때만 유효)
    var recordedAudioURL: URL? { get }
    func start(locale: Locale) async throws
    func append(_ sampleBuffer: CMSampleBuffer)
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

final class AppleSpeechLiveTranscriber: LiveTranscriber {
    var onPartialResult: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    let handlesRecording = false
    private(set) var recordedAudioURL: URL?

    private struct CachedPCMBufferState {
        var sampleRate: Double = 0
        var channelCount: AVAudioChannelCount = 0
        var commonFormat: AVAudioCommonFormat = .otherFormat
        var isInterleaved = false
        var format: AVAudioFormat?
        var buffer: AVAudioPCMBuffer?
    }

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var cachedPCMBufferState = CachedPCMBufferState()

    private let lock = OSAllocatedUnfairLock(initialState: ())
    private let levelNormalizerLock = OSAllocatedUnfairLock(initialState: LiveAudioLevelNormalizer())
    private var finalizeContinuation: CheckedContinuation<String, Error>?
    private var finalResult: Result<String, Error>?
    private var latestTranscript: String = ""

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
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.addsPunctuation = true
        request.shouldReportPartialResults = true
        self.recognitionRequest = request

        os_log(.default, log: speechLog,
               "recognition task starting locale=%{public}@ supportsOnDevice=%d",
               locale.identifier, recognizer.supportsOnDeviceRecognition)
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handleTaskResult(result, error: error)
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let pcmBuffer = pcmBuffer(from: sampleBuffer) else { return }
        let didAppend = lock.withLock { () -> Bool in
            guard let recognitionRequest else { return false }
            recognitionRequest.append(pcmBuffer)
            return true
        }
        guard didAppend else { return }
        onAudioLevel?(normalizedLevel(from: pcmBuffer))
    }

    func finalize() async throws -> String {
        os_log(.default, log: speechLog, "finalize() called")
        lock.withLock {
            recognitionRequest?.endAudio()
            recognitionRequest = nil
        }

        if let existing = lock.withLock({ finalResult }) {
            return try existing.get()
        }

        // endAudio() 후 결과가 돌아오지 않으면 타임아웃 후 현재까지 누적된 텍스트 반환
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.lock.withLock {
                        if let result = self.finalResult {
                            continuation.resume(with: result)
                        } else {
                            self.finalizeContinuation = continuation
                        }
                    }
                }
            }
            group.addTask { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(Self.finalizeTimeoutSeconds * 1_000_000_000))
                guard let self else { return "" }
                let latest = self.lock.withLock { self.latestTranscript }
                os_log(.default, log: speechLog, "finalize timeout — returning latestTranscript=%{public}@", latest)
                self.resumeAll(with: .success(latest))
                return latest
            }
            guard let result = try await group.next() else {
                return lock.withLock { latestTranscript }
            }
            group.cancelAll()
            return result
        }
    }

    func cancel() {
        onAudioLevel?(0)
        recognitionTask?.cancel()
        let latest = lock.withLock { () -> String in
            recognitionRequest = nil
            cachedPCMBufferState.buffer = nil
            cachedPCMBufferState.format = nil
            return latestTranscript
        }
        recordedAudioURL = nil
        resumeAll(with: .success(latest))
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

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        let sampleFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else {
            return nil
        }

        let pcmBuffer: AVAudioPCMBuffer? = lock.withLock {
            let shouldResetBuffer =
                cachedPCMBufferState.sampleRate != sampleFormat.sampleRate ||
                cachedPCMBufferState.channelCount != sampleFormat.channelCount ||
                cachedPCMBufferState.commonFormat != sampleFormat.commonFormat ||
                cachedPCMBufferState.isInterleaved != sampleFormat.isInterleaved
            if shouldResetBuffer {
                cachedPCMBufferState.sampleRate = sampleFormat.sampleRate
                cachedPCMBufferState.channelCount = sampleFormat.channelCount
                cachedPCMBufferState.commonFormat = sampleFormat.commonFormat
                cachedPCMBufferState.isInterleaved = sampleFormat.isInterleaved
                cachedPCMBufferState.format = sampleFormat
                cachedPCMBufferState.buffer = nil
            }
            guard let cachedFormat = cachedPCMBufferState.format else {
                return nil
            }
            if cachedPCMBufferState.buffer == nil || cachedPCMBufferState.buffer?.frameCapacity ?? 0 < frameCount {
                cachedPCMBufferState.buffer = AVAudioPCMBuffer(pcmFormat: cachedFormat, frameCapacity: frameCount)
            }
            cachedPCMBufferState.buffer?.frameLength = frameCount
            return cachedPCMBufferState.buffer
        }

        guard let pcmBuffer else {
            return nil
        }
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else {
            os_log(.error, log: speechLog, "failed to copy CMSampleBuffer to PCM buffer status=%d", status)
            return nil
        }
        return pcmBuffer
    }

    private func handleTaskResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            lock.withLock { latestTranscript = text }
            os_log(.default, log: speechLog, "result isFinal=%d text=%{public}@", result.isFinal, text)
            onPartialResult?(text)
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
                resumeAll(with: .success(lock.withLock { latestTranscript }))
            } else {
                resumeAll(with: .failure(error))
            }
        } else {
            os_log(.default, log: speechLog, "task completed with no result/error")
            resumeAll(with: .success(lock.withLock { latestTranscript }))
        }
    }

    private func resumeAll(with result: Result<String, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<String, Error>? in
            guard finalResult == nil else { return nil }
            finalResult = result
            defer { finalizeContinuation = nil }
            return finalizeContinuation
        }
        continuation?.resume(with: result)
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
