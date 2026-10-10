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
        try await testSyncTurnedBackOnCanDownload()
        try await testCancelAllStopsEveryDownload()
        try await testRequestAfterStopStartsAFreshDownload()
        try await testVerifiedCopyReplacesAFileInTheWay()
        try await testMissingPartAsksForASync()
        try await testFailureForAnEarlierMarkerIsForgotten()
        try await testChangedMarkerStopsTheDownload()
        try testEmptyFileIsNoAudioHere()
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
    static func setup(syncOn: Bool = true, onMissingPart: @escaping @MainActor () -> Void = {}) throws -> Setup {
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
            isSyncOn: { syncOn },
            onMissingPart: onMissingPart
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
        precondition(off.state(noteID: id, hasAudio: true, isLocal: false, manifest: nil) == .none,
                     "a missing file on a Mac without sync looks like no audio, as before")
        precondition(NoteAudioState.downloading(0.5).isInICloud && NoteAudioState.downloadable.isInICloud)
        precondition(!NoteAudioState.local.isInICloud && !NoteAudioState.unavailable(.syncOff).isInICloud)
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

    /// Trying while sync was off doesn't leave the audio stuck as "turn on
    /// sync" once sync is back on.
    @MainActor
    static func testSyncTurnedBackOnCanDownload() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        var syncOn = false
        var fetcherAvailable = false
        let downloader = NoteAudioDownloader(
            downloadsDirectory: s.dir.appendingPathComponent("downloads", isDirectory: true),
            fetcher: { fetcherAvailable ? s.fetcher : nil },
            isSyncOn: { syncOn }
        )
        _ = await downloader.download(noteID: s.noteID, manifest: s.manifest, to: s.destination)
        syncOn = true
        fetcherAvailable = true
        precondition(downloader.state(noteID: s.noteID, hasAudio: true, isLocal: false, manifest: s.manifest) == .downloadable)
    }

    /// Turning sync off stops every download and removes what it fetched.
    @MainActor
    static func testCancelAllStopsEveryDownload() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        s.fetcher.beforeEachPart = {
            if s.fetcher.fetched.count == 1 { s.downloader.cancelAll() }
        }
        let url = await s.downloader.download(noteID: s.noteID, manifest: s.manifest, to: s.destination)
        precondition(url == nil)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: s.dir.appendingPathComponent("downloads").path)) ?? []
        precondition(leftovers.isEmpty, "the partial file is removed: \(leftovers)")
        precondition(s.downloader.state(noteID: s.noteID, hasAudio: true, isLocal: false, manifest: s.manifest) == .downloadable)
    }

    /// A request right after Stop starts a fresh download; the stopped one
    /// can't clear it or remove its file.
    @MainActor
    static func testRequestAfterStopStartsAFreshDownload() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        var restarted: Task<URL?, Never>?
        s.fetcher.beforeEachPart = {
            if s.fetcher.fetched.count == 1, restarted == nil {
                s.downloader.cancel(noteID: s.noteID)
                restarted = Task { await s.downloader.download(noteID: s.noteID, manifest: s.manifest, to: s.destination) }
            }
        }
        let first = await s.downloader.download(noteID: s.noteID, manifest: s.manifest, to: s.destination)
        let second = await restarted?.value
        precondition(first == nil && second == s.destination, "the new download finishes")
        let joined = try Data(contentsOf: s.destination)
        precondition(joined == Data((0..<10).map { UInt8($0) }))
    }

    /// Whatever sits where the audio goes, the verified download wins.
    @MainActor
    static func testVerifiedCopyReplacesAFileInTheWay() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        try FileManager.default.createDirectory(at: s.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([9, 9]).write(to: s.destination)
        let url = await s.downloader.download(noteID: s.noteID, manifest: s.manifest, to: s.destination)
        precondition(url == s.destination)
        let saved = try Data(contentsOf: s.destination)
        precondition(saved == Data((0..<10).map { UInt8($0) }), "the unverified file was replaced")
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

    /// A part gone from iCloud usually means another Mac replaced the file
    /// and this Mac's marker is out of date: a sync brings the new one.
    @MainActor
    static func testMissingPartAsksForASync() async throws {
        final class Count { var syncs = 0 }
        let count = Count()
        let s = try setup(onMissingPart: { count.syncs += 1 })
        defer { try? FileManager.default.removeItem(at: s.dir) }
        s.fetcher.parts = [:]
        _ = await s.downloader.download(noteID: s.noteID, manifest: s.manifest, to: s.destination)
        precondition(count.syncs == 1)
        s.fetcher.error = .offline
        _ = await s.downloader.download(noteID: s.noteID, manifest: s.manifest, to: s.destination)
        precondition(count.syncs == 1, "offline isn't a missing part")
    }

    /// A failure belongs to the marker it was for; new audio from another
    /// Mac starts fresh.
    @MainActor
    static func testFailureForAnEarlierMarkerIsForgotten() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        s.fetcher.error = .offline
        _ = await s.downloader.download(noteID: s.noteID, manifest: s.manifest, to: s.destination)
        let newer = NoteAudioManifest(sha256: String(repeating: "cd", count: 32), bytes: 10, partSize: 4, parts: 3)
        precondition(s.downloader.state(noteID: s.noteID, hasAudio: true, isLocal: false, manifest: s.manifest) == .unavailable(.offline))
        precondition(s.downloader.state(noteID: s.noteID, hasAudio: true, isLocal: false, manifest: newer) == .downloadable)
    }

    /// Another Mac's new file arrives mid-download: the download of the
    /// earlier one stops; the same marker arriving again doesn't stop it.
    @MainActor
    static func testChangedMarkerStopsTheDownload() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        s.fetcher.beforeEachPart = { s.downloader.cancel(noteID: s.noteID, unlessDownloading: s.manifest) }
        let same = await s.downloader.download(noteID: s.noteID, manifest: s.manifest, to: s.destination)
        precondition(same == s.destination, "the same marker keeps going")

        let t = try setup()
        defer { try? FileManager.default.removeItem(at: t.dir) }
        let newer = NoteAudioManifest(sha256: String(repeating: "cd", count: 32), bytes: 10, partSize: 4, parts: 3)
        t.fetcher.beforeEachPart = { t.downloader.cancel(noteID: t.noteID, unlessDownloading: newer) }
        let stale = await t.downloader.download(noteID: t.noteID, manifest: t.manifest, to: t.destination)
        precondition(stale == nil && !FileManager.default.fileExists(atPath: t.destination.path))
        t.fetcher.beforeEachPart = { t.downloader.cancel(noteID: t.noteID, unlessDownloading: nil) }
        let cleared = await t.downloader.download(noteID: t.noteID, manifest: t.manifest, to: t.destination)
        precondition(cleared == nil, "a marker cleared elsewhere stops it too")
    }

    /// An empty file (an interrupted copy) isn't audio here, so the copy
    /// in iCloud is offered.
    static func testEmptyFileIsNoAudioHere() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quill-audio-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appendingPathComponent("empty.wav"), full = dir.appendingPathComponent("full.wav")
        try Data().write(to: empty)
        try Data([1, 2, 3]).write(to: full)
        precondition(!NoteAudioDownloader.isUsableLocalAudio(at: empty))
        precondition(NoteAudioDownloader.isUsableLocalAudio(at: full))
        precondition(!NoteAudioDownloader.isUsableLocalAudio(at: dir.appendingPathComponent("gone.wav")))
    }
}
