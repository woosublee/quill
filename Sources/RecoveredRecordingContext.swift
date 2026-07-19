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
