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
        testProviderHostNeverLeaves()
        testUnknownKeysMergeTheSameBothWays()
        testMergeKeepsNewerBuildClockGroups()
        testEachFieldChangesOnlyItsGroup()
        testMissingRequiredKeysKeepLocalValues()
        testStampsCompareAtMilliseconds()
        testNewNoteNeedsEveryRequiredField()
        testUnreadableKnownValuesAreDetected()
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
        // Every stored property, nil or not (JSON leaves out nil optionals).
        let keys = Set(Mirror(reflecting: item()).children.compactMap(\.label))
        let synced = Set(NoteSyncField.allCases.map(\.itemKey))
        let bookkeeping: Set<String> = ["id", "deletedAt", "fieldClock"]
        let unclassified = keys.subtracting(synced).subtracting(NoteSyncRecord.localOnlyItemKeys).subtracting(bookkeeping)
        precondition(unclassified.isEmpty, "unclassified item fields: \(unclassified.sorted())")
        precondition(synced.isDisjoint(with: NoteSyncRecord.localOnlyItemKeys))
    }

    static func testRoundTripKeepsSyncedFields() {
        let original = item()
        let record = NoteSyncRecord(item: original)
        let received = record.newNote()!
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
        let received = NoteSyncRecord(item: item()).newNote()!
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
        let received = record.newNote()!
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

    static func attempt(host: String?) -> MeetingSummaryAttempt {
        MeetingSummaryAttempt(
            occurredAt: t0,
            outcome: .succeeded,
            backendKind: .cloud,
            modelID: "synthetic-model",
            providerHost: host,
            language: nil,
            issue: nil
        )
    }

    static func testProviderHostNeverLeaves() {
        let base = item()
        let withAttempt = PipelineHistoryItem(
            id: base.id, timestamp: t0, rawTranscript: "r", postProcessedTranscript: "e",
            postProcessingPrompt: nil, contextSummary: "", contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot", postProcessingStatus: "succeeded",
            debugStatus: "", customVocabulary: "",
            meetingSummaryAttempt: attempt(host: "llm.internal.example")
        )
        let record = NoteSyncRecord(item: withAttempt)
        guard case .data(let encoded)? = record.fields[NoteSyncField.meetingSummaryAttempt.rawValue] else {
            preconditionFailure("the attempt syncs")
        }
        precondition(!String(decoding: encoded, as: UTF8.self).contains("llm.internal.example"),
                     "a private provider host never leaves the Mac")
        let received = record.newNote()!
        precondition(received.meetingSummaryAttempt?.modelID == "synthetic-model")
        precondition(received.meetingSummaryAttempt?.providerHost == nil)
    }

    static func testUnknownKeysMergeTheSameBothWays() {
        let base = item()
        var a = record(base, stamps: [.title: t0.addingTimeInterval(10)])
        var b = record(base, stamps: [.title: t0.addingTimeInterval(10)])
        a.fields["futureField"] = .string("alpha")
        b.fields["futureField"] = .string("bravo")
        let onA = NoteSyncMerge.merge(local: a, remote: b).fields["futureField"]
        let onB = NoteSyncMerge.merge(local: b, remote: a).fields["futureField"]
        precondition(onA == onB, "both Macs keep the same newer-build value")
        var current = record(base, stamps: [.title: t0.addingTimeInterval(30)])
        current.fields["futureField"] = .string("current")
        var older = record(base, stamps: [.title: t0.addingTimeInterval(10)])
        older.fields["futureField"] = .string("older")
        older.fields[NoteSyncRecord.schemaVersionKey] = .int(0)
        precondition(NoteSyncMerge.merge(local: current, remote: older) == current, "an older copy changes nothing")
    }

    static func testMergeKeepsNewerBuildClockGroups() {
        let base = item()
        let local = record(base, stamps: [:])
        var remote = record(base, stamps: [:])
        remote.clock = NoteFieldClock(stamps: remote.clock.stamps.merging(["attachments": t0.addingTimeInterval(99)]) { $1 })
        let merged = NoteSyncMerge.merge(local: local, remote: remote)
        precondition(merged.clock.stamps["attachments"] == t0.addingTimeInterval(99))
    }

    /// Each synced field belongs to exactly one clock group, the same one
    /// `NoteFieldClock` stamps when that field changes.
    static func testEachFieldChangesOnlyItsGroup() {
        let base = item()
        let baseRecord = NoteSyncRecord(item: base)
        let match = CalendarEventMatch(
            calendarID: "synthetic-calendar", eventID: "synthetic-event", title: "Synthetic",
            start: t0, end: t0.addingTimeInterval(60), matchSource: .importSelection, titleState: .suggested
        )
        for field in NoteSyncField.allCases {
            var changed = baseRecord
            let key = field.rawValue
            switch (field, changed.fields[key]) {
            case (.intent, _): changed.fields[key] = .string("command:manual")
            case (.spokenLanguageResolution, _): changed.fields[key] = .string("engineDetected")
            case (.calendarMatch, _): changed.fields[key] = .data(try! JSONEncoder().encode(match))
            case (.meetingSummaryAttempt, _): changed.fields[key] = .data(try! JSONEncoder().encode(attempt(host: nil)))
            case (.meetingSummaryJSON, _): changed.fields[key] = .data(Data("{\"other\":1}".utf8))
            case (_, .string(let text)?): changed.fields[key] = .string(text + " changed")
            case (_, .date(let date)?): changed.fields[key] = .date(date.addingTimeInterval(1))
            case (_, .bool(let flag)?): changed.fields[key] = .bool(!flag)
            default: changed.fields[key] = .string("synthetic new")
            }
            let groups = NoteFieldClock.changedGroups(from: base, to: changed.applied(onto: base))
            precondition(groups == [field.group], "\(key) changes \(groups), expected \(field.group)")
        }
    }

    static func testMissingRequiredKeysKeepLocalValues() {
        let local = item(edited: "local edited")
        var remote = NoteSyncRecord(item: item(id: local.id, edited: "remote edited"))
        for field in [NoteSyncField.rawTranscript, .postProcessedTranscript, .postProcessingStatus,
                      .transcriptionLanguageCode, .aiProcessingOutcome, .localTranscriptionModelID,
                      .usedLocalTranscription, .usedPostProcessing] {
            remote.fields.removeValue(forKey: field.rawValue)
        }
        let applied = remote.applied(onto: local)
        precondition(applied.postProcessedTranscript == "local edited")
        precondition(applied.rawTranscript == local.rawTranscript)
        precondition(applied.postProcessingStatus == local.postProcessingStatus)
        precondition(applied.transcriptionLanguageCode == local.transcriptionLanguageCode)
        precondition(applied.usedLocalTranscription == local.usedLocalTranscription)
        var newer = remote
        newer.clock = newer.clock.setting(.editedTranscript, to: t0.addingTimeInterval(100))
        let merged = NoteSyncMerge.merge(local: NoteSyncRecord(item: local), remote: newer)
        precondition(merged.fields[NoteSyncField.postProcessedTranscript.rawValue] == .string("local edited"),
                     "a winning group missing a required key keeps the local value")
    }

    static func testStampsCompareAtMilliseconds() {
        let fine = t0.addingTimeInterval(0.123_456_7)
        let local = item(clock: NoteFieldClock.uniform(t0).setting(.title, to: fine))
        let record = NoteSyncRecord(item: local)
        precondition(record.clock.stamp(for: .title) == Date(timeIntervalSince1970: (fine.timeIntervalSince1970 * 1000).rounded() / 1000))
        var unrounded = record
        unrounded.clock = unrounded.clock.setting(.title, to: fine)
        let merged = NoteSyncMerge.merge(local: unrounded, remote: record)
        precondition(merged.fields[NoteSyncField.customTitle.rawValue] == record.fields[NoteSyncField.customTitle.rawValue])
        precondition(merged.clock.stamp(for: .title) == record.clock.stamp(for: .title), "the same edit compares equal after rounding")
    }

    static func testNewNoteNeedsEveryRequiredField() {
        precondition(NoteSyncRecord(item: item()).newNote() != nil)
        for field in NoteSyncField.allCases where field.isRequired {
            var record = NoteSyncRecord(item: item())
            record.fields.removeValue(forKey: field.rawValue)
            precondition(record.newNote() == nil, "a record missing \(field.rawValue) never becomes a new note")
        }
        var noTimestamp = NoteSyncRecord(item: item())
        noTimestamp.fields.removeValue(forKey: NoteSyncField.timestamp.rawValue)
        precondition(noTimestamp.applied(onto: item(id: noTimestamp.noteID)).timestamp == t0,
                     "an existing note keeps its own timestamp")
    }

    static func testUnreadableKnownValuesAreDetected() {
        precondition(!NoteSyncRecord(item: item()).hasUnreadableKnownFields)
        let cases: [(String, NoteSyncValue)] = [
            (NoteSyncField.customTitle.rawValue, .raw(Data("[1]".utf8))),
            (NoteSyncField.rawTranscript.rawValue, .int(3)),
            (NoteSyncField.timestamp.rawValue, .string("yesterday")),
            (NoteSyncField.intent.rawValue, .string("meetingV2")),
            (NoteSyncField.spokenLanguageResolution.rawValue, .string("future")),
            (NoteSyncField.usedPostProcessing.rawValue, .string("yes")),
            (NoteSyncField.meetingSummaryJSON.rawValue, .string("{}")),
            (NoteSyncRecord.schemaVersionKey, .string("2"))
        ]
        for (key, value) in cases {
            var record = NoteSyncRecord(item: item())
            record.fields[key] = value
            precondition(record.hasUnreadableKnownFields, "\(key) with a value this build can't read is detected")
        }
        var future = NoteSyncRecord(item: item())
        future.fields["futureField"] = .raw(Data("[1]".utf8))
        precondition(!future.hasUnreadableKnownFields, "unknown keys are fine")
    }
}
