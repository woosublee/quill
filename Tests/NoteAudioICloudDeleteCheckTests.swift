import Foundation
import QuillNoteSyncCore

@main
struct NoteAudioICloudDeleteCheckTests {
    typealias Check = NoteAudioICloudDeleteCheck

    static func main() {
        testNoPartsIsSafe()
        testARecordingHereNeedsNoRead()
        testAKnownMarkerWithPartsIsDownloadedWithoutARead()
        testANoteNotHereIsRead()
        testAKnownNoteWithoutMarkerOrFileIsRead()
        testAMarkerNamingAnotherFileIsRead()
        testAServerMarkerThisDeviceHoldsAfterTheMergeIsDownloaded()
        testAServerMarkerNotMergedHereCantBeSure()
        testAnUnreadOrUnreadableNoteCantBeSure()
        testLeftoverAndUploadingPartsDontBlock()
        testANoteBeingDeletedHereIsNeverRead()
        testOneDoubtStopsEverything()
        testSeveralNotesDownloadTogether()
        testPartsUnderAnotherKeyTooAreRead()
        testAServerMarkerMustMatchWhole()
        testARecentlyDeletedNoteWithItsFileHereIsRead()
        testARecentlyDeletedNoteWithItsFileHereIsHeldOnceRead()
        testARecentlyDeletedNoteHereThatCantBeReadCantBeSure()
        print("NoteAudioICloudDeleteCheckTests passed")
    }

    static func marker(_ digit: Character) -> NoteAudioManifest {
        NoteAudioManifest(
            sha256: String(repeating: digit, count: 64),
            bytes: 150, partSize: 100, parts: 2
        )
    }

    static func parts(_ id: UUID, _ m: NoteAudioManifest) -> [NoteAudioPartID] {
        m.partIDs(noteID: id)
    }

    static func testNoPartsIsSafe() {
        let id = UUID()
        let device = [id: Check.DeviceNote(hasLocalAudio: false, marker: marker("a"))]
        precondition(Check.notesToRead(parts: [], device: device, deletingHere: []) == [])
        precondition(Check.verdict(parts: [], serverNotes: [:], device: device, deletingHere: []) == .safeToDelete)
        precondition(Check.verdict(parts: [], serverNotes: [:], device: [:], deletingHere: []) == .safeToDelete)
    }

    static func testARecordingHereNeedsNoRead() {
        let id = UUID()
        let p = parts(id, marker("a"))
        for m in [nil, marker("a"), marker("b")] {
            let device = [id: Check.DeviceNote(hasLocalAudio: true, marker: m)]
            precondition(Check.notesToRead(parts: p, device: device, deletingHere: []) == [])
            precondition(Check.verdict(parts: p, serverNotes: [:], device: device, deletingHere: []) == .safeToDelete)
        }
    }

    static func testAKnownMarkerWithPartsIsDownloadedWithoutARead() {
        let id = UUID()
        let p = parts(id, marker("a"))
        let device = [id: Check.DeviceNote(hasLocalAudio: false, marker: marker("a"))]
        precondition(Check.notesToRead(parts: p, device: device, deletingHere: []) == [])
        precondition(Check.verdict(parts: p, serverNotes: [:], device: device, deletingHere: []) == .download([id]))
    }

    static func testANoteNotHereIsRead() {
        let id = UUID()
        let p = parts(id, marker("a"))
        precondition(Check.notesToRead(parts: p, device: [:], deletingHere: []) == [id])
    }

    static func testAKnownNoteWithoutMarkerOrFileIsRead() {
        let id = UUID()
        let p = parts(id, marker("a"))
        let device = [id: Check.DeviceNote(hasLocalAudio: false, marker: nil)]
        precondition(Check.notesToRead(parts: p, device: device, deletingHere: []) == [id])
    }

    static func testAMarkerNamingAnotherFileIsRead() {
        let id = UUID()
        let p = parts(id, marker("a"))
        let device = [id: Check.DeviceNote(hasLocalAudio: false, marker: marker("b"))]
        precondition(Check.notesToRead(parts: p, device: device, deletingHere: []) == [id])
    }

    static func testAServerMarkerThisDeviceHoldsAfterTheMergeIsDownloaded() {
        let id = UUID()
        let m = marker("b")
        let p = parts(id, marker("a"))
        let device = [id: Check.DeviceNote(hasLocalAudio: false, marker: m)]
        precondition(Check.verdict(parts: p, serverNotes: [id: .marker(m)], device: device, deletingHere: []) == .download([id]))
    }

    static func testAServerMarkerNotMergedHereCantBeSure() {
        let id = UUID()
        let m = marker("a")
        let p = parts(id, m)
        let cases: [[UUID: Check.DeviceNote]] = [
            [:],
            [id: Check.DeviceNote(hasLocalAudio: false, marker: nil)],
            [id: Check.DeviceNote(hasLocalAudio: false, marker: marker("b"))],
        ]
        for device in cases {
            precondition(Check.verdict(parts: p, serverNotes: [id: .marker(m)], device: device, deletingHere: []) == .cannotBeSure)
        }
    }

    static func testAnUnreadOrUnreadableNoteCantBeSure() {
        let id = UUID()
        let p = parts(id, marker("a"))
        precondition(Check.verdict(parts: p, serverNotes: [:], device: [:], deletingHere: []) == .cannotBeSure)
        precondition(Check.verdict(parts: p, serverNotes: [id: .unreadable], device: [:], deletingHere: []) == .cannotBeSure)
    }

