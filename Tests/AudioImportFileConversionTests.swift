import AVFoundation
import Foundation
import QuillAudioFormatCore

/// The shared import rules and the decoder both apps use for an imported
/// file. Every file here is a synthetic tone written by the test.
@main
struct AudioImportFileConversionTests {
    static func main() async throws {
        try testImportTypes()
        try testRecordingTimeNeedsEmbeddedDateAndLength()
        try testStereoFloatWAVBecomesCanonicalRecording()
        try testAACM4ABecomesCanonicalRecording()
        try testInspectEstimatesTheCanonicalSize()
        try testUnreadableFileIsRejectedWithoutOutput()
        try testEmptyFileIsRejected()
        try testMacKeepsAnEmptyFileAsAnEmptyRecording()
        try testChannelMixingIsTheCallersChoice()
        try await testCancellationLeavesNoOutput()
        print("AudioImportFileConversionTests passed")
    }

    private static func testImportTypes() throws {
        for name in ["a.mp3", "b.M4A", "c.mp4", "d.mpeg", "e.mpga", "f.WAV"] {
            try expect(AudioImportFileTypes.isDecodable(fileName: name), "\(name) decodes on the device")
        }
        for name in ["a.flac", "b.ogg", "c.webm", "d.txt", "e", "f.m4a.zip"] {
            try expect(!AudioImportFileTypes.isDecodable(fileName: name), "\(name) doesn't decode on the device")
        }
        try expect(AudioImportFileTypes.decodableExtensions.isSubset(of: AudioImportFileTypes.broadlySupportedExtensions),
                   "every decodable type is an import type")
        try expect(AudioImportFileTypes.storageExtension(for: "x.OGG") == "ogg", "keeps a known extension")
        try expect(AudioImportFileTypes.storageExtension(for: "x.exe") == "wav", "unknown extension stores as wav")
    }

    private static func testRecordingTimeNeedsEmbeddedDateAndLength() throws {
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        try expect(AudioFileRecordingTime.make(creationDate: nil, duration: 60) == nil, "no date, no time")
        try expect(AudioFileRecordingTime.make(creationDate: base, duration: 0) == nil, "no length, no time")
        try expect(AudioFileRecordingTime.make(creationDate: base, duration: .nan) == nil, "bad length, no time")
        try expect(AudioFileRecordingTime.make(creationDate: base, duration: 90)
                   == AudioFileRecordingTime(start: base, end: base.addingTimeInterval(90)), "date and length")
    }

    private static func testStereoFloatWAVBecomesCanonicalRecording() throws {
        let source = try writeTone(sampleRate: 44_100, channels: 2, seconds: 0.5, fileExtension: "wav", settings: nil)
        let output = temporaryURL("wav")
        defer { remove(source, output) }
        var reported: [Double] = []
        let layout = try CanonicalAudioFileConversion.convert(source, to: output) { reported.append($0) }
        try expectCanonical(output, layout: layout, expectedSeconds: 0.5)
        try expect(reported.last == 1, "progress ends at 1")
        try expect(reported == reported.sorted(), "progress only grows")
    }

