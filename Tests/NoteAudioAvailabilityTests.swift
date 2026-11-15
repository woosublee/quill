import Foundation
import QuillNoteSyncCore

/// #836: the rule both apps use for whether a note's recording can be had.
@main
struct NoteAudioAvailabilityTests {
    static let marker = NoteAudioManifest(sha256: String(repeating: "ab", count: 32), bytes: 1_000, partSize: 50_000_000, parts: 1)

    static func of(
        hasAudio: Bool = true, isLocal: Bool = false, progress: Double? = nil,
        marker: NoteAudioManifest? = Self.marker, isSyncOn: Bool = true,
        failure: (sha256: String, reason: NoteAudioAvailability.Reason)? = nil,
        waitsForWiFi: Bool = false, comesFromICloud: Bool = false
    ) -> NoteAudioAvailability {
        NoteAudioAvailability.of(.init(
            hasAudio: hasAudio, isLocal: isLocal, downloadProgress: progress, marker: marker,
            isSyncOn: isSyncOn, lastFailure: failure.map { .init(sha256: $0.sha256, reason: $0.reason) },
            waitsForWiFi: waitsForWiFi, comesFromICloud: comesFromICloud
        ))
    }

    static func main() {
        precondition(of(hasAudio: false) == .none, "no recording")
        precondition(of(isLocal: true, isSyncOn: false) == .local, "the file here wins")
        precondition(of(progress: 0.5) == .downloading(0.5), "a download running")
        precondition(of(progress: 0.5, isSyncOn: false) == .downloading(0.5), "a running download shows before sync off")

        // Sync off.
        precondition(of(isSyncOn: false) == .unavailable(.syncOff), "marked audio waits for sync")
        precondition(of(marker: nil, isSyncOn: false) == .none, "a file lost here with no marker is no audio")
        precondition(of(marker: nil, isSyncOn: false, comesFromICloud: true) == .unavailable(.syncOff),
                     "a received note's recording still to come waits for sync")
        precondition(of(isSyncOn: false, comesFromICloud: true) == .unavailable(.syncOff),
                     "a received note's marked recording waits for sync")
        precondition(of(isSyncOn: false, failure: (marker.sha256, .failed)) == .unavailable(.syncOff),
                     "sync off is said before an earlier failure")

        // Sync on.
        precondition(of(marker: nil) == .unavailable(.notUploadedYet), "no marker yet")
        precondition(of(marker: nil, comesFromICloud: true) == .unavailable(.notUploadedYet),
                     "with sync on, no marker is not uploaded yet either way")
        precondition(of(failure: (marker.sha256, .offline)) == .unavailable(.offline), "the failure for this marker")
        precondition(of(failure: (String(repeating: "cd", count: 32), .failed)) == .downloadable,
                     "a failure for another marker says nothing")
        precondition(of(failure: (marker.sha256, .failed), waitsForWiFi: true) == .unavailable(.waitingForWiFi),
                     "cellular not allowed is said before an earlier failure, so no retry is offered")
        precondition(of(failure: (marker.sha256, .offline), comesFromICloud: true) == .unavailable(.offline),
                     "a received note's failure for this marker")
        precondition(of(waitsForWiFi: true) == .unavailable(.waitingForWiFi), "cellular not allowed")
        precondition(of() == .downloadable)
        print("NoteAudioAvailabilityTests passed")
    }
}
