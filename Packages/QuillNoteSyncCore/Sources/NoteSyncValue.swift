import Foundation

/// One synced field value. Absence of a key means `nil`.
public enum NoteSyncValue: Codable, Equatable, Sendable {
    case string(String)
    case date(Date)
    case bool(Bool)
    case data(Data)
    case int(Int)
    /// A value from a newer build, kept as its JSON and written back unchanged.
    case raw(Data)
}

/// The note fields that sync, each in the field group it merges with. Raw
/// values are the record keys, so they never change once shipped.
public enum NoteSyncField: String, CaseIterable, Sendable {
    case customTitle
    case rawTranscript
    case transcriptFileName
    case postProcessedTranscript
    case meetingSummaryJSON
    case meetingSummaryAttempt
    case calendarMatch
    case timestamp
    case recordingStartedAt
    case recordingEndedAt
    case transcriptionLanguageCode
    case spokenLanguageCode
    case spokenLanguageResolution
    case intent
    case postProcessingStatus
    case aiProcessingOutcome
    case localTranscriptionModelID
    case usedLocalTranscription
    case usedPostProcessing
    case audioFileName
    case audioManifest
    /// The notices dismissed on this note, on any device (`NoteDismissedNotices`).
    case dismissedNotices
    /// A retranscription that matched the shown transcript, on any device
    /// (`NoteUnchangedRetranscription`).
    case unchangedRetranscription

    /// Fields every record carries. A record missing one (a malformed or
    /// partial record) never overwrites the local value with a default.
    public var isRequired: Bool {
        switch self {
        case .rawTranscript, .postProcessedTranscript, .timestamp, .transcriptionLanguageCode,
             .intent, .postProcessingStatus, .aiProcessingOutcome, .localTranscriptionModelID,
             .usedLocalTranscription, .usedPostProcessing:
            return true
        default:
            return false
        }
    }

    public var group: NoteFieldGroup {
        switch self {
        case .customTitle: return .title
        case .rawTranscript, .transcriptFileName: return .rawTranscript
        case .postProcessedTranscript: return .editedTranscript
        case .meetingSummaryJSON, .meetingSummaryAttempt: return .summary
        case .calendarMatch: return .calendar
        case .timestamp, .recordingStartedAt, .recordingEndedAt: return .recordingTime
        case .transcriptionLanguageCode, .spokenLanguageCode, .spokenLanguageResolution: return .language
        case .intent, .postProcessingStatus, .aiProcessingOutcome, .localTranscriptionModelID,
             .usedLocalTranscription, .usedPostProcessing: return .status
        case .audioFileName, .audioManifest: return .audio
        case .dismissedNotices: return .notices
        case .unchangedRetranscription: return .unchangedRetranscription
        }
    }

    public enum ValueKind: Sendable { case string, date, bool, data }

    /// The kind of value this field always carries.
    public var valueKind: ValueKind {
        switch self {
        case .meetingSummaryJSON, .meetingSummaryAttempt, .calendarMatch, .audioManifest, .dismissedNotices,
             .unchangedRetranscription: return .data
        case .timestamp, .recordingStartedAt, .recordingEndedAt: return .date
        case .usedLocalTranscription, .usedPostProcessing: return .bool
        default: return .string
        }
    }
}