    private static func testAACM4ABecomesCanonicalRecording() throws {
        let source = try writeTone(sampleRate: 44_100, channels: 1, seconds: 1, fileExtension: "m4a", settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
        ])
        let output = temporaryURL("wav")
        defer { remove(source, output) }
        let layout = try CanonicalAudioFileConversion.convert(source, to: output)
        try expectCanonical(output, layout: layout, expectedSeconds: 1)
    }

    private static func testInspectEstimatesTheCanonicalSize() throws {
        let source = try writeTone(sampleRate: 48_000, channels: 2, seconds: 2, fileExtension: "wav", settings: nil)
        defer { remove(source) }
        let info = try CanonicalAudioFileConversion.inspect(source)
        try expect(abs(info.duration - 2) < 0.01, "duration")
        try expect(info.estimatedDataByteCount == 64_000, "2 s is 64,000 canonical bytes, got \(info.estimatedDataByteCount)")
        try expect(CanonicalAudioFileConversion.estimatedDataByteCount(frameCount: 0, sampleRate: 48_000) == 0, "no frames")
        try expect(CanonicalAudioFileConversion.maximumDataByteCount == UInt64(UInt32.max) - 37,
                   "the header limit in whole frames")
    }

    private static func testUnreadableFileIsRejectedWithoutOutput() throws {
        let source = temporaryURL("m4a")
        try Data("not audio at all".utf8).write(to: source)
        let output = temporaryURL("wav")
        defer { remove(source, output) }
        try expectThrows(.unreadable) { try CanonicalAudioFileConversion.convert(source, to: output) }
        try expectThrows(.unreadable) { _ = try CanonicalAudioFileConversion.inspect(source) }
        try expect(!FileManager.default.fileExists(atPath: output.path), "no output after a failure")
    }

    private static func testEmptyFileIsRejected() throws {
        let source = try writeTone(sampleRate: 16_000, channels: 1, seconds: 0, fileExtension: "wav", settings: nil)
        let output = temporaryURL("wav")
        defer { remove(source, output) }
        try expectThrows(.empty) { _ = try CanonicalAudioFileConversion.inspect(source) }
        try expectThrows(.empty) { try CanonicalAudioFileConversion.convert(source, to: output) }
        try expect(!FileManager.default.fileExists(atPath: output.path), "no output for an empty file")
    }

    private static func testMacKeepsAnEmptyFileAsAnEmptyRecording() throws {
        let source = try writeTone(sampleRate: 16_000, channels: 1, seconds: 0, fileExtension: "wav", settings: nil)
        let output = temporaryURL("wav")
        defer { remove(source, output) }
        let layout = try CanonicalAudioFileConversion.convert(source, to: output, allowsEmpty: true)
        try expect(layout.dataByteCount == 0, "an empty recording")
        try expect(try CanonicalPCM16WAV.validateFile(at: output, requireNonEmpty: false) == layout, "a valid empty file")
    }

    private static func testChannelMixingIsTheCallersChoice() throws {
        // The tone is only on the left channel.
        let source = try writeTone(sampleRate: 16_000, channels: 2, seconds: 0.5, fileExtension: "wav", settings: nil, silentAfterFirstChannel: true)
        let firstOnly = temporaryURL("wav")
        let mixed = temporaryURL("wav")
        defer { remove(source, firstOnly, mixed) }
        try CanonicalAudioFileConversion.convert(source, to: firstOnly, mixesChannels: false)
        try CanonicalAudioFileConversion.convert(source, to: mixed, mixesChannels: true)
        let firstPeak = try peak(firstOnly)
        let mixedPeak = try peak(mixed)
        try expect(firstPeak > 15_000, "the first channel is kept whole, peak \(firstPeak)")
        try expect(mixedPeak > 3_000 && mixedPeak < firstPeak, "the mix holds both channels, peak \(mixedPeak)")
    }

    private static func peak(_ url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let samples = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        return samples.map { abs(Int($0)) }.max() ?? 0
    }

    private static func testCancellationLeavesNoOutput() async throws {
        let source = try writeTone(sampleRate: 16_000, channels: 1, seconds: 2, fileExtension: "wav", settings: nil)
        let output = temporaryURL("wav")
        defer { remove(source, output) }
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try CanonicalAudioFileConversion.convert(source, to: output)
        }
        do {
            _ = try await task.value
            throw TestFailure("a cancelled conversion must throw")
        } catch is CancellationError {
        }
        try expect(!FileManager.default.fileExists(atPath: output.path), "no output after cancelling")
    }

    // MARK: - Helpers

    private static func expectCanonical(_ url: URL, layout: CanonicalPCM16WAVLayout, expectedSeconds: Double) throws {
        let validated = try CanonicalPCM16WAV.validateFile(at: url)
        try expect(validated == layout, "returned layout matches the file")
        try expect(layout.dataOffset == 44, "plain 44-byte header")
        try expect(abs(layout.duration - expectedSeconds) < 0.05, "duration \(layout.duration)")
        let data = try Data(contentsOf: url)
        let samples = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        try expect(samples.contains { abs(Int($0)) > 1_000 }, "the tone survives the conversion")
    }

    /// A 440 Hz tone, the same on every channel.
    private static func writeTone(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        seconds: Double,
        fileExtension: String,
        settings: [String: Any]?,
        silentAfterFirstChannel: Bool = false
    ) throws -> URL {
        let url = temporaryURL(fileExtension)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        do {
            let floatWAV: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: Int(channels),
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings ?? floatWAV)
            if frames > 0 {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
                buffer.frameLength = frames
                for channel in 0..<Int(channels) {
                    let samples = buffer.floatChannelData![channel]
                    for frame in 0..<Int(frames) {
                        samples[frame] = channel > 0 && silentAfterFirstChannel
                            ? 0
                            : 0.5 * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate))
                    }
                }
                try file.write(from: buffer)
            }
        }
        return url
    }

    private static func temporaryURL(_ fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-import-test-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
    }

    private static func remove(_ urls: URL...) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    private static func expectThrows(_ expected: CanonicalAudioFileConversionError, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as CanonicalAudioFileConversionError {
            try expect(error == expected, "expected \(expected), got \(error)")
            return
        }
        throw TestFailure("expected \(expected)")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw TestFailure(message) }
    }

    struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
