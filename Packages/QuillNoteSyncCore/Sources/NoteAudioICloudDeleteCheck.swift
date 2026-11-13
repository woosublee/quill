import Foundation

/// Before deleting everything from iCloud: is every recording iCloud holds
/// on this device? Pure; each app does the reads.
///
/// For each note with parts in iCloud (not being deleted here):
/// 1. A recording file here: held. This rests on a note's recording never
///    changing once set, so the file here is the one the parts are of.
/// 2. This device's marker, with every one of the note's parts under its
///    key: downloaded, without reading the server's note.
/// 3. Otherwise the server's note is read: no note or no marker holds
///    nothing to keep, a marker equal to this device's (after the merge) is
///    downloaded, and anything else can't be sure.
public enum NoteAudioICloudDeleteCheck {
    /// What the server's copy of a note says of its recording.
    public enum ServerNote: Equatable, Sendable {
        case noNote
        case noMarker
        case marker(NoteAudioManifest)
        /// Couldn't be fetched or read.
        case unreadable
    }

    /// A note on this device. A note that isn't here has no entry.
    public struct DeviceNote: Equatable, Sendable {
        /// A non-empty recording file is on this device.
        public var hasLocalAudio: Bool
        public var marker: NoteAudioManifest?

        public init(hasLocalAudio: Bool, marker: NoteAudioManifest?) {
            self.hasLocalAudio = hasLocalAudio
            self.marker = marker
        }
    }

    public enum Verdict: Equatable, Sendable {
        case safeToDelete
        /// These notes' recordings are in iCloud, not here, and this device
        /// holds the marker to download them with.
        case download(Set<UUID>)
        case cannotBeSure
    }

    private enum NoteState {
        case held
        case download
        case needsRead
    }

    /// The notes whose server record must be read before `verdict`.
    public static func notesToRead(
        parts: [NoteAudioPartID],
        device: [UUID: DeviceNote],
        deletingHere: Set<UUID>
    ) -> Set<UUID> {
        Set(states(parts: parts, device: device, deletingHere: deletingHere).compactMap {
            $0.value == .needsRead ? $0.key : nil
        })
    }

    public static func verdict(
        parts: [NoteAudioPartID],
        serverNotes: [UUID: ServerNote],
        device: [UUID: DeviceNote],
        deletingHere: Set<UUID>
    ) -> Verdict {
        var downloads = Set<UUID>()
        var doubt = false
        for (id, state) in states(parts: parts, device: device, deletingHere: deletingHere) {
            switch state {
            case .held:
                break
            case .download:
                downloads.insert(id)
            case .needsRead:
                switch serverNotes[id] {
                case .none, .unreadable:
                    doubt = true
                case .noNote, .noMarker:
                    // Leftover parts, or an upload still running: nothing to keep.
                    break
                case .marker(let marker):
                    if let held = device[id]?.marker, held == marker {
                        downloads.insert(id)
                    } else {
                        doubt = true
                    }
                }
            }
        }
        if doubt { return .cannotBeSure }
        return downloads.isEmpty ? .safeToDelete : .download(downloads)
    }

    private static func states(
        parts: [NoteAudioPartID],
        device: [UUID: DeviceNote],
        deletingHere: Set<UUID>
    ) -> [UUID: NoteState] {
        var keysByNote: [UUID: Set<String>] = [:]
        for part in parts where !deletingHere.contains(part.noteID) {
            keysByNote[part.noteID, default: []].insert(part.key)
        }
        var result: [UUID: NoteState] = [:]
        for (id, keys) in keysByNote {
            if let note = device[id] {
                if note.hasLocalAudio {
                    result[id] = .held
                    continue
                }
                // Parts under any other key may be a recording this device
                // doesn't know of: the server decides.
                if let marker = note.marker,
                   keys == [NoteAudioPartID.key(sha256: marker.sha256)] {
                    result[id] = .download
                    continue
                }
            }
            result[id] = .needsRead
        }
        return result
    }
}
