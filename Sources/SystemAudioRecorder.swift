import AVFoundation
import CoreMedia
import Foundation
import os.log
@preconcurrency import ScreenCaptureKit

private let systemAudioRecordingLog = OSLog(subsystem: "com.woosublee.quill", category: "SystemAudioRecording")

enum SystemAudioRecorderError: LocalizedError {
    case noDisplayAvailable
    case failedToLoadShareableContent(String)
    case failedToAddAudioOutput(String)
    case failedToStartCapture(String)
    case failedToStopCapture(String)
    case noAudioBuffersReceived
    case invalidInputFormat(String)
    case failedToBeginFileRecording(String)

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            return "No display is available for system audio capture."
        case .failedToLoadShareableContent(let details):
            return "Could not load system audio capture sources: \(details)"
        case .failedToAddAudioOutput(let details):
            return "Could not prepare system audio capture: \(details)"
        case .failedToStartCapture(let details):
            return "Could not start system audio capture: \(details)"
        case .failedToStopCapture(let details):
            return "Could not stop system audio capture: \(details)"
        case .noAudioBuffersReceived:
            return "No system audio was received."
        case .invalidInputFormat(let details):
            return "Invalid system audio format: \(details)"
        case .failedToBeginFileRecording(let details):
            return "Could not record system audio: \(details)"
        }
    }
}

