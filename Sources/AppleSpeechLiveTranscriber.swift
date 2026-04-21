import AVFoundation
import CoreMedia
import os.log
import Speech

private let speechLog = OSLog(subsystem: "com.woosublee.quill", category: "AppleSpeech")

// 실시간 전사를 지원하는 모든 백엔드가 따르는 프로토콜
protocol LiveTranscriber: AnyObject {
    var onPartialResult: ((String) -> Void)? { get set }
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

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private let lock = OSAllocatedUnfairLock(initialState: ())
    private var finalizeContinuation: CheckedContinuation<String, Error>?
    private var finalResult: Result<String, Error>?
    private var latestTranscript: String = ""
    private var cachedConverter: AVAudioConverter?
    private var appendCount = 0

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
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.shouldReportPartialResults = true
        self.recognitionRequest = request

        os_log(.default, log: speechLog,
               "recognition task starting locale=%{public}@ supportsOnDevice=%d",
               locale.identifier, recognizer.supportsOnDeviceRecognition)
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handleTaskResult(result, error: error)
        }
        os_log(.default, log: speechLog, "recognition task created state=%ld",
               recognitionTask?.state.rawValue ?? -1)
    }

    // Called from AudioRecorder's sampleBufferQueue
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let request = recognitionRequest else { return }
        guard let pcmBuffer = convertToSpeechBuffer(sampleBuffer) else { return }
        request.append(pcmBuffer)
        appendCount += 1
        if appendCount == 1 || appendCount % 100 == 0 {
            os_log(.default, log: speechLog, "appended buffer #%d frameLength=%d",
                   appendCount, pcmBuffer.frameLength)
        }
    }

    // CMSampleBuffer(Float32 interleaved) → AVAudioPCMBuffer(Float32 non-interleaved mono)
    // SFSpeechRecognizer는 non-interleaved native-rate 버퍼에서 안정적으로 동작함
    private func convertToSpeechBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let srcFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }

        // 소스 버퍼 생성 (AudioRecorder의 interleaved Float32 포맷)
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else { return nil }
        srcBuffer.frameLength = frameCount
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: srcBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return nil }

        // 이미 non-interleaved mono면 그대로 반환
        if !srcFormat.isInterleaved && srcFormat.channelCount == 1 {
            return srcBuffer
        }

        // non-interleaved mono Float32로 변환 (변환기 캐싱으로 매 버퍼마다 재생성 방지)
        if cachedConverter == nil {
            let dstFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: srcFormat.sampleRate,
                channels: 1,
                interleaved: false
            )
            guard let dstFormat else { return nil }
            cachedConverter = AVAudioConverter(from: srcFormat, to: dstFormat)
            os_log(.default, log: speechLog, "converter created sampleRate=%.0f", srcFormat.sampleRate)
        }
        guard let converter = cachedConverter,
              let dstBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: frameCount) else { return nil }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return srcBuffer
        }
        let status = converter.convert(to: dstBuffer, error: &error, withInputFrom: inputBlock)
        if let error {
            os_log(.error, log: speechLog, "audio conversion failed: %{public}@", error.localizedDescription)
            return nil
        }
        if appendCount <= 1 {
            os_log(.default, log: speechLog,
                   "convert status=%ld srcFrames=%d dstFrames=%d",
                   status.rawValue, frameCount, dstBuffer.frameLength)
        }
        guard dstBuffer.frameLength > 0 else { return nil }
        return dstBuffer
    }

    func finalize() async throws -> String {
        os_log(.default, log: speechLog, "finalize() called endAudio()")
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
        recognitionTask?.cancel()
        cachedConverter = nil
        let latest = lock.withLock { latestTranscript }
        resumeAll(with: .success(latest))
    }

    private func handleTaskResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            lock.withLock { latestTranscript = text }
            os_log(.default, log: speechLog, "result isFinal=%d text=%{public}@", result.isFinal, text)
            // partial이든 final이든 UI 업데이트 — macOS는 partial 결과를 잘 안 보내므로 final도 반영
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
                resumeAll(with: .success(""))
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
