import AVFoundation
import Foundation

/// Which audio files Quill imports into a note, the same on both apps.
/// Imported files are untrusted input: callers never log their names.
public enum AudioImportFileTypes {
    /// Every type the Mac imports. A cloud transcription uploads these as
    /// they are.
    public static let broadlySupportedExtensions: Set<String> = [
        "flac", "mp3", "mp4", "mpeg", "mpga", "m4a", "ogg", "wav", "webm"
    ]

    /// The types the system audio decoder reads, so Quill can turn them into
    /// the canonical recording on the device: the Mac's on-device imports,
    /// and every iPhone import (the iPhone stores and transcribes only the
    /// canonical recording).
    public static let decodableExtensions: Set<String> = [
        "mp3", "mp4", "mpeg", "mpga", "m4a", "wav"
    ]

    /// The lowercased extension of a file name.
    public static func fileExtension(of fileName: String) -> String {
        URL(fileURLWithPath: fileName).pathExtension.lowercased()
    }

    /// Whether the device can decode a file with this name into the
    /// canonical recording.
    public static func isDecodable(fileName: String) -> Bool {
        decodableExtensions.contains(fileExtension(of: fileName))
    }

    /// The extension a stored copy keeps: its own when Quill imports that
    /// type, otherwise `wav`.
    public static func storageExtension(for fileName: String) -> String {
        let ext = fileExtension(of: fileName)
        return broadlySupportedExtensions.contains(ext) ? ext : "wav"
    }
}

/// The span an imported file was recorded over, from the creation date
/// recorders write into the file and its length. With it the note sits at
/// its real recording time. Filesystem dates are not used: copying or
/// downloading a file changes them.
public struct AudioFileRecordingTime: Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public static func make(creationDate: Date?, duration: TimeInterval) -> AudioFileRecordingTime? {
        guard let creationDate, duration.isFinite, duration > 0 else { return nil }
        return AudioFileRecordingTime(start: creationDate, end: creationDate.addingTimeInterval(duration))
    }

    /// Reads metadata only; the audio is not decoded.
    public static func read(from url: URL) async -> AudioFileRecordingTime? {
        let asset = AVURLAsset(url: url)
        guard let item = try? await asset.load(.creationDate),
              let date = try? await item.load(.dateValue),
              let duration = try? await asset.load(.duration) else {
            return nil
        }
        return make(creationDate: date, duration: duration.seconds)
    }
}

public enum CanonicalAudioFileConversionError: Error, Equatable, Sendable {
    /// The system decoder can't open the file as audio.
    case unreadable
    /// The file holds no audio frames.
    case empty
    /// The canonical recording would be larger than its header can declare.
    case tooLong
    case converterUnavailable
    /// Decoding stopped partway. `reason` is the system's description, for
    /// the Mac's issue text; never log it with the file's name.
    case conversionFailed(reason: String)
}

/// What an audio file will become, read before decoding it.
public struct CanonicalAudioFileSource: Equatable, Sendable {
    public let duration: TimeInterval
    /// The PCM bytes the canonical recording is expected to hold.
    public let estimatedDataByteCount: UInt64

    public init(duration: TimeInterval, estimatedDataByteCount: UInt64) {
        self.duration = duration
        self.estimatedDataByteCount = estimatedDataByteCount
    }
}

/// Decodes any audio file the system reads (MP3, M4A, MP4, WAV in any
/// layout) into the canonical recording: 16 kHz mono 16-bit PCM with the
/// plain 44-byte header. The Mac
/// uses it for on-device transcription of an imported file, and the iPhone
/// to store an imported file as the note's recording.
public enum CanonicalAudioFileConversion {
    /// The largest PCM payload a canonical header can declare (its RIFF
    /// size is the payload plus 36 and must fit in 32 bits), in whole frames.
    public static let maximumDataByteCount: UInt64 = {
        let limit = UInt64(UInt32.max) - 36
        return limit - limit % UInt64(CanonicalPCM16WAV.bytesPerFrame)
    }()

