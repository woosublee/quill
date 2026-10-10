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

    /// The audio is in iCloud and can be had: ready to download, already
    /// downloading (a request joins it), or worth trying again.
    var isInICloud: Bool {
        if case .downloading = self { return true }
        return canStartDownload
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
    /// Why a download failed, for the marker it was for.
    struct Failure: Equatable {
        let reason: NoteAudioUnavailableReason
        let sha256: String
    }

    @Published private(set) var failures: [UUID: Failure] = [:]

    private let downloadsDirectory: URL
    private let fetcher: @MainActor () -> NoteAudioPartFetching?
    private let isSyncOn: @MainActor () -> Bool
    private let hashFile: (URL) async throws -> String
    /// A part is gone from iCloud: the marker here is likely out of date.
    private let onMissingPart: @MainActor () -> Void
    /// Each download has its own token, so one that was cancelled can't
    /// clear what a new download for the same note set up.
    private var running: [UUID: (token: UUID, manifest: NoteAudioManifest, task: Task<URL?, Never>)] = [:]

    init(
        downloadsDirectory: URL,
        fetcher: @escaping @MainActor () -> NoteAudioPartFetching?,
        isSyncOn: @escaping @MainActor () -> Bool,
        onMissingPart: @escaping @MainActor () -> Void = {},
        hashFile: @escaping (URL) async throws -> String = NoteAudioDownloader.hashOffMain
    ) {
        self.downloadsDirectory = downloadsDirectory
        self.fetcher = fetcher
        self.isSyncOn = isSyncOn
        self.onMissingPart = onMissingPart
        self.hashFile = hashFile
    }

    nonisolated static func hashOffMain(_ url: URL) async throws -> String {
        try await Task.detached(priority: .utility) { try NoteAudioParts.sha256(of: url) }.value
    }

    func state(noteID: UUID, hasAudio: Bool, isLocal: Bool, manifest: NoteAudioManifest?) -> NoteAudioState {
        guard hasAudio else { return .none }
        if isLocal { return .local }
        if let progress = progress[noteID] { return .downloading(progress) }
        guard isSyncOn() else {
            // A file missing on a Mac that never synced it is no audio, as
            // before sync; audio marked in iCloud waits for sync.
            return manifest == nil ? .none : .unavailable(.syncOff)
        }
        guard let manifest else { return .unavailable(.notUploadedYet) }
        // A failure for an earlier marker says nothing about this one.
        if let failure = failures[noteID], failure.sha256 == manifest.sha256 { return .unavailable(failure.reason) }
        return .downloadable
    }

    /// Returns `destination` once the audio is there, or nil when it
    /// couldn't be downloaded (the reason is in `state`) or was cancelled.
    func download(noteID: UUID, manifest: NoteAudioManifest, to destination: URL) async -> URL? {
        if let current = running[noteID] {
            // The same audio joins the running download; other audio (a
            // new file from another Mac) replaces it.
            if current.manifest == manifest { return await current.task.value }
            cancel(noteID: noteID)
        }
        failures[noteID] = nil
        progress[noteID] = 0
        let token = UUID()
        let task = Task { await self.run(noteID: noteID, token: token, manifest: manifest, destination: destination) }
        running[noteID] = (token, manifest, task)
        return await task.value
    }

    /// Stops a download and removes what it had fetched. A request right
    /// after starts a new download rather than joining the stopped one.
    func cancel(noteID: UUID) {
        running.removeValue(forKey: noteID)?.task.cancel()
        progress[noteID] = nil
    }

    /// The notes downloading now.
    var downloadingNotes: Set<UUID> { Set(running.keys) }

    /// The note's marker changed (another Mac replaced or removed the
    /// file): a download of the earlier one stops.
    func cancel(noteID: UUID, unlessDownloading manifest: NoteAudioManifest?) {
        guard let current = running[noteID], current.manifest != manifest else { return }
        cancel(noteID: noteID)
    }

    /// Sync turned off: every download stops. (The engine removes download
    /// files when it starts and stops.)
    func cancelAll() {
        for noteID in Array(running.keys) { cancel(noteID: noteID) }
    }

    private func isCurrent(_ noteID: UUID, _ token: UUID) -> Bool {
        running[noteID]?.token == token
    }

    /// Progress only moves forward, and only in steps a person can see.
    private func report(_ fraction: Double, for noteID: UUID, token: UUID) {
        guard isCurrent(noteID, token) else { return }
        let current = progress[noteID] ?? 0
        if fraction >= current + 0.01 || (fraction >= 1 && current < 1) { progress[noteID] = fraction }
    }

    nonisolated static func removeDownloadFiles(in directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where ["partial", "fetched"].contains(file.pathExtension) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func partialFile(for noteID: UUID, token: UUID) -> URL {
        downloadsDirectory.appendingPathComponent("\(noteID.uuidString)-\(token.uuidString).partial")
    }

    private func run(noteID: UUID, token: UUID, manifest: NoteAudioManifest, destination: URL) async -> URL? {
        let partial = partialFile(for: noteID, token: token)
        defer {
            try? FileManager.default.removeItem(at: partial)
            if isCurrent(noteID, token) {
                running[noteID] = nil
                progress[noteID] = nil
            }
        }
        guard let fetcher = fetcher() else {
            // With sync off, `state` says so; nothing to remember.
            if isSyncOn() { failures[noteID] = Failure(reason: .failed, sha256: manifest.sha256) }
            return nil
        }
        for attempt in 0..<2 {
            do {
                if isCurrent(noteID, token) { progress[noteID] = 0 }
                try await fetchParts(noteID: noteID, token: token, manifest: manifest, from: fetcher, into: partial)
                let size = (try? FileManager.default.attributesOfItem(atPath: partial.path))?[.size] as? NSNumber
                let sha256 = try await hashFile(partial)
                try Task.checkCancellation()
                guard isCurrent(noteID, token) else { return nil }
                guard size?.int64Value == manifest.bytes, sha256 == manifest.sha256 else {
                    // A bad copy: thrown away, and fetched once more.
                    print("[NoteSync] Downloaded audio didn't match its marker")
                    try? FileManager.default.removeItem(at: partial)
                    if attempt == 0 { continue }
                    if isCurrent(noteID, token) { failures[noteID] = Failure(reason: .failed, sha256: manifest.sha256) }
                    return nil
                }
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                // Only the verified copy is trusted, even over a file
                // already in the way.
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
                } else {
                    try FileManager.default.moveItem(at: partial, to: destination)
                }
                return destination
            } catch is CancellationError {
                return nil
            } catch {
                // A stopped download didn't fail; whatever it hit after the
                // stop (sync gone, its file removed) isn't the audio's fault.
                guard !Task.isCancelled, isCurrent(noteID, token) else { return nil }
                if case NoteAudioFetchError.offline = error {
                    failures[noteID] = Failure(reason: .offline, sha256: manifest.sha256)
                } else {
                    print("[NoteSync] Couldn't download audio")
                    failures[noteID] = Failure(reason: .failed, sha256: manifest.sha256)
                    // Usually another Mac replaced the file: a sync brings
                    // the new marker (or that the zone is gone).
                    if case NoteAudioFetchError.missing = error { onMissingPart() }
                }
                return nil
            }
        }
        return nil
    }

    /// Fetches every part in order and appends it to `partial`.
    private func fetchParts(
        noteID: UUID,
        token: UUID,
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
                    self?.report((Double(index) + fraction) / count, for: noteID, token: token)
                }
            }
            defer { try? FileManager.default.removeItem(at: file) }
            try Task.checkCancellation()
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            report(Double(index + 1) / count, for: noteID, token: token)
        }
    }
}
