import AVFoundation
import os.log
import Speech

private let analyzerLog = OSLog(subsystem: "com.woosublee.quill", category: "AppleSpeechAnalyzer")

// MARK: - Engine selection

/// Apple's speech engines. `speechAnalyzer` is the macOS 26 SpeechAnalyzer +
/// SpeechTranscriber model; `legacyRecognizer` is SFSpeechRecognizer.
enum AppleSpeechEngine: Equatable {
    case speechAnalyzer
    case legacyRecognizer
}

/// Mirrors `AssetInventory.Status` so selection stays testable on any OS.
enum AppleSpeechAssetState: Equatable {
    case unsupported
    case supported
    case downloading
    case installed
}

enum AppleSpeechEngineSelection {
    struct Decision: Equatable {
        let engine: AppleSpeechEngine
        /// True when the language can use SpeechAnalyzer once Apple's system
        /// assets are downloaded; the current session still uses the legacy engine.
        let shouldInstallAssets: Bool
    }

    static func decide(
        analyzerAvailable: Bool,
        localeSupported: Bool,
        assetState: AppleSpeechAssetState
    ) -> Decision {
        guard analyzerAvailable, localeSupported else {
            return Decision(engine: .legacyRecognizer, shouldInstallAssets: false)
        }
        switch assetState {
        case .installed:
            return Decision(engine: .speechAnalyzer, shouldInstallAssets: false)
        case .supported:
            // Never block recording on a download: use the legacy engine now.
            return Decision(engine: .legacyRecognizer, shouldInstallAssets: true)
        case .downloading, .unsupported:
            return Decision(engine: .legacyRecognizer, shouldInstallAssets: false)
        }
    }
}

/// Accumulates SpeechTranscriber results: finalized segments are appended,
/// the latest volatile segment replaces the previous one.
struct AppleSpeechProgressiveTranscript {
    private(set) var finalizedText = ""
    private(set) var volatileText = ""

    var text: String { finalizedText + volatileText }

    mutating func apply(text: String, isFinal: Bool) {
        if isFinal {
            finalizedText += text
            volatileText = ""
        } else {
            volatileText = text
        }
    }
}

// MARK: - Live routing

/// Picks SpeechAnalyzer on macOS 26+ when the language is ready, otherwise the
/// SFSpeechRecognizer transcriber. The choice happens in `start(locale:)`.
final class AppleSpeechRoutingLiveTranscriber: LiveTranscriber, @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var onPartialResult: (@Sendable (String) -> Void)?
        var onAudioLevel: (@Sendable (Float) -> Void)?
        var active: (any LiveTranscriber)?
        var cancelled = false
    }

    private let stateLock = OSAllocatedUnfairLock(initialState: State())

    var onPartialResult: (@Sendable (String) -> Void)? {
        get { stateLock.withLock { $0.onPartialResult } }
        set {
            let active = stateLock.withLock { state -> (any LiveTranscriber)? in
                state.onPartialResult = newValue
                return state.active
            }
            active?.onPartialResult = newValue
        }
    }

    var onAudioLevel: (@Sendable (Float) -> Void)? {
        get { stateLock.withLock { $0.onAudioLevel } }
        set {
            let active = stateLock.withLock { state -> (any LiveTranscriber)? in
                state.onAudioLevel = newValue
                return state.active
            }
            active?.onAudioLevel = newValue
        }
    }

    let handlesRecording = false
    var recordedAudioURL: URL? { nil }

    func start(locale: Locale) async throws {
        #if compiler(>=6.2)
        if #available(macOS 26, *),
           let analyzerLocale = await AppleSpeechAnalyzerSupport.readyLocale(for: locale) {
            let analyzer = AppleSpeechAnalyzerLiveTranscriber(analyzerLocale: analyzerLocale)
            guard adopt(analyzer) else { return }
            do {
                try await analyzer.start(locale: locale)
                return
            } catch AppleSpeechError.notAuthorized {
                throw AppleSpeechError.notAuthorized
            } catch {
                let nsError = error as NSError
                os_log(.error, log: analyzerLog,
                       "SpeechAnalyzer live start failed domain=%{public}@ code=%ld; using SFSpeechRecognizer",
                       nsError.domain, nsError.code)
                analyzer.cancel()
            }
        }
        #endif
        let legacy = AppleSpeechLiveTranscriber()
        guard adopt(legacy) else { return }
        try await legacy.start(locale: locale)
    }

    func appendPCM16(_ data: Data) {
        stateLock.withLock { $0.active }?.appendPCM16(data)
    }

    func finalize() async throws -> String {
        guard let active = stateLock.withLock({ $0.active }) else { return "" }
        return try await active.finalize()
    }

    func cancel() {
        let active = stateLock.withLock { state -> (any LiveTranscriber)? in
            state.cancelled = true
            return state.active
        }
        active?.cancel()
    }

    /// Makes `transcriber` the active engine unless this router was cancelled.
    private func adopt(_ transcriber: any LiveTranscriber) -> Bool {
        let adopted = stateLock.withLock { state -> Bool in
            guard !state.cancelled else { return false }
            transcriber.onPartialResult = state.onPartialResult
            transcriber.onAudioLevel = state.onAudioLevel
            state.active = transcriber
            return true
        }
        if !adopted { transcriber.cancel() }
        return adopted
    }
}

