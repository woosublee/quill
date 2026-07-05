import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum NativeWhisperInstallerError: LocalizedError, Equatable {
    case cancelled
    case downloadFailed(String)
    case verificationFailed(String)
    case moveFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Local Whisper installation was canceled."
        case .downloadFailed:
            return "Could not download Local Whisper. Check your network connection and free disk space, then try again."
        case .verificationFailed:
            return "Could not verify the Local Whisper model. Try downloading it again."
        case .moveFailed:
            return "Could not finish installing Local Whisper."
        }
    }
}

final class NativeWhisperInstallTask {
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
        let shouldCancelImmediately: Bool
        lock.lock()
        cancellationHandler = handler
        shouldCancelImmediately = cancelled && handler != nil
        lock.unlock()
        if shouldCancelImmediately {
            handler?()
        }
    }
}

struct NativeWhisperInstaller {
    typealias DownloadFunction = (
        _ source: URL,
        _ destination: URL,
        _ progress: @escaping (NativeWhisperDownloadProgress) -> Void,
        _ task: NativeWhisperInstallTask
    ) throws -> Void

    let store: NativeWhisperModelStore
    let download: DownloadFunction
    private let queue: DispatchQueue

    init(
        store: NativeWhisperModelStore = NativeWhisperModelStore(),
        queue: DispatchQueue = DispatchQueue(label: "quill.native-whisper-installer", qos: .utility),
        download: @escaping DownloadFunction = NativeWhisperInstaller.urlSessionDownload
    ) {
        self.store = store
        self.queue = queue
        self.download = download
    }

    @discardableResult
    func install(
        model: NativeWhisperModel,
        progress: @escaping (NativeWhisperDownloadProgress) -> Void,
        completion: @escaping (Result<Void, NativeWhisperInstallerError>) -> Void
    ) -> NativeWhisperInstallTask {
        let task = NativeWhisperInstallTask()
        queue.async {
            let result = performInstall(model: model, progress: progress, task: task)
            completion(result)
        }
        return task
    }

    private func performInstall(
        model: NativeWhisperModel,
        progress: @escaping (NativeWhisperDownloadProgress) -> Void,
        task: NativeWhisperInstallTask
    ) -> Result<Void, NativeWhisperInstallerError> {
        let partial = store.partialModelURL(for: model)
        do {
            try store.ensureModelsDirectoryExists()
            let final = store.modelURL(for: model)
            try? store.fileManager.removeItem(at: partial)
            try download(model.downloadURL, partial, progress, task)
            task.setCancellationHandler(nil)
            guard !task.isCancelled else {
                try? store.fileManager.removeItem(at: partial)
                return .failure(.cancelled)
            }
            guard store.fileManager.fileExists(atPath: partial.path) else {
                return .failure(.downloadFailed("Download produced no file."))
            }
            if let validationError = store.validationError(for: model, at: partial) {
                try? store.fileManager.removeItem(at: partial)
                return .failure(.verificationFailed(validationError))
            }
            do {
                if store.fileManager.fileExists(atPath: final.path) {
                    _ = try store.fileManager.replaceItemAt(final, withItemAt: partial)
                } else {
                    try store.fileManager.moveItem(at: partial, to: final)
                }
            } catch {
                try? store.fileManager.removeItem(at: partial)
                return .failure(.moveFailed(error.localizedDescription))
            }
            return .success(())
        } catch let error as NativeWhisperInstallerError {
            try? store.fileManager.removeItem(at: partial)
            return .failure(error)
        } catch {
            try? store.fileManager.removeItem(at: partial)
            return .failure(.downloadFailed(error.localizedDescription))
        }
    }

    private static func urlSessionDownload(
        source: URL,
        destination: URL,
        progress: @escaping (NativeWhisperDownloadProgress) -> Void,
        task installTask: NativeWhisperInstallTask
    ) throws {
        let downloader = URLSessionStreamingDownloader(
            destination: destination,
            progress: progress,
            installTask: installTask
        )
        try downloader.download(from: source)
    }
}

private final class URLSessionStreamingDownloader: NSObject, URLSessionDataDelegate {
    private let destination: URL
    private let progress: (NativeWhisperDownloadProgress) -> Void
    private let installTask: NativeWhisperInstallTask
    private let semaphore = DispatchSemaphore(value: 0)
    private var fileHandle: FileHandle?
    private var session: URLSession?
    private var downloadedBytes: Int64 = 0
    private var totalBytes: Int64?
    private var result: Result<Void, Error> = .success(())
    private var preserveCompletionFailure = false

    init(
        destination: URL,
        progress: @escaping (NativeWhisperDownloadProgress) -> Void,
        installTask: NativeWhisperInstallTask
    ) {
        self.destination = destination
        self.progress = progress
        self.installTask = installTask
    }

    func download(from source: URL) throws {
        try Data().write(to: destination)
        fileHandle = try FileHandle(forWritingTo: destination)

        let configuration = URLSessionConfiguration.default
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let urlSessionTask = session.dataTask(with: source)
        installTask.setCancellationHandler { [weak urlSessionTask] in
            urlSessionTask?.cancel()
        }

        if installTask.isCancelled {
            urlSessionTask.cancel()
        } else {
            urlSessionTask.resume()
        }

        semaphore.wait()
        installTask.setCancellationHandler(nil)
        try fileHandle?.close()
        fileHandle = nil
        session.invalidateAndCancel()
        try result.get()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            result = .failure(NativeWhisperInstallerError.downloadFailed("HTTP \(httpResponse.statusCode)"))
            preserveCompletionFailure = true
            completionHandler(.cancel)
            return
        }
        let expected = response.expectedContentLength
        totalBytes = expected > 0 ? expected : nil
        progress(NativeWhisperDownloadProgress(downloadedBytes: downloadedBytes, totalBytes: totalBytes))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if installTask.isCancelled {
            dataTask.cancel()
            return
        }

        do {
            try fileHandle?.write(contentsOf: data)
            downloadedBytes += Int64(data.count)
            progress(NativeWhisperDownloadProgress(downloadedBytes: downloadedBytes, totalBytes: totalBytes))
        } catch {
            result = .failure(NativeWhisperInstallerError.downloadFailed(error.localizedDescription))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { semaphore.signal() }

        if installTask.isCancelled {
            result = .failure(NativeWhisperInstallerError.cancelled)
            progress(NativeWhisperDownloadProgress(
                downloadedBytes: downloadedBytes,
                totalBytes: totalBytes,
                isCancelled: true
            ))
            return
        }

        if let error {
            if !preserveCompletionFailure {
                result = .failure(NativeWhisperInstallerError.downloadFailed(error.localizedDescription))
            }
            return
        }

        result = .success(())
    }
}
