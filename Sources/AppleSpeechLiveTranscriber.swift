import AVFoundation
import CoreMedia
import os.log
import Speech

private let speechLog = OSLog(subsystem: "com.woosublee.quill", category: "AppleSpeech")

// 실시간 전사를 지원하는 모든 백엔드가 따르는 프로토콜
protocol LiveTranscriber: AnyObject {
    var onPartialResult: ((String) -> Void)? { get set }
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
    let handlesRecording = true
    private(set) var recordedAudioURL: URL?

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?

    private let lock = OSAllocatedUnfairLock(initialState: ())
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
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.addsPunctuation = true
        request.shouldReportPartialResults = true
        self.recognitionRequest = request

        os_log(.default, log: speechLog,
               "recognition task starting locale=%{public}@ supportsOnDevice=%d",
               locale.identifier, recognizer.supportsOnDeviceRecognition)
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handleTaskResult(result, error: error)
        }

        // AVAudioEngine으로 마이크를 직접 탭 — SFSpeechRecognizer 공급 + 파일 저장을 하나의 세션으로 처리
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        os_log(.default, log: speechLog, "engine input format sampleRate=%.0f channels=%d",
               format.sampleRate, format.channelCount)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        let audioFile = try AVAudioFile(forWriting: tempURL, settings: format.settings)
        self.tempFileURL = tempURL
        self.audioFile = audioFile

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
            try? audioFile.write(from: buffer)
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
        os_log(.default, log: speechLog, "AVAudioEngine started")
    }

    // AVAudioEngine이 마이크를 직접 탭하므로 AudioRecorder 버퍼는 사용하지 않음
    func append(_ sampleBuffer: CMSampleBuffer) {}

    func finalize() async throws -> String {
        os_log(.default, log: speechLog, "finalize() called")
        stopEngine()
        recordedAudioURL = tempFileURL
        recognitionRequest?.endAudio()

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
                let latest = self?.lock.withLock { self?.latestTranscript ?? "" } ?? ""
                os_log(.default, log: speechLog, "finalize timeout — returning latestTranscript=%{public}@", latest)
                self?.resumeAll(with: .success(latest))
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
        stopEngine()
        recognitionTask?.cancel()
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
        recordedAudioURL = nil
        let latest = lock.withLock { latestTranscript }
        resumeAll(with: .success(latest))
    }

    private func stopEngine() {
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
        audioEngine = nil
        os_log(.default, log: speechLog, "AVAudioEngine stopped")
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
            if nsError.code == 1110 || nsError.code == 203 {
                os_log(.default, log: speechLog, "handled silent error code=%ld", nsError.code)
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
