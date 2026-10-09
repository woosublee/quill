import Foundation

@main
struct NoteAudioDownloaderTests {
    @MainActor
    static func main() async throws {
        testStates()
        try await testPartsRejoinIntoTheAudioFile()
        try await testHashMismatchTriesOnceMoreThenFails()
        try await testCancelRemovesThePartialFile()
        try await testTwoRequestsShareOneDownload()
        try await testOfflineAndMissingPartsSayWhy()
        try await testRetryAfterAFailureStartsClean()
        print("NoteAudioDownloaderTests passed")
    }

    /// Serves synthetic parts from memory, like iCloud would.
    final class FakeFetcher: NoteAudioPartFetching, @unchecked Sendable {
        var parts: [NoteAudioPartID: Data] = [:]
        var error: NoteAudioFetchError?
        var fetched: [NoteAudioPartID] = []
        var corruptOnce = false
        var corruptAlways = false
        /// Runs before each part is served, for tests that act mid-download.
        var beforeEachPart: (@MainActor () async -> Void)?
        let dir: URL

        init(dir: URL) { self.dir = dir }

        func fetchAudioPart(_ part: NoteAudioPartID, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
            await beforeEachPart?()
            try Task.checkCancellation()
            fetched.append(part)
            if let error { throw error }
            guard var data = parts[part] else { throw NoteAudioFetchError.missing }
            if corruptAlways || corruptOnce {
                corruptOnce = false
                data[0] ^= 0xFF
            }
            progress(0.5)
            let url = dir.appendingPathComponent("served-\(UUID().uuidString)")
            try data.write(to: url)
            progress(1)
            return url
        }
    }

    struct Setup {
        let downloader: NoteAudioDownloader
        let fetcher: FakeFetcher
        let dir: URL
        let destination: URL
        let manifest: NoteAudioManifest
        let noteID: UUID
    }

