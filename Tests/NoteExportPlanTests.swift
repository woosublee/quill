import Foundation
import QuillNoteCore

/// Save Files' shared rules (quill-universal-private#281): what is offered,
/// the stale-summary flag, and the file names. Synthetic text only.
@main
struct NoteExportPlanTests {
    static func main() {
        testBlankTextIsNotOffered()
        testStaleNeedsASummary()
        testFileNamesFollowItemOrderAndFormat()
        testUnavailableItemsAreSkipped()
        testSanitizedAndSuggestedNames()
        testFileNameLimit()
        print("NoteExportPlanTests passed")
    }

    private static func testBlankTextIsNotOffered() {
        let plan = NoteExportPlan(transcript: " \n", summary: "\t", audioPathExtension: nil)
        precondition(plan.availableItems.isEmpty)
        let all = NoteExportPlan(transcript: "Synthetic line.", summary: "# Synthetic summary", audioPathExtension: "m4a")
        precondition(all.availableItems == [.transcript, .summary, .audio])
        let summaryOnly = NoteExportPlan(transcript: nil, summary: "# Synthetic summary", audioPathExtension: nil)
        precondition(summaryOnly.availableItems == [.summary])
    }

    private static func testStaleNeedsASummary() {
        precondition(NoteExportPlan(transcript: "a", summary: "b", audioPathExtension: nil, isSummaryStale: true).isSummaryStale)
        precondition(!NoteExportPlan(transcript: "a", summary: "b", audioPathExtension: nil, isSummaryStale: false).isSummaryStale)
        precondition(!NoteExportPlan(transcript: "a", summary: " ", audioPathExtension: nil, isSummaryStale: true).isSummaryStale)
        precondition(!NoteExportPlan(transcript: "a", summary: nil, audioPathExtension: nil, isSummaryStale: true).isSummaryStale)
    }

    private static func testFileNamesFollowItemOrderAndFormat() {
        let plan = NoteExportPlan(transcript: "a", summary: "b", audioPathExtension: "m4a")
        let names = plan.fileNames(for: [.audio, .summary, .transcript], textFormat: .markdown, baseName: "Weekly Sync")
        precondition(names.map(\.item) == [.transcript, .summary, .audio])
        precondition(names.map(\.name) == ["Weekly Sync.md", "Weekly Sync-summary.md", "Weekly Sync.m4a"])
        let plain = plan.fileNames(for: [.summary], textFormat: .plainText, baseName: "Weekly Sync")
        precondition(plain.map(\.name) == ["Weekly Sync-summary.txt"])
        let noExtension = NoteExportPlan(transcript: nil, summary: nil, audioPathExtension: "")
        precondition(noExtension.fileNames(for: [.audio], textFormat: .plainText, baseName: "x").map(\.name) == ["x.wav"])
    }

    private static func testUnavailableItemsAreSkipped() {
        let plan = NoteExportPlan(transcript: "a", summary: nil, audioPathExtension: nil)
        let names = plan.fileNames(for: [.transcript, .summary, .audio], textFormat: .plainText, baseName: "n")
        precondition(names.map(\.item) == [.transcript])
    }

    private static func testSanitizedAndSuggestedNames() {
        precondition(NoteExportPlan.sanitizedBaseName(" a/b:c. ", fallback: "f") == "a-b:c")
        precondition(NoteExportPlan.sanitizedBaseName("/// ..", fallback: "Fallback") == "Fallback")
        precondition(NoteExportPlan.sanitizedBaseName("", fallback: "") == NoteExportPlan.fallbackBaseName)
        let plan = NoteExportPlan(transcript: "a", summary: nil, audioPathExtension: nil)
        precondition(plan.fileNames(for: [.transcript], textFormat: .plainText, baseName: "?").map(\.name) == ["Quill Recording.txt"])

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        precondition(NoteExportPlan.suggestedBaseName(customTitle: " Mine ", calendarTitle: "Event", timestamp: date) == "Mine")
        precondition(NoteExportPlan.suggestedBaseName(customTitle: "  ", calendarTitle: "Event", timestamp: date) == "Event")
        let dated = NoteExportPlan.suggestedBaseName(
            customTitle: nil,
            calendarTitle: nil,
            timestamp: date,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!
        )
        precondition(dated.contains("2027"), "an untitled note is named by its time")
        precondition(!dated.contains("\u{202F}"), "narrow spaces become plain spaces")
    }

    private static func testFileNameLimit() {
        precondition(!NoteExportPlan.isFileNameTooLong(String(repeating: "a", count: 255)))
        precondition(NoteExportPlan.isFileNameTooLong(String(repeating: "a", count: 256)))
    }
}
