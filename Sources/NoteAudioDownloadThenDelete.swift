import Combine
import Foundation
import QuillNoteSyncCore

/// Turn Off and Delete from iCloud, keeping every recording: downloads the
/// recordings that are only in iCloud, one at a time, and runs the delete
/// only once none is left, as read straight after asking the sync engine
/// to fetch. That fetch may not reach the server (#562): a recording
/// another device made iCloud-only can be missed when this Mac never
/// heard of the change (#839). One runs at a time.
@MainActor
final class NoteAudioDownloadThenDelete: ObservableObject {
    struct Work {
        /// Read again before every download and before the delete. Nil: can't be read.
        var recordingsOnlyInICloud: @MainActor () -> [NoteAudioOnlyInICloud]?
        /// Asks sync to fetch and returns once what it fetched is applied
        /// here; false with sync not running or when the fetch failed.
        /// True doesn't mean iCloud was asked (#562, #839).
        var refresh: @MainActor () async -> Bool
        var freeBytes: @MainActor () -> Int64?
        /// True once the recording is on this Mac.
        var download: @MainActor (UUID) async -> Bool
        var cancelDownload: @MainActor (UUID) -> Void
        /// The existing Turn Off and Delete from iCloud; false when it failed.
        var deleteFromICloud: @MainActor () async -> Bool
    }

    enum Phase: Equatable {
        case idle
        /// Fetching from iCloud: first, and each time the list went empty.
        case checking
        /// `done` finished; `total` is `done` plus what is still only in iCloud.
        case downloading(done: Int, total: Int, current: UUID)
        case deleting
    }

    enum Outcome: Equatable {
        case deleted
        /// The delete ran and failed; the controller's `turnOffFailure` says why.
        case deleteFailed
        case notEnoughSpace(shortBy: Int64)
        case downloadFailed
        case cannotCheck
        case cancelled
        case alreadyRunning
    }

    @Published private(set) var phase: Phase = .idle
    /// The last run's outcome when it needs saying: `.deleteFailed`,
    /// `.notEnoughSpace`, `.downloadFailed`, `.cannotCheck`. Stays until dismissed,
    /// so it shows even if Settings was closed meanwhile.
    @Published private(set) var notice: Outcome?
    @Published private(set) var isRunning = false

    private let work: Work
    private var cancelRequested = false

    init(work: Work) {
        self.work = work
    }

    @discardableResult
    func run() async -> Outcome {
        guard !isRunning else { return .alreadyRunning }
        isRunning = true
        cancelRequested = false
        notice = nil

        var tried = Set<UUID>()
        var done = 0
        // True when the next list read follows a fetch: what this Mac has
        // fetched may miss a recording another device just made iCloud-only.
        var fetchFirst = true
        while true {
            if fetchFirst {
                phase = .checking
                let fetched = await work.refresh()
                if cancelRequested { return finish(.cancelled) }
                if !fetched { return finish(.downloadFailed) }
            }
            guard let listed = work.recordingsOnlyInICloud() else { return finish(.cannotCheck) }
            if listed.isEmpty {
                // Only an empty list read straight after a fetch deletes.
                if fetchFirst { break }
                fetchFirst = true
                continue
            }
            fetchFirst = false
            let summary = NoteAudioICloudOnlySummary(markerBytes: listed.map(\.bytes))
            if case .short(let by) = NoteAudioICloudDeletePolicy.space(
                neededBytes: summary.bytes, freeBytes: work.freeBytes()
            ) {
                return finish(.notEnoughSpace(shortBy: by))
            }
            // A recording already tried that is still listed won't get better.
            guard let next = listed.first(where: { !tried.contains($0.id) }) else {
                return finish(.downloadFailed)
            }
            tried.insert(next.id)
            phase = .downloading(done: done, total: done + listed.count, current: next.id)
            let downloaded = await work.download(next.id)
            if cancelRequested { return finish(.cancelled) }
            if !downloaded { return finish(.downloadFailed) }
            done += 1
        }

        // A backstop: every await above already checks for Cancel.
        if cancelRequested { return finish(.cancelled) }
        phase = .deleting
        let deleted = await work.deleteFromICloud()
        return finish(deleted ? .deleted : .deleteFailed)
    }

    /// Stops the run: the current download stops, and a fetch running ends
    /// the run when it returns. Does nothing once the delete began.
    func cancel() {
        switch phase {
        case .checking:
            cancelRequested = true
        case .downloading(_, _, let current):
            cancelRequested = true
            work.cancelDownload(current)
        case .idle, .deleting:
            return
        }
    }

    func dismissNotice() {
        notice = nil
    }

    private func finish(_ outcome: Outcome) -> Outcome {
        phase = .idle
        isRunning = false
        switch outcome {
        case .deleteFailed, .notEnoughSpace, .downloadFailed, .cannotCheck:
            notice = outcome
        case .deleted, .cancelled, .alreadyRunning:
            break
        }
        return outcome
    }

    /// Free space for a user's own files on the volume holding `url`
    /// (`volumeAvailableCapacityForImportantUsage`); nil when it can't be read.
    nonisolated static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
