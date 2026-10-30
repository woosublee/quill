import Foundation
import QuillUserIssueCore

/// What a note's post-processing status string says about it, read the same
/// way on both apps. The status string syncs, so every prefix and raw value
/// here must stay byte-for-byte the same.
public enum NoteMachineStatus: Equatable, Sendable {
    case importing
    case liveRecording
    case cloudTranscribing
    case audioOnly
    case recovered(RecoveredRecordingContext)
    /// Startup recovery could not restore the recording's audio.
    case unrecovered(UnrecoveredRecordingContext)
    case failed(QuillUserIssueRecord)
    case completed

    public static let importingStatus = "importing"
    public static let liveRecordingStatus = "live-recording"
    public static let cloudTranscribingStatus = "cloud-transcribing"
    public static let audioOnlyStatus = "audio-only"

    public init(postProcessingStatus status: String) {
        if status == Self.importingStatus {
            self = .importing
        } else if status == Self.liveRecordingStatus {
            self = .liveRecording
        } else if status == Self.cloudTranscribingStatus {
            self = .cloudTranscribing
        } else if status == Self.audioOnlyStatus {
            self = .audioOnly
        } else if let context = UnrecoveredRecordingContext.parse(status) {
            self = .unrecovered(context)
        } else if let context = RecoveredRecordingContext.recoveredContext(for: status) {
            self = .recovered(context)
        } else if let record = Self.userIssueRecord(postProcessingStatus: status),
                  record.severity == .error {
            self = .failed(record)
        } else {
            self = .completed
        }
    }

    /// The issue a status stores. A `user-issue:` status that can't be read
    /// is `unknown`, and an old `Error:` status is `legacy`.
    public static func userIssueRecord(
        postProcessingStatus status: String
    ) -> QuillUserIssueRecord? {
        if status.hasPrefix("user-issue:") {
            return (try? QuillUserIssueRecord.decodePersistedStatus(status))
                ?? QuillUserIssueRecord(code: .unknown)
        }
        if status.hasPrefix("Error:") {
            return QuillUserIssueRecord(code: .legacy)
        }
        return nil
    }

    /// The note's transcription was interrupted and waits to run again, in
    /// any of its forms: `transcription-interrupted[:<reason>][:<mode>]`.
    /// A malformed form is not a placeholder. This is the one placeholder
    /// check for both apps; `RecoveredRecordingMode.placeholderMode(for:)`
    /// reads its mode from the same parse.
    public static func isTranscriptionPlaceholder(
        postProcessingStatus status: String
    ) -> Bool {
        RecoveredRecordingContext.placeholderContext(for: status) != nil
    }

    /// The note is still importing, recording, transcribing, or waiting for
    /// an interrupted transcription to run again, so it has no transcript yet.
    public static func isIncompleteTranscription(
        postProcessingStatus status: String
    ) -> Bool {
        isTranscriptionPlaceholder(postProcessingStatus: status)
            || status == importingStatus
            || status == liveRecordingStatus
            || status == cloudTranscribingStatus
    }

    /// A finished note keeps its transcript editor when the text is empty,
    /// so a cleared transcript can be typed again. Notes still recording,
    /// transcribing, or waiting on a recovery keep their empty state.
    public static func keepsTranscriptEditorWhenEmpty(
        postProcessingStatus status: String
    ) -> Bool {
        NoteMachineStatus(postProcessingStatus: status) == .completed
            && !isIncompleteTranscription(postProcessingStatus: status)
    }
}

/// What stopped a recording, as stored in a recovered note's status.
public enum RecordingInterruptionReason: String, Codable, Equatable, CaseIterable, Sendable {
    case storageFull = "storage-full"
    case permissionDenied = "permission-denied"
    case journalIOFailure = "journal-io-failure"
}

public enum RecoveredRecordingMode: String, Codable, Equatable, CaseIterable, Sendable {
    case complete
    case microphoneOnly = "microphone-only"
    case systemAudioOnly = "system-audio-only"
    case partial
}

public extension RecoveredRecordingMode {
    var placeholderStatus: String {
        RecoveredRecordingContext(mode: self, interruptionReason: nil)
            .placeholderStatus
    }

    var recoveredStatus: String {
        RecoveredRecordingContext(mode: self, interruptionReason: nil)
            .recoveredStatus
    }

    static func placeholderMode(for status: String) -> RecoveredRecordingMode? {
        RecoveredRecordingContext.placeholderContext(for: status)?.mode
    }

    static func recoveredMode(for status: String) -> RecoveredRecordingMode? {
        RecoveredRecordingContext.recoveredContext(for: status)?.mode
    }
}

/// A recording that recovery turned back into audio, or whose transcription
/// was interrupted: `<prefix>[:<reason>][:<mode>]`.
public struct RecoveredRecordingContext: Equatable, Sendable {
    public static let placeholderStatusPrefix = "transcription-interrupted"
    public static let recoveredStatusPrefix = "recording-recovered"

