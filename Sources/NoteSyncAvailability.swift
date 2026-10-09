import Foundation
import Security

enum NoteSyncUnavailableReason: Equatable {
    case requiresMacOS14
    /// The app was signed without the iCloud entitlement (no provisioning
    /// profile), so it can't reach the container.
    case buildWithoutICloud
}

enum NoteSyncAvailability {
    static let containerIdentifier = "iCloud.com.woosublee.quill"

    static func evaluate(isMacOS14OrLater: Bool, hasCloudKitEntitlement: Bool) -> NoteSyncUnavailableReason? {
        if !isMacOS14OrLater { return .requiresMacOS14 }
        if !hasCloudKitEntitlement { return .buildWithoutICloud }
        return nil
    }

    static func current() -> NoteSyncUnavailableReason? {
        evaluate(
            isMacOS14OrLater: ProcessInfo.processInfo.isOperatingSystemAtLeast(
                OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
            ),
            hasCloudKitEntitlement: hasCloudKitEntitlement()
        )
    }

    /// Reads the running app's own signature: CloudKit for this container.
    private static func hasCloudKitEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        func value(_ key: String) -> [String] {
            (SecTaskCopyValueForEntitlement(task, key as CFString, nil) as? [String]) ?? []
        }
        return value("com.apple.developer.icloud-services").contains("CloudKit")
            && value("com.apple.developer.icloud-container-identifiers").contains(containerIdentifier)
    }
}
