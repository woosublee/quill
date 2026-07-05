import CryptoKit
import Foundation

@main
struct NativeWhisperInstallerTests {
    static func main() throws {
        try testSuccessfulInstallMovesPartialFileToFinalPath()
        try testFailedDownloadKeepsFailureMessageAndRemovesPartial()
        try testCancelPreventsReadyInstall()
        try testProgressCanBeReportedBeforeDownloadCompletes()
        try testCancelInvokesDownloaderCancellationHandler()
        try testConcurrentInstallForSameModelIsRejected()
        try testInvalidDownloadedModelPreservesExistingFinalModel()
        print("NativeWhisperInstallerTests passed")
    }

    private static func testSuccessfulInstallMovesPartialFileToFinalPath() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWhisperModelStore(rootDirectory: root)
        let data = Data(repeating: 3, count: 12)
        let model = testModel(approximateBytes: 12, checksumSHA256: sha256HexDigest(for: data))
        var progressValues: [NativeWhisperDownloadProgress] = []
        let completion = CompletionWaiter<Void, NativeWhisperInstallerError>()
        let installer = NativeWhisperInstaller(store: store) { _, destination, progress, task in
            assert(!task.isCancelled)
            try data.write(to: destination)
            progress(NativeWhisperDownloadProgress(downloadedBytes: 12, totalBytes: 12))
        }

        _ = installer.install(model: model, progress: { progressValues.append($0) }) { completion.complete($0) }
        let result = try completion.wait()