    public let mode: RecoveredRecordingMode
    public let interruptionReason: RecordingInterruptionReason?

    public init(
        mode: RecoveredRecordingMode,
        interruptionReason: RecordingInterruptionReason?
    ) {
        self.mode = mode
        self.interruptionReason = interruptionReason
    }

    public var placeholderStatus: String {
        encodedStatus(prefix: Self.placeholderStatusPrefix)
    }

    public var recoveredStatus: String {
        encodedStatus(prefix: Self.recoveredStatusPrefix)
    }

    public static func placeholderContext(
        for status: String
    ) -> RecoveredRecordingContext? {
        parse(status, prefix: placeholderStatusPrefix)
    }

    public static func recoveredContext(
        for status: String
    ) -> RecoveredRecordingContext? {
        parse(status, prefix: recoveredStatusPrefix)
    }

    private func encodedStatus(prefix: String) -> String {
        var components = [prefix]
        if let interruptionReason {
            components.append(interruptionReason.rawValue)
        }
        if mode != .complete {
            components.append(mode.rawValue)
        }
        return components.joined(separator: ":")
    }

    private static func parse(
        _ status: String,
        prefix: String
    ) -> RecoveredRecordingContext? {
        guard status == prefix || status.hasPrefix(prefix + ":") else {
            return nil
        }
        if status == prefix {
            return RecoveredRecordingContext(
                mode: .complete,
                interruptionReason: nil
            )
        }

        let suffix = String(status.dropFirst(prefix.count + 1))
        guard !suffix.isEmpty else { return nil }
        let components = suffix.split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.contains(where: \.isEmpty) else { return nil }

        if let reason = RecordingInterruptionReason(rawValue: components[0]) {
            switch components.count {
            case 1:
                return RecoveredRecordingContext(
                    mode: .complete,
                    interruptionReason: reason
                )
            case 2:
                guard let mode = RecoveredRecordingMode(rawValue: components[1]),
                      mode != .complete else {
                    return nil
                }
                return RecoveredRecordingContext(
                    mode: mode,
                    interruptionReason: reason
                )
            default:
                return nil
            }
        }

        guard components.count == 1,
              let mode = RecoveredRecordingMode(rawValue: components[0]),
              mode != .complete else {
            return nil
        }
        return RecoveredRecordingContext(
            mode: mode,
            interruptionReason: nil
        )
    }
}

/// What stopped a recording or its recovery, as a category that is safe to
/// store and show. It never carries file paths or system error text.
public enum UnrecoveredRecordingCause: String, Codable, Equatable, CaseIterable, Sendable {
    case storageFull = "storage-full"
    case storageUnavailable = "storage-unavailable"
    case saveError = "save-error"

    public init(interruptionReason: RecordingInterruptionReason) {
        switch interruptionReason {
        case .storageFull: self = .storageFull
        case .permissionDenied: self = .storageUnavailable
        case .journalIOFailure: self = .saveError
        }
    }
}

public enum UnrecoveredRecordingKind: String, Codable, Equatable, CaseIterable, Sendable {
    /// The recording left no audio to recover.
    case noAudio = "no-audio"
    /// Recording pieces remain, but they could not be put back together.
    case recoveryFailed = "recovery-failed"
}

/// A recording that startup recovery could not turn into audio:
/// `recording-unrecovered:<kind>[:<cause>]`. Its note stays in the list with
/// this status so the user can see what happened.
public struct UnrecoveredRecordingContext: Equatable, Sendable {
    public static let statusPrefix = "recording-unrecovered"

    public let kind: UnrecoveredRecordingKind
    public let cause: UnrecoveredRecordingCause?

    public init(kind: UnrecoveredRecordingKind, cause: UnrecoveredRecordingCause?) {
        self.kind = kind
        self.cause = cause
    }

    public var status: String {
        var components = [Self.statusPrefix, kind.rawValue]
        if let cause {
            components.append(cause.rawValue)
        }
        return components.joined(separator: ":")
    }

    public static func parse(_ status: String) -> UnrecoveredRecordingContext? {
        guard status.hasPrefix(statusPrefix + ":") else { return nil }
        let components = status.dropFirst(statusPrefix.count + 1)
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        guard let kindValue = components.first,
              let kind = UnrecoveredRecordingKind(rawValue: kindValue) else {
            return nil
        }
        switch components.count {
        case 1:
            return UnrecoveredRecordingContext(kind: kind, cause: nil)
        case 2:
            guard let cause = UnrecoveredRecordingCause(
                rawValue: components[1]
            ) else {
                return nil
            }
            return UnrecoveredRecordingContext(kind: kind, cause: cause)
        default:
            return nil
        }
    }
}
