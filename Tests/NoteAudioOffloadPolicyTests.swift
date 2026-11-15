import Foundation
import QuillNoteSyncCore

@main
struct NoteAudioOffloadPolicyTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 24 * 60 * 60

    static func base(lastUsedAgo: TimeInterval = 8 * day) -> NoteAudioOffloadPolicy.Note {
        NoteAudioOffloadPolicy.Note(
            hasMarker: true,
            hasTranscript: true,
            hasLocalAudio: true,
            isBusy: false,
            isRecentlyDeleted: false,
            hasUnrecoveredPieces: false,
            lastUsedAt: now.addingTimeInterval(-lastUsedAgo),
            recordingEndedAt: nil,
            createdAt: now.addingTimeInterval(-100 * day)
        )
    }

    static func candidate(_ note: NoteAudioOffloadPolicy.Note, optimize: Bool = true, sync: Bool = true) -> Bool {
        NoteAudioOffloadPolicy.isCandidate(note, isOptimizeOn: optimize, isSyncRunning: sync, now: now)
    }

    static func main() {
        testBaseIsCandidate()
        testEachSingleChangeBlocks()
        testRetentionEdge()
        testFallbackDates()
        testFutureDateBlocks()
        testCopyKeys()
        testConfirmedOnlyWithEveryPartAndTheSameMarker()
        testPassLocalFileIsAPlainNonEmptyFileOfTheMarkersSize()
        testPassRetentionOverrideIsForDevelopmentOnly()
        testPassOrdersTiesByID()
        print("NoteAudioOffloadPolicyTests passed")
    }

    static func testBaseIsCandidate() {
        precondition(candidate(base()))
        precondition(NoteAudioOffloadPolicy.retention == 7 * day)
    }

    static func testEachSingleChangeBlocks() {
        precondition(!candidate(base(), optimize: false), "optimize off")
        precondition(!candidate(base(), sync: false), "sync not running")
        var note = base(); note.hasMarker = false
        precondition(!candidate(note), "no marker")
        note = base(); note.hasTranscript = false
        precondition(!candidate(note), "no transcript")
        note = base(); note.hasLocalAudio = false
        precondition(!candidate(note), "no local audio")
        note = base(); note.isBusy = true
        precondition(!candidate(note), "busy")
        note = base(); note.isRecentlyDeleted = true
        precondition(!candidate(note), "recently deleted")
        note = base(); note.hasUnrecoveredPieces = true
        precondition(!candidate(note), "unrecovered pieces")
    }

    static func testRetentionEdge() {
        precondition(candidate(base(lastUsedAgo: 7 * day)), "exactly 7 days")
        precondition(!candidate(base(lastUsedAgo: 7 * day - 1)), "1 second short of 7 days")
    }

    static func testFallbackDates() {
        var note = base()
        note.lastUsedAt = nil
        note.recordingEndedAt = now.addingTimeInterval(-8 * day)
        precondition(candidate(note), "recording end used when never used")

        note.lastUsedAt = now.addingTimeInterval(-3600)
        note.recordingEndedAt = now.addingTimeInterval(-90 * day)
        precondition(!candidate(note), "last used wins over recording end")
        precondition(NoteAudioOffloadPolicy.lastUsed(note) == now.addingTimeInterval(-3600))

        note.lastUsedAt = nil
        note.recordingEndedAt = nil
        note.createdAt = now.addingTimeInterval(-8 * day)
        precondition(candidate(note), "created date decides when both are nil")
        note.createdAt = now.addingTimeInterval(-2 * day)
        precondition(!candidate(note))
    }

    static func testFutureDateBlocks() {
        precondition(!candidate(base(lastUsedAgo: -day)), "future last-used date")
    }

    static func testCopyKeys() {
        precondition(NoteAudioOffloadCopy.toggleKey == "Optimize Storage")
        precondition(NoteAudioOffloadCopy.detailKey == "Recordings you haven't used for a week are removed from this device and kept in iCloud. You can download them again.")
        precondition(NoteAudioOffloadCopy.needsSyncKey == "Turn on iCloud sync to use this.")
    }

    static func testConfirmedOnlyWithEveryPartAndTheSameMarker() {
        let local = NoteAudioManifest(sha256: String(repeating: "a", count: 64), bytes: 150, partSize: 100, parts: 2)
        func confirmed(_ parts: Bool, _ server: NoteAudioManifest?) -> Bool {
            NoteAudioOffloadPolicy.isConfirmedInICloud(local: local, partsPresent: parts, serverMarker: server)
        }
        precondition(confirmed(true, local), "every part, and iCloud's note names the same marker")
        precondition(!confirmed(false, local), "a part missing")
        precondition(!confirmed(true, nil), "iCloud's note names no marker, or can't be read")
        let others = [
            NoteAudioManifest(sha256: String(repeating: "b", count: 64), bytes: 150, partSize: 100, parts: 2),
            NoteAudioManifest(sha256: local.sha256, bytes: 151, partSize: 100, parts: 2),
            NoteAudioManifest(sha256: local.sha256, bytes: 150, partSize: 200, parts: 2),
            NoteAudioManifest(sha256: local.sha256, bytes: 150, partSize: 100, parts: 3),
        ]
        for other in others { precondition(!confirmed(true, other), "another marker: \(other)") }
    }

    /// Both apps' passes remove only a plain, non-empty file, the size its
    /// marker names, never a link or a folder.
    static func testPassLocalFileIsAPlainNonEmptyFileOfTheMarkersSize() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("offload-pass-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.wav")
        try! Data(repeating: 1, count: 10).write(to: file)
        let empty = folder.appendingPathComponent("empty.wav")
        try! Data().write(to: empty)
        let link = folder.appendingPathComponent("link.wav")
        try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        let local = NoteAudioOffloadPass.LocalFile(at: file)
        precondition(local?.size == 10)
        precondition(NoteAudioOffloadPass.LocalFile(at: empty) == nil, "empty")
        precondition(NoteAudioOffloadPass.LocalFile(at: link) == nil, "a link")
        precondition(NoteAudioOffloadPass.LocalFile(at: folder) == nil, "a folder")
        precondition(NoteAudioOffloadPass.LocalFile(at: folder.appendingPathComponent("none.wav")) == nil, "missing")
        let manifest = NoteAudioManifest(sha256: String(repeating: "ab", count: 32), bytes: 10, partSize: 10, parts: 1)
        precondition(local?.matches(manifest) == true)
        precondition(local?.matches(NoteAudioManifest(sha256: manifest.sha256, bytes: 9, partSize: 10, parts: 1)) == false, "smaller marker")
        precondition(local?.matches(NoteAudioManifest(sha256: manifest.sha256, bytes: 11, partSize: 11, parts: 1)) == false, "larger marker")
        precondition(local?.matches(NoteAudioManifest(sha256: manifest.sha256, bytes: 0, partSize: 10, parts: 0)) == false, "empty marker")
        precondition(NoteAudioOffloadPass.sameFileKey("Ab\u{0065}\u{0301}.wav") == NoteAudioOffloadPass.sameFileKey("aB\u{00E9}.WAV"))
    }

    static func testPassRetentionOverrideIsForDevelopmentOnly() {
        let arguments = ["Quill", NoteAudioOffloadPass.retentionArgument, "60"]
        precondition(NoteAudioOffloadPass.retention(isDevelopmentBuild: true, arguments: arguments) == 60)
        precondition(NoteAudioOffloadPass.retention(isDevelopmentBuild: false, arguments: arguments) == NoteAudioOffloadPolicy.retention)
        precondition(NoteAudioOffloadPass.retention(isDevelopmentBuild: true, arguments: ["Quill"]) == NoteAudioOffloadPolicy.retention)
        for bad in ["0", "-5", "nan", "inf", "soon"] {
            precondition(NoteAudioOffloadPass.retention(
                isDevelopmentBuild: true, arguments: ["Quill", NoteAudioOffloadPass.retentionArgument, bad]
            ) == NoteAudioOffloadPolicy.retention, bad)
        }
        precondition(NoteAudioOffloadPass.retention(
            isDevelopmentBuild: true, arguments: ["Quill", NoteAudioOffloadPass.retentionArgument]
        ) == NoteAudioOffloadPolicy.retention, "no value")
    }

    /// The same date is ordered by id, so both apps ask about the same notes.
    static func testPassOrdersTiesByID() {
        let ids = (0..<(NoteAudioOffloadPass.maxPerPass + 5)).map { _ in UUID() }
        let candidates = ids.map { (id: $0, lastUsed: now) }
        let first = NoteAudioOffloadPass.notesToAsk(candidates: candidates.shuffled(), waiting: [:], now: now).ask
        let second = NoteAudioOffloadPass.notesToAsk(candidates: candidates.shuffled(), waiting: [:], now: now).ask
        precondition(first == second)
        precondition(first == Array(ids.sorted { $0.uuidString < $1.uuidString }.prefix(NoteAudioOffloadPass.maxPerPass)))
    }
}