    /// Ten synthetic bytes in parts of four, so three parts.
    @MainActor
    static func setup(syncOn: Bool = true) throws -> Setup {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quill-audio-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bytes = Data((0..<10).map { UInt8($0) })
        let source = dir.appendingPathComponent("source.wav")
        try bytes.write(to: source)
        let sha = try NoteAudioParts.sha256(of: source)
        try FileManager.default.removeItem(at: source)
        let noteID = UUID()
        let manifest = NoteAudioManifest(sha256: sha, bytes: 10, partSize: 4, parts: 3)
        let fetcher = FakeFetcher(dir: dir)
        for part in manifest.partIDs(noteID: noteID) {
            let range = NoteAudioParts.range(index: part.index, bytes: 10, partSize: 4)
            fetcher.parts[part] = bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
        let downloader = NoteAudioDownloader(
            downloadsDirectory: dir.appendingPathComponent("downloads", isDirectory: true),
            fetcher: { fetcher },
            isSyncOn: { syncOn }
        )
        return Setup(
            downloader: downloader,
            fetcher: fetcher,
            dir: dir,
            destination: dir.appendingPathComponent("audio/note.wav"),
            manifest: manifest,
            noteID: noteID
        )
    }

    @MainActor
    static func testStates() {
        let downloader = NoteAudioDownloader(
            downloadsDirectory: FileManager.default.temporaryDirectory,
            fetcher: { nil },
            isSyncOn: { true }
        )
        let off = NoteAudioDownloader(
            downloadsDirectory: FileManager.default.temporaryDirectory,
            fetcher: { nil },
            isSyncOn: { false }
        )
        let id = UUID()
        let manifest = NoteAudioManifest(sha256: String(repeating: "ab", count: 32), bytes: 10, partSize: 4, parts: 3)
        precondition(downloader.state(noteID: id, hasAudio: false, isLocal: false, manifest: manifest) == .none)
        precondition(downloader.state(noteID: id, hasAudio: true, isLocal: true, manifest: nil) == .local)
        precondition(downloader.state(noteID: id, hasAudio: true, isLocal: false, manifest: manifest) == .downloadable)
        precondition(downloader.state(noteID: id, hasAudio: true, isLocal: false, manifest: nil) == .unavailable(.notUploadedYet))
        precondition(off.state(noteID: id, hasAudio: true, isLocal: false, manifest: manifest) == .unavailable(.syncOff))
        precondition(NoteAudioState.downloadable.canStartDownload && NoteAudioState.unavailable(.failed).canStartDownload)
        precondition(NoteAudioState.unavailable(.offline).canStartDownload, "offline can be tried again")
        precondition(!NoteAudioState.unavailable(.notUploadedYet).canStartDownload && !NoteAudioState.unavailable(.syncOff).canStartDownload)
    }

    @MainActor
    static func testPartsRejoinIntoTheAudioFile() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        let url = await s.downloader.download(noteID: s.noteID, manifest: s.manifest, to: s.destination)
        precondition(url == s.destination)
        let joined = try Data(contentsOf: s.destination)
        precondition(joined == Data((0..<10).map { UInt8($0) }), "parts rejoin to the original bytes")
        precondition(s.fetcher.fetched.map(\.index) == [0, 1, 2], "in order")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: s.dir.appendingPathComponent("downloads").path)) ?? []
        precondition(leftovers.isEmpty, "the partial file is gone")
        precondition(s.downloader.state(noteID: s.noteID, hasAudio: true, isLocal: true, manifest: s.manifest) == .local)
    }

    @MainActor
    static func testHashMismatchTriesOnceMoreThenFails() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        s.fetcher.corruptOnce = true
        let healed = await s.downloader.download(noteID: s.noteID, manifest: s.manifest, to: s.destination)
        precondition(healed == s.destination && s.fetcher.fetched.count == 6, "a bad copy is fetched once more")

        let t = try setup()
        defer { try? FileManager.default.removeItem(at: t.dir) }
        t.fetcher.corruptAlways = true
        let failed = await t.downloader.download(noteID: t.noteID, manifest: t.manifest, to: t.destination)
        precondition(failed == nil && !FileManager.default.fileExists(atPath: t.destination.path))
        precondition(t.downloader.state(noteID: t.noteID, hasAudio: true, isLocal: false, manifest: t.manifest) == .unavailable(.failed))
    }

    @MainActor
    static func testCancelRemovesThePartialFile() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        var served = 0
        var stateMidway: NoteAudioState?
        s.fetcher.beforeEachPart = {
            served += 1
            if served == 2 {
                stateMidway = s.downloader.state(noteID: s.noteID, hasAudio: true, isLocal: false, manifest: s.manifest)
                s.downloader.cancel(noteID: s.noteID)
            }
        }
        let url = await s.downloader.download(noteID: s.noteID, manifest: s.manifest, to: s.destination)
        guard case .downloading(let progress)? = stateMidway else { preconditionFailure("shows progress while downloading") }
        precondition(progress > 0.3 && progress < 0.4, "one part of three: \(progress)")
        precondition(url == nil && !FileManager.default.fileExists(atPath: s.destination.path))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: s.dir.appendingPathComponent("downloads").path)) ?? []
        precondition(leftovers.isEmpty, "the partial file is removed")
        precondition(s.downloader.state(noteID: s.noteID, hasAudio: true, isLocal: false, manifest: s.manifest) == .downloadable,
                     "a cancel isn't a failure")
    }

    @MainActor
    static func testTwoRequestsShareOneDownload() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        async let first = s.downloader.download(noteID: s.noteID, manifest: s.manifest, to: s.destination)
        async let second = s.downloader.download(noteID: s.noteID, manifest: s.manifest, to: s.destination)
        let (a, b) = await (first, second)
        precondition(a == s.destination && b == s.destination)
        precondition(s.fetcher.fetched.count == 3, "each part is fetched once")
    }

    @MainActor
    static func testOfflineAndMissingPartsSayWhy() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        s.fetcher.error = .offline
        _ = await s.downloader.download(noteID: s.noteID, manifest: s.manifest, to: s.destination)
        precondition(s.downloader.state(noteID: s.noteID, hasAudio: true, isLocal: false, manifest: s.manifest) == .unavailable(.offline))

        let t = try setup()
        defer { try? FileManager.default.removeItem(at: t.dir) }
        t.fetcher.parts = [:]
        _ = await t.downloader.download(noteID: t.noteID, manifest: t.manifest, to: t.destination)
        precondition(t.downloader.state(noteID: t.noteID, hasAudio: true, isLocal: false, manifest: t.manifest) == .unavailable(.failed),
                     "a marker whose parts are gone can't be downloaded")
        precondition(t.fetcher.fetched.count == 1, "a missing part isn't fetched again")
    }

    @MainActor
    static func testRetryAfterAFailureStartsClean() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        s.fetcher.error = .offline
        _ = await s.downloader.download(noteID: s.noteID, manifest: s.manifest, to: s.destination)
        s.fetcher.error = nil
        let url = await s.downloader.download(noteID: s.noteID, manifest: s.manifest, to: s.destination)
        precondition(url == s.destination)
        precondition(s.downloader.state(noteID: s.noteID, hasAudio: true, isLocal: true, manifest: s.manifest) == .local)
    }
}
