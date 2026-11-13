import Combine
import Foundation
import QuillNoteSyncCore

@main
struct NoteAudioDownloadThenDeleteTests {
    @MainActor
    static func main() async throws {
        await testDownloadsEveryRecordingThenDeletes()
        await testSyncPausedWithNothingToDownloadWithDeletesNothing()
        await testTooLittleSpaceDownloadsAndDeletesNothing()
        await testAFailedDownloadStopsEverything()
        await testADownloadThatLeavesTheRecordingInICloudFails()
        await testHistoryThatCantBeReadAfterADownloadDeletesNothing()
        await testARecordingFoundByTheLastFetchIsDownloadedFirst()
        await testAFailedFirstFetchDeletesNothing()
        await testAFailedFetchAfterTheDownloadsDeletesNothing()
        await testCancelDuringAFetchDeletesNothing()
        await testARecordingThatBecameICloudOnlyMeanwhileIsDownloadedToo()
        await testSpaceIsCheckedAgainBeforeEachDownload()
        await testCancelStopsTheDownloadAndDeletesNothing()
        await testCancelAfterTheLastDownloadStillDeletesNothing()
        await testCancelDuringTheDeleteDoesNothing()
        await testHistoryThatCantBeReadDeletesNothing()
        await testNothingOnlyInICloudJustDeletes()
        await testAFailedDeleteIsReported()
        await testASecondRunWhileOneRunsStartsNothing()
        await testPhaseCountsDownloads()
        await testANewRunClearsTheOldNotice()
        await testTheDeleteWaitsForICloudsAnswer()
        await testARecordingICloudNamesIsDownloadedBeforeTheDelete()
        await testAnUnsureAnswerDeletesNothing()
        await testARecordingICloudNamesThatIsntListedDeletesNothing()
        await testSafeWithARecordingListedMeanwhileDownloadsIt()
        await testCancelDuringTheICloudCheckDeletesNothing()
        await testTheCheckRunsOncePerEmptyList()
        await testAFailedDownloadNeverAsksICloud()
        await testTooLittleSpaceNeverAsksICloud()
        await testARecordingICloudNamesAgainAfterItsDownloadFails()
        testFreeBytesOfARealFolderIsPositive()
        print("NoteAudioDownloadThenDeleteTests passed")
    }

    static let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    static let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    static let x = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!
    static let y = UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!
    static let names: [UUID: String] = [a: "a", b: "b", c: "c", x: "x", y: "y"]
    static let room = NoteAudioICloudDeletePolicy.workingRoom

    /// Holds a mutable list and logs what the runner does, in order.
    @MainActor
    final class Fake {
        var list: [NoteAudioOnlyInICloud]? = []
        /// Whether recordings can be fetched from iCloud now.
        var canDownload = true
        var free: Int64? = Int64.max
        var freeAsked = 0
        var log: [String] = []
        /// What a download returns; absent means true.
        var results: [UUID: Bool] = [:]
        /// Recordings a finished download leaves in the list.
        var keepsListed: Set<UUID> = []
        var onDownload: ((UUID) -> Void)?
        /// What each fetch returns, in order; once used up, true.
        var refreshResults: [Bool] = []
        var refreshes = 0
        /// Runs during a fetch, with the 1-based fetch number.
        var onRefresh: ((Int) -> Void)?
        var onDelete: (() -> Void)?
        var deleteResult = true
        /// What each check with iCloud returns, in order; once used up, `.safeToDelete`.
        var verdicts: [NoteAudioICloudDeleteCheck.Verdict] = []
        var confirms = 0
        /// Runs during a check with iCloud, with the 1-based check number.
        var onConfirm: ((Int) -> Void)?
        /// While set, a download waits for `release`.
        var holdDownloads = false
        var waiting: CheckedContinuation<Bool, Never>?

        func ids(_ ids: [UUID], bytes: Int64 = 100) {
            list = ids.map { NoteAudioOnlyInICloud(id: $0, bytes: bytes) }
        }

        func release(_ value: Bool) {
            waiting?.resume(returning: value)
            waiting = nil
        }