final class SystemAudioRecorder: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private static let sessionQueueKey = DispatchSpecificKey<UInt8>()
    private static let watchdogTimeout: TimeInterval = 2.0
    private static let sampleRateLogLimit = 40

    private let sessionQueue = DispatchQueue(label: "com.woosublee.quill.system-audio.session")
    private let sampleBufferQueue = DispatchQueue(label: "com.woosublee.quill.system-audio.samples")
    private let _recording = OSAllocatedUnfairLock(initialState: false)
    private let _bufferCount = OSAllocatedUnfairLock(initialState: 0)
    private let fileWriteErrorLock = OSAllocatedUnfairLock(initialState: ())
    private let liveLevelNormalizerLock = OSAllocatedUnfairLock(initialState: LiveAudioLevelNormalizer())
    private let recordingConverterLock = OSAllocatedUnfairLock<AVAudioConverter?>(initialState: nil)
    private let pcm16ConverterLock = OSAllocatedUnfairLock<AVAudioConverter?>(initialState: nil)

    private var stream: SCStream?
    private var tempFileURL: URL?
    private var activeAudioFile: AVAudioFile?
    private var recordedFrameCount: AVAudioFramePosition = 0
    private var fileWriteError: Error?
    private var watchdogTimer: DispatchSourceTimer?
    private var recordingStartTime: CFAbsoluteTime = 0
    private var readyFired = false
    private var failureReported = false
    private var loggedCaptureFormat = false
    private var pcm16InputFormat: AVAudioFormat?
    private var pcm16InputBuffer: AVAudioPCMBuffer?
    private var pcm16OutputBuffer: AVAudioPCMBuffer?

    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0

    var onRecordingReady: (() -> Void)?
    var onRecordingFailure: ((Error) -> Void)?
    var onPCM16Samples: ((Data) -> Void)?

    private let recordingTargetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let pcm16TargetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!

    override init() {
        super.init()
        sessionQueue.setSpecific(key: Self.sessionQueueKey, value: 1)
    }

    deinit {
        let cleanup = {
            self.cancelWatchdog()
            self._recording.withLock { $0 = false }
            self.stream = nil
            self.activeAudioFile = nil
            self.recordedFrameCount = 0
            if let url = self.tempFileURL {
                try? FileManager.default.removeItem(at: url)
                self.tempFileURL = nil
            }
        }

        if DispatchQueue.getSpecific(key: Self.sessionQueueKey) != nil {
            cleanup()
        } else {
            sessionQueue.sync(execute: cleanup)
        }
    }

    func startRecording() async throws {
        let t0 = CFAbsoluteTimeGetCurrent()
        recordingStartTime = t0
        _bufferCount.withLock { $0 = 0 }
        readyFired = false
        failureReported = false
        loggedCaptureFormat = false
        liveLevelNormalizerLock.withLock { $0.reset() }

        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let content = try await Self.loadShareableContent()
        guard let display = content.displays.first else {
            throw SystemAudioRecorderError.noDisplayAvailable
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleBufferQueue)
        } catch {
            throw SystemAudioRecorderError.failedToAddAudioOutput(error.localizedDescription)
        }

        await withCheckedContinuation { continuation in
            sessionQueue.async {
                self.stream = stream
                self.tempFileURL = outputURL
                self.recordedFrameCount = 0
                self.fileWriteErrorLock.withLock { _ in self.fileWriteError = nil }
                self.recordingConverterLock.withLock { $0 = nil }
                self.pcm16ConverterLock.withLock { $0 = nil }
                self.pcm16InputFormat = nil
                self.pcm16InputBuffer = nil
                self.pcm16OutputBuffer = nil
                self._recording.withLock { $0 = true }
                self.startBufferWatchdog()
                continuation.resume()
            }
        }

        do {
            try await stream.startCapture()
        } catch {
            await discardFailedStart(outputURL: outputURL)
            throw SystemAudioRecorderError.failedToStartCapture(error.localizedDescription)
        }

        await MainActor.run {
            self.isRecording = true
            self.audioLevel = 0.0
        }
        os_log(.info, log: systemAudioRecordingLog, "startRecording() complete: %.3fms total", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        let currentStream = currentStreamSnapshot()
        Task {
            if let currentStream {
                do {
                    try await currentStream.stopCapture()
                } catch {
                    os_log(.error, log: systemAudioRecordingLog, "stopCapture failed: %{public}@", error.localizedDescription)
                }
            }
            finishRecording(discard: false, completion: completion)
        }
    }

    func cancelRecording() {
        let currentStream = currentStreamSnapshot()
        Task {
            if let currentStream {
                try? await currentStream.stopCapture()
            }
            finishRecording(discard: true, completion: nil)
        }
    }

    func cleanup() {
        let cleanup = {
            if let url = self.tempFileURL {
                try? FileManager.default.removeItem(at: url)
                self.tempFileURL = nil
            }
        }
        if DispatchQueue.getSpecific(key: Self.sessionQueueKey) != nil {
            cleanup()
        } else {
            sessionQueue.sync(execute: cleanup)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard _recording.withLock({ $0 }) else { return }
        guard CMSampleBufferIsValid(sampleBuffer) else { return }

        do {
            try appendSampleBufferToFile(sampleBuffer)
        } catch {
            fileWriteErrorLock.withLock { _ in fileWriteError = error }
            reportRecordingFailure(error)
            return
        }

        emitPCM16IfNeeded(from: sampleBuffer)
        let count = _bufferCount.withLock { value -> Int in
            value += 1
            return value
        }
        let rms = updateAudioLevel(from: sampleBuffer)
        if count <= Self.sampleRateLogLimit {
            let elapsed = (CFAbsoluteTimeGetCurrent() - recordingStartTime) * 1000
            os_log(.info, log: systemAudioRecordingLog, "buffer #%d at %.3fms, rms=%.6f", count, elapsed, rms)
        }
        if !readyFired {
            readyFired = true
            DispatchQueue.main.async { self.onRecordingReady?() }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        reportRecordingFailure(error)
    }

    private static func loadShareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
                if let content {
                    continuation.resume(returning: content)
                    return
                }
                let details = error?.localizedDescription ?? "Unknown error"
                continuation.resume(throwing: SystemAudioRecorderError.failedToLoadShareableContent(details))
            }
        }
    }

    private func discardFailedStart(outputURL: URL) async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                self.cancelWatchdog()
                self.stream = nil
                self.tempFileURL = nil
                self.activeAudioFile = nil
                self.recordedFrameCount = 0
                self.fileWriteErrorLock.withLock { _ in self.fileWriteError = nil }
                self._recording.withLock { $0 = false }
                self.liveLevelNormalizerLock.withLock { $0.reset() }
                try? FileManager.default.removeItem(at: outputURL)
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.audioLevel = 0.0
                    continuation.resume()
                }
            }
        }
    }

    private func currentStreamSnapshot() -> SCStream? {
        if DispatchQueue.getSpecific(key: Self.sessionQueueKey) != nil {
            return stream
        }
        return sessionQueue.sync { stream }
    }

    private func finishRecording(discard: Bool, completion: ((URL?) -> Void)?) {
        sessionQueue.async {
            self.cancelWatchdog()
            let fileURLToDelete = self.tempFileURL
            let resultURL = self.finishAudioFileLocked(discard: discard)
            self.stream = nil
            self._recording.withLock { $0 = false }
            self.liveLevelNormalizerLock.withLock { $0.reset() }
            if discard || resultURL == nil, let fileURLToDelete {
                try? FileManager.default.removeItem(at: fileURLToDelete)
            }
            DispatchQueue.main.async {
                self.isRecording = false
                self.audioLevel = 0.0
                completion?(discard ? nil : resultURL)
            }
        }
    }

    private func reportRecordingFailure(_ error: Error) {
        sessionQueue.async {
            guard !self.failureReported else { return }
            self.failureReported = true
            self.cancelWatchdog()
            self._recording.withLock { $0 = false }

            let fileURLToDelete = self.tempFileURL
            _ = self.finishAudioFileLocked(discard: true)
            self.stream = nil
            self.liveLevelNormalizerLock.withLock { $0.reset() }
            if let fileURLToDelete {
                try? FileManager.default.removeItem(at: fileURLToDelete)
            }

            DispatchQueue.main.async {
                self.isRecording = false
                self.audioLevel = 0.0
                self.onRecordingFailure?(error)
            }
        }
    }

    private func startBufferWatchdog() {
        let baselineCount = _bufferCount.withLock { $0 }
        cancelWatchdog()

        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + Self.watchdogTimeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self._recording.withLock({ $0 }) else { return }

            let count = self._bufferCount.withLock { $0 }
            if count == baselineCount {
                os_log(.error, log: systemAudioRecordingLog, "watchdog: no new buffers after %.1fs — giving up", Self.watchdogTimeout)
                self.reportRecordingFailure(SystemAudioRecorderError.noAudioBuffersReceived)
            } else {
                os_log(.info, log: systemAudioRecordingLog, "watchdog: %d new buffers after %.1fs — healthy", count - baselineCount, Self.watchdogTimeout)
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func cancelWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    private func finishAudioFileLocked(discard: Bool) -> URL? {
        var finalizedURL: URL?
        var shouldKeepFile = false

        sampleBufferQueue.sync {
            finalizedURL = self.tempFileURL
            shouldKeepFile = !discard && self.recordedFrameCount > 0 && self.fileWriteErrorLock.withLock { _ in
                self.fileWriteError == nil
            }
            self.activeAudioFile = nil
        }

        defer {
            self.recordedFrameCount = 0
            self.fileWriteErrorLock.withLock { _ in
                self.fileWriteError = nil
            }
            if !shouldKeepFile {
                self.tempFileURL = nil
            }
        }

        return shouldKeepFile ? finalizedURL : nil
    }

    private func appendSampleBufferToFile(_ sampleBuffer: CMSampleBuffer) throws {
        if let fileWriteError = fileWriteErrorLock.withLock({ _ in self.fileWriteError }) {
            throw fileWriteError
        }

        guard let outputURL = tempFileURL else {
            throw SystemAudioRecorderError.failedToBeginFileRecording("Missing temporary output URL.")
        }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw SystemAudioRecorderError.invalidInputFormat("Could not determine audio format from sample buffer.")
        }
        let sourceFormat = try validatedPCMBufferFormat(
            AVAudioFormat(cmAudioFormatDescription: formatDescription),
            context: "system audio sample buffer"
        )

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return }
        let inputBuffer = try makePCMBuffer(from: sampleBuffer, format: sourceFormat, frameCount: frameCount)

        let targetFormat = recordingTargetFormat
        if !loggedCaptureFormat {
            loggedCaptureFormat = true
            os_log(
                .info,
                log: systemAudioRecordingLog,
                "system audio format source=%{public}@ %.0fHz %u ch interleaved=%{public}@ target=%{public}@ %.0fHz %u ch interleaved=%{public}@ conversion=%{public}@",
                String(describing: sourceFormat.commonFormat),
                sourceFormat.sampleRate,
                sourceFormat.channelCount,
                String(sourceFormat.isInterleaved),
                String(describing: targetFormat.commonFormat),
                targetFormat.sampleRate,
                targetFormat.channelCount,
                String(targetFormat.isInterleaved),
                String(sourceFormat != targetFormat)
            )
        }
        if activeAudioFile == nil {
            let settings = pcmFileSettings(for: targetFormat)
            let audioFile = try AVAudioFile(
                forWriting: outputURL,
                settings: settings,
                commonFormat: targetFormat.commonFormat,
                interleaved: targetFormat.isInterleaved
            )
            activeAudioFile = audioFile
            os_log(.info, log: systemAudioRecordingLog, "system audio file writer created at %{public}@", outputURL.path)
        }

        guard let activeAudioFile else {
            throw SystemAudioRecorderError.failedToBeginFileRecording("Audio file writer was not initialized.")
        }

        if sourceFormat == targetFormat {
            try activeAudioFile.write(from: inputBuffer)
            recordedFrameCount += AVAudioFramePosition(inputBuffer.frameLength)
            return
        }

        let outputBuffer = try convertRecordingBuffer(
            inputBuffer,
            from: sourceFormat,
            to: targetFormat
        )
        guard outputBuffer.frameLength > 0 else { return }
        try activeAudioFile.write(from: outputBuffer)
        recordedFrameCount += AVAudioFramePosition(outputBuffer.frameLength)
    }

    private func validatedPCMBufferFormat(
        _ format: AVAudioFormat,
        context: String
    ) throws -> AVAudioFormat {
        let isPCM = format.commonFormat == .pcmFormatFloat32
            || format.commonFormat == .pcmFormatFloat64
            || format.commonFormat == .pcmFormatInt16
            || format.commonFormat == .pcmFormatInt32

        guard isPCM else {
            throw SystemAudioRecorderError.invalidInputFormat(
                "\(context) is not PCM (commonFormat=\(String(describing: format.commonFormat)), settings=\(format.settings))."
            )
        }

        guard format.channelCount > 0 else {
            throw SystemAudioRecorderError.invalidInputFormat(
                "\(context) reported zero channels."
            )
        }

        guard format.sampleRate > 0 else {
            throw SystemAudioRecorderError.invalidInputFormat(
                "\(context) reported an invalid sample rate (\(format.sampleRate))."
            )
        }

        return format
    }

    private func pcmFileSettings(for format: AVAudioFormat) -> [String: Any] {
        let isFloat = isFloatFormat(format.commonFormat)
        let bitDepth = bitDepth(for: format.commonFormat)

        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: isFloat,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !format.isInterleaved,
        ]
    }

    private func isFloatFormat(_ commonFormat: AVAudioCommonFormat) -> Bool {
        commonFormat == .pcmFormatFloat32 || commonFormat == .pcmFormatFloat64
    }

    private func bitDepth(for commonFormat: AVAudioCommonFormat) -> Int {
        switch commonFormat {
        case .pcmFormatFloat64:
            64
        case .pcmFormatFloat32, .pcmFormatInt32:
            32
        case .pcmFormatInt16:
            16
        default:
            0
        }
    }

    private func makePCMBuffer(
        from sampleBuffer: CMSampleBuffer,
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw SystemAudioRecorderError.failedToBeginFileRecording("Could not allocate PCM buffer for format \(format.settings).")
        }
        inputBuffer.frameLength = frameCount
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: inputBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            throw SystemAudioRecorderError.failedToBeginFileRecording("Could not copy sample buffer data (OSStatus \(copyStatus)).")
        }
        return inputBuffer
    }

    private struct ConversionResult {
        let buffer: AVAudioPCMBuffer
        let status: String
    }

    private func convertRecordingBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        from sourceFormat: AVAudioFormat,
        to targetFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let converter = recordingConverterLock.withLock { existing -> AVAudioConverter? in
            if let existing, existing.inputFormat == sourceFormat {
                return existing
            }
            let new = AVAudioConverter(from: sourceFormat, to: targetFormat)
            existing = new
            return new
        }
        guard let converter else {
            throw SystemAudioRecorderError.failedToBeginFileRecording("Could not create recording converter.")
        }

        return try convertBuffer(
            inputBuffer,
            from: sourceFormat,
            using: converter,
            to: targetFormat
        ).buffer
    }

    private func convertBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        from sourceFormat: AVAudioFormat,
        using converter: AVAudioConverter,
        to targetFormat: AVAudioFormat
    ) throws -> ConversionResult {
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            throw SystemAudioRecorderError.failedToBeginFileRecording("Could not allocate converted audio buffer.")
        }

        var suppliedInput = false
        var converterError: NSError?
        let status = converter.convert(to: outputBuffer, error: &converterError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        if let converterError {
            throw SystemAudioRecorderError.failedToBeginFileRecording("Audio conversion failed: \(converterError.localizedDescription)")
        }
        guard status != .error, outputBuffer.frameLength > 0 else {
            throw SystemAudioRecorderError.failedToBeginFileRecording("Audio conversion produced no data.")
        }
        return ConversionResult(buffer: outputBuffer, status: String(describing: status))
    }

    private func updateAudioLevel(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return 0 }
        guard let sourceFormat = try? validatedPCMBufferFormat(
            AVAudioFormat(cmAudioFormatDescription: formatDescription),
            context: "system audio level sample buffer"
        ) else { return 0 }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return 0 }
        guard let inputBuffer = try? makePCMBuffer(
            from: sampleBuffer,
            format: sourceFormat,
            frameCount: frameCount
        ) else { return 0 }

        let rms = rmsLevel(for: inputBuffer)
        let normalizedDisplayLevel = liveLevelNormalizerLock.withLock {
            $0.normalizedLevel(forRMS: rms)
        }

        DispatchQueue.main.async {
            self.audioLevel = normalizedDisplayLevel
        }
        return rms
    }

    private func rmsLevel(for buffer: AVAudioPCMBuffer) -> Float {
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)

        var totalSamples = 0
        var sumOfSquares: Double = 0

        for audioBuffer in audioBuffers {
            guard let baseAddress = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else {
                continue
            }

            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:
                let samples = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
                let pointer = baseAddress.assumingMemoryBound(to: Float.self)
                totalSamples += samples
                for index in 0..<samples {
                    let sample = Double(pointer[index])
                    sumOfSquares += sample * sample
                }
            case .pcmFormatFloat64:
                let samples = Int(audioBuffer.mDataByteSize) / MemoryLayout<Double>.size
                let pointer = baseAddress.assumingMemoryBound(to: Double.self)
                totalSamples += samples
                for index in 0..<samples {
                    let sample = pointer[index]
                    sumOfSquares += sample * sample
                }
            case .pcmFormatInt16:
                let samples = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
                let pointer = baseAddress.assumingMemoryBound(to: Int16.self)
                totalSamples += samples
                for index in 0..<samples {
                    let sample = Double(pointer[index]) / 32768.0
                    sumOfSquares += sample * sample
                }
            case .pcmFormatInt32:
                let samples = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size
                let pointer = baseAddress.assumingMemoryBound(to: Int32.self)
                totalSamples += samples
                for index in 0..<samples {
                    let sample = Double(pointer[index]) / 2147483648.0
                    sumOfSquares += sample * sample
                }
            default:
                continue
            }
        }

        guard totalSamples > 0 else { return 0 }
        return Float(sqrt(sumOfSquares / Double(totalSamples)))
    }

    private func emitPCM16IfNeeded(from sampleBuffer: CMSampleBuffer) {
        guard let handler = onPCM16Samples else { return }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }
        guard let sourceFormat = try? validatedPCMBufferFormat(
            AVAudioFormat(cmAudioFormatDescription: formatDescription),
            context: "system audio realtime sample buffer"
        ) else {
            return
        }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return }

        if pcm16InputFormat != sourceFormat {
            pcm16InputFormat = sourceFormat
            pcm16InputBuffer = nil
            pcm16OutputBuffer = nil
        }

        if pcm16InputBuffer == nil || pcm16InputBuffer?.frameCapacity ?? 0 < frameCount {
            pcm16InputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)
        }
        guard let inputBuffer = pcm16InputBuffer else { return }
        inputBuffer.frameLength = frameCount
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: inputBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return }

        let converter = pcm16ConverterLock.withLock { existing -> AVAudioConverter? in
            if let existing, existing.inputFormat == sourceFormat {
                return existing
            }
            let new = AVAudioConverter(from: sourceFormat, to: pcm16TargetFormat)
            existing = new
            return new
        }
        guard let converter else { return }

        let sourceRate = sourceFormat.sampleRate
        guard sourceRate > 0 else { return }
        let ratio = pcm16TargetFormat.sampleRate / sourceRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(frameCount) * ratio)) + 32
        if pcm16OutputBuffer == nil || pcm16OutputBuffer?.frameCapacity ?? 0 < outputCapacity {
            pcm16OutputBuffer = AVAudioPCMBuffer(
                pcmFormat: pcm16TargetFormat,
                frameCapacity: outputCapacity
            )
        }
        guard let outputBuffer = pcm16OutputBuffer else { return }
        outputBuffer.frameLength = 0

        var suppliedInput = false
        var converterError: NSError?
        let status = converter.convert(to: outputBuffer, error: &converterError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error, converterError == nil else { return }

        let outputFrames = Int(outputBuffer.frameLength)
        guard outputFrames > 0, let int16Ptr = outputBuffer.int16ChannelData?[0] else {
            return
        }
        let byteCount = outputFrames * MemoryLayout<Int16>.size
        let data = Data(bytes: int16Ptr, count: byteCount)
        handler(data)
    }
}
