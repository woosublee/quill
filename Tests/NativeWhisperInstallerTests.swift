import Foundation

@main
struct NativeWhisperInstallerTests {
    static func main() throws {
        try testSuccessfulInstallMovesPartialFileToFinalPath()
        try testFailedDownloadKeepsFailureMessageAndRemovesPartial()
        try testCancelPreventsReadyInstall()
        print("NativeWhisperInstallerTests passed")
    }

    private static func testSuccessfulInstallMovesPartialFileToFinalPath() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWhisperModelStore(rootDirectory: root)
        let model = NativeWhisperModelCatalog.recommended
        var progressValues: [NativeWhisperDownloadProgress] = []
        let completion = CompletionWaiter<Void, NativeWhisperInstallerError>()
        let installer = NativeWhisperInstaller(store: store) { _, destination, progress, shouldCancel in
            assert(!shouldCancel())
            try Data(repeating: 3, count: 12).write(to: destination)
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
        let installer = NativeWhisperInstaller(store: store) { _, destination, _, shouldCancel in
            started.signal()
            _ = allowCancelCheck.wait(timeout: .now() + 2)
            try Data([1, 2, 3]).write(to: destination)
            if shouldCancel() { throw NativeWhisperInstallerError.cancelled }
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

    var description: String { "\(file):\(line): \(message)" }
}
