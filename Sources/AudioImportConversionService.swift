import AVFoundation
import Foundation
import QuillAudioFormatCore

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

    /// `outputDirectory` is where a converted file is written (the system
    /// temporary directory when nil).
    func prepareForNativeWhisper(
        _ sourceURL: URL,
        outputDirectory: URL? = nil
    ) async throws -> PreparedNativeWhisperAudio {
        try Task.checkCancellation()
        if Self.isNativeWhisperCompatibleWAV(sourceURL) {
            return PreparedNativeWhisperAudio(fileURL: sourceURL)
        }

        let convert = self.convert
        let outputDirectory = outputDirectory ?? FileManager.default.temporaryDirectory
        let conversionTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            if let convert {
                return try convert(sourceURL)
            }
            return try Self.convertToNativeWhisperWAV(
                sourceURL,
                outputDirectory: outputDirectory
            )
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
    }

    /// The decoding itself is shared with the iPhone app
    /// (`CanonicalAudioFileConversion`); it writes the canonical recording.
    private static func convertToNativeWhisperWAV(
        _ sourceURL: URL,
        outputDirectory: URL
    ) throws -> PreparedNativeWhisperAudio {
        let outputURL = outputDirectory
            .appendingPathComponent("quill-native-whisper-import-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        do {
            // As before the decoder was shared: the first channel of a stereo
            // file, and an empty file passes on as an empty recording.
            try CanonicalAudioFileConversion.convert(
                sourceURL,
                to: outputURL,
                mixesChannels: false,
                allowsEmpty: true
            )
        } catch let error as CanonicalAudioFileConversionError {
            switch error {
            case .unreadable:
                throw AudioImportConversionError.unreadableAudio(sourceURL.lastPathComponent)
            case .converterUnavailable:
                throw AudioImportConversionError.converterUnavailable
            case .empty:
                throw AudioImportConversionError.conversionFailed("The file has no audio.")
            case .tooLong:
                throw AudioImportConversionError.conversionFailed("The file is too long.")
            case .conversionFailed(let reason):
                throw AudioImportConversionError.conversionFailed(reason)
            }
        }
        return PreparedNativeWhisperAudio(fileURL: outputURL, temporaryFileURL: outputURL)
    }
}
