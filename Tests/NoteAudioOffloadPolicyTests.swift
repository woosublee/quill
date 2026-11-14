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
}
