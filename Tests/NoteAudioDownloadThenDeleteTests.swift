import Combine
import Foundation
import QuillNoteSyncCore

@main
struct NoteAudioDownloadThenDeleteTests {
    @MainActor
    static func main() async throws {
        await testDownloadsEveryRecordingThenDeletes()
        await testTooLittleSpaceDownloadsAndDeletesNothing()
        await testAFailedDownloadStopsEverything()
        await testADownloadThatLeavesTheRecordingInICloudFails()
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
        testFreeBytesOfAMissingVolumeIsNil()
        print("NoteAudioDownloadThenDeleteTests passed")
    }

    static let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    static let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    static let names: [UUID: String] = [a: "a", b: "b", c: "c"]
    static let room = NoteAudioICloudDeletePolicy.workingRoom

    /// Holds a mutable list and logs what the runner does, in order.
    @MainActor
    final class Fake {
        var list: [NoteAudioOnlyInICloud]? = []
        var free: Int64? = Int64.max
        var freeAsked = 0
        var log: [String] = []
        /// What a download returns; absent means true.
        var results: [UUID: Bool] = [:]
        /// Whether a finished download leaves the recording out of the list.
        var removesOnDownload = true
        var onDownload: ((UUID) -> Void)?
        var onDelete: (() -> Void)?
        var deleteResult = true
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
                recordingsOnlyInICloud: { self.list },
                freeBytes: { self.freeAsked += 1; return self.free },
                download: { id in
                    self.log.append("download \(NoteAudioDownloadThenDeleteTests.names[id] ?? "?")")
                    self.onDownload?(id)
                    var result = self.results[id] ?? true
                    if self.holdDownloads {
                        result = await withCheckedContinuation { self.waiting = $0 }
                    }
                    if result && self.removesOnDownload { self.list?.removeAll { $0.id == id } }
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
        precondition(fake.log == ["download a", "download b", "download c", "delete"], "\(fake.log)")
        precondition(runner.notice == nil)
        precondition(runner.phase == .idle && !runner.isRunning)
    }

    @MainActor
    static func testTooLittleSpaceDownloadsAndDeletesNothing() async {
        let fake = Fake()
        fake.list = [.init(id: a, bytes: 600), .init(id: b, bytes: 500)]
        fake.free = 1_100 + room - 1
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .notEnoughSpace(shortBy: 1), "\(outcome)")
        precondition(fake.log.isEmpty, "\(fake.log)")
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
        precondition(fake.log == ["download a", "download b"], "\(fake.log)")
        precondition(runner.notice == .downloadFailed)
        precondition(runner.phase == .idle)
    }

    @MainActor
    static func testADownloadThatLeavesTheRecordingInICloudFails() async {
        let fake = Fake()
        fake.ids([a])
        fake.removesOnDownload = false
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .downloadFailed)
        precondition(fake.log == ["download a"], "\(fake.log)")
        precondition(runner.notice == .downloadFailed)
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
        precondition(fake.log == ["download a", "download b", "download c", "delete"], "\(fake.log)")
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
        precondition(fake.log == ["download a"], "\(fake.log)")
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
        precondition(fake.log == ["download a", "cancel a"], "\(fake.log)")
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
        precondition(fake.log.isEmpty)
        precondition(runner.notice == .cannotCheck)
    }

    @MainActor
    static func testNothingOnlyInICloudJustDeletes() async {
        let fake = Fake()
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        let outcome = await runner.run()
        precondition(outcome == .deleted)
        precondition(fake.log == ["delete"], "\(fake.log)")
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
        precondition(fake.log == ["download a"], "\(fake.log)")
        fake.release(true)
        let outcome = await first.value
        precondition(outcome == .deleted)
        precondition(fake.log == ["download a", "delete"], "\(fake.log)")
    }

    @MainActor
    static func testPhaseCountsDownloads() async {
        let fake = Fake()
        fake.ids([a, b])
        let runner = NoteAudioDownloadThenDelete(work: fake.work())
        var seen: [NoteAudioDownloadThenDelete.Phase] = []
        let cancellable = runner.$phase.sink { seen.append($0) }
        _ = await runner.run()
        cancellable.cancel()
        precondition(seen == [
            .idle,
            .downloading(done: 0, total: 2, current: a),
            .downloading(done: 1, total: 2, current: b),
            .deleting,
            .idle,
        ], "\(seen)")
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
        runner.dismissNotice()
        precondition(runner.notice == nil)
    }

    static func testFreeBytesOfAMissingVolumeIsNil() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-missing-\(UUID().uuidString)")
            .appendingPathComponent("deeper")
        if let value = NoteAudioDownloadThenDelete.freeBytes(at: missing) {
            precondition(value > 0)
        }
    }
}
