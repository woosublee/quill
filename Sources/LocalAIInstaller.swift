import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum LocalAIInstallerError: LocalizedError, Equatable {
    case cancelled
    case downloadFailed(String)
    case verificationFailed(String)
    case moveFailed(String)
    case alreadyInProgress

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Local AI model installation was canceled."
        case .downloadFailed: return "Could not download the local AI model. Check your network connection and free disk space, then try again."
        case .verificationFailed: return "Could not verify the local AI model. Try downloading it again."
        case .moveFailed: return "Could not finish installing the local AI model."
        case .alreadyInProgress: return "This local AI model is already being installed."
        }
    }
}

final class LocalAIInstallTask {
    private let lock = NSLock()
    private var cancelled = false
    private var cancellationHandler: (() -> Void)?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        let handler: (() -> Void)?
        lock.lock()
        cancelled = true
        handler = cancellationHandler
        lock.unlock()
        handler?()
    }

    func setCancellationHandler(_ handler: (() -> Void)?) {
        let cancelImmediately: Bool
        lock.lock()
        cancellationHandler = handler
        cancelImmediately = cancelled && handler != nil
        lock.unlock()
        if cancelImmediately { handler?() }
    }
}

/// A small seam for deterministically exercising cancellation during validation.
struct LocalAIInstallerValidation {
    let validateArtifact: (LocalAIModelArtifact, URL) -> String?

    init(_ validateArtifact: @escaping (LocalAIModelArtifact, URL) -> String?) {
        self.validateArtifact = validateArtifact
    }
}

/// A small seam for testing filesystem failures during package commits.
struct LocalAIInstallerFileOperations {
    let moveItem: (URL, URL) throws -> Void
    let removeItem: (URL) throws -> Void
    let installPartial: (URL, URL) throws -> Void

    static let `default` = LocalAIInstallerFileOperations(
        moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
        removeItem: { try FileManager.default.removeItem(at: $0) },
        installPartial: { source, destination in try FileManager.default.moveItem(at: source, to: destination) }
    )

    func replacing(_ installPartial: @escaping (URL, URL) throws -> Void) -> LocalAIInstallerFileOperations {
        LocalAIInstallerFileOperations(moveItem: moveItem, removeItem: removeItem, installPartial: installPartial)
    }
}

struct LocalAIInstaller {
    typealias DownloadFunction = (
        _ source: URL,
        _ destination: URL,
        _ progress: @escaping (LocalAIDownloadProgress) -> Void,
        _ task: LocalAIInstallTask
    ) throws -> Void

    let store: LocalAIModelStore
    let download: DownloadFunction
    private let validateArtifact: (LocalAIModelArtifact, URL) -> String?
    private let queue: DispatchQueue
    private let fileOperations: LocalAIInstallerFileOperations
    private static let inFlightLock = NSLock()
    private static var inFlightInstallKeys: Set<String> = []

    init(
        store: LocalAIModelStore = LocalAIModelStore(),
        queue: DispatchQueue = DispatchQueue(label: "quill.local-ai-installer", qos: .utility, attributes: .concurrent),
        fileOperations: LocalAIInstallerFileOperations = .default,
        validation: LocalAIInstallerValidation? = nil,
        download: @escaping DownloadFunction = LocalAIInstaller.urlSessionDownload
    ) {
        self.store = store
        self.queue = queue
        self.fileOperations = fileOperations
        self.validateArtifact = validation?.validateArtifact ?? { artifact, url in
            store.validationError(for: artifact, at: url)
        }
        self.download = download
    }

    @discardableResult
    func install(
        model: LocalAIModel,
        progress: @escaping (LocalAIDownloadProgress) -> Void,
        completion: @escaping (Result<Void, LocalAIInstallerError>) -> Void
    ) -> LocalAIInstallTask {
        let task = LocalAIInstallTask()
        let key = "\(store.rootDirectory.standardizedFileURL.path)|\(model.id)"
        guard Self.beginInstall(key: key) else {
            completion(.failure(.alreadyInProgress))
            return task
        }

        queue.async {
            let result = performInstall(model: model, progress: progress, task: task)
            Self.endInstall(key: key)
            completion(result)
        }
        return task
    }