        assertResultSucceeded(result)
        assert(store.installStatus(for: model) == .ready)
        assert(!FileManager.default.fileExists(atPath: store.partialModelURL(for: model).path))
        assert(progressValues.last == NativeWhisperDownloadProgress(downloadedBytes: 12, totalBytes: 12))
    }

    private static func testFailedDownloadKeepsFailureMessageAndRemovesPartial() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWhisperModelStore(rootDirectory: root)
        let model = NativeWhisperModelCatalog.recommended
        let completion = CompletionWaiter<Void, NativeWhisperInstallerError>()
        let installer = NativeWhisperInstaller(store: store) { _, destination, _, _ in
            try Data([9]).write(to: destination)
            throw NativeWhisperInstallerError.downloadFailed("network down")
        }

        _ = installer.install(model: model, progress: { _ in }) { completion.complete($0) }
        let result = try completion.wait()

        assertResultFailed(result, .downloadFailed("network down"))
        assert(store.installStatus(for: model) == .notInstalled)
        assert(!FileManager.default.fileExists(atPath: store.partialModelURL(for: model).path))
    }

    private static func testCancelPreventsReadyInstall() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWhisperModelStore(rootDirectory: root)
        let model = NativeWhisperModelCatalog.recommended
        let completion = CompletionWaiter<Void, NativeWhisperInstallerError>()
        let started = DispatchSemaphore(value: 0)
        let allowCancelCheck = DispatchSemaphore(value: 0)
        let installer = NativeWhisperInstaller(store: store) { _, destination, _, task in
            started.signal()
            _ = allowCancelCheck.wait(timeout: .now() + 2)
            try Data([1, 2, 3]).write(to: destination)
            if task.isCancelled { throw NativeWhisperInstallerError.cancelled }
        }
        let task = installer.install(model: model, progress: { _ in }) { completion.complete($0) }
        _ = started.wait(timeout: .now() + 2)

        task.cancel()
        allowCancelCheck.signal()
        let result = try completion.wait()

        assert(task.isCancelled)
        assertResultFailed(result, .cancelled)
        assert(store.installStatus(for: model) != .ready)
    }

    private static func testProgressCanBeReportedBeforeDownloadCompletes() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWhisperModelStore(rootDirectory: root)
        let finalData = Data([1, 2, 3, 4, 5, 6])
        let model = testModel(approximateBytes: 6, checksumSHA256: sha256HexDigest(for: finalData))
        var progressValues: [NativeWhisperDownloadProgress] = []
        let completion = CompletionWaiter<Void, NativeWhisperInstallerError>()
        let firstChunkWritten = DispatchSemaphore(value: 0)
        let finishDownload = DispatchSemaphore(value: 0)
        let installer = NativeWhisperInstaller(store: store) { _, destination, progress, _ in
            try Data([1, 2, 3]).write(to: destination)
            progress(NativeWhisperDownloadProgress(downloadedBytes: 3, totalBytes: 6))
            firstChunkWritten.signal()
            _ = finishDownload.wait(timeout: .now() + 2)
            try finalData.write(to: destination)
            progress(NativeWhisperDownloadProgress(downloadedBytes: 6, totalBytes: 6))
        }

        _ = installer.install(model: model, progress: { progressValues.append($0) }) { completion.complete($0) }
        guard firstChunkWritten.wait(timeout: .now() + 2) == .success else {
            throw TestFailure(message: "Timed out waiting for early progress")
        }

        assert(progressValues == [NativeWhisperDownloadProgress(downloadedBytes: 3, totalBytes: 6)])
        finishDownload.signal()
        assertResultSucceeded(try completion.wait())
        assert(progressValues.last == NativeWhisperDownloadProgress(downloadedBytes: 6, totalBytes: 6))
    }

    private static func testCancelInvokesDownloaderCancellationHandler() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWhisperModelStore(rootDirectory: root)
        let model = NativeWhisperModelCatalog.recommended
        let completion = CompletionWaiter<Void, NativeWhisperInstallerError>()
        let handlerInstalled = DispatchSemaphore(value: 0)
        let cancellationForwarded = DispatchSemaphore(value: 0)
        let installer = NativeWhisperInstaller(store: store) { _, destination, _, task in
            try Data([1, 2, 3]).write(to: destination)
            task.setCancellationHandler {
                cancellationForwarded.signal()
            }
            handlerInstalled.signal()
            guard cancellationForwarded.wait(timeout: .now() + 2) == .success else {
                throw NativeWhisperInstallerError.downloadFailed("cancel handler was not called")
            }
            throw NativeWhisperInstallerError.cancelled
        }

        let task = installer.install(model: model, progress: { _ in }) { completion.complete($0) }
        guard handlerInstalled.wait(timeout: .now() + 2) == .success else {
            throw TestFailure(message: "Timed out waiting for cancellation handler installation")
        }
        task.cancel()

        assertResultFailed(try completion.wait(), .cancelled)
        assert(!FileManager.default.fileExists(atPath: store.partialModelURL(for: model).path))
    }

    private static func testConcurrentInstallForSameModelIsRejected() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWhisperModelStore(rootDirectory: root)
        let data = Data(repeating: 4, count: 12)
        let model = testModel(approximateBytes: 12, checksumSHA256: sha256HexDigest(for: data))
        let firstStarted = DispatchSemaphore(value: 0)
        let finishFirst = DispatchSemaphore(value: 0)
        let firstCompletion = CompletionWaiter<Void, NativeWhisperInstallerError>()
        let secondCompletion = CompletionWaiter<Void, NativeWhisperInstallerError>()
        let firstInstaller = NativeWhisperInstaller(store: store) { _, destination, _, _ in
            firstStarted.signal()
            _ = finishFirst.wait(timeout: .now() + 2)
            try data.write(to: destination)
        }
        let secondInstaller = NativeWhisperInstaller(store: store) { _, _, _, _ in
            throw NativeWhisperInstallerError.downloadFailed("second install should not start")
        }

        _ = firstInstaller.install(model: model, progress: { _ in }) { firstCompletion.complete($0) }
        guard firstStarted.wait(timeout: .now() + 2) == .success else {
            throw TestFailure(message: "Timed out waiting for first install")
        }
        _ = secondInstaller.install(model: model, progress: { _ in }) { secondCompletion.complete($0) }

        assertResultFailed(try secondCompletion.wait(), .alreadyInProgress)
        finishFirst.signal()
        assertResultSucceeded(try firstCompletion.wait())
    }

    private static func testInvalidDownloadedModelPreservesExistingFinalModel() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWhisperModelStore(rootDirectory: root)
        let model = NativeWhisperModelCatalog.recommended
        let completion = CompletionWaiter<Void, NativeWhisperInstallerError>()
        try store.ensureModelsDirectoryExists()
        let final = store.modelURL(for: model)
        try Data([8, 8, 8]).write(to: final)
        let partialDirectory = store.partialModelURL(for: model)
        let installer = NativeWhisperInstaller(store: store) { _, destination, _, _ in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data([1]).write(to: destination.appendingPathComponent("invalid-replacement"))
        }

        _ = installer.install(model: model, progress: { _ in }) { completion.complete($0) }
        let result = try completion.wait()

        switch result {
        case .success:
            assertionFailure("Expected verification failure, got success")
        case .failure(.verificationFailed):
            break
        case .failure(let error):
            assertionFailure("Expected verification failure, got \(error)")
        }
        let preservedData = try Data(contentsOf: final)
        assert(preservedData == Data([8, 8, 8]))
        assert(!FileManager.default.fileExists(atPath: partialDirectory.path))
    }

    private static func testModel(approximateBytes: Int64, checksumSHA256: String) -> NativeWhisperModel {
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

    private static func assertResultSucceeded(_ result: Result<Void, NativeWhisperInstallerError>) {
        switch result {
        case .success:
            break
        case .failure(let error):
            assertionFailure("Expected success, got \(error)")
        }
    }

    private static func assertResultFailed(
        _ result: Result<Void, NativeWhisperInstallerError>,
        _ expectedError: NativeWhisperInstallerError
    ) {
        switch result {
        case .success:
            assertionFailure("Expected failure \(expectedError), got success")
        case .failure(let error):
            assert(error == expectedError)
        }
    }

    private static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-native-whisper-installer-tests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private final class CompletionWaiter<Success, Failure: Error> {
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Success, Failure>?

    func complete(_ result: Result<Success, Failure>) {
        self.result = result
        semaphore.signal()
    }

    func wait(file: StaticString = #filePath, line: UInt = #line) throws -> Result<Success, Failure> {
        guard semaphore.wait(timeout: .now() + 2) == .success, let result else {
            throw TestFailure(message: "Timed out waiting for installer completion", file: file, line: line)
        }
        return result
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let message: String
    let file: StaticString
    let line: UInt

    init(message: String, file: StaticString = #filePath, line: UInt = #line) {
        self.message = message
        self.file = file
        self.line = line
    }

    var description: String { "\(file):\(line): \(message)" }
}