    private static let targetSampleRate = Double(CanonicalPCM16WAV.sampleRate)
    private static let outputFrameCapacity: AVAudioFrameCount = 16_384

    /// The canonical bytes `frameCount` frames at `sampleRate` become.
    public static func estimatedDataByteCount(frameCount: Int64, sampleRate: Double) -> UInt64 {
        guard frameCount > 0, sampleRate.isFinite, sampleRate > 0 else { return 0 }
        let frames = (Double(frameCount) * targetSampleRate / sampleRate).rounded(.up)
        let bytes = frames * Double(CanonicalPCM16WAV.bytesPerFrame)
        guard bytes.isFinite, bytes < Double(UInt64.max / 2) else { return UInt64.max }
        return UInt64(bytes)
    }

    /// Reads the file's length without decoding it. The size is an estimate
    /// (a compressed file's length is), so `convert` still checks the real
    /// size against the limit.
    public static func inspect(_ sourceURL: URL) throws -> CanonicalAudioFileSource {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: sourceURL)
        } catch {
            throw CanonicalAudioFileConversionError.unreadable
        }
        let sampleRate = file.processingFormat.sampleRate
        guard file.length > 0, sampleRate > 0 else {
            throw CanonicalAudioFileConversionError.empty
        }
        let estimated = estimatedDataByteCount(frameCount: file.length, sampleRate: sampleRate)
        guard estimated <= maximumDataByteCount else {
            throw CanonicalAudioFileConversionError.tooLong
        }
        return CanonicalAudioFileSource(
            duration: Double(file.length) / sampleRate,
            estimatedDataByteCount: estimated
        )
    }

    /// Writes the canonical recording of `sourceURL` to `destinationURL`, a
    /// new path of the caller's (anything already there is replaced, and
    /// removed if the conversion fails). Stops with `CancellationError` when
    /// the calling task is cancelled. `progress` gets the share of the source
    /// read so far, from 0 to 1, and ends at 1. No partial output is left
    /// behind on failure.
    ///
    /// - Parameters:
    ///   - mixesChannels: mixes every channel into the mono recording, as the
    ///     iPhone's recorder does. Off, a stereo file keeps only its first
    ///     channel, as the Mac's on-device import always has.
    ///   - allowsEmpty: writes an empty recording for a file with no audio
    ///     (the Mac's on-device import passes it on) instead of throwing
    ///     `.empty`.
    @discardableResult
    public static func convert(
        _ sourceURL: URL,
        to destinationURL: URL,
        mixesChannels: Bool = true,
        allowsEmpty: Bool = false,
        progress: ((Double) -> Void)? = nil
    ) throws -> CanonicalPCM16WAVLayout {
        let inputFile: AVAudioFile
        do {
            inputFile = try AVAudioFile(forReading: sourceURL)
        } catch {
            throw CanonicalAudioFileConversionError.unreadable
        }
        guard inputFile.length > 0 || allowsEmpty else {
            throw CanonicalAudioFileConversionError.empty
        }
        let inputFormat = inputFile.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: AVAudioChannelCount(CanonicalPCM16WAV.channelCount),
            interleaved: true
        ),
            let converter = AVAudioConverter(from: inputFormat, to: targetFormat),
            let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            throw CanonicalAudioFileConversionError.converterUnavailable
        }
        converter.downmix = mixesChannels

        try? FileManager.default.removeItem(at: destinationURL)
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw CanonicalAudioFileConversionError.conversionFailed(reason: "The output file couldn't be created.")
        }
        var keepsOutput = false
        defer {
            if !keepsOutput { try? FileManager.default.removeItem(at: destinationURL) }
        }
        let output: FileHandle
        do {
            output = try FileHandle(forWritingTo: destinationURL)
        } catch {
            throw CanonicalAudioFileConversionError.conversionFailed(reason: error.localizedDescription)
        }
        defer { try? output.close() }

        var dataByteCount: UInt64 = 0
        do {
            // A placeholder header; the real one is written once the size is known.
            try output.write(contentsOf: CanonicalPCM16WAV.header(dataByteCount: 0))
            let length = inputFile.length
            var didFinish = false
            while !didFinish {
                try Task.checkCancellation()
                outputBuffer.frameLength = 0
                var readError: Error?
                var conversionError: NSError?
                let status = converter.convert(to: outputBuffer, error: &conversionError) { packetCount, inputStatus in
                    guard inputFile.framePosition < length else {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    let remaining = length - inputFile.framePosition
                    let requested = AVAudioFrameCount(min(AVAudioFramePosition(packetCount), remaining))
                    guard let inputBuffer = AVAudioPCMBuffer(
                        pcmFormat: inputFormat,
                        frameCapacity: max(requested, 1)
                    ) else {
                        readError = CanonicalAudioFileConversionError.converterUnavailable
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    do {
                        try inputFile.read(into: inputBuffer, frameCount: requested)
                    } catch {
                        readError = error
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    guard inputBuffer.frameLength > 0 else {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    inputStatus.pointee = .haveData
                    return inputBuffer
                }
                if let conversionError {
                    throw CanonicalAudioFileConversionError.conversionFailed(reason: conversionError.localizedDescription)
                }
                if let readError {
                    throw CanonicalAudioFileConversionError.conversionFailed(reason: readError.localizedDescription)
                }
                if outputBuffer.frameLength > 0 {
                    let chunk = try pcmData(from: outputBuffer)
                    guard dataByteCount + UInt64(chunk.count) <= maximumDataByteCount else {
                        throw CanonicalAudioFileConversionError.tooLong
                    }
                    try output.write(contentsOf: chunk)
                    dataByteCount += UInt64(chunk.count)
                }
                switch status {
                case .haveData, .inputRanDry:
                    break
                case .endOfStream:
                    didFinish = true
                case .error:
                    throw CanonicalAudioFileConversionError.conversionFailed(reason: "Audio conversion failed.")
                @unknown default:
                    throw CanonicalAudioFileConversionError.conversionFailed(
                        reason: "Audio conversion returned an unknown status."
                    )
                }
                if !didFinish, length > 0 {
                    progress?(min(1, Double(inputFile.framePosition) / Double(length)))
                }
            }
            guard dataByteCount > 0 || allowsEmpty else {
                throw CanonicalAudioFileConversionError.empty
            }
            try output.seek(toOffset: 0)
            try output.write(contentsOf: CanonicalPCM16WAV.header(dataByteCount: UInt32(dataByteCount)))
            try output.synchronize()
            // A compressed file's length is an estimate, so the last read can
            // stop short of it.
            progress?(1)
        } catch let error as CanonicalAudioFileConversionError {
            throw error
        } catch let error as CancellationError {
            throw error
        } catch {
            throw CanonicalAudioFileConversionError.conversionFailed(reason: error.localizedDescription)
        }

        let layout: CanonicalPCM16WAVLayout
        do {
            layout = try CanonicalPCM16WAV.validateFile(at: destinationURL, requireNonEmpty: !allowsEmpty)
        } catch {
            throw CanonicalAudioFileConversionError.conversionFailed(reason: "The converted file isn't a canonical recording.")
        }
        keepsOutput = true
        return layout
    }

    private static func pcmData(from buffer: AVAudioPCMBuffer) throws -> Data {
        let byteCount = Int(buffer.frameLength) * Int(CanonicalPCM16WAV.bytesPerFrame)
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        guard buffer.audioBufferList.pointee.mNumberBuffers == 1,
              let bytes = audioBuffer.mData,
              Int(audioBuffer.mDataByteSize) >= byteCount else {
            throw CanonicalAudioFileConversionError.conversionFailed(reason: "The converted audio has an unexpected layout.")
        }
        // Apple platforms are little-endian, the canonical byte order.
        return Data(bytes: bytes, count: byteCount)
    }
}
