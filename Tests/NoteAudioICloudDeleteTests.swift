import Foundation
import QuillNoteSyncCore

@main
struct NoteAudioICloudDeleteTests {
    static func main() {
        testSummaryAddsMarkerSizes()
        testSpaceNeedsTheRecordingsAndWorkingRoom()
        testSizeTextReadsInTheLocale()
        testTitleKeyFollowsTheCount()
        testCopyKeysAreTheAgreedText()
        print("NoteAudioICloudDeleteTests passed")
    }

    static func testSummaryAddsMarkerSizes() {
        let two = NoteAudioICloudOnlySummary(markerBytes: [100, 250])
        precondition(two.count == 2 && two.bytes == 350)
        let none = NoteAudioICloudOnlySummary(markerBytes: [])
        precondition(none.count == 0 && none.bytes == 0)
        let negative = NoteAudioICloudOnlySummary(markerBytes: [100, -5])
        precondition(negative.count == 2 && negative.bytes == 100)
        let huge = NoteAudioICloudOnlySummary(markerBytes: [Int64.max, 1])
        precondition(huge.bytes == Int64.max)
    }

    static func testSpaceNeedsTheRecordingsAndWorkingRoom() {
        typealias P = NoteAudioICloudDeletePolicy
        precondition(P.workingRoom == 100_000_000)
        precondition(P.space(neededBytes: 1_000_000_000, freeBytes: 1_100_000_000) == .enough)
        precondition(P.space(neededBytes: 1_000_000_000, freeBytes: 1_099_999_999) == .short(by: 1))
        precondition(P.space(neededBytes: 1_000_000_000, freeBytes: 0) == .short(by: 1_100_000_000))
        precondition(P.space(neededBytes: 1_000_000_000, freeBytes: nil) == .enough)
        precondition(P.space(neededBytes: Int64.max, freeBytes: 0) == .short(by: Int64.max))
    }

    static func testSizeTextReadsInTheLocale() {
        typealias P = NoteAudioICloudDeletePolicy
        let us = Locale(identifier: "en_US")
        precondition(P.sizeText(bytes: 1_200_000_000, locale: us) == "1.2 GB")
        precondition(P.sizeText(bytes: 340_000_000, locale: us) == "340 MB")
        precondition(!P.sizeText(bytes: 0, locale: us).contains("Zero"))
        let ko = P.sizeText(bytes: 1_200_000_000, locale: Locale(identifier: "ko_KR"))
        precondition(ko.contains("1.2") && ko.contains("GB"))
    }

    static func testTitleKeyFollowsTheCount() {
        typealias C = NoteAudioICloudDeleteCopy
        precondition(C.titleFormatKey(count: 1) == C.titleOneFormatKey)
        precondition(C.titleFormatKey(count: 2) == C.titleManyFormatKey)
        precondition(C.titleFormatKey(count: 0) == C.titleManyFormatKey)
    }

    static func testCopyKeysAreTheAgreedText() {
        typealias C = NoteAudioICloudDeleteCopy
        precondition(C.titleOneFormatKey == "1 recording (about %@) is only in iCloud")
        precondition(C.titleManyFormatKey == "%lld recordings (about %@) are only in iCloud")
        precondition(C.messageKey == "After they're deleted from iCloud, this device can't get them. Download them first to keep them here. Transcripts and summaries stay either way.")
        precondition(C.downloadThenDeleteKey == "Download, Then Delete")
        precondition(C.deleteWithoutRecordingsKey == "Delete Without Recordings")
        precondition(C.progressFormatKey == "Downloading recordings from iCloud · %lld of %lld")
        precondition(C.progressDetailKey == "Nothing is deleted from iCloud until every recording is on this device.")
        precondition(C.notEnoughSpaceTitleKey == "Not enough space to download the recordings")
        precondition(C.notEnoughSpaceMessageFormatKey == "Free up %@ more on this device, then try again. Nothing was deleted from iCloud, and sync is still on.")
        precondition(C.downloadFailedTitleKey == "Couldn't download every recording")
        precondition(C.downloadFailedMessageKey == "Nothing was deleted from iCloud, and sync is still on. Recordings already downloaded stay on this device. Check your internet connection and try again.")
        precondition(C.cannotCheckMessageKey == "Quill couldn't check which recordings are only in iCloud, so nothing was deleted. Sync is still on.")
    }
}
