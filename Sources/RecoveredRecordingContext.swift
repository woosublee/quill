import Foundation
import QuillNoteCore

// The status format lives in QuillNoteCore; the on-screen text stays here.
extension RecoveredRecordingContext {
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
}

extension UnrecoveredRecordingCause {
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

extension UnrecoveredRecordingContext {
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
