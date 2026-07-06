import AVFoundation
import Foundation

struct PreparedNativeWhisperAudio {
    let fileURL: URL
    private let temporaryFileURL: URL?

    init(fileURL: URL, temporaryFileURL: URL? = nil) {
        self.fileURL = fileURL
        self.temporaryFileURL = temporaryFileURL
    }

    func cleanup() {
        guard let temporaryFileURL else { return }
        try? FileManager.default.removeItem(at: temporaryFileURL)
    }
}

enum AudioImportConversionError: LocalizedError {
    case unreadableAudio(String)
    case converterUnavailable
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableAudio(let path):
            return "Quill couldn't read this audio file for local transcription: \(path). Try API transcription, legacy mlx-whisper, or convert the file to MP3, M4A, MP4, or WAV."
        case .converterUnavailable:
            return "Quill couldn't prepare this audio file for native Local Whisper. Try API transcription or convert the file to MP3, M4A, MP4, or WAV."
        case .conversionFailed(let message):
            return "Quill couldn't prepare this audio file for native Local Whisper: \(message)"
        }
    }
}

struct AudioImportConversionService {
    private static let targetSampleRate: Double = 16_000
    private static let targetChannelCount: AVAudioChannelCount = 1

    private let convert: (@Sendable (URL) throws -> PreparedNativeWhisperAudio)?

    init(convert: (@Sendable (URL) throws -> PreparedNativeWhisperAudio)? = nil) {
        self.convert = convert
    }

    func prepareForNativeWhisper(_ sourceURL: URL) async throws -> PreparedNativeWhisperAudio {
        try Task.checkCancellation()
        if Self.isNativeWhisperCompatibleWAV(sourceURL) {
            return PreparedNativeWhisperAudio(fileURL: sourceURL)
        }

        let convert = self.convert
        let conversionTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            if let convert {
                return try convert(sourceURL)
            }
            return try Self.convertToNativeWhisperWAV(sourceURL)
        }

        return try await withTaskCancellationHandler {
            try await conversionTask.value
        } onCancel: {
            conversionTask.cancel()
        }
    }

    private static func isNativeWhisperCompatibleWAV(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "wav" else { return false }
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        let format = file.fileFormat
        return abs(format.sampleRate - targetSampleRate) < 0.5
            && format.channelCount == targetChannelCount
            && format.commonFormat == .pcmFormatInt16
            && format.isInterleaved
    }

    private static func convertToNativeWhisperWAV(_ sourceURL: URL) throws -> PreparedNativeWhisperAudio {
        let inputFile: AVAudioFile
        do {
            inputFile = try AVAudioFile(forReading: sourceURL)
        } catch {
            throw AudioImportConversionError.unreadableAudio(sourceURL.lastPathComponent)
        }

        let inputFormat = inputFile.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannelCount,
            interleaved: true
        ) else {
            throw AudioImportConversionError.converterUnavailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioImportConversionError.converterUnavailable
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-native-whisper-import-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        do {
            let outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: pcmFileSettings(for: targetFormat),
                commonFormat: targetFormat.commonFormat,
                interleaved: targetFormat.isInterleaved
            )

            var didFinish = false
            while !didFinish {
                try Task.checkCancellation()

                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4_096) else {
                    throw AudioImportConversionError.converterUnavailable
                }

                var readError: Error?
                var conversionError: NSError?
                let status = converter.convert(to: outputBuffer, error: &conversionError) { packetCount, outStatus in
                    guard inputFile.framePosition < inputFile.length else {
                        outStatus.pointee = .endOfStream
                        return nil
                    }

                    let remainingFrames = inputFile.length - inputFile.framePosition
                    let requestedFrames = AVAudioFrameCount(min(AVAudioFramePosition(packetCount), remainingFrames))
                    guard let inputBuffer = AVAudioPCMBuffer(
                        pcmFormat: inputFormat,
                        frameCapacity: max(requestedFrames, AVAudioFrameCount(1))
                    ) else {
                        outStatus.pointee = .noDataNow
                        return nil
                    }

                    do {
                        try inputFile.read(into: inputBuffer, frameCount: requestedFrames)
                    } catch {
                        readError = error
                        outStatus.pointee = .noDataNow
                        return nil
                    }

                    guard inputBuffer.frameLength > 0 else {
                        outStatus.pointee = .endOfStream
                        return nil
                    }

                    outStatus.pointee = .haveData
                    return inputBuffer
                }

                if let conversionError {
                    throw AudioImportConversionError.conversionFailed(conversionError.localizedDescription)
                }
                if let readError {
                    throw AudioImportConversionError.conversionFailed(readError.localizedDescription)
                }
                if outputBuffer.frameLength > 0 {
                    try outputFile.write(from: outputBuffer)
                }

                switch status {
                case .haveData, .inputRanDry:
                    continue
                case .endOfStream:
                    didFinish = true
                case .error:
                    throw AudioImportConversionError.conversionFailed("Audio conversion failed.")
                @unknown default:
                    throw AudioImportConversionError.conversionFailed("Audio conversion returned an unknown status.")
                }
            }

            return PreparedNativeWhisperAudio(fileURL: outputURL, temporaryFileURL: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static func pcmFileSettings(for format: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !format.isInterleaved,
        ]
    }
}