#if compiler(>=6.2)

// MARK: - SpeechAnalyzer support

@available(macOS 26, *)
enum AppleSpeechAnalyzerSupport {
    private static let installingLocales = OSAllocatedUnfairLock(initialState: Set<String>())

    /// The SpeechTranscriber locale for `locale` when its assets are installed.
    /// Returns nil when the legacy engine should be used; if the language only
    /// needs Apple's system assets, their download starts in the background.
    static func readyLocale(for locale: Locale) async -> Locale? {
        let analyzerAvailable = SpeechTranscriber.isAvailable
        let supportedLocale = analyzerAvailable
            ? await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            : nil
        var assetState = AppleSpeechAssetState.unsupported
        if let supportedLocale {
            let probe = SpeechTranscriber(locale: supportedLocale, preset: .transcription)
            assetState = Self.assetState(for: await AssetInventory.status(forModules: [probe]))
        }
        let decision = AppleSpeechEngineSelection.decide(
            analyzerAvailable: analyzerAvailable,
            localeSupported: supportedLocale != nil,
            assetState: assetState
        )
        os_log(.default, log: analyzerLog,
               "engine=%{public}@ locale=%{public}@ installAssets=%d",
               decision.engine == .speechAnalyzer ? "SpeechAnalyzer" : "SFSpeechRecognizer",
               locale.identifier, decision.shouldInstallAssets)
        if decision.shouldInstallAssets, let supportedLocale {
            installAssetsInBackground(for: supportedLocale)
        }
        return decision.engine == .speechAnalyzer ? supportedLocale : nil
    }

    /// Transcribes a whole audio file with SpeechTranscriber on this Mac.
    static func transcribeFile(_ fileURL: URL, locale: Locale) async throws -> String {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let audioFile = try AVAudioFile(forReading: fileURL)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var transcript = AppleSpeechProgressiveTranscript()
            for try await result in transcriber.results {
                transcript.apply(text: String(result.text.characters), isFinal: result.isFinal)
            }
            return transcript.text
        }
        do {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func assetState(for status: AssetInventory.Status) -> AppleSpeechAssetState {
        switch status {
        case .installed: return .installed
        case .supported: return .supported
        case .downloading: return .downloading
        default: return .unsupported
        }
    }

    /// Asks macOS to download the language model. Only the model comes from
    /// Apple; no audio or transcript is sent.
    private static func installAssetsInBackground(for locale: Locale) {
        let identifier = locale.identifier
        guard installingLocales.withLock({ $0.insert(identifier).inserted }) else { return }
        Task.detached(priority: .utility) {
            defer { _ = installingLocales.withLock { $0.remove(identifier) } }
            let module = SpeechTranscriber(locale: locale, preset: .transcription)
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    try await request.downloadAndInstall()
                }
                os_log(.default, log: analyzerLog, "assets installed locale=%{public}@", identifier)
            } catch {
                let nsError = error as NSError
                os_log(.error, log: analyzerLog,
                       "asset install failed locale=%{public}@ domain=%{public}@ code=%ld",
                       identifier, nsError.domain, nsError.code)
            }
        }
    }
}

// MARK: - SpeechAnalyzer live transcription