        func work() -> NoteAudioDownloadThenDelete.Work {
            .init(
                canDownload: { self.canDownload },
                recordingsOnlyInICloud: { self.list },
                refresh: {
                    self.log.append("refresh")
                    self.refreshes += 1
                    self.onRefresh?(self.refreshes)
                    return self.refreshResults.isEmpty ? true : self.refreshResults.removeFirst()
                },
                confirmWithICloud: {
                    self.log.append("confirm")
                    self.confirms += 1
                    self.onConfirm?(self.confirms)
                    return self.verdicts.isEmpty ? .safeToDelete : self.verdicts.removeFirst()
                },
                freeBytes: { self.freeAsked += 1; return self.free },
                download: { id in
                    self.log.append("download \(NoteAudioDownloadThenDeleteTests.names[id] ?? "?")")
                    self.onDownload?(id)
                    var result = self.results[id] ?? true
                    if self.holdDownloads {
                        result = await withCheckedContinuation { self.waiting = $0 }
                    }
                    if result && !self.keepsListed.contains(id) { self.list?.removeAll { $0.id == id } }
                    return result
                },
                cancelDownload: { id in
                    self.log.append("cancel \(NoteAudioDownloadThenDeleteTests.names[id] ?? "?")")
                    self.release(false)
                },
                deleteFromICloud: {
                    self.log.append("delete")
                    self.onDelete?()
                    return self.deleteResult
                }
            )
        }
    }

    @MainActor
    static func waitUntil(_ condition: @MainActor () -> Bool) async {
        var spins = 0
        while !condition() {
            await Task.yield()
            spins += 1
            precondition(spins < 100_000, "condition never became true")
        }
    }

