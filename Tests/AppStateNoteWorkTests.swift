import Foundation
import QuillNoteCore
import QuillNoteUI

/// The events `AppState` sends its `NoteWorkBoard` (#768 step 3), driven
/// through AppState itself with synthetic notes: a retry starting and
/// ending, an audio-only note transcribed from the Note Browser, each note's
/// own cleanup split, a setting change, and a deleted note leaving the board.
enum AppStateNoteWorkTests {
    static func main() async throws {
        try await verifiesRetryStartsAndEnds()
        try await verifiesStageFollowsTheSetting()
        try await verifiesDeleteNowForgetsTheWork()
        try await verifiesFirstTranscriptionProgress()
        try verifiesJobNoteMoves()
        print("AppStateNoteWorkTests passed")
    }

    /// A job that lets go of its note ends that note's first transcription
    /// (a cleanup-off import saving its note), and starts nothing on the
    /// job's own ID.
    private static func verifiesJobNoteMoves() throws {
        let job = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
        let got = AppState.noteWorkMove(before: job, after: noteA, hasLiveNote: true)
        try expect(got.ends == job && got.starts == noteA, "getting a note moves the work to it")
        let released = AppState.noteWorkMove(before: noteA, after: job, hasLiveNote: false)
        try expect(released.ends == noteA && released.starts == nil, "letting go of the note ends its first transcription")
        let same = AppState.noteWorkMove(before: noteA, after: noteA, hasLiveNote: true)
        try expect(same.ends == nil && same.starts == nil, "no move, no change")

        // What ending the released note's transcription leaves: its cleanup.
        var work = NoteWork(stage: .cloud)
        work.apply(.transcriptionStarted(.first, reportsProgress: false))
        work.apply(.transcriptionFinished(cleanupFollows: true))
        work.apply(.transcriptionEnded)
        try expect(work.isPostProcessing, "a running cleanup stays when the note is let go")
        var plain = NoteWork(stage: .off)
        plain.apply(.transcriptionStarted(.first, reportsProgress: false))
        plain.apply(.transcriptionEnded)
        try expect(!plain.isActive, "a cleanup-off import leaves no work once its note is saved")
    }

