import CoreData
import Foundation
import QuillNoteSyncCore

@main
struct PipelineHistoryStoreAudioLastUsedTests {
    static func main() throws {
        try testNewNoteReadsNil()
        try testSetThenReadReturnsTheDate()
        try testSettingItStaysOnThisMac()
        try testUnknownNoteThrows()
        try testSnapshotsReadHasTranscript()
        try testSnapshotsCarryTheRestOfTheNote()
        try testLegacyStoreOpensAndReadsNil()
        print("PipelineHistoryStoreAudioLastUsedTests passed")
    }

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func makeItem(
        id: UUID = UUID(),
        status: String = "succeeded",
        raw: String = "synthetic raw",
        edited: String = "synthetic edited",
        audio: String? = "synthetic.wav",
        clock: NoteFieldClock? = nil
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: id,
            timestamp: t0,
            rawTranscript: raw,
            postProcessedTranscript: edited,
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: status,
            debugStatus: "",
            customVocabulary: "",
            audioFileName: audio,
            fieldClock: clock
        )
    }

    private static func store() -> PipelineHistoryStore {
        let store = PipelineHistoryStore(inMemory: true)
        store.now = { t0 }
        return store
    }

    private static func temporaryStoreURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-last-used-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("PipelineHistory.sqlite")
    }

    private static func testNewNoteReadsNil() throws {
        let s = store()
        let note = makeItem()
        _ = try s.append(note, maxCount: Int.max)
        precondition(s.audioLastUsedAt(id: note.id) == nil)
        precondition(s.audioLastUsedAt(id: UUID()) == nil)
    }

    private static func testSetThenReadReturnsTheDate() throws {
        let s = store()
        let note = makeItem()
        _ = try s.append(note, maxCount: Int.max)
        let used = t0.addingTimeInterval(3_600)
        try s.setAudioLastUsedAt(used, id: note.id)
        precondition(s.audioLastUsedAt(id: note.id) == used)
        let later = used.addingTimeInterval(60)
        try s.setAudioLastUsedAt(later, id: note.id)
        precondition(s.audioLastUsedAt(id: note.id) == later)
    }

    private static func testSettingItStaysOnThisMac() throws {
        let s = store()
        let note = makeItem(audio: "kept.wav")
        _ = try s.append(note, maxCount: Int.max)
        let manifest = NoteAudioManifest(sha256: String(repeating: "ab", count: 32), bytes: 10, partSize: 50_000_000, parts: 1)
        try s.setAudioManifest(manifest, id: note.id)
        try s.setAudioUploadKey(String(repeating: "cd", count: 32), id: note.id)
        try s.setSyncSystemFields(Data([7]), id: note.id)
        let recordBefore = s.syncRecord(id: note.id)
        var changes: [PipelineHistoryChange] = []
        s.onChange = { changes += $0 }
        try s.setAudioLastUsedAt(t0.addingTimeInterval(500), id: note.id)
        precondition(changes.isEmpty, "the last-used date reports no change")
        precondition(s.syncRecord(id: note.id) == recordBefore, "the record, with its field clock, is as it was")
        precondition(s.syncSystemFields(id: note.id) == Data([7]))
        precondition(s.audioManifest(id: note.id) == manifest)
        precondition(s.audioUploadKey(id: note.id) == String(repeating: "cd", count: 32))
        precondition(s.loadAllHistory().first { $0.id == note.id }?.audioFileName == "kept.wav")
    }

    private static func testUnknownNoteThrows() throws {
        do {
            try store().setAudioLastUsedAt(t0, id: UUID())
            preconditionFailure("an unknown note can't be stamped")
        } catch PipelineHistoryStoreError.historyEntryNotFound {
        } catch {
            preconditionFailure("wrong error \(error)")
        }
    }

    private static func testSnapshotsReadHasTranscript() throws {
        let s = store()
        let finished = makeItem()
        let rawOnly = makeItem(raw: "synthetic raw", edited: "")
        let audioOnly = makeItem(status: "audio-only", raw: "", edited: "")
        let placeholder = makeItem(status: "transcription-interrupted", raw: "", edited: "")
        let blank = makeItem(raw: "  ", edited: "\n ")
        let failed = makeItem(status: "Error: synthetic failure")
        let transcribing = makeItem(status: "cloud-transcribing", raw: "", edited: "")
        for item in [finished, rawOnly, audioOnly, placeholder, blank, failed, transcribing] {
            _ = try s.append(item, maxCount: Int.max)
        }
        let byID = Dictionary(uniqueKeysWithValues: s.audioOffloadSnapshots().map { ($0.id, $0) })
        precondition(byID.count == 7, "every note is read, settled or not")
        precondition(byID[finished.id]?.hasTranscript == true)
        precondition(byID[rawOnly.id]?.hasTranscript == true)
        precondition(byID[audioOnly.id]?.hasTranscript == false)
        precondition(byID[placeholder.id]?.hasTranscript == false)
        precondition(byID[blank.id]?.hasTranscript == false)
        precondition(byID[failed.id]?.hasTranscript == false)
        precondition(byID[transcribing.id]?.hasTranscript == false)
    }

    private static func testSnapshotsCarryTheRestOfTheNote() throws {
        let s = store()
        let plain = makeItem(audio: nil)
        let deleted = makeItem(audio: "deleted.wav")
        let broken = makeItem(status: "recording-unrecovered:recovery-failed", raw: "", edited: "")
        let noAudio = makeItem(status: "recording-unrecovered:no-audio", raw: "", edited: "")
        let marked = makeItem(audio: "marked.wav")
        for item in [plain, deleted, broken, noAudio, marked] { _ = try s.append(item, maxCount: Int.max) }
        _ = try s.setDeletedAt(t0.addingTimeInterval(10), id: deleted.id)
        let manifest = NoteAudioManifest(sha256: String(repeating: "ab", count: 32), bytes: 10, partSize: 50_000_000, parts: 1)
        try s.setAudioManifest(manifest, id: marked.id)
        let used = t0.addingTimeInterval(99)
        try s.setAudioLastUsedAt(used, id: marked.id)
        let byID = Dictionary(uniqueKeysWithValues: s.audioOffloadSnapshots().map { ($0.id, $0) })
        precondition(byID[plain.id] == NoteAudioOffloadSnapshot(
            id: plain.id, audioFileName: nil, manifest: nil, lastUsedAt: nil, recordingEndedAt: nil,
            createdAt: t0, hasTranscript: true, isRecentlyDeleted: false, hasUnrecoveredPieces: false
        ))
        precondition(byID[deleted.id]?.isRecentlyDeleted == true && byID[plain.id]?.isRecentlyDeleted == false)
        precondition(byID[broken.id]?.hasUnrecoveredPieces == true)
        precondition(byID[noAudio.id]?.hasUnrecoveredPieces == false)
        precondition(byID[marked.id]?.audioFileName == "marked.wav")
        precondition(byID[marked.id]?.manifest == manifest && byID[marked.id]?.lastUsedAt == used)
    }

    private static func testLegacyStoreOpensAndReadsNil() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID()
        try PipelineHistoryStore.writeLegacyStoreForTesting(at: url, id: id, timestamp: t0)
        let reopened = PipelineHistoryStore(storeURL: url)
        precondition(reopened.availability == .ready)
        precondition(reopened.audioLastUsedAt(id: id) == nil)
        try reopened.setAudioLastUsedAt(t0, id: id)
        precondition(PipelineHistoryStore(storeURL: url).audioLastUsedAt(id: id) == t0)
        precondition(reopened.audioOffloadSnapshots().first?.lastUsedAt == t0)
    }
}