    static func testLeftoverAndUploadingPartsDontBlock() {
        let id = UUID()
        let p = parts(id, marker("a"))
        precondition(Check.verdict(parts: p, serverNotes: [id: .noNote], device: [:], deletingHere: []) == .safeToDelete)
        precondition(Check.verdict(parts: p, serverNotes: [id: .noMarker], device: [:], deletingHere: []) == .safeToDelete)
    }

    static func testANoteBeingDeletedHereIsNeverRead() {
        let id = UUID()
        let p = parts(id, marker("a"))
        precondition(Check.notesToRead(parts: p, device: [:], deletingHere: [id]) == [])
        precondition(Check.verdict(parts: p, serverNotes: [:], device: [:], deletingHere: [id]) == .safeToDelete)
        precondition(Check.verdict(parts: p, serverNotes: [id: .unreadable], device: [:], deletingHere: [id]) == .safeToDelete)
    }

    static func testOneDoubtStopsEverything() {
        let a = UUID(), b = UUID()
        let p = parts(a, marker("a")) + parts(b, marker("b"))
        let device = [a: Check.DeviceNote(hasLocalAudio: false, marker: marker("a"))]
        precondition(Check.verdict(parts: p, serverNotes: [b: .unreadable], device: device, deletingHere: []) == .cannotBeSure)
    }

    static func testSeveralNotesDownloadTogether() {
        let a = UUID(), b = UUID(), c = UUID()
        let p = parts(a, marker("a")) + parts(b, marker("b")) + parts(c, marker("c"))
        let device = [
            a: Check.DeviceNote(hasLocalAudio: false, marker: marker("a")),
            b: Check.DeviceNote(hasLocalAudio: false, marker: marker("d")),
            c: Check.DeviceNote(hasLocalAudio: true, marker: nil),
        ]
        let server: [UUID: Check.ServerNote] = [b: .marker(marker("d"))]
        precondition(Check.notesToRead(parts: p, device: device, deletingHere: []) == [b])
        precondition(Check.verdict(parts: p, serverNotes: server, device: device, deletingHere: []) == .download([a, b]))
    }

    /// The device's marker skips the read only when every part of the note
    /// is under its key.
    static func testPartsUnderAnotherKeyTooAreRead() {
        let id = UUID()
        let a = marker("a"), b = marker("b")
        let p = parts(id, a) + parts(id, b)
        let device = [id: Check.DeviceNote(hasLocalAudio: false, marker: b)]
        precondition(Check.notesToRead(parts: p, device: device, deletingHere: []) == [id])
        precondition(Check.verdict(parts: p, serverNotes: [:], device: device, deletingHere: []) == .cannotBeSure)
        precondition(Check.verdict(parts: p, serverNotes: [id: .marker(b)], device: device, deletingHere: []) == .download([id]))
        precondition(Check.verdict(parts: p, serverNotes: [id: .marker(a)], device: device, deletingHere: []) == .cannotBeSure)
    }

    /// iCloud's marker must equal the device's whole, not only its hash.
    static func testAServerMarkerMustMatchWhole() {
        let id = UUID()
        let held = marker("b")
        let p = parts(id, marker("a"))
        let device = [id: Check.DeviceNote(hasLocalAudio: false, marker: held)]
        let others = [
            NoteAudioManifest(sha256: held.sha256, bytes: held.bytes, partSize: held.partSize, parts: held.parts + 1),
            NoteAudioManifest(sha256: held.sha256, bytes: held.bytes, partSize: held.partSize * 2, parts: held.parts),
        ]
        for other in others {
            precondition(Check.verdict(parts: p, serverNotes: [id: .marker(other)], device: device, deletingHere: []) == .cannotBeSure)
        }
    }

    /// A note in Recently Deleted here, with its file here, is read: the
    /// app merges iCloud's copy, so a restore made elsewhere comes here
    /// before the delete. A live note with its file here still isn't.
    static func testARecentlyDeletedNoteWithItsFileHereIsRead() {
        let deleted = UUID(), live = UUID()
        let p = parts(deleted, marker("a")) + parts(live, marker("b"))
        let device = [
            deleted: Check.DeviceNote(hasLocalAudio: true, marker: marker("a"), isRecentlyDeleted: true),
            live: Check.DeviceNote(hasLocalAudio: true, marker: marker("b")),
        ]
        precondition(Check.notesToRead(parts: p, device: device, deletingHere: []) == [deleted])
        precondition(Check.DeviceNote(hasLocalAudio: true, marker: nil).isRecentlyDeleted == false, "live by default")
    }

    /// Whatever iCloud's copy says, the file is here: held.
    static func testARecentlyDeletedNoteWithItsFileHereIsHeldOnceRead() {
        let id = UUID()
        let p = parts(id, marker("a"))
        let device = [id: Check.DeviceNote(hasLocalAudio: true, marker: marker("a"), isRecentlyDeleted: true)]
        let answers: [Check.ServerNote] = [.noNote, .noMarker, .marker(marker("a")), .marker(marker("b"))]
        for answer in answers {
            precondition(
                Check.verdict(parts: p, serverNotes: [id: answer], device: device, deletingHere: []) == .safeToDelete,
                "\(answer)"
            )
        }
    }

    /// Unread or unreadable: the restore may not have come here.
    static func testARecentlyDeletedNoteHereThatCantBeReadCantBeSure() {
        let id = UUID()
        let p = parts(id, marker("a"))
        let device = [id: Check.DeviceNote(hasLocalAudio: true, marker: nil, isRecentlyDeleted: true)]
        precondition(Check.verdict(parts: p, serverNotes: [:], device: device, deletingHere: []) == .cannotBeSure)
        precondition(Check.verdict(parts: p, serverNotes: [id: .unreadable], device: device, deletingHere: []) == .cannotBeSure)
    }
}