    private static func verifiesRetryStartsAndEnds() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            let note = makeNote(id: noteA, status: "Post-processing succeeded")
            let audioOnly = makeNote(id: noteB, status: NoteMachineStatus.audioOnlyStatus)
            let store = PipelineHistoryStore(storeURL: environment.storageLayout.historyStoreURL)
            _ = try store.append(note, maxCount: Int.max)
            _ = try store.append(audioOnly, maxCount: Int.max)
            let appState = await MainActor.run { AppState(dependencies: environment.dependencies) }
            try await MainActor.run {
                let board = appState.noteWorkBoard
                try expect(board.works.isEmpty, "nothing runs at launch")

                let before = appState.retryingItemIDs
                appState.retryingItemIDs.formUnion([noteA, noteB])
                appState.noteRetriesChanged(from: before, progressBefore: [:])
                try expect(board.work(for: noteA.uuidString).status == .retranscribing(nil), "a retry without progress: no bar")
                try expect(board.work(for: noteA.uuidString).toolbarWork == .retranscribing)
                try expect(
                    board.work(for: noteB.uuidString).status == .transcribing(nil),
                    "an audio-only note was never transcribed"
                )
                try expect(board.work(for: noteB.uuidString).toolbarWork == .transcribing)

                let joined = appState.retryingItemIDs
                appState.retryingItemIDs.subtract([noteA])
                appState.noteRetriesChanged(from: joined, progressBefore: [:])
                try expect(board.works[noteA.uuidString] == nil, "a retry that ends leaves no work")
                try expect(board.works[noteB.uuidString] != nil, "the other note keeps its own")
            }
        }
    }

    private static func verifiesStageFollowsTheSetting() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            let store = PipelineHistoryStore(storeURL: environment.storageLayout.historyStoreURL)
            _ = try store.append(makeNote(id: noteA, status: "Post-processing succeeded"), maxCount: Int.max)
            let appState = await MainActor.run { AppState(dependencies: environment.dependencies) }
            try await MainActor.run {
                appState.disablePostProcessing = false
                appState.retryingItemIDs.insert(noteA)
                appState.noteRetriesChanged(from: [], progressBefore: [:])
                let board = appState.noteWorkBoard
                try expect(
                    board.work(for: noteA.uuidString).stage == appState.noteCleanupStage(noteID: noteA),
                    "the note's work splits the bar as its cleanup does"
                )
                try expect(board.work(for: noteA.uuidString).stage != .off)
                appState.disablePostProcessing = true
                try expect(board.work(for: noteA.uuidString).stage == .off, "turning cleanup off reaches running work")
                appState.disablePostProcessing = false
                try expect(board.work(for: noteA.uuidString).stage == appState.noteCleanupStage(noteID: noteA))
            }
        }
    }

    private static func verifiesDeleteNowForgetsTheWork() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            for directory in [environment.storageLayout.audioDirectory, environment.storageLayout.transcriptDirectory] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let store = PipelineHistoryStore(storeURL: environment.storageLayout.historyStoreURL)
            _ = try store.append(makeNote(id: noteA, status: "Post-processing succeeded"), maxCount: Int.max)
            try store.setDeletedAt(Date(), id: noteA)
            let appState = await MainActor.run { AppState(dependencies: environment.dependencies) }
            try await MainActor.run {
                appState.retryingItemIDs.insert(noteA)
                appState.noteRetriesChanged(from: [], progressBefore: [:])
                try expect(appState.noteWorkBoard.works[noteA.uuidString] != nil)
                appState.deleteRecentlyDeletedNoteNow(id: noteA)
                try expect(appState.noteWorkBoard.works[noteA.uuidString] == nil, "a deleted note leaves the board")
            }
        }
    }

    /// A first transcription's chunk progress, as AppState sends it (#768
    /// rule 2): resuming only for a cloud job with chunks done, none
    /// uploading, and some left; a late "every chunk in" starts nothing.
    private static func verifiesFirstTranscriptionProgress() async throws {
        try await AppStateTestStorage.withIsolatedStorage { environment in
            let store = PipelineHistoryStore(storeURL: environment.storageLayout.historyStoreURL)
            _ = try store.append(makeNote(id: noteA, status: NoteMachineStatus.cloudTranscribingStatus), maxCount: Int.max)
            _ = try store.append(makeNote(id: noteB, status: NoteMachineStatus.liveRecordingStatus), maxCount: Int.max)
            let appState = await MainActor.run { AppState(dependencies: environment.dependencies) }
            try await MainActor.run {
                let board = appState.noteWorkBoard
                func progress(_ done: Int, _ total: Int, attempt: Int? = nil) -> CloudTranscriptionDisplayProgress {
                    CloudTranscriptionDisplayProgress(completedChunkCount: done, totalChunkCount: total, activeAttempt: attempt)
                }
                @MainActor func transcription(_ id: UUID) -> NoteWork.Transcription? { board.work(for: id.uuidString).transcription }

                appState.noteFirstTranscriptionProgressed(noteID: noteA, progress: progress(4, 4))
                try expect(board.works.isEmpty, "every chunk in on a note without work starts nothing")
                appState.noteFirstTranscriptionProgressed(noteID: noteA, progress: progress(0, 4))
                try expect(transcription(noteA) == .running(.first, NoteWorkProgress(completed: 0, total: 4)), "planned: starting, not resuming")
                appState.noteFirstTranscriptionProgressed(noteID: noteA, progress: progress(2, 4))
                try expect(transcription(noteA) == .resumingCloud(NoteWorkProgress(completed: 2, total: 4)), "chunks done, none uploading")
                appState.noteFirstTranscriptionProgressed(noteID: noteA, progress: progress(2, 4, attempt: 1))
                try expect(transcription(noteA) == .running(.first, NoteWorkProgress(completed: 2, total: 4)), "uploading again")
                appState.noteFirstTranscriptionProgressed(noteID: noteA, progress: progress(4, 4))
                try expect(transcription(noteA) == .running(.first, NoteWorkProgress(completed: 4, total: 4)), "all in: still transcribing")
                try expect(board.work(for: noteA.uuidString).toolbarWork == .transcribing)

                // Local AI reports chunks too, and is never resuming.
                appState.noteFirstTranscriptionProgressed(noteID: noteB, progress: progress(2, 4))
                try expect(transcription(noteB) == .running(.first, NoteWorkProgress(completed: 2, total: 4)))
                // The bar never moves back (accepted, #768).
                appState.noteFirstTranscriptionProgressed(noteID: noteB, progress: progress(1, 4, attempt: 1))
                try expect(transcription(noteB) == .running(.first, NoteWorkProgress(completed: 2, total: 4)))
            }
        }
    }

    private static let noteA = UUID(uuidString: "00000000-0000-0000-0000-0000000007A1")!
    private static let noteB = UUID(uuidString: "00000000-0000-0000-0000-0000000007B1")!

    private static func makeNote(id: UUID, status: String) -> PipelineHistoryItem {
        let isAudioOnly = status == NoteMachineStatus.audioOnlyStatus
        return PipelineHistoryItem(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1_000),
            rawTranscript: isAudioOnly ? "" : "Synthetic decision: ship Friday.",
            postProcessedTranscript: isAudioOnly ? "" : "Synthetic decision: ship Friday.",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: status,
            debugStatus: "Done",
            customVocabulary: "",
            usedPostProcessing: false,
            transcriptionLanguageCode: "en"
        )
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String = "") throws {
        guard condition else { throw Failure(description: "AppStateNoteWorkTests: \(message())") }
    }
}
