import UserNotifications

enum SetupFlow {
    enum ProcessingLocation: Equatable {
        case recordOnly
        case onThisMac
        case apiProvider
    }

    enum LocalModel: Equatable {
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

    static func isNotificationAuthorizationGranted(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional
    }

    static func notificationPermissionActionTitle(for status: UNAuthorizationStatus) -> String {
        status == .denied ? String(localized: "Open Settings") : String(localized: "Grant Access")
    }
}
