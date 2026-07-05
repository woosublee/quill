import CryptoKit
import Foundation

@main
struct NativeWhisperModelTests {
    static func main() throws {
        try testRecommendedModelMetadata()
        try testStoreUsesQuillOwnedDirectory()
        try testMissingModelReportsNotInstalled()
        try testCompleteModelReportsReadyWithChecksum()
        try testChecksumMismatchReportsCorrupt()
        try testTruncatedLargeModelReportsCorrupt()
        try testSmallCompleteModelReportsCorrupt()
        try testPartialModelReportsPartial()
        try testDeleteRemovesOnlySelectedNativeModel()
        try testDeleteMissingModelSucceeds()
        try testDownloadProgressDisplayText()
        print("NativeWhisperModelTests passed")
    }

    private static func testRecommendedModelMetadata() throws {
        let model = NativeWhisperModelCatalog.recommended

        assert(model.id == "whisper-large-v3-turbo")
        assert(model.displayName == "Whisper Large v3 Turbo")
        assert(model.expectedFileName == "ggml-large-v3-turbo.bin")
        assert(model.downloadURL.absoluteString == "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")
        assert(model.approximateBytes == 1_624_555_275)
        assert(model.checksumSHA256 == "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69")
    }

    private static func testStoreUsesQuillOwnedDirectory() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWhisperModelStore(rootDirectory: root)
        let model = NativeWhisperModelCatalog.recommended

        assert(store.modelsDirectory.path == root.appendingPathComponent("LocalWhisper/Models", isDirectory: true).path)
        assert(store.modelURL(for: model).path.hasSuffix("LocalWhisper/Models/ggml-large-v3-turbo.bin"))
        assert(store.partialModelURL(for: model).path.hasSuffix("LocalWhisper/Models/ggml-large-v3-turbo.bin.download"))
    }

    private static func testMissingModelReportsNotInstalled() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWhisperModelStore(rootDirectory: root)

        assert(store.installStatus(for: .recommended) == .notInstalled)
    }

    private static func testCompleteModelReportsReadyWithChecksum() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWhisperModelStore(rootDirectory: root)
        let data = Data(repeating: 7, count: 16)
        let model = testModel(approximateBytes: 16, checksumSHA256: sha256HexDigest(for: data))
        try FileManager.default.createDirectory(at: store.modelsDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: store.modelURL(for: model).path, contents: data)

        assert(store.installStatus(for: model) == .ready)
    }

    private static func testChecksumMismatchReportsCorrupt() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWhisperModelStore(rootDirectory: root)
        let model = testModel(approximateBytes: 16, checksumSHA256: String(repeating: "0", count: 64))
        try FileManager.default.createDirectory(at: store.modelsDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: store.modelURL(for: model).path, contents: Data(repeating: 7, count: 16))

        if case .corrupt(let message) = store.installStatus(for: model) {
            assert(message.contains("checksum mismatch"))
        } else {
            assertionFailure("Expected checksum mismatch to be corrupt")
        }
    }

    private static func testTruncatedLargeModelReportsCorrupt() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWhisperModelStore(rootDirectory: root)
        let model = testModel(approximateBytes: 1_000_000_000)
        try FileManager.default.createDirectory(at: store.modelsDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: store.modelURL(for: model).path, contents: nil)
        let handle = try FileHandle(forWritingTo: store.modelURL(for: model))
        try handle.truncate(atOffset: 100_000_000)
        try handle.close()

        if case .corrupt(let message) = store.installStatus(for: model) {
            assert(message.contains("too small"))
        } else {
            assertionFailure("Expected truncated large model file to be corrupt")
        }
    }

    private static func testSmallCompleteModelReportsCorrupt() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWhisperModelStore(rootDirectory: root)
        let model = NativeWhisperModelCatalog.recommended
        try FileManager.default.createDirectory(at: store.modelsDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: store.modelURL(for: model).path, contents: Data(repeating: 7, count: 16))

        if case .corrupt(let message) = store.installStatus(for: model) {
            assert(message.contains("too small"))
        } else {
            assertionFailure("Expected tiny recommended model file to be corrupt")
        }
    }

    private static func testPartialModelReportsPartial() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWhisperModelStore(rootDirectory: root)
        let model = NativeWhisperModelCatalog.recommended
        try FileManager.default.createDirectory(at: store.modelsDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: store.partialModelURL(for: model).path, contents: Data(repeating: 1, count: 4))

        assert(store.installStatus(for: model) == .partial(downloadedBytes: 4, expectedBytes: model.approximateBytes))
    }

    private static func testDeleteRemovesOnlySelectedNativeModel() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWhisperModelStore(rootDirectory: root)
        let selected = NativeWhisperModelCatalog.recommended
        let other = NativeWhisperModel(
            id: "other",
            displayName: "Other",
            description: "Other test model",
            downloadURL: URL(string: "https://example.com/other.bin")!,
            expectedFileName: "other.bin",
            approximateBytes: 8,
            checksumSHA256: sha256HexDigest(for: Data([2]))
        )
        try FileManager.default.createDirectory(at: store.modelsDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: store.modelURL(for: selected).path, contents: Data([1]))
        FileManager.default.createFile(atPath: store.modelURL(for: other).path, contents: Data([2]))

        try store.deleteModel(selected)

        assert(!FileManager.default.fileExists(atPath: store.modelURL(for: selected).path))
        assert(FileManager.default.fileExists(atPath: store.modelURL(for: other).path))
    }

    private static func testDeleteMissingModelSucceeds() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWhisperModelStore(rootDirectory: root)

        try store.deleteModel(.recommended)

        assert(store.installStatus(for: .recommended) == .notInstalled)
    }

    private static func testDownloadProgressDisplayText() throws {
        assert(NativeWhisperDownloadProgress(downloadedBytes: 0, totalBytes: 100).displayText == "Starting...")
        assert(NativeWhisperDownloadProgress(downloadedBytes: 50, totalBytes: 100).displayText == "50% · 50 bytes")
        assert(NativeWhisperDownloadProgress(downloadedBytes: 100, totalBytes: 100, isCancelled: true).displayText == "Canceled")
    }

    private static func testModel(
        approximateBytes: Int64,
        checksumSHA256: String = String(repeating: "0", count: 64)
    ) -> NativeWhisperModel {
        NativeWhisperModel(
            id: "test-model-\(approximateBytes)",
            displayName: "Test Model",
            description: "Small test model",
            downloadURL: URL(string: "https://example.com/test-model.bin")!,
            expectedFileName: "test-model-\(approximateBytes).bin",
            approximateBytes: approximateBytes,
            checksumSHA256: checksumSHA256
        )
    }

    private static func sha256HexDigest(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-native-whisper-model-tests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
