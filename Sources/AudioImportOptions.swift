import Foundation

enum NoteBrowserTranscriptionMode: CaseIterable, Equatable {
    case apiStandard
    case apiRealtime
    case localWhisper
    case localAppleLive
}

struct AudioImportOptions {
    static let broadlySupportedExtensions: Set<String> = [
        "flac", "mp3", "mp4", "mpeg", "mpga", "m4a", "ogg", "wav", "webm"
    ]
    static let apiUploadLimitBytes: Int64 = 25_000_000

    static func storageExtension(for fileName: String) -> String {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        return broadlySupportedExtensions.contains(ext) ? ext : "wav"
    }

    static func importContextSummary(for fileName: String) -> String {
        ""
    }

    let fileExtension: String
    let currentMode: NoteBrowserTranscriptionMode
    let fileSizeBytes: Int64?
    let hasAPIKey: Bool
    let hasLocalWhisperModel: Bool

    init(
        fileExtension: String,
        currentMode: NoteBrowserTranscriptionMode,
        fileSizeBytes: Int64? = nil,
        hasAPIKey: Bool = true,
        hasLocalWhisperModel: Bool = true
    ) {
        self.fileExtension = fileExtension
        self.currentMode = currentMode
        self.fileSizeBytes = fileSizeBytes
        self.hasAPIKey = hasAPIKey
        self.hasLocalWhisperModel = hasLocalWhisperModel
    }

    var apiUnavailableReason: String {
        if !(fileSizeBytes.map({ $0 <= Self.apiUploadLimitBytes }) ?? true) {
            return "API transcription is unavailable for files over 25MB"
        }
        if !hasAPIKey {
            return "API key is not configured"
        }
        return "API transcription is unavailable"
    }

    var supportedModes: [NoteBrowserTranscriptionMode] {
        let normalizedExtension = fileExtension.lowercased()
        guard Self.broadlySupportedExtensions.contains(normalizedExtension) else { return [] }

        var modes: [NoteBrowserTranscriptionMode] = []
        if hasAPIKey, fileSizeBytes.map({ $0 <= Self.apiUploadLimitBytes }) ?? true {
            modes.append(.apiStandard)
        }
        if hasLocalWhisperModel {
            modes.append(.localWhisper)
        }
        return modes
    }

    var defaultMode: NoteBrowserTranscriptionMode? {
        let preferredMode: NoteBrowserTranscriptionMode
        switch currentMode {
        case .apiStandard, .apiRealtime:
            preferredMode = .apiStandard
        case .localWhisper, .localAppleLive:
            preferredMode = .localWhisper
        }
        if supportedModes.contains(preferredMode) {
            return preferredMode
        }
        return supportedModes.first
    }
}
