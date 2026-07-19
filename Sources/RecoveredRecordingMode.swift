import Foundation

enum RecoveredRecordingMode: String, Codable, Equatable, CaseIterable {
    case complete
    case microphoneOnly = "microphone-only"
    case systemAudioOnly = "system-audio-only"
    case partial
}

extension RecoveredRecordingMode {
    var placeholderStatus: String {
        switch self {
        case .complete: return "transcription-interrupted"
        case .microphoneOnly:
            return "transcription-interrupted:microphone-only"
        case .systemAudioOnly:
            return "transcription-interrupted:system-audio-only"
        case .partial:
            return "transcription-interrupted:partial"
        }
    }

    var recoveredStatus: String {
        switch self {
        case .complete: return "recording-recovered"
        case .microphoneOnly:
            return "recording-recovered:microphone-only"
        case .systemAudioOnly:
            return "recording-recovered:system-audio-only"
        case .partial:
            return "recording-recovered:partial"
        }
    }

    var recoveredDebugStatus: String {
        switch self {
        case .complete:
            return "Recovered after an unexpected shutdown; transcription has not started"
        case .microphoneOnly:
            return "Recovered microphone audio after an unexpected shutdown; System Audio was unavailable; transcription has not started"
        case .systemAudioOnly:
            return "Recovered System Audio after an unexpected shutdown; microphone audio was unavailable; transcription has not started"
        case .partial:
            return "Recovered part of a recording after an unexpected shutdown; some audio may be missing; transcription has not started"
        }
    }

    static func placeholderMode(for status: String) -> RecoveredRecordingMode? {
        RecoveredRecordingContext.placeholderContext(for: status)?.mode
    }

    static func recoveredMode(for status: String) -> RecoveredRecordingMode? {
        RecoveredRecordingContext.recoveredContext(for: status)?.mode
    }

    var titleLocalizationKey: String {
        switch self {
        case .complete: return "Recording interrupted"
        case .microphoneOnly: return "Microphone audio recovered"
        case .systemAudioOnly: return "System Audio recovered"
        case .partial: return "Some audio recovered"
        }
    }

    var descriptionLocalizationKey: String {
        switch self {
        case .complete:
            return "Recovered after an unexpected shutdown. Not yet transcribed."
        case .microphoneOnly:
            return "System Audio could not be recovered. Microphone audio is available for playback or transcription."
        case .systemAudioOnly:
            return "Microphone audio could not be recovered. System Audio is available for playback or transcription."
        case .partial:
            return "Some parts of this recording may be missing. The recovered audio is available for playback or transcription."
        }
    }
}

extension RecordingPromotion {
    var resolvedRecoveryMode: RecoveredRecordingMode {
        recoveryMode ?? .complete
    }

    var resolvedRecoveryIssues: [RecordingRecoveryIssue] {
        recoveryIssues ?? []
    }
}
