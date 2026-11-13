import Foundation

/// The recordings that are only in iCloud, counted for the prompt.
public struct NoteAudioICloudOnlySummary: Equatable, Sendable {
    public let count: Int
    /// The markers' byte counts added up. A negative count adds 0; the sum
    /// stops at Int64.max instead of overflowing.
    public let bytes: Int64

    public init(markerBytes: [Int64]) {
        count = markerBytes.count
        var total: Int64 = 0
        for value in markerBytes {
            let (sum, overflow) = total.addingReportingOverflow(max(0, value))
            total = overflow ? Int64.max : sum
        }
        bytes = total
    }
}

public enum NoteAudioICloudDeletePolicy {
    /// Room a download needs beyond the recording itself: two copies of one
    /// part in flight (CloudKit's and the downloader's).
    public static let workingRoom: Int64 = 2 * NoteAudioParts.partSize

    public enum Space: Equatable, Sendable {
        case enough
        /// How many more bytes must be free.
        case short(by: Int64)
    }

    /// `neededBytes + workingRoom` against `freeBytes`. Free space that
    /// can't be read (nil) is `.enough`: a download that runs out of room
    /// fails, and a failed download deletes nothing.
    public static func space(neededBytes: Int64, freeBytes: Int64?) -> Space {
        guard let freeBytes else { return .enough }
        let (required, overflow) = max(0, neededBytes).addingReportingOverflow(workingRoom)
        let total = overflow ? Int64.max : required
        let free = max(0, freeBytes)
        return free >= total ? .enough : .short(by: total - free)
    }

    /// "1.2 GB", "340 MB": file-style units, zero as a number, in `locale`.
    public static func sizeText(bytes: Int64, locale: Locale) -> String {
        bytes.formatted(
            .byteCount(style: .file, allowedUnits: .all, spellsOutZero: false, includesActualByteCount: false)
                .locale(locale)
        )
    }
}

public enum NoteAudioICloudDeleteCopy {
    /// One argument: the size text.
    public static let titleOneFormatKey = "1 recording (about %@) is only in iCloud"
    /// Two arguments: the count, then the size text.
    public static let titleManyFormatKey = "%lld recordings (about %@) are only in iCloud"
    public static func titleFormatKey(count: Int) -> String {
        count == 1 ? titleOneFormatKey : titleManyFormatKey
    }
    public static let messageKey = "After they're deleted from iCloud, this device can't get them. Download them first to keep them here. Transcripts and summaries stay either way."
    public static let downloadThenDeleteKey = "Download, Then Delete"
    public static let deleteWithoutRecordingsKey = "Delete Without Recordings"
    /// Two arguments: done, total.
    public static let progressFormatKey = "Downloading recordings from iCloud · %lld of %lld"
    public static let progressDetailKey = "Nothing is deleted from iCloud until every recording is on this device."
    public static let notEnoughSpaceTitleKey = "Not enough space to download the recordings"
    /// One argument: the size text of what is missing.
    public static let notEnoughSpaceMessageFormatKey = "Free up %@ more on this device, then try again. Nothing was deleted from iCloud."
    public static let downloadFailedTitleKey = "Couldn't download every recording"
    public static let downloadFailedMessageKey = "Nothing was deleted from iCloud. Recordings already downloaded stay on this device. Check your internet connection and try again."
    public static let cannotCheckMessageKey = "Quill couldn't check which recordings are only in iCloud, so nothing was deleted."
    /// Sync paused with nothing running to download with (#838).
    public static let syncPausedTitleKey = "Can't download recordings while sync is paused"
    public static let syncPausedMessageKey = "Nothing was deleted from iCloud. Check the sync status above, then try again."
}
