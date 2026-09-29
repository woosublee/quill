import Foundation

struct RecoveredRecordingContext: Equatable {
    let mode: RecoveredRecordingMode
    let interruptionReason: RecordingInterruptionReason?

    var placeholderStatus: String {
        encodedStatus(prefix: "transcription-interrupted")
    }

    var recoveredStatus: String {
        encodedStatus(prefix: "recording-recovered")
    }

    static func placeholderContext(
        for status: String
    ) -> RecoveredRecordingContext? {
        parse(status, prefix: "transcription-interrupted")
    }

    static func recoveredContext(
        for status: String
    ) -> RecoveredRecordingContext? {
        parse(status, prefix: "recording-recovered")
    }

    var titleLocalizationKey: String {
        interruptionReason?.titleLocalizationKey ?? mode.titleLocalizationKey
    }

    func localizedDescription() -> String {
        guard let interruptionReason else {
            return localizedCatalogString(mode.descriptionLocalizationKey)
        }
        let cause = localizedCatalogString(
            interruptionReason.causeDescriptionLocalizationKey
        )
        let resultKey = mode == .complete
            ? "Audio saved before the interruption is available for playback or transcription."
            : mode.descriptionLocalizationKey
        return cause + " " + localizedCatalogString(resultKey)
    }

    /// What interrupted the recording, when known.
    func localizedCause() -> String? {
        interruptionReason.map {
            localizedCatalogString($0.causeDescriptionLocalizationKey)
        }
    }

    /// What the user can do with the recovered audio.
    func localizedResult() -> String {
        let resultKey = interruptionReason != nil && mode == .complete
            ? "Audio saved before the interruption is available for playback or transcription."
            : mode.descriptionLocalizationKey
        return localizedCatalogString(resultKey)
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
enum UnrecoveredRecordingCause: String, Codable, Equatable, CaseIterable {
    case storageFull = "storage-full"
    case storageUnavailable = "storage-unavailable"
    case saveError = "save-error"

    init(interruptionReason: RecordingInterruptionReason) {
        switch interruptionReason {
        case .storageFull: self = .storageFull
        case .permissionDenied: self = .storageUnavailable
        case .journalIOFailure: self = .saveError
        }
    }

    /// The category of a recovery error, or nil when it is not a known
    /// storage problem.
    static func classifying(_ error: Error) -> UnrecoveredRecordingCause? {
        guard let failure = RecordingJournalPersistenceFailure
            .classifyIfPersistenceFailure(error, operation: .writeManifest) else {
            return nil
        }
        switch failure.reason {
        case .storageFull: return .storageFull
        case .permissionDenied: return .storageUnavailable
        case .journalIOFailure: return nil
        }
    }
}

enum UnrecoveredRecordingKind: String, Codable, Equatable, CaseIterable {
    /// The recording left no audio to recover.
    case noAudio = "no-audio"
    /// Recording pieces remain, but they could not be put back together.
    case recoveryFailed = "recovery-failed"
}

/// A recording that startup recovery could not turn into audio. Its note
/// stays in the list with this status so the user can see what happened.
struct UnrecoveredRecordingContext: Equatable {
    static let statusPrefix = "recording-unrecovered"

    let kind: UnrecoveredRecordingKind
    let cause: UnrecoveredRecordingCause?

    var status: String {
        var components = [Self.statusPrefix, kind.rawValue]
        if let cause {
            components.append(cause.rawValue)
        }
        return components.joined(separator: ":")
    }

    static func parse(_ status: String) -> UnrecoveredRecordingContext? {
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

    var titleLocalizationKey: String {
        switch kind {
        case .noAudio: return "Recording was interrupted"
        case .recoveryFailed: return "Couldn't recover the recording"
        }
    }

    func localizedTitle(
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> String {
        localizedCatalogString(
            titleLocalizationKey,
            language: language,
            bundle: bundle
        )
    }

    /// What happened, and for pieces that remain, what the user can do.
    /// `startTime` is the recording's start time, already formatted.
    func localizedBody(
        startTime: String,
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> String {
        switch kind {
        case .noAudio:
            guard let cause else {
                return localizedCatalogFormat(
                    "The recording that started at %@ stopped when Quill quit unexpectedly. No audio was saved, so it can't be recovered.",
                    startTime,
                    language: language,
                    bundle: bundle
                )
            }
            return localizedCatalogString(
                cause.interruptionDescriptionLocalizationKey,
                language: language,
                bundle: bundle
            ) + " " + localizedCatalogFormat(
                "No audio from the recording that started at %@ was saved, so it can't be recovered.",
                startTime,
                language: language,
                bundle: bundle
            )
        case .recoveryFailed:
            let causeKey: String
            let hintKey: String
            switch cause {
            case .storageFull:
                causeKey = "There isn't enough storage space to recover the recording."
                hintKey = "Free up space, then recover again."
            case .storageUnavailable:
                causeKey = "Quill couldn't access the recording pieces."
                hintKey = "Use Open Folder to get the recording pieces."
            case .saveError, nil:
                causeKey = "Quill couldn't put the recording pieces back together."
                hintKey = "Use Open Folder to get the recording pieces."
            }
            return localizedCatalogString(
                causeKey,
                language: language,
                bundle: bundle
            ) + " " + localizedCatalogString(
                hintKey,
                language: language,
                bundle: bundle
            )
        }
    }
}

extension UnrecoveredRecordingCause {
    var interruptionDescriptionLocalizationKey: String {
        switch self {
        case .storageFull:
            return "Quill stopped recording because storage was full."
        case .storageUnavailable:
            return "Quill stopped recording because audio storage was unavailable."
        case .saveError:
            return "Quill stopped recording because of an audio save error."
        }
    }
}