    private static func beginInstall(key: String) -> Bool {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        guard !inFlightInstallKeys.contains(key) else { return false }
        inFlightInstallKeys.insert(key)
        return true
    }

    private static func endInstall(key: String) {
        inFlightLock.lock()
        inFlightInstallKeys.remove(key)
        inFlightLock.unlock()
    }

    private func performInstall(
        model: LocalAIModel,
        progress: @escaping (LocalAIDownloadProgress) -> Void,
        task: LocalAIInstallTask
    ) -> Result<Void, LocalAIInstallerError> {
        do {
            try store.ensureModelsDirectoryExists()
            try store.deletePartialModel(model)
            var completedBytes: Int64 = 0

            for artifact in model.artifacts {
                try checkCancellation(task)
                let artifactBytes = artifact.approximateBytes
                try downloadArtifact(artifact, completedBytes: completedBytes, model: model, progress: progress, task: task)
                try checkCancellation(task)
                completedBytes += artifactBytes
            }

            try checkCancellation(task)
            for artifact in model.artifacts {
                try checkCancellation(task)
                if let validationError = validateArtifact(artifact, store.partialArtifactURL(for: artifact)) {
                    throw LocalAIInstallerError.verificationFailed("\(artifact.expectedFileName): \(validationError)")
                }
                try checkCancellation(task)
            }

            try checkCancellation(task)
            try replacePackage(model, task: task)
            progress(LocalAIDownloadProgress(downloadedBytes: model.approximateBytes, totalBytes: model.approximateBytes))
            return .success(())
        } catch let error as LocalAIInstallerError {
            cleanupPartials(for: model)
            return .failure(error)
        } catch {
            cleanupPartials(for: model)
            return .failure(.downloadFailed(error.localizedDescription))
        }
    }

    private func downloadArtifact(
        _ artifact: LocalAIModelArtifact,
        completedBytes: Int64,
        model: LocalAIModel,
        progress: @escaping (LocalAIDownloadProgress) -> Void,
        task: LocalAIInstallTask
    ) throws {
        defer { task.setCancellationHandler(nil) }
        try download(artifact.downloadURL, store.partialArtifactURL(for: artifact), { current in
            let downloaded = min(model.approximateBytes, completedBytes + max(0, current.downloadedBytes))
            progress(LocalAIDownloadProgress(
                downloadedBytes: downloaded,
                totalBytes: model.approximateBytes,
                isCancelled: current.isCancelled || task.isCancelled
            ))
        }, task)
    }

    private func checkCancellation(_ task: LocalAIInstallTask) throws {
        if task.isCancelled { throw LocalAIInstallerError.cancelled }
    }

    private func replacePackage(_ model: LocalAIModel, task: LocalAIInstallTask) throws {
        let token = UUID().uuidString
        let finals = model.artifacts.map { store.artifactURL(for: $0) }
        let backups = finals.map { $0.appendingPathExtension("backup-\(token)") }
        var backedUp: [(final: URL, backup: URL)] = []
        var installed: [URL] = []

        do {
            try checkCancellation(task)
            for (final, backup) in zip(finals, backups) where FileManager.default.fileExists(atPath: final.path) {
                try fileOperations.moveItem(final, backup)
                backedUp.append((final, backup))
            }
            for (artifact, final) in zip(model.artifacts, finals) {
                try checkCancellation(task)
                try fileOperations.installPartial(store.partialArtifactURL(for: artifact), final)
                installed.append(final)
                try checkCancellation(task)
            }
            try checkCancellation(task)
        } catch {
            let rollbackError = rollback(installed: installed, backups: backedUp)
            if let rollbackError {
                throw LocalAIInstallerError.moveFailed("\(error.localizedDescription); rollback failed: \(rollbackError)")
            }
            if let installerError = error as? LocalAIInstallerError, installerError == .cancelled {
                throw LocalAIInstallerError.cancelled
            }
            throw LocalAIInstallerError.moveFailed(error.localizedDescription)
        }

        cleanupBackupsBestEffort(backedUp)
    }

