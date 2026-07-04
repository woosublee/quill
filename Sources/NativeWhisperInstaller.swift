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

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

struct NativeWhisperInstaller {
    typealias DownloadFunction = (
        _ source: URL,
        _ destination: URL,
        _ progress: @escaping (NativeWhisperDownloadProgress) -> Void,
        _ shouldCancel: @escaping () -> Bool
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
            try download(model.downloadURL, partial, progress, { task.isCancelled })
            guard !task.isCancelled else {
                try? store.fileManager.removeItem(at: partial)
                return .failure(.cancelled)
            }
            guard store.fileManager.fileExists(atPath: partial.path) else {
                return .failure(.downloadFailed("Download produced no file."))
            }
            try? store.fileManager.removeItem(at: final)
            do {
                try store.fileManager.moveItem(at: partial, to: final)
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
        shouldCancel: @escaping () -> Bool
    ) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, Error> = .failure(NativeWhisperInstallerError.downloadFailed("Download did not start."))
        let task = URLSession.shared.downloadTask(with: source) { temporaryURL, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(NativeWhisperInstallerError.downloadFailed(error.localizedDescription))
                return
            }
            guard let temporaryURL else {
                result = .failure(NativeWhisperInstallerError.downloadFailed("No downloaded file was produced."))
                return
            }
            do {
                let total = response?.expectedContentLength ?? -1
                let data = try Data(contentsOf: temporaryURL)
                if shouldCancel() {
                    result = .failure(NativeWhisperInstallerError.cancelled)
                    return
                }
                try data.write(to: destination, options: .atomic)
                progress(NativeWhisperDownloadProgress(
                    downloadedBytes: Int64(data.count),
                    totalBytes: total > 0 ? total : Int64(data.count)
                ))
                result = .success(())
            } catch {
                result = .failure(NativeWhisperInstallerError.downloadFailed(error.localizedDescription))
            }
        }
        task.resume()
        semaphore.wait()
        try result.get()
    }
}
