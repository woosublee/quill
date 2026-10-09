import Foundation

/// Why a note's audio can't be downloaded right now.
enum NoteAudioUnavailableReason: Equatable, Sendable {
    /// No marker: the Mac that recorded it hasn't finished uploading.
    case notUploadedYet
    case syncOff
    case offline
    case failed
}

/// A note's audio as the audio bar, Retranscribe, and Export see it.
enum NoteAudioState: Equatable {
    /// The note has no audio.
    case none
    case local
    case downloadable
    case downloading(Double)
    case unavailable(NoteAudioUnavailableReason)

    /// Why the audio can't be had right now, for the audio bar and Export.
    var unavailableMessage: String? {
        guard case .unavailable(let reason) = self else { return nil }
        switch reason {
        case .notUploadedYet:
            return localizedCatalogString("Audio hasn't reached iCloud yet from the Mac that recorded it.")
        case .syncOff:
            return localizedCatalogString("Turn on iCloud sync to download this audio.")
        case .offline:
            return localizedCatalogString("Connect to the internet to download this audio.")
        case .failed:
            return localizedCatalogString("Couldn't download this audio. Try again.")
        }
    }

    /// Whether choosing the audio starts a download: also after a failed
    /// or offline try, which can be tried again.
    var canStartDownload: Bool {
        switch self {
        case .downloadable, .unavailable(.failed), .unavailable(.offline): return true
        default: return false
        }
    }
}

enum NoteAudioFetchError: Error {
    /// iCloud has no such part.
    case missing
    case offline
    case failed
}

/// Downloads one audio part from iCloud. The CloudKit engine provides it;
/// tests use a fake.
protocol NoteAudioPartFetching: AnyObject {
    /// Saves the part's bytes to a new file the caller owns and removes.
    /// `progress` reports this part from 0 to 1.
    func fetchAudioPart(_ part: NoteAudioPartID, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

/// Downloads note audio from iCloud when the user plays, retranscribes, or
/// exports it. Parts are fetched in order into `<id>.partial`, checked
/// against the marker's size and SHA-256, and moved into place; a bad copy
/// is fetched once more. A download keeps going when the note closes, and
/// a second request for the same note joins it.
@MainActor
final class NoteAudioDownloader: ObservableObject {
    @Published private(set) var progress: [UUID: Double] = [:]
    @Published private(set) var failures: [UUID: NoteAudioUnavailableReason] = [:]

    private let downloadsDirectory: URL
    private let fetcher: @MainActor () -> NoteAudioPartFetching?
    private let isSyncOn: @MainActor () -> Bool
    private let hashFile: (URL) async throws -> String
    private var running: [UUID: Task<URL?, Never>] = [:]

    init(
        downloadsDirectory: URL,
        fetcher: @escaping @MainActor () -> NoteAudioPartFetching?,
        isSyncOn: @escaping @MainActor () -> Bool,
        hashFile: @escaping (URL) async throws -> String = NoteAudioDownloader.hashOffMain
    ) {
        self.downloadsDirectory = downloadsDirectory
        self.fetcher = fetcher
        self.isSyncOn = isSyncOn
        self.hashFile = hashFile
    }

    nonisolated static func hashOffMain(_ url: URL) async throws -> String {
        try await Task.detached(priority: .utility) { try NoteAudioParts.sha256(of: url) }.value
    }

    func state(noteID: UUID, hasAudio: Bool, isLocal: Bool, manifest: NoteAudioManifest?) -> NoteAudioState {
        guard hasAudio else { return .none }
        if isLocal { return .local }
        if let progress = progress[noteID] { return .downloading(progress) }
        guard isSyncOn() else { return .unavailable(.syncOff) }
        guard manifest != nil else { return .unavailable(.notUploadedYet) }
        if let reason = failures[noteID] { return .unavailable(reason) }
        return .downloadable
    }

    /// Returns `destination` once the audio is there, or nil when it
    /// couldn't be downloaded (the reason is in `state`) or was cancelled.
    func download(noteID: UUID, manifest: NoteAudioManifest, to destination: URL) async -> URL? {
        if let task = running[noteID] { return await task.value }
        failures[noteID] = nil
        progress[noteID] = 0
        let task = Task { await self.run(noteID: noteID, manifest: manifest, destination: destination) }
        running[noteID] = task
        return await task.value
    }

    /// Stops a download and removes what it had fetched.
    func cancel(noteID: UUID) {
        running[noteID]?.cancel()
    }

    private func partialFile(for noteID: UUID) -> URL {
        downloadsDirectory.appendingPathComponent("\(noteID.uuidString).partial")
    }

    private func run(noteID: UUID, manifest: NoteAudioManifest, destination: URL) async -> URL? {
        let partial = partialFile(for: noteID)
        defer {
            try? FileManager.default.removeItem(at: partial)
            running[noteID] = nil
            progress[noteID] = nil
        }
        guard let fetcher = fetcher() else {
            failures[noteID] = isSyncOn() ? .failed : .syncOff
            return nil
        }
        for attempt in 0..<2 {
            do {
                try await fetchParts(noteID: noteID, manifest: manifest, from: fetcher, into: partial)
                let size = (try? FileManager.default.attributesOfItem(atPath: partial.path))?[.size] as? NSNumber
                let sha256 = try await hashFile(partial)
                try Task.checkCancellation()
                guard size?.int64Value == manifest.bytes, sha256 == manifest.sha256 else {
                    // A bad copy: thrown away, and fetched once more.
                    print("[NoteSync] Downloaded audio didn't match its marker")
                    try? FileManager.default.removeItem(at: partial)
                    if attempt == 0 { continue }
                    failures[noteID] = .failed
                    return nil
                }
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.moveItem(at: partial, to: destination)
                }
                return destination
            } catch is CancellationError {
                return nil
            } catch NoteAudioFetchError.offline {
                failures[noteID] = .offline
                return nil
            } catch {
                print("[NoteSync] Couldn't download audio")
                failures[noteID] = .failed
                return nil
            }
        }
        return nil
    }

    /// Fetches every part in order and appends it to `partial`.
    private func fetchParts(
        noteID: UUID,
        manifest: NoteAudioManifest,
        from fetcher: NoteAudioPartFetching,
        into partial: URL
    ) async throws {
        try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let output = try FileHandle(forWritingTo: partial)
        defer { try? output.close() }
        let parts = manifest.partIDs(noteID: noteID)
        for (index, part) in parts.enumerated() {
            try Task.checkCancellation()
            let count = Double(parts.count)
            let file = try await fetcher.fetchAudioPart(part) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.running[noteID] != nil else { return }
                    self.progress[noteID] = (Double(index) + fraction) / count
                }
            }
            defer { try? FileManager.default.removeItem(at: file) }
            try Task.checkCancellation()
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            progress[noteID] = Double(index + 1) / count
        }
    }
}
