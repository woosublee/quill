import AVFoundation
import Foundation

@main
struct AudioImportConversionServiceTests {
    static func main() async throws {
        try await testCompatibleWAVReturnsOriginalURL()
        try await testReadableNonNativeWAVConvertsToNativeWhisperShape()
        try await testInvalidAudioThrowsReadableLocalConversionError()
        try await testCancellationCancelsWorkerConversionTask()
        print("AudioImportConversionServiceTests passed")
    }

    private static func testCompatibleWAVReturnsOriginalURL() async throws {
        let sourceURL = try writeTinyNativeWAV(samples: [100, -100, 200])
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let prepared = try await AudioImportConversionService().prepareForNativeWhisper(sourceURL)

        try expectEqual(prepared.fileURL.standardizedFileURL, sourceURL.standardizedFileURL, "compatible WAV should be reused")
        prepared.cleanup()
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw TestFailure("cleanup must not remove the original compatible WAV")
        }
    }

    private static func testReadableNonNativeWAVConvertsToNativeWhisperShape() async throws {
        let sourceURL = try writeStereoFloatWAV(sampleRate: 44_100, frameCount: 4_410)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let prepared = try await AudioImportConversionService().prepareForNativeWhisper(sourceURL)
        defer { prepared.cleanup() }

        guard prepared.fileURL.pathExtension == "wav" else {
            throw TestFailure("expected converted file to use .wav, got \(prepared.fileURL.lastPathComponent)")
        }
        guard prepared.fileURL.standardizedFileURL != sourceURL.standardizedFileURL else {
            throw TestFailure("non-native source should be converted to a temporary WAV")
        }

        let convertedFile = try AVAudioFile(forReading: prepared.fileURL)
        let convertedFormat = convertedFile.fileFormat
        try expectEqual(Int(convertedFormat.sampleRate.rounded()), 16_000, "converted sample rate")
        try expectEqual(convertedFormat.channelCount, 1, "converted channel count")
        guard convertedFormat.commonFormat == .pcmFormatInt16 else {
            throw TestFailure("expected converted common format pcmFormatInt16, got \(convertedFormat.commonFormat)")
        }
        guard convertedFormat.isInterleaved else {
            throw TestFailure("expected converted WAV to be interleaved")
        }
        guard convertedFile.length > 0 else {
            throw TestFailure("converted file should contain audio frames")
        }
    }

    private static func testInvalidAudioThrowsReadableLocalConversionError() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-invalid-import-\(ProcessInfo.processInfo.globallyUniqueString)")
            .appendingPathExtension("webm")
        try Data("not an audio file".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        do {
            _ = try await AudioImportConversionService().prepareForNativeWhisper(sourceURL)
            throw TestFailure("invalid audio should throw AudioImportConversionError.unreadableAudio")
        } catch AudioImportConversionError.unreadableAudio(let path) {
            guard path.contains(sourceURL.lastPathComponent) else {
                throw TestFailure("error should include the file name, got \(path)")
            }
        } catch {
            throw TestFailure("expected unreadableAudio, got \(error)")
        }
    }

    private static func testCancellationCancelsWorkerConversionTask() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-cancellable-import-\(ProcessInfo.processInfo.globallyUniqueString)")
            .appendingPathExtension("mp3")
        try Data("placeholder audio that forces injected conversion".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let workerStarted = ThreadSignal()
        let workerCancelled = ThreadSignal()
        let service = AudioImportConversionService { _ in
            workerStarted.signal()
            while !Task.isCancelled {
                Thread.sleep(forTimeInterval: 0.01)
            }
            workerCancelled.signal()
            throw CancellationError()
        }

        let task = Task {
            try await service.prepareForNativeWhisper(sourceURL)
        }
        try await workerStarted.wait()
        task.cancel()

        do {
            _ = try await task.value
            throw TestFailure("cancelled preparation should throw CancellationError")
        } catch is CancellationError {
        } catch {
            throw TestFailure("expected CancellationError, got \(error)")
        }

        try await workerCancelled.wait()
    }

    private static func writeTinyNativeWAV(samples: [Int16]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-native-wav-\(ProcessInfo.processInfo.globallyUniqueString)")
            .appendingPathExtension("wav")
        var data = Data()
        let sampleDataByteCount = UInt32(samples.count * MemoryLayout<Int16>.size)

        data.appendASCII("RIFF")
        data.appendUInt32LE(36 + sampleDataByteCount)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendUInt32LE(16)
        data.appendUInt16LE(1)
        data.appendUInt16LE(1)
        data.appendUInt32LE(16_000)
        data.appendUInt32LE(16_000 * 2)
        data.appendUInt16LE(2)
        data.appendUInt16LE(16)
        data.appendASCII("data")
        data.appendUInt32LE(sampleDataByteCount)
        for sample in samples {
            data.appendUInt16LE(UInt16(bitPattern: sample))
        }

        try data.write(to: url, options: .atomic)
        return url
    }

    private static func writeStereoFloatWAV(sampleRate: Double, frameCount: AVAudioFrameCount) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-stereo-float-\(ProcessInfo.processInfo.globallyUniqueString)")
            .appendingPathExtension("wav")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        )!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        for channel in 0..<Int(format.channelCount) {
            let channelData = buffer.floatChannelData![channel]
            for frame in 0..<Int(frameCount) {
                channelData[frame] = channel == 0 ? 0.25 : -0.25
            }
        }
        try file.write(from: buffer)
        return url
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
        guard actual == expected else {
            throw TestFailure("\(label): expected \(expected), got \(actual)")
        }
    }

    fileprivate struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}

private final class ThreadSignal: @unchecked Sendable {
    private let condition = NSCondition()
    private var signaled = false

    func signal() {
        condition.lock()
        signaled = true
        condition.broadcast()
        condition.unlock()
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Thread {
                let deadline = Date().addingTimeInterval(1)
                self.condition.lock()
                defer { self.condition.unlock() }

                while !self.signaled {
                    if !self.condition.wait(until: deadline) {
                        continuation.resume(throwing: AudioImportConversionServiceTests.TestFailure("timed out waiting for worker conversion task cancellation"))
                        return
                    }
                }
                continuation.resume()
            }.start()
        }
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0x00ff))
        append(UInt8((value & 0xff00) >> 8))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0x000000ff))
        append(UInt8((value & 0x0000ff00) >> 8))
        append(UInt8((value & 0x00ff0000) >> 16))
        append(UInt8((value & 0xff000000) >> 24))
    }
}
