import Foundation

@main
struct NoteSyncRecordTests {
    static func main() throws {
        try testEveryItemFieldIsClassified()
        testRoundTripKeepsSyncedFields()
        testRecordNeverCarriesLocalOnlyFields()
        testApplyKeepsLocalOnlyFields()
        testNewNoteFromRecordLeavesLocalOnlyFieldsEmpty()
        testUnknownAndMissingKeys()
        testEligibility()
        testMergeTakesLaterGroupFromEachSide()
        testTieResolvesTheSameBothWays()
        testMergeIsIdempotentAndIgnoresOlderCopy()
        testMergeKeepsUnknownKeys()
        testDeletionMergesLikeAField()
        print("NoteSyncRecordTests passed")
    }

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func item(
        id: UUID = UUID(),
        title: String? = "Synthetic title",
        edited: String = "synthetic edited",
        status: String = "succeeded",
        audio: String? = "synthetic.m4a",
        deletedAt: Date? = nil,
        clock: NoteFieldClock? = nil
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            intent: .dictation,
            selectedText: "synthetic selected",
            capturedSelection: "synthetic captured",
            id: id,
            timestamp: t0,
            recordingStartedAt: t0.addingTimeInterval(-60),
            recordingEndedAt: t0,
            calendarMatch: nil,
            rawTranscript: "synthetic raw",
            postProcessedTranscript: edited,
            postProcessingPrompt: "synthetic prompt",
            systemPrompt: "synthetic system",
            contextSummary: "synthetic context",
            contextSystemPrompt: "synthetic context system",
            contextPrompt: "synthetic context prompt",
            contextScreenshotDataURL: "data:image/png;base64,AAAA",
            contextScreenshotStatus: "available (image)",
            postProcessingStatus: status,
            aiProcessingOutcome: "succeeded",
            debugStatus: "synthetic debug",
            customVocabulary: "synthetic vocabulary",
            customSystemPrompt: "synthetic custom system",
            audioFileName: audio,
            usedLocalTranscription: true,
            usedContextCapture: true,
            usedPostProcessing: true,
            transcriptionLanguageCode: "ko",
            spokenLanguageCode: "ko",
            spokenLanguageResolution: .configured,
            meetingSummaryAttempt: nil,
            localTranscriptionModelID: "synthetic-model",
            transcriptFileName: "synthetic.json",
            contextAppName: "Synthetic App",
            contextBundleIdentifier: "com.example.synthetic",
            contextWindowTitle: "Synthetic Window",
            customTitle: title,
            meetingSummaryJSON: Data("{\"synthetic\":true}".utf8),
            deletedAt: deletedAt,
            fieldClock: clock ?? NoteFieldClock.uniform(t0)
        )
    }

    /// Every key the item encodes is either synced or local-only, so a new
    /// field can't slip into sync, or out of it, unnoticed.
    static func testEveryItemFieldIsClassified() throws {
        let data = try JSONEncoder().encode(item())
        let keys = Set((try JSONSerialization.jsonObject(with: data) as! [String: Any]).keys)
        let synced = Set(NoteSyncField.allCases.map(\.itemKey))
        let bookkeeping: Set<String> = ["id", "deletedAt", "fieldClock"]
        let unclassified = keys.subtracting(synced).subtracting(NoteSyncRecord.localOnlyItemKeys).subtracting(bookkeeping)
        precondition(unclassified.isEmpty, "unclassified item fields: \(unclassified.sorted())")
        precondition(synced.isDisjoint(with: NoteSyncRecord.localOnlyItemKeys))
    }

    static func testRoundTripKeepsSyncedFields() {
        let original = item()
        let record = NoteSyncRecord(item: original)
        let received = record.applied(onto: nil)
        precondition(received.id == original.id)
        precondition(received.customTitle == original.customTitle)
        precondition(received.rawTranscript == original.rawTranscript)
        precondition(received.postProcessedTranscript == original.postProcessedTranscript)
        precondition(received.meetingSummaryJSON == original.meetingSummaryJSON)
        precondition(received.timestamp == original.timestamp)
        precondition(received.recordingStartedAt == original.recordingStartedAt)
        precondition(received.recordingEndedAt == original.recordingEndedAt)
        precondition(received.transcriptionLanguageCode == "ko")
        precondition(received.spokenLanguageResolution == .configured)
        precondition(received.postProcessingStatus == "succeeded")
        precondition(received.usedLocalTranscription && received.usedPostProcessing)
        precondition(received.localTranscriptionModelID == "synthetic-model")
        precondition(received.audioFileName == "synthetic.m4a")
        precondition(received.transcriptFileName == "synthetic.json")
        precondition(received.fieldClock == original.fieldClock)
        precondition(received.deletedAt == nil)
    }

    static func testRecordNeverCarriesLocalOnlyFields() {
        let record = NoteSyncRecord(item: item())
        let values = record.fields.values.compactMap { value -> String? in
            if case .string(let text) = value { return text }
            return nil
        }
        for secret in [
            "synthetic selected", "synthetic captured", "synthetic prompt",
            "synthetic system", "synthetic context", "synthetic context system",
            "synthetic context prompt", "data:image/png;base64,AAAA",
            "synthetic debug", "synthetic vocabulary", "synthetic custom system",
            "Synthetic App", "com.example.synthetic", "Synthetic Window"
        ] {
            precondition(!values.contains(secret), "record leaks a local-only value")
        }
        for key in NoteSyncRecord.localOnlyItemKeys {
            precondition(record.fields[key] == nil, "record has local-only key \(key)")
        }
    }

    static func testApplyKeepsLocalOnlyFields() {
        let local = item(title: "Local")
        let remote = NoteSyncRecord(item: item(id: local.id, title: "Remote"))
        let merged = remote.applied(onto: local)
        precondition(merged.customTitle == "Remote")
        precondition(merged.contextScreenshotDataURL == local.contextScreenshotDataURL)
        precondition(merged.contextWindowTitle == local.contextWindowTitle)
        precondition(merged.selectedText == local.selectedText)
        precondition(merged.customVocabulary == local.customVocabulary)
        precondition(merged.usedContextCapture == local.usedContextCapture)
    }

    static func testNewNoteFromRecordLeavesLocalOnlyFieldsEmpty() {
        let received = NoteSyncRecord(item: item()).applied(onto: nil)
        precondition(received.contextScreenshotDataURL == nil)
        precondition(received.contextWindowTitle == nil && received.contextAppName == nil)
        precondition(received.selectedText == nil && received.capturedSelection == nil)
        precondition(received.contextSummary.isEmpty && received.customVocabulary.isEmpty)
        precondition(received.postProcessingPrompt == nil && received.systemPrompt == nil)
        precondition(!received.usedContextCapture)
    }

    static func testUnknownAndMissingKeys() {
        var record = NoteSyncRecord(item: item())
        record.fields["futureField"] = .string("from a newer build")
        record.fields.removeValue(forKey: NoteSyncField.customTitle.rawValue)
        let received = record.applied(onto: nil)
        precondition(received.customTitle == nil, "a missing key reads as nil")
        precondition(received.rawTranscript == "synthetic raw")
        precondition(record.fields["futureField"] == .string("from a newer build"))
    }

    static func testEligibility() {
        precondition(NoteSyncEligibility.isSyncable(item()))
        precondition(NoteSyncEligibility.isSyncable(item(status: "audio-only")))
        precondition(NoteSyncEligibility.isSyncable(item(status: "user-issue:synthetic")))
        for status in ["live-recording", "importing", PipelineHistoryItem.cloudTranscribingStatus,
                       PipelineHistoryItem.transcriptionRecoveryPlaceholderStatus] {
            precondition(!NoteSyncEligibility.isSyncable(item(status: status)), "\(status) waits")
        }
    }

    static func record(
        _ base: PipelineHistoryItem,
        title: String? = nil,
        edited: String? = nil,
        stamps: [NoteFieldGroup: Date]
    ) -> NoteSyncRecord {
        var clock = NoteFieldClock.uniform(t0)
        for (group, date) in stamps { clock = clock.setting(group, to: date) }
        let source = item(
            id: base.id,
            title: title ?? base.customTitle,
            edited: edited ?? base.postProcessedTranscript,
            clock: clock
        )
        return NoteSyncRecord(item: source)
    }

    static func testMergeTakesLaterGroupFromEachSide() {
        let base = item(title: "Base", edited: "base")
        let local = record(base, title: "Local title", stamps: [.title: t0.addingTimeInterval(10)])
        let remote = record(base, edited: "remote summary edit", stamps: [.editedTranscript: t0.addingTimeInterval(20)])
        let merged = NoteSyncMerge.merge(local: local, remote: remote).applied(onto: base)
        precondition(merged.customTitle == "Local title", "local's later title stays")
        precondition(merged.postProcessedTranscript == "remote summary edit", "remote's later edit arrives")
        precondition(merged.fieldClock?.stamp(for: .title) == t0.addingTimeInterval(10))
        precondition(merged.fieldClock?.stamp(for: .editedTranscript) == t0.addingTimeInterval(20))
    }

    static func testTieResolvesTheSameBothWays() {
        let base = item()
        let a = record(base, title: "Alpha", stamps: [.title: t0.addingTimeInterval(5)])
        let b = record(base, title: "Bravo", stamps: [.title: t0.addingTimeInterval(5)])
        let onA = NoteSyncMerge.merge(local: a, remote: b).applied(onto: base).customTitle
        let onB = NoteSyncMerge.merge(local: b, remote: a).applied(onto: base).customTitle
        precondition(onA == onB, "both Macs settle on the same title")
    }

    static func testMergeIsIdempotentAndIgnoresOlderCopy() {
        let base = item()
        let current = record(base, title: "Current", stamps: [.title: t0.addingTimeInterval(30)])
        let older = record(base, title: "Older", stamps: [.title: t0.addingTimeInterval(10)])
        precondition(NoteSyncMerge.merge(local: current, remote: current) == current)
        precondition(NoteSyncMerge.merge(local: current, remote: older) == current)
    }

    static func testMergeKeepsUnknownKeys() {
        let base = item()
        let local = record(base, stamps: [:])
        var remote = record(base, stamps: [:])
        remote.fields["futureField"] = .string("from a newer build")
        let merged = NoteSyncMerge.merge(local: local, remote: remote)
        precondition(merged.fields["futureField"] == .string("from a newer build"))
    }

    static func testDeletionMergesLikeAField() {
        let base = item()
        var deletedRemotely = record(base, stamps: [.deletion: t0.addingTimeInterval(40)])
        deletedRemotely.deletedAt = t0.addingTimeInterval(40)
        let editedLocally = record(base, title: "Edited", stamps: [.title: t0.addingTimeInterval(50)])
        let merged = NoteSyncMerge.merge(local: editedLocally, remote: deletedRemotely)
        precondition(merged.deletedAt == t0.addingTimeInterval(40), "a later deletion wins over no deletion")
        precondition(merged.applied(onto: base).customTitle == "Edited", "the later title still applies")
        var restoredLocally = editedLocally
        restoredLocally.clock = restoredLocally.clock.setting(.deletion, to: t0.addingTimeInterval(60))
        let restored = NoteSyncMerge.merge(local: restoredLocally, remote: deletedRemotely)
        precondition(restored.deletedAt == nil, "a later restore wins over the deletion")
    }
}
