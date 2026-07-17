import Foundation


enum NoteBrowserTranscriptionMode: CaseIterable, Equatable, Hashable {
    case apiStandard
    case apiRealtime
    case localWhisper
    case localAppleLive
}

enum TranscriptionBackendChoice: Hashable, Identifiable {
    case apiStandard(modelID: String)
    case apiRealtime(modelID: String?)
    case nativeWhisper(modelID: String)
    case legacyMlxWhisper(model: TranscriptionModel)
    case appleLive

    var id: String {
        switch self {
        case .apiStandard(let modelID):
            return "api-standard:\(modelID)"
        case .apiRealtime(let modelID):
            return "api-realtime:\(modelID ?? "provider-default")"
        case .nativeWhisper(let modelID):
            return "native-whisper:\(modelID)"
        case .legacyMlxWhisper(let model):
            return "legacy-mlx-whisper:\(model.id)"
        case .appleLive:
            return "apple-live"
        }
    }

    var mode: NoteBrowserTranscriptionMode {
        switch self {
        case .apiStandard:
            return .apiStandard
        case .apiRealtime:
            return .apiRealtime
        case .nativeWhisper, .legacyMlxWhisper:
            return .localWhisper
        case .appleLive:
            return .localAppleLive
        }
    }

    var isImportable: Bool {
        switch self {
        case .apiStandard, .nativeWhisper, .legacyMlxWhisper:
            return true
        case .apiRealtime, .appleLive:
            return false
        }
    }
}

struct TranscriptionChoiceDisplay: Identifiable, Equatable {
    let choice: TranscriptionBackendChoice
    let section: String
    let title: String
    let subtitle: String?
    let compactLabel: String
    let currentLabel: String
    let isAvailable: Bool
    let unavailableReason: String?

    var id: String { choice.id }

