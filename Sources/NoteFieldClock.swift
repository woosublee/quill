import Foundation

/// Groups of note fields that change, sync, and merge together. Only fields a
/// person sees are listed; screenshots, window context, selected text, and
/// prompts never sync.
enum NoteFieldGroup: String, CaseIterable, Sendable {
    case title
    case rawTranscript
    case editedTranscript
    case summary
    case calendar
    case recordingTime
    case language
    case status
    case audio
    case deletion
}

/// When each field group of a note last changed. Sync keeps, per group, the
/// value with the later time. Keys are `NoteFieldGroup` raw values, so a
/// newer build's groups survive a round trip through this one.
struct NoteFieldClock: Codable, Equatable, Sendable {
    private(set) var stamps: [String: Date]

    init(stamps: [String: Date] = [:]) {
        self.stamps = stamps
    }

    static func uniform(_ date: Date) -> NoteFieldClock {
        NoteFieldClock(stamps: Dictionary(
            uniqueKeysWithValues: NoteFieldGroup.allCases.map { ($0.rawValue, date) }
        ))
    }

    func stamp(for group: NoteFieldGroup) -> Date? {
        stamps[group.rawValue]
    }

    func setting(_ group: NoteFieldGroup, to date: Date) -> NoteFieldClock {
        var copy = self
        copy.stamps[group.rawValue] = date
        return copy
    }

    /// The groups whose values differ. `deletion` is never reported: only
    /// `PipelineHistoryStore.setDeletedAt(_:id:)` changes it.
    static func changedGroups(
        from old: PipelineHistoryItem,
        to new: PipelineHistoryItem
    ) -> Set<NoteFieldGroup> {
        Set(NoteFieldGroup.allCases.filter {
            $0 != .deletion && signature(of: $0, in: old) != signature(of: $0, in: new)
        })
    }

    /// The clock to save with `current`. A new note stamps every group now.
    /// A note saved before clocks existed starts from its own timestamp.
    static func stamped(
        previous: PipelineHistoryItem?,
        current: PipelineHistoryItem,
        existing: NoteFieldClock?,
        now: Date
    ) -> NoteFieldClock {
        guard let previous else { return uniform(now) }
        var clock = existing ?? uniform(previous.timestamp)
        for group in changedGroups(from: previous, to: current) {
            clock = clock.setting(group, to: now)
        }
        return clock
    }

    private static func signature(
        of group: NoteFieldGroup,
        in item: PipelineHistoryItem
    ) -> [String?] {
        switch group {
        case .title:
            return [item.customTitle]
        case .rawTranscript:
            return [item.rawTranscript, item.transcriptFileName]
        case .editedTranscript:
            return [item.postProcessedTranscript]
        case .summary:
            return [
                item.meetingSummaryJSON?.base64EncodedString(),
                json(item.meetingSummaryAttempt)
            ]
        case .calendar:
            return [json(item.calendarMatch)]
        case .recordingTime:
            return [
                date(item.timestamp),
                item.recordingStartedAt.map(date),
                item.recordingEndedAt.map(date)
            ]
        case .language:
            return [
                item.transcriptionLanguageCode,
                item.spokenLanguageCode,
                item.spokenLanguageResolution?.rawValue
            ]
        case .status:
            return [
                item.postProcessingStatus,
                item.aiProcessingOutcome,
                item.localTranscriptionModelID,
                String(item.usedLocalTranscription),
                String(item.usedPostProcessing)
            ]
        case .audio:
            return [item.audioFileName]
        case .deletion:
            return []
        }
    }

    private static func date(_ value: Date) -> String {
        String(value.timeIntervalSince1970)
    }

    private static func json<T: Encodable>(_ value: T?) -> String? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