@available(macOS 26, *)
final class AppleSpeechAnalyzerLiveTranscriber: LiveTranscriber, @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var onPartialResult: (@Sendable (String) -> Void)?
        var onAudioLevel: (@Sendable (Float) -> Void)?
        var analyzer: SpeechAnalyzer?
        var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
        var converter: AVAudioConverter?
        var resultsTask: Task<Void, Never>?
        var transcript = AppleSpeechProgressiveTranscript()
        var resultsError: Error?
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

    private let analyzerLocale: Locale
    private let stateLock = OSAllocatedUnfairLock(initialState: State())
    private let levelNormalizerLock = OSAllocatedUnfairLock(initialState: LiveAudioLevelNormalizer())

    // Same bound as the SFSpeechRecognizer transcriber.
    private static let finalizeTimeoutSeconds: TimeInterval = 10

    /// Quill streams 24 kHz mono PCM16 to live transcribers.
    private static let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: true
    )

    init(analyzerLocale: Locale) {
        self.analyzerLocale = analyzerLocale
    }

    func start(locale: Locale) async throws {
        let authStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard authStatus == .authorized else {
            throw AppleSpeechError.notAuthorized
        }

        let transcriber = SpeechTranscriber(
            locale: analyzerLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        guard let inputFormat = Self.inputFormat,
              let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
            throw AppleSpeechError.notAvailable(analyzerLocale.identifier)
        }

        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        let resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.handleResult(text: String(result.text.characters), isFinal: result.isFinal)
                }
            } catch {
                self?.stateLock.withLock { $0.resultsError = error }
            }
        }

        let shouldStart = stateLock.withLock { state -> Bool in
            guard !state.cancelled else { return false }
            state.analyzer = analyzer
            state.inputContinuation = inputContinuation
            state.converter = converter
            state.resultsTask = resultsTask
            return true
        }
        guard shouldStart else {
            inputContinuation.finish()
            resultsTask.cancel()
            return
        }

        os_log(.default, log: analyzerLog, "analysis starting locale=%{public}@", analyzerLocale.identifier)
        try await analyzer.start(inputSequence: inputSequence)
    }

    func appendPCM16(_ data: Data) {
        let appendResult = stateLock.withLock { state -> (level: Float, callback: @Sendable (Float) -> Void)? in
            guard let continuation = state.inputContinuation,
                  let converter = state.converter,
                  let input = Self.convertedBuffer(fromPCM16: data, using: converter) else {
                return nil
            }
            continuation.yield(AnalyzerInput(buffer: input))
            guard let callback = state.onAudioLevel else { return nil }
            return (normalizedLevel(fromPCM16: data), callback)
        }
        guard let appendResult else { return }
        appendResult.callback(appendResult.level)
    }

    func finalize() async throws -> String {
        os_log(.default, log: analyzerLog, "finalize() called")
        let (continuation, analyzer, resultsTask) = stateLock.withLock { state in
            defer {
                state.inputContinuation = nil
                state.converter = nil
            }
            return (state.inputContinuation, state.analyzer, state.resultsTask)
        }
        continuation?.finish()

        if let analyzer {
            // If finishing stalls, stop the analyzer so its results sequence ends
            // and the transcript gathered so far is returned.
            let timeout = Task {
                try await Task.sleep(nanoseconds: UInt64(Self.finalizeTimeoutSeconds * 1_000_000_000))
                os_log(.default, log: analyzerLog, "finalize timeout — returning transcript so far")
                resultsTask?.cancel()
                await analyzer.cancelAndFinishNow()
            }
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                let nsError = error as NSError
                os_log(.error, log: analyzerLog, "finalize failed domain=%{public}@ code=%ld",
                       nsError.domain, nsError.code)
            }
            await resultsTask?.value
            timeout.cancel()
        }

        let (text, resultsError) = stateLock.withLock { ($0.transcript.text, $0.resultsError) }
        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if transcript.isEmpty, let resultsError, !(resultsError is CancellationError) {
            throw resultsError
        }
        return transcript
    }

    func cancel() {
        let cancellation = stateLock.withLock { state -> (
            analyzer: SpeechAnalyzer?,
            continuation: AsyncStream<AnalyzerInput>.Continuation?,
            resultsTask: Task<Void, Never>?,
            callback: (@Sendable (Float) -> Void)?
        ) in
            state.cancelled = true
            let result = (state.analyzer, state.inputContinuation, state.resultsTask, state.onAudioLevel)
            state.analyzer = nil
            state.inputContinuation = nil
            state.converter = nil
            state.resultsTask = nil
            return result
        }
        cancellation.callback?(0)
        cancellation.continuation?.finish()
        cancellation.resultsTask?.cancel()
        if let analyzer = cancellation.analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private func handleResult(text: String, isFinal: Bool) {
        let (partial, callback) = stateLock.withLock { state -> (String, (@Sendable (String) -> Void)?) in
            state.transcript.apply(text: text, isFinal: isFinal)
            return (state.transcript.text, state.onPartialResult)
        }
        callback?(partial)
    }

    private func normalizedLevel(fromPCM16 data: Data) -> Float {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }
        var sumOfSquares: Float = 0
        data.withUnsafeBytes { rawBuffer in
            for sample in rawBuffer.bindMemory(to: Int16.self) {
                let normalized = Float(sample) / Float(Int16.max)
                sumOfSquares += normalized * normalized
            }
        }
        let rms = sqrtf(sumOfSquares / Float(sampleCount))
        return levelNormalizerLock.withLock {
            $0.normalizedLevel(forRMS: rms)
        }
    }

    /// Converts one PCM16 chunk to the analyzer's format. Each call returns a
    /// new buffer because the analyzer keeps it after `yield`.
    private static func convertedBuffer(
        fromPCM16 data: Data,
        using converter: AVAudioConverter
    ) -> AVAudioPCMBuffer? {
        let bytesPerFrame = MemoryLayout<Int16>.size
        guard !data.isEmpty, data.count % bytesPerFrame == 0 else { return nil }
        let frameCount = AVAudioFrameCount(data.count / bytesPerFrame)
        guard let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: frameCount),
              let channelData = input.int16ChannelData?[0] else {
            return nil
        }
        input.frameLength = frameCount
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            channelData.update(
                from: baseAddress.assumingMemoryBound(to: Int16.self),
                count: Int(frameCount)
            )
        }

        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount((Double(frameCount) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: outputCapacity) else {
            return nil
        }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

#endif
