import CryptoKit
import Foundation

@main
struct LocalAIInstallerTests {
    static func main() throws {
        try testSuccessfulPackageInstallProducesEveryFinalArtifact()
        try testPackageProgressAggregatesArtifacts()
        try testFailureOnSecondArtifactCleansEveryPartial()
        try testCancellationStopsPackageBeforeLaterArtifact()
        try testConcurrentInstallForSameModelIsRejected()
        try testConcurrentInstallsForDifferentModelsBothSucceed()
        try testInvalidArtifactPreservesEntireExistingPackage()
        try testMoveFailureRollsBackEntireExistingPackage()
        print("LocalAIInstallerTests passed")
    }

    private static func testSuccessfulPackageInstallProducesEveryFinalArtifact() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = [Data(repeating: 1, count: 12), Data(repeating: 2, count: 15)]
        let model = testModel(id: "successful", contents: contents)
        let store = LocalAIModelStore(rootDirectory: root)
        let completion = CompletionWaiter<Void, LocalAIInstallerError>()
        let installer = LocalAIInstaller(store: store) { source, destination, _, _ in
            try contents[artifactIndex(source)].write(to: destination)
        }

        _ = installer.install(model: model, progress: { _ in }) { completion.complete($0) }

        assertSucceeded(try completion.wait())
        assert(store.installStatus(for: model) == .ready)
        for (artifact, data) in zip(model.artifacts, contents) {
            let installed = try Data(contentsOf: store.artifactURL(for: artifact))
            assert(installed == data)
            assert(!FileManager.default.fileExists(atPath: store.partialArtifactURL(for: artifact).path))
        }
    }

    private static func testPackageProgressAggregatesArtifacts() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = [Data(repeating: 3, count: 10), Data(repeating: 4, count: 20)]
        let model = testModel(id: "progress", contents: contents)
        let store = LocalAIModelStore(rootDirectory: root)
        let completion = CompletionWaiter<Void, LocalAIInstallerError>()
        var progress: [LocalAIDownloadProgress] = []
        let lock = NSLock()
        let installer = LocalAIInstaller(store: store) { source, destination, report, _ in
            let data = contents[artifactIndex(source)]
            try data.write(to: destination)
            report(LocalAIDownloadProgress(downloadedBytes: Int64(data.count), totalBytes: Int64(data.count)))
        }

        _ = installer.install(model: model, progress: {
            lock.lock()
            progress.append($0)
            lock.unlock()
        }) { completion.complete($0) }

        assertSucceeded(try completion.wait())
        assert(progress.contains(LocalAIDownloadProgress(downloadedBytes: 10, totalBytes: 30)))
        assert(progress.last == LocalAIDownloadProgress(downloadedBytes: 30, totalBytes: 30))
    }

    private static func testFailureOnSecondArtifactCleansEveryPartial() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = [Data(repeating: 5, count: 12), Data(repeating: 6, count: 13)]
        let model = testModel(id: "failure", contents: contents)
        let store = LocalAIModelStore(rootDirectory: root)
        let completion = CompletionWaiter<Void, LocalAIInstallerError>()
        let installer = LocalAIInstaller(store: store) { source, destination, _, _ in
            if artifactIndex(source) == 1 {
                try contents[1].write(to: destination)
                throw LocalAIInstallerError.downloadFailed("second artifact failed")
            }
            try contents[0].write(to: destination)
        }

        _ = installer.install(model: model, progress: { _ in }) { completion.complete($0) }

        assertFailed(try completion.wait(), .downloadFailed("second artifact failed"))
        assert(store.installStatus(for: model) == .notInstalled)
        for artifact in model.artifacts {
            assert(!FileManager.default.fileExists(atPath: store.partialArtifactURL(for: artifact).path))
            assert(!FileManager.default.fileExists(atPath: store.artifactURL(for: artifact).path))
        }
    }

    private static func testCancellationStopsPackageBeforeLaterArtifact() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = [Data(repeating: 7, count: 12), Data(repeating: 8, count: 13)]
        let model = testModel(id: "cancel", contents: contents)
        let store = LocalAIModelStore(rootDirectory: root)
        let started = DispatchSemaphore(value: 0)
        let continueDownload = DispatchSemaphore(value: 0)
        let completion = CompletionWaiter<Void, LocalAIInstallerError>()
        var startedArtifacts: [Int] = []
        let lock = NSLock()
        let installer = LocalAIInstaller(store: store) { source, destination, _, task in
            let index = artifactIndex(source)
            lock.lock()
            startedArtifacts.append(index)
            lock.unlock()
            if index == 0 {
                started.signal()
                _ = continueDownload.wait(timeout: .now() + 2)
                try contents[0].write(to: destination)
                if task.isCancelled { throw LocalAIInstallerError.cancelled }
            }
        }
        let task = installer.install(model: model, progress: { _ in }) { completion.complete($0) }
        guard started.wait(timeout: .now() + 2) == .success else { throw TestFailure("first artifact did not start") }

        task.cancel()
        continueDownload.signal()

        assertFailed(try completion.wait(), .cancelled)
        assert(startedArtifacts == [0])
        assert(store.installStatus(for: model) != .ready)
        for artifact in model.artifacts {
            assert(!FileManager.default.fileExists(atPath: store.partialArtifactURL(for: artifact).path))
        }
    }

    private static func testConcurrentInstallForSameModelIsRejected() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = [Data(repeating: 9, count: 12)]
        let model = testModel(id: "dedupe", contents: contents)
        let store = LocalAIModelStore(rootDirectory: root)
        let started = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let first = CompletionWaiter<Void, LocalAIInstallerError>()
        let second = CompletionWaiter<Void, LocalAIInstallerError>()
        let installer = LocalAIInstaller(store: store) { _, destination, _, _ in
            started.signal()
            _ = finish.wait(timeout: .now() + 2)
            try contents[0].write(to: destination)
        }

        _ = installer.install(model: model, progress: { _ in }) { first.complete($0) }
        guard started.wait(timeout: .now() + 2) == .success else { throw TestFailure("first install did not start") }
        _ = installer.install(model: model, progress: { _ in }) { second.complete($0) }

        assertFailed(try second.wait(), .alreadyInProgress)
        finish.signal()
        assertSucceeded(try first.wait())
    }

    private static func testConcurrentInstallsForDifferentModelsBothSucceed() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let qualityContents = [Data(repeating: 10, count: 12)]
        let fastContents = [Data(repeating: 11, count: 13)]
        let quality = testModel(id: "quality", contents: qualityContents)
        let fast = testModel(id: "fast", contents: fastContents)
        let store = LocalAIModelStore(rootDirectory: root)
        let bothStarted = DispatchSemaphore(value: 0)
        let allowDownloads = DispatchSemaphore(value: 0)
        let qualityCompletion = CompletionWaiter<Void, LocalAIInstallerError>()
        let fastCompletion = CompletionWaiter<Void, LocalAIInstallerError>()
        let installer = LocalAIInstaller(store: store) { source, destination, _, _ in
            bothStarted.signal()
            _ = allowDownloads.wait(timeout: .now() + 2)
            try (source.lastPathComponent.contains("quality") ? qualityContents[0] : fastContents[0]).write(to: destination)
        }

        _ = installer.install(model: quality, progress: { _ in }) { qualityCompletion.complete($0) }
        _ = installer.install(model: fast, progress: { _ in }) { fastCompletion.complete($0) }
        guard bothStarted.wait(timeout: .now() + 2) == .success,
              bothStarted.wait(timeout: .now() + 2) == .success else { throw TestFailure("different installs did not run concurrently") }
        allowDownloads.signal()
        allowDownloads.signal()

        assertSucceeded(try qualityCompletion.wait())
        assertSucceeded(try fastCompletion.wait())
    }

    private static func testInvalidArtifactPreservesEntireExistingPackage() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldContents = [Data(repeating: 12, count: 12), Data(repeating: 13, count: 13)]
        let newContents = [Data(repeating: 14, count: 12), Data(repeating: 15, count: 13)]
        let model = testModel(id: "validation", contents: newContents)
        let store = LocalAIModelStore(rootDirectory: root)
        try store.ensureModelsDirectoryExists()
        for (artifact, old) in zip(model.artifacts, oldContents) {
            try old.write(to: store.artifactURL(for: artifact))
        }
        let completion = CompletionWaiter<Void, LocalAIInstallerError>()
        let installer = LocalAIInstaller(store: store) { source, destination, _, _ in
            let index = artifactIndex(source)
            try (index == 0 ? newContents[index] : Data([99])).write(to: destination)
        }

        _ = installer.install(model: model, progress: { _ in }) { completion.complete($0) }

        guard case .failure(.verificationFailed) = try completion.wait() else { throw TestFailure("invalid artifact should fail verification") }
        for (artifact, old) in zip(model.artifacts, oldContents) {
            let installed = try Data(contentsOf: store.artifactURL(for: artifact))
            assert(installed == old)
            assert(!FileManager.default.fileExists(atPath: store.partialArtifactURL(for: artifact).path))
        }
    }

    private static func testMoveFailureRollsBackEntireExistingPackage() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldContents = [Data(repeating: 16, count: 12), Data(repeating: 17, count: 13)]
        let newContents = [Data(repeating: 18, count: 12), Data(repeating: 19, count: 13)]
        let model = testModel(id: "rollback", contents: newContents)
        let store = LocalAIModelStore(rootDirectory: root)
        try store.ensureModelsDirectoryExists()
        for (artifact, old) in zip(model.artifacts, oldContents) {
            try old.write(to: store.artifactURL(for: artifact))
        }
        let finalPaths = Set(model.artifacts.map { store.artifactURL(for: $0).path })
        var replacements = 0
        let operations = LocalAIInstallerFileOperations.default.replacing { destination, source in
            replacements += 1
            if replacements == 2 { throw TestFailure("simulated replacement failure") }
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source, backupItemName: nil, options: [])
        }
        let completion = CompletionWaiter<Void, LocalAIInstallerError>()
        let installer = LocalAIInstaller(store: store, fileOperations: operations) { source, destination, _, _ in
            try newContents[artifactIndex(source)].write(to: destination)
        }

        _ = installer.install(model: model, progress: { _ in }) { completion.complete($0) }

        guard case .failure(.moveFailed) = try completion.wait() else { throw TestFailure("move failure should be reported") }
        for (artifact, old) in zip(model.artifacts, oldContents) {
            let installed = try Data(contentsOf: store.artifactURL(for: artifact))
            assert(installed == old)
            assert(!FileManager.default.fileExists(atPath: store.partialArtifactURL(for: artifact).path))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: store.modelsDirectory.path)
        assert(!names.contains { $0.contains(".backup-") })
        assert(finalPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
    }

    private static func artifactIndex(_ source: URL) -> Int {
        Int(source.deletingPathExtension().lastPathComponent.split(separator: "-").last!)!
    }

    private static func testModel(id: String, contents: [Data]) -> LocalAIModel {
        LocalAIModel(
            id: id,
            displayName: id,
            description: "Test package",
            artifacts: contents.enumerated().map { index, data in
                LocalAIModelArtifact(
                    downloadURL: URL(string: "https://example.com/\(id)-\(index).gguf")!,
                    expectedFileName: "\(id)-\(index).gguf",
                    approximateBytes: Int64(data.count),
                    checksumSHA256: sha256HexDigest(for: data)
                )
            },
            approximateResidentRAMBytes: 100
        )
    }

    private static func sha256HexDigest(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func assertSucceeded(_ result: Result<Void, LocalAIInstallerError>) {
        guard case .success = result else { assertionFailure("Expected success, got \(result)"); return }
    }

    private static func assertFailed(_ result: Result<Void, LocalAIInstallerError>, _ expected: LocalAIInstallerError) {
        guard case .failure(let error) = result else { assertionFailure("Expected \(expected), got success"); return }
        assert(error == expected)
    }

    private static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("quill-local-ai-installer-tests-\(UUID().uuidString)", isDirectory: true)
    }
}

private final class CompletionWaiter<Success, Failure: Error> {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Success, Failure>?

    func complete(_ result: Result<Success, Failure>) {
        lock.lock()
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait() throws -> Result<Success, Failure> {
        guard semaphore.wait(timeout: .now() + 2) == .success else { throw TestFailure("Timed out waiting for installer completion") }
        lock.lock()
        defer { lock.unlock() }
        guard let result else { throw TestFailure("Installer completion had no result") }
        return result
    }
}

private struct TestFailure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
