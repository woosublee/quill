import Foundation
import UserNotifications

enum SetupFlow {
    enum ProcessingLocation: Equatable, Codable {
        case recordOnly
        case onThisMac
        case apiProvider
    }

    enum LocalModel: Equatable, Codable {
        case appleSpeech
        case nativeWhisper
        case localAIModel(id: String)

        static let `default`: LocalModel = .appleSpeech
    }

    enum ProcessingPreset: Equatable {
        case recordOnly
        case localAppleSpeech
        case localNativeWhisper
        case localAIModel(id: String)
        case apiStandard
    }

    enum Permission: Hashable, CaseIterable {
        case microphone
        case accessibility
        case speechRecognition
        case screenRecording
    }

    static func processingPreset(
        location: ProcessingLocation?,
        localModel: LocalModel
    ) -> ProcessingPreset? {
        switch location {
        case .recordOnly:
            return .recordOnly
        case .onThisMac:
            switch localModel {
            case .appleSpeech:
                return .localAppleSpeech
            case .nativeWhisper:
                return .localNativeWhisper
            case .localAIModel(let id):
                return .localAIModel(id: id)
            }
        case .apiProvider:
            return .apiStandard
        case nil:
            return nil
        }
    }

    static func hasRequiredAudioSource(
        for preset: ProcessingPreset,
        recordOnlySource: AudioRecordingSource?
    ) -> Bool {
        preset != .recordOnly || recordOnlySource != nil
    }

    static func requiredPermissions(
        for preset: ProcessingPreset,
        audioSource: AudioRecordingSource = .microphone
    ) -> Set<Permission> {
        switch preset {
        case .recordOnly:
            var permissions: Set<Permission> = []
            if audioSource.requiresMicrophonePermission {
                permissions.insert(.microphone)
            }
            if audioSource.requiresSystemAudioPermission {
                permissions.insert(.screenRecording)
            }
            return permissions
        case .localNativeWhisper, .localAIModel, .apiStandard:
            return [.microphone]
        case .localAppleSpeech:
            return [.microphone, .speechRecognition]
        }
    }

    static func canContinuePermissions(
        for preset: ProcessingPreset,
        recordOnlySource: AudioRecordingSource?,
        grantedPermissions: Set<Permission>
    ) -> Bool {
        guard hasRequiredAudioSource(for: preset, recordOnlySource: recordOnlySource) else {
            return false
        }
        return requiredPermissions(for: preset, audioSource: recordOnlySource ?? .microphone)
            .isSubset(of: grantedPermissions)
    }

    /// Choices made in setup, saved when the user grants Screen Recording.
    /// That makes macOS quit and reopen Quill, and setup then picks up
    /// where it stopped, once (#516). Holds only choices, never the API key:
    /// that is already in Settings, and a key is validated again if the
    /// user goes back to it.
    struct SavedProgress: Codable, Equatable {
        var step: Int
        var processingLocation: ProcessingLocation?
        var localModel: LocalModel
        var recordOnlyAudioSourceID: String?
        /// Connections and Sync choices; nil in progress saved before them.
        var wantsICloudSync: Bool? = nil
        var wantsMCP: Bool? = nil
        var savedAt: Date

        /// The relaunch follows the grant within minutes. Older progress
        /// means the user chose Later or never granted it, and their
        /// choices may have changed since.
        static let maxAge: TimeInterval = 30 * 60

        func isRecent(now: Date) -> Bool {
            let age = now.timeIntervalSince(savedAt)
            return age >= 0 && age <= Self.maxAge
        }

        var recordOnlyAudioSource: AudioRecordingSource? {
            AudioRecordingSource.allCases.first { $0.id == recordOnlyAudioSourceID }
        }
    }

    static let savedProgressKey = "setup_saved_progress"

    static func loadSavedProgress(from defaults: UserDefaults) -> SavedProgress? {
        guard let data = defaults.data(forKey: savedProgressKey) else { return nil }
        return try? JSONDecoder().decode(SavedProgress.self, from: data)
    }

    static func saveProgress(_ progress: SavedProgress, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        defaults.set(data, forKey: savedProgressKey)
    }

    static func clearSavedProgress(in defaults: UserDefaults) {
        defaults.removeObject(forKey: savedProgressKey)
    }

    /// The step to reopen at: the saved one, unless an earlier step can't
    /// be passed any more, such as a permission that was taken back.
    static func resumeStep(savedStep: Int, lastStep: Int, canContinue: (Int) -> Bool) -> Int {
        var step = 0
        while step < min(savedStep, lastStep), canContinue(step) {
            step += 1
        }
        return step
    }

    static func isNotificationAuthorizationGranted(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional
    }

    static func notificationPermissionActionTitle(for status: UNAuthorizationStatus) -> String {
        status == .denied ? String(localized: "Open Settings") : String(localized: "Grant Access")
    }
}