    private func rollback(installed: [URL], backups: [(final: URL, backup: URL)]) -> String? {
        var failures: [String] = []
        for final in installed.reversed() where FileManager.default.fileExists(atPath: final.path) {
            do {
                try fileOperations.removeItem(final)
            } catch {
                failures.append("remove \(final.lastPathComponent): \(error.localizedDescription)")
            }
        }
        for (final, backup) in backups.reversed() where FileManager.default.fileExists(atPath: backup.path) {
            guard !FileManager.default.fileExists(atPath: final.path) else {
                failures.append("restore \(final.lastPathComponent): replacement still exists")
                continue
            }
            do {
                try fileOperations.moveItem(backup, final)
            } catch {
                failures.append("restore \(final.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return failures.isEmpty ? nil : failures.joined(separator: "; ")
    }

    private func cleanupBackupsBestEffort(_ backups: [(final: URL, backup: URL)]) {
        for (_, backup) in backups where FileManager.default.fileExists(atPath: backup.path) {
            try? fileOperations.removeItem(backup)
        }
    }

    private func cleanupPartials(for model: LocalAIModel) {
        try? store.deletePartialModel(model)
    }

    private static func urlSessionDownload(
        source: URL,
        destination: URL,
        progress: @escaping (LocalAIDownloadProgress) -> Void,
        task: LocalAIInstallTask
    ) throws {
        let downloader = URLSessionStreamingDownloader(destination: destination, progress: progress, installTask: task)
        try downloader.download(from: source)
    }
}

private final class URLSessionStreamingDownloader: NSObject, URLSessionDataDelegate {
    private let destination: URL
    private let progress: (LocalAIDownloadProgress) -> Void
    private let installTask: LocalAIInstallTask
    private let semaphore = DispatchSemaphore(value: 0)
    private var fileHandle: FileHandle?
    private var downloadedBytes: Int64 = 0
    private var totalBytes: Int64?
    private var result: Result<Void, Error> = .success(())
    private var preserveFailure = false

    init(destination: URL, progress: @escaping (LocalAIDownloadProgress) -> Void, installTask: LocalAIInstallTask) {
        self.destination = destination
        self.progress = progress
        self.installTask = installTask
    }

    func download(from source: URL) throws {
        try Data().write(to: destination)
        fileHandle = try FileHandle(forWritingTo: destination)
        defer { try? fileHandle?.close() }

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let dataTask = session.dataTask(with: source)
        installTask.setCancellationHandler { [weak dataTask] in dataTask?.cancel() }
        if installTask.isCancelled { dataTask.cancel() } else { dataTask.resume() }
        semaphore.wait()
        installTask.setCancellationHandler(nil)
        session.invalidateAndCancel()
        try result.get()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            result = .failure(LocalAIInstallerError.downloadFailed("HTTP \(response.statusCode)"))
            preserveFailure = true
            completionHandler(.cancel)
            return
        }
        let expected = response.expectedContentLength
        totalBytes = expected > 0 ? expected : nil
        progress(LocalAIDownloadProgress(downloadedBytes: downloadedBytes, totalBytes: totalBytes))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if installTask.isCancelled { dataTask.cancel(); return }
        do {
            try fileHandle?.write(contentsOf: data)
            downloadedBytes += Int64(data.count)
            progress(LocalAIDownloadProgress(downloadedBytes: downloadedBytes, totalBytes: totalBytes))
        } catch {
            result = .failure(LocalAIInstallerError.downloadFailed(error.localizedDescription))
            preserveFailure = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { semaphore.signal() }
        if installTask.isCancelled {
            result = .failure(LocalAIInstallerError.cancelled)
            progress(LocalAIDownloadProgress(downloadedBytes: downloadedBytes, totalBytes: totalBytes, isCancelled: true))
        } else if let error, !preserveFailure {
            result = .failure(LocalAIInstallerError.downloadFailed(error.localizedDescription))
        }
    }
}