    @MainActor
    static func testDownloadsEveryRecordingThenDeletes() async {
        let fake = Fake()
        fake.ids([a, b, c])
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .deleted)
        // The delete follows a fetch straight away: every awaited call the
        // runner makes (fetch, download, delete) is in the log.
        precondition(fake.log == ["refresh", "download a", "download b", "download c", "refresh", "confirm", "delete"], "\(fake.log)")
        precondition(runner.notice == nil)
        precondition(runner.phase == .idle && !runner.isRunning)
    }

    /// Sync paused with nothing running to download with (#838): the run
    /// says so, without fetching, downloading, or deleting anything.
    @MainActor
    static func testSyncPausedWithNothingToDownloadWithDeletesNothing() async {
        let fake = Fake()
        fake.ids([a, b])
        fake.canDownload = false
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .syncPaused, "\(outcome)")
        precondition(runner.notice == .syncPaused, "the notice stays until dismissed")
        precondition(fake.log.isEmpty, "nothing fetched, downloaded, or deleted: \(fake.log)")
        precondition(fake.refreshes == 0 && fake.freeAsked == 0 && fake.confirms == 0)
        precondition(runner.phase == .idle && !runner.isRunning)
        runner.dismissNotice()
        precondition(runner.notice == nil)
    }

    @MainActor
    static func testTooLittleSpaceDownloadsAndDeletesNothing() async {
        let fake = Fake()
        fake.list = [.init(id: a, bytes: 600), .init(id: b, bytes: 500)]
        fake.free = 1_100 + room - 1
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .notEnoughSpace(shortBy: 1), "\(outcome)")
        precondition(fake.log == ["refresh"], "\(fake.log)")
        precondition(runner.notice == .notEnoughSpace(shortBy: 1))
        precondition(runner.phase == .idle)
    }

    @MainActor
    static func testAFailedDownloadStopsEverything() async {
        let fake = Fake()
        fake.ids([a, b, c])
        fake.results[b] = false
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .downloadFailed)
        precondition(fake.log == ["refresh", "download a", "download b"], "\(fake.log)")
        precondition(runner.notice == .downloadFailed)
        precondition(runner.phase == .idle)
    }

    @MainActor
    static func testADownloadThatLeavesTheRecordingInICloudFails() async {
        let fake = Fake()
        fake.ids([a, b])
        fake.keepsListed = [a]
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .downloadFailed)
        // `a` is still listed after its download; `b` is tried, then the run stops.
        precondition(fake.log == ["refresh", "download a", "download b"], "\(fake.log)")
        precondition(runner.notice == .downloadFailed)
    }

    @MainActor
    static func testHistoryThatCantBeReadAfterADownloadDeletesNothing() async {
        let fake = Fake()
        fake.ids([a, b])
        fake.onDownload = { _ in fake.list = nil }
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .cannotCheck, "\(outcome)")
        precondition(fake.log == ["refresh", "download a"], "\(fake.log)")
        precondition(runner.notice == .cannotCheck)
    }

    /// The list went empty, and the fetch before the delete brought a
    /// recording another device made iCloud-only meanwhile.
    @MainActor
    static func testARecordingFoundByTheLastFetchIsDownloadedFirst() async {
        let fake = Fake()
        fake.ids([a])
        fake.onRefresh = { count in
            if count == 2 { fake.list?.append(.init(id: b, bytes: 100)) }
        }
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .deleted, "\(outcome)")
        precondition(fake.log == ["refresh", "download a", "refresh", "download b", "refresh", "confirm", "delete"], "\(fake.log)")
    }

    @MainActor
    static func testAFailedFirstFetchDeletesNothing() async {
        let fake = Fake()
        fake.ids([a])
        fake.refreshResults = [false]
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .downloadFailed, "\(outcome)")
        precondition(fake.log == ["refresh"], "\(fake.log)")
        precondition(runner.notice == .downloadFailed)
        precondition(runner.phase == .idle && !runner.isRunning)
    }

    @MainActor
    static func testAFailedFetchAfterTheDownloadsDeletesNothing() async {
        let fake = Fake()
        fake.ids([a, b])
        fake.refreshResults = [true, false]
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .downloadFailed, "\(outcome)")
        precondition(fake.log == ["refresh", "download a", "download b", "refresh"], "\(fake.log)")
        precondition(runner.notice == .downloadFailed)
    }

    /// Cancel during the first fetch and during the one before the delete.
    @MainActor
    static func testCancelDuringAFetchDeletesNothing() async {
        for cancelAt in [1, 2] {
            let fake = Fake()
            fake.ids([a])
            let runner = NoteAudioDownloadThenDelete(work: fake.work())
            fake.onRefresh = { count in
                guard count == cancelAt else { return }
                precondition(runner.phase == .checking)
                runner.cancel()
            }
            let outcome = await runner.run()
            precondition(outcome == .cancelled, "\(outcome)")
            let expected = cancelAt == 1 ? ["refresh"] : ["refresh", "download a", "refresh"]
            precondition(fake.log == expected, "\(fake.log)")
            precondition(runner.notice == nil)
            precondition(runner.phase == .idle && !runner.isRunning)
        }
    }

    @MainActor
    static func testARecordingThatBecameICloudOnlyMeanwhileIsDownloadedToo() async {
        let fake = Fake()
        fake.ids([a, b])
        fake.onDownload = { id in
            if id == a { fake.list?.append(.init(id: c, bytes: 100)) }
        }
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        var totals: [Int] = []
        let cancellable = runner.$phase.sink { phase in
            if case .downloading(_, let total, _) = phase { totals.append(total) }
        }
        let outcome = await runner.run()
        cancellable.cancel()
        precondition(outcome == .deleted)
        precondition(fake.log == ["refresh", "download a", "download b", "download c", "refresh", "confirm", "delete"], "\(fake.log)")
        precondition(totals.contains(3), "\(totals)")
    }

    @MainActor
    static func testSpaceIsCheckedAgainBeforeEachDownload() async {
        let fake = Fake()
        fake.ids([a, b], bytes: 600)
        fake.free = 1_200 + room
        fake.onDownload = { _ in fake.free = 600 + room - 1 }
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .notEnoughSpace(shortBy: 1), "\(outcome)")
        precondition(fake.log == ["refresh", "download a"], "\(fake.log)")
        precondition(runner.notice == outcome)
    }

    @MainActor
    static func testCancelStopsTheDownloadAndDeletesNothing() async {
        let fake = Fake()
        fake.ids([a, b])
        fake.holdDownloads = true
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let running = Task { @MainActor in await runner.run() }
        await waitUntil { fake.waiting != nil }
        runner.cancel()
        let outcome = await running.value
        precondition(outcome == .cancelled)
        precondition(fake.log == ["refresh", "download a", "cancel a"], "\(fake.log)")
        precondition(runner.notice == nil)
        precondition(runner.phase == .idle)
    }

    @MainActor
    static func testCancelAfterTheLastDownloadStillDeletesNothing() async {
        let fake = Fake()
        fake.ids([a])
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        fake.onDownload = { _ in runner.cancel() }
        let outcome = await runner.run()
        precondition(outcome == .cancelled)
        precondition(!fake.log.contains("delete"), "\(fake.log)")
        precondition(runner.notice == nil)
    }

    @MainActor
    static func testCancelDuringTheDeleteDoesNothing() async {
        let fake = Fake()
        fake.ids([a])
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        fake.onDelete = {
            precondition(runner.phase == .deleting)
            runner.cancel()
        }
        let outcome = await runner.run()
        precondition(outcome == .deleted)
        precondition(!fake.log.contains("cancel a"), "\(fake.log)")
    }

    @MainActor
    static func testHistoryThatCantBeReadDeletesNothing() async {
        let fake = Fake()
        fake.list = nil
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .cannotCheck)
        precondition(fake.log == ["refresh"], "\(fake.log)")
        precondition(runner.notice == .cannotCheck)
    }

    @MainActor
    static func testNothingOnlyInICloudJustDeletes() async {
        let fake = Fake()
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .deleted)
        precondition(fake.log == ["refresh", "confirm", "delete"], "\(fake.log)")
        precondition(fake.freeAsked == 0)
    }

    @MainActor
    static func testAFailedDeleteIsReported() async {
        let fake = Fake()
        fake.deleteResult = false
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .deleteFailed)
        precondition(runner.notice == .deleteFailed)
        precondition(runner.phase == .idle)
    }

    @MainActor
    static func testASecondRunWhileOneRunsStartsNothing() async {
        let fake = Fake()
        fake.ids([a])
        fake.holdDownloads = true
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let first = Task { @MainActor in await runner.run() }
        await waitUntil { fake.waiting != nil }
        let phase = runner.phase
        let second = await runner.run()
        precondition(second == .alreadyRunning)
        precondition(runner.phase == phase && runner.notice == nil && runner.isRunning)
        precondition(fake.log == ["refresh", "download a"], "\(fake.log)")
        fake.release(true)
        let outcome = await first.value
        precondition(outcome == .deleted)
        precondition(fake.log == ["refresh", "download a", "refresh", "confirm", "delete"], "\(fake.log)")
    }

    @MainActor
    static func testPhaseCountsDownloads() async {
        let fake = Fake()
        fake.ids([a, b])
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        var seen: [NoteAudioDownloadThenDelete.Phase] = []
        var running: [Bool] = []
        let cancellable = runner.$phase.sink { seen.append($0) }
        let runningCancellable = runner.$isRunning.sink { running.append($0) }
        _ = await runner.run()
        cancellable.cancel()
        runningCancellable.cancel()
        precondition(seen == [
            .idle,
            .checking,
            .downloading(done: 0, total: 2, current: a),
            .downloading(done: 1, total: 2, current: b),
            .checking,
            .deleting,
            .idle,
        ], "\(seen)")
        precondition(running == [false, true, false], "\(running)")
    }

    @MainActor
    static func testANewRunClearsTheOldNotice() async {
        let fake = Fake()
        fake.deleteResult = false
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        _ = await runner.run()
        precondition(runner.notice == .deleteFailed)
        fake.deleteResult = true
        _ = await runner.run()
        precondition(runner.notice == nil)
        fake.deleteResult = false
        _ = await runner.run()
        precondition(runner.notice == .deleteFailed)
        runner.dismissNotice()
        precondition(runner.notice == nil)
    }

    /// The delete runs only after iCloud's own list was asked (#839).
    @MainActor
    static func testTheDeleteWaitsForICloudsAnswer() async {
        let fake = Fake()
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        fake.onConfirm = { _ in precondition(runner.phase == .checking) }
        let outcome = await runner.run()
        precondition(outcome == .deleted, "\(outcome)")
        precondition(fake.log == ["refresh", "confirm", "delete"], "\(fake.log)")
    }

    /// iCloud holds a recording this Mac didn't know was there: the check
    /// merges it into the list, and it is downloaded before the delete.
    @MainActor
    static func testARecordingICloudNamesIsDownloadedBeforeTheDelete() async {
        let fake = Fake()
        fake.verdicts = [.download([x])]
        fake.onConfirm = { count in
            if count == 1 { fake.list?.append(.init(id: x, bytes: 100)) }
        }
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .deleted, "\(outcome)")
        precondition(fake.log == ["refresh", "confirm", "download x", "refresh", "confirm", "delete"], "\(fake.log)")
        precondition(runner.notice == nil)
    }

    @MainActor
    static func testAnUnsureAnswerDeletesNothing() async {
        let fake = Fake()
        fake.verdicts = [.cannotBeSure]
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .cannotCheck, "\(outcome)")
        precondition(fake.log == ["refresh", "confirm"], "\(fake.log)")
        precondition(runner.notice == .cannotCheck)
        precondition(runner.phase == .idle && !runner.isRunning)
    }

    /// iCloud names a recording the list doesn't hold: there is nothing to
    /// download it with, so nothing is deleted.
    @MainActor
    static func testARecordingICloudNamesThatIsntListedDeletesNothing() async {
        let fake = Fake()
        fake.verdicts = [.download([x])]
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .cannotCheck, "\(outcome)")
        precondition(!fake.log.contains("delete"), "\(fake.log)")
        precondition(runner.notice == .cannotCheck)
    }

    /// iCloud says it's safe, but a recording became iCloud-only during the
    /// check: it is downloaded, and iCloud is asked again.
    @MainActor
    static func testSafeWithARecordingListedMeanwhileDownloadsIt() async {
        let fake = Fake()
        fake.onConfirm = { count in
            if count == 1 { fake.list?.append(.init(id: y, bytes: 100)) }
        }
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .deleted, "\(outcome)")
        precondition(fake.log == ["refresh", "confirm", "download y", "refresh", "confirm", "delete"], "\(fake.log)")
    }

    @MainActor
    static func testCancelDuringTheICloudCheckDeletesNothing() async {
        let fake = Fake()
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        fake.onConfirm = { _ in
            precondition(runner.phase == .checking)
            runner.cancel()
        }
        let outcome = await runner.run()
        precondition(outcome == .cancelled, "\(outcome)")
        precondition(fake.log == ["refresh", "confirm"], "\(fake.log)")
        precondition(runner.notice == nil)
        precondition(runner.phase == .idle && !runner.isRunning)
    }

    @MainActor
    static func testTheCheckRunsOncePerEmptyList() async {
        let fake = Fake()
        fake.ids([a, b, c])
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .deleted)
        precondition(fake.confirms == 1)
        precondition(fake.log == ["refresh", "download a", "download b", "download c", "refresh", "confirm", "delete"], "\(fake.log)")
    }

    /// iCloud names the same recording after its download, and it is
    /// listed again: it isn't downloaded twice, and nothing is deleted.
    @MainActor
    static func testARecordingICloudNamesAgainAfterItsDownloadFails() async {
        let fake = Fake()
        fake.verdicts = [.download([a]), .download([a])]
        fake.onConfirm = { _ in
            if fake.list?.contains(where: { $0.id == a }) == false { fake.list?.append(.init(id: a, bytes: 100)) }
        }
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .downloadFailed, "\(outcome)")
        precondition(fake.log == ["refresh", "confirm", "download a", "refresh", "confirm"], "\(fake.log)")
        precondition(fake.confirms == 2 && fake.list?.map(\.id) == [a])
        precondition(runner.notice == .downloadFailed)
    }

    @MainActor
    static func testAFailedDownloadNeverAsksICloud() async {
        let fake = Fake()
        fake.ids([a])
        fake.results[a] = false
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .downloadFailed)
        precondition(fake.confirms == 0 && !fake.log.contains("confirm"), "\(fake.log)")
    }

    @MainActor
    static func testTooLittleSpaceNeverAsksICloud() async {
        let fake = Fake()
        fake.ids([a], bytes: 600)
        fake.free = 600 + room - 1
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .notEnoughSpace(shortBy: 1), "\(outcome)")
        precondition(fake.confirms == 0 && !fake.log.contains("confirm"), "\(fake.log)")
    }

    /// A real folder reads as some free space. What a missing path reads
    /// (nil, or its volume's space) depends on Foundation and isn't pinned.
    static func testFreeBytesOfARealFolderIsPositive() {
        let folder = FileManager.default.temporaryDirectory
        guard let value = NoteAudioDownloadThenDelete.freeBytes(at: folder) else {
            preconditionFailure("the temporary folder's free space can be read")
        }
        precondition(value > 0)
    }
}
