import UserNotifications

enum SetupFlow {
    enum ProcessingLocation: Equatable {
        case onThisMac
        case apiProvider
    }

    enum LocalModel: Equatable {
        case appleSpeech
        case nativeWhisper

        static let `default`: LocalModel = .appleSpeech
    }

    enum ProcessingPreset: Equatable {
        case localAppleSpeech
        case localNativeWhisper
        case apiStandard
    }

    enum Permission: Hashable {
        case microphone
        case accessibility
        case speechRecognition
    }

    static func processingPreset(
        location: ProcessingLocation?,
        localModel: LocalModel
    ) -> ProcessingPreset? {
        switch location {
        case .onThisMac:
            switch localModel {
            case .appleSpeech:
                return .localAppleSpeech
            case .nativeWhisper:
                return .localNativeWhisper
            }
        case .apiProvider:
            return .apiStandard
        case nil:
            return nil
        }
    }

    static func requiredPermissions(for preset: ProcessingPreset) -> Set<Permission> {
        var permissions: Set<Permission> = [.microphone, .accessibility]
        if preset == .localAppleSpeech {
            permissions.insert(.speechRecognition)
        }
        return permissions
    }

    static func isNotificationAuthorizationGranted(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional
    }

    static func notificationPermissionActionTitle(for status: UNAuthorizationStatus) -> String {
        status == .denied ? String(localized: "Open Settings") : String(localized: "Grant Access")
    }
}