    /// Resolves only static UI labels; model IDs and persisted backend choices remain verbatim.
    func localizedTitle(
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> String {
        localizedStaticLabel(title, language: language, bundle: bundle)
    }

    func localizedCompactLabel(
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> String {
        switch choice {
        case .apiStandard(let modelID):
            return "\(localizedStaticLabel("Standard", language: language, bundle: bundle)) · \(modelID)"
        case .nativeWhisper:
            return "\(localizedStaticLabel("Native Whisper", language: language, bundle: bundle)) · \(nativeModelName())"
        case .legacyMlxWhisper(let model):
            return "\(localizedStaticLabel("Legacy", language: language, bundle: bundle)) · \(model.displayName)"
        case .apiRealtime(let modelID):
            return "\(localizedStaticLabel("Realtime", language: language, bundle: bundle)) · \(modelID ?? "provider-default")"
        case .appleLive:
            return localizedStaticLabel("Apple Live", language: language, bundle: bundle)
        }
    }

    private func nativeModelName() -> String {
        subtitle ?? ""
    }

    func localizedCurrentLabel(
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> String {
        switch choice {
        case .apiStandard(let modelID): return "\(localizedCatalogString("API", language: language, bundle: bundle)) · \(localizedStaticLabel("Standard", language: language, bundle: bundle)) · \(modelID)"
        case .apiRealtime(let modelID): return "\(localizedCatalogString("API", language: language, bundle: bundle)) · \(localizedStaticLabel("Realtime", language: language, bundle: bundle)) · \(modelID ?? "provider-default")"
        case .nativeWhisper: return "\(localizedCatalogString("Local", language: language, bundle: bundle)) · \(localizedStaticLabel("Native Whisper", language: language, bundle: bundle)) · \(nativeModelName())"
        case .legacyMlxWhisper(let model): return "\(localizedCatalogString("Local", language: language, bundle: bundle)) · \(localizedStaticLabel("Legacy", language: language, bundle: bundle)) · \(model.displayName)"
        case .appleLive: return "\(localizedCatalogString("Local", language: language, bundle: bundle)) · \(localizedStaticLabel("Apple Live", language: language, bundle: bundle))"
        }
    }

    func localizedUnavailableReason(
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> String? {
        unavailableReason.map { localizedCatalogString($0, language: language, bundle: bundle) }
    }

    private func localizedStaticLabel(_ value: String, language: String, bundle: Bundle) -> String {
        localizedCatalogString(value, language: language, bundle: bundle)
    }
}

struct AudioImportOptions {
    static let broadlySupportedExtensions: Set<String> = [
        "flac", "mp3", "mp4", "mpeg", "mpga", "m4a", "ogg", "wav", "webm"
    ]
    static let nativeLocalWhisperExtensions: Set<String> = [
        "mp3", "mp4", "mpeg", "mpga", "m4a", "wav"
    ]
    static let apiUploadLimitBytes: Int64 = 25_000_000
    static let fallbackAPIModelID = "whisper-large-v3"
    static let fallbackNativeWhisperModelID = "whisper-large-v3-turbo"
    static let fallbackNativeWhisperDisplayName = "Whisper Large v3 Turbo"

    static func storageExtension(for fileName: String) -> String {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        return broadlySupportedExtensions.contains(ext) ? ext : "wav"
    }

    static func importContextSummary(for fileName: String) -> String {
        ""
    }

    let fileExtension: String
    let currentChoice: TranscriptionBackendChoice
    let apiStandardModelID: String
    let fileSizeBytes: Int64?
    let hasAPIKey: Bool
    let hasNativeLocalWhisperModel: Bool
    let legacyLocalWhisperModels: [TranscriptionModel]
    let nativeWhisperModelID: String
    let nativeWhisperDisplayName: String

    init(
        fileExtension: String,
        currentChoice: TranscriptionBackendChoice,
        apiStandardModelID: String,
        fileSizeBytes: Int64? = nil,
        hasAPIKey: Bool = true,
        hasNativeLocalWhisperModel: Bool = true,
        legacyLocalWhisperModels: [TranscriptionModel] = [],
        nativeWhisperModelID: String = Self.fallbackNativeWhisperModelID,
        nativeWhisperDisplayName: String = Self.fallbackNativeWhisperDisplayName
    ) {
        self.fileExtension = fileExtension
        self.currentChoice = currentChoice
        self.apiStandardModelID = Self.nonEmpty(apiStandardModelID) ?? Self.fallbackAPIModelID
        self.fileSizeBytes = fileSizeBytes
        self.hasAPIKey = hasAPIKey
        self.hasNativeLocalWhisperModel = hasNativeLocalWhisperModel
        self.legacyLocalWhisperModels = legacyLocalWhisperModels
        self.nativeWhisperModelID = nativeWhisperModelID
        self.nativeWhisperDisplayName = nativeWhisperDisplayName
    }

    init(
        fileExtension: String,
        currentMode: NoteBrowserTranscriptionMode,
        fileSizeBytes: Int64? = nil,
        hasAPIKey: Bool = true,
        hasLocalWhisperModel: Bool = true
    ) {
        let apiModelID = Self.fallbackAPIModelID
        let currentChoice: TranscriptionBackendChoice
        switch currentMode {
        case .apiStandard:
            currentChoice = .apiStandard(modelID: apiModelID)
        case .apiRealtime:
            currentChoice = .apiRealtime(modelID: nil)
        case .localWhisper:
            currentChoice = .nativeWhisper(modelID: Self.fallbackNativeWhisperModelID)
        case .localAppleLive:
            currentChoice = .appleLive
        }
        self.init(
            fileExtension: fileExtension,
            currentChoice: currentChoice,
            apiStandardModelID: apiModelID,
            fileSizeBytes: fileSizeBytes,
            hasAPIKey: hasAPIKey,
            hasNativeLocalWhisperModel: hasLocalWhisperModel,
            legacyLocalWhisperModels: []
        )
    }

    var displayRows: [TranscriptionChoiceDisplay] {
        [apiStandardDisplay, nativeWhisperDisplay] + legacyWhisperDisplays
    }

    var supportedChoices: [TranscriptionBackendChoice] {
        displayRows.filter(\.isAvailable).map(\.choice)
    }

    var defaultChoice: TranscriptionBackendChoice? {
        let choices = supportedChoices
        guard !choices.isEmpty else { return nil }

        let nativeChoice = TranscriptionBackendChoice.nativeWhisper(modelID: nativeWhisperModelID)
        let apiChoice = TranscriptionBackendChoice.apiStandard(modelID: apiStandardModelID)
        let legacyChoices = legacyLocalWhisperModels.map { TranscriptionBackendChoice.legacyMlxWhisper(model: $0) }
        let preferredChoices: [TranscriptionBackendChoice]

        switch currentChoice {
        case .apiStandard, .apiRealtime:
            preferredChoices = [apiChoice, nativeChoice] + legacyChoices
        case .nativeWhisper:
            preferredChoices = [nativeChoice] + legacyChoices + [apiChoice]
        case .legacyMlxWhisper(let model):
            let matchingLegacy = TranscriptionBackendChoice.legacyMlxWhisper(model: model)
            preferredChoices = [matchingLegacy, nativeChoice] + legacyChoices.filter { $0 != matchingLegacy } + [apiChoice]
        case .appleLive:
            preferredChoices = [nativeChoice] + legacyChoices + [apiChoice]
        }

        return preferredChoices.first { choices.contains($0) } ?? choices.first
    }

    var supportedModes: [NoteBrowserTranscriptionMode] {
        supportedChoices.reduce(into: []) { modes, choice in
            let mode = choice.mode
            if !modes.contains(mode) {
                modes.append(mode)
            }
        }
    }

    var defaultMode: NoteBrowserTranscriptionMode? {
        defaultChoice?.mode
    }

    var apiUnavailableReason: String {
        apiStandardDisplay.unavailableReason ?? "API transcription is unavailable"
    }

    var localWhisperUnavailableReason: String {
        nativeWhisperDisplay.unavailableReason ?? "Local Whisper is unavailable for this file"
    }

    private var normalizedExtension: String {
        fileExtension.lowercased()
    }

    private var isBroadlySupported: Bool {
        Self.broadlySupportedExtensions.contains(normalizedExtension)
    }

    private var isWithinAPIUploadLimit: Bool {
        fileSizeBytes.map { $0 <= Self.apiUploadLimitBytes } ?? true
    }

    private var apiStandardDisplay: TranscriptionChoiceDisplay {
        let choice = TranscriptionBackendChoice.apiStandard(modelID: apiStandardModelID)
        let unavailableReason: String? = if !isBroadlySupported {
            "This file type is not supported for import"
        } else if !isWithinAPIUploadLimit {
            "API transcription is unavailable for files over 25MB"
        } else if !hasAPIKey {
            "API key is not configured"
        } else {
            nil
        }
        return TranscriptionChoiceDisplay(
            choice: choice,
            section: "API",
            title: "API Standard",
            subtitle: apiStandardModelID,
            compactLabel: "Standard · \(apiStandardModelID)",
            currentLabel: "API · Standard · \(apiStandardModelID)",
            isAvailable: unavailableReason == nil,
            unavailableReason: unavailableReason
        )
    }

    private var nativeWhisperDisplay: TranscriptionChoiceDisplay {
        let choice = TranscriptionBackendChoice.nativeWhisper(modelID: nativeWhisperModelID)
        let unavailableReason: String? = if !isBroadlySupported {
            "This file type is not supported for import"
        } else if !Self.nativeLocalWhisperExtensions.contains(normalizedExtension) {
            "Native Whisper supports MP3, MP4, M4A, MPEG, MPGA, and WAV imports"
        } else if !hasNativeLocalWhisperModel {
            "Install the native Local Whisper model to import locally"
        } else {
            nil
        }
        return TranscriptionChoiceDisplay(
            choice: choice,
            section: "Local",
            title: "Native Whisper",
            subtitle: nativeWhisperDisplayName,
            compactLabel: "Native Whisper · \(nativeWhisperDisplayName)",
            currentLabel: "Local · Native Whisper · \(nativeWhisperDisplayName)",
            isAvailable: unavailableReason == nil,
            unavailableReason: unavailableReason
        )
    }

    private var legacyWhisperDisplays: [TranscriptionChoiceDisplay] {
        legacyLocalWhisperModels.map { model in
            let choice = TranscriptionBackendChoice.legacyMlxWhisper(model: model)
            let unavailableReason: String? = isBroadlySupported ? nil : "This file type is not supported for import"
            return TranscriptionChoiceDisplay(
                choice: choice,
                section: "Legacy mlx-whisper",
                title: "Legacy mlx-whisper",
                subtitle: model.displayName,
                compactLabel: "Legacy · \(model.displayName)",
                currentLabel: "Local · Legacy · \(model.displayName)",
                isAvailable: unavailableReason == nil,
                unavailableReason: unavailableReason
            )
        }
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
