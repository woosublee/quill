import CoreGraphics
import Foundation

/// Permissions granted by adding Quill to a System Settings list. Microphone,
/// Speech Recognition, and notifications use the system's allow/deny prompt
/// and do not need this guide.
enum PermissionGuideKind: Equatable, Sendable {
    case screenRecording
    case accessibility

    var settingsURL: URL {
        let pane = switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

/// One display in both coordinate systems: AppKit (bottom-left origin) and
/// Quartz window bounds (top-left origin).
struct PermissionGuideScreen: Equatable, Sendable {
    let appKitFrame: CGRect
    let visibleFrame: CGRect
    let cgBounds: CGRect
}

enum SystemSettingsWindowLocator {
    static let bundleIdentifier = "com.apple.systempreferences"

    /// The main System Settings window in AppKit coordinates, from
    /// `CGWindowListCopyWindowInfo` output. Window bounds are readable without
    /// Screen Recording permission; titles are not needed.
    static func settingsWindowFrame(
        windowInfo: [[String: Any]],
        settingsPID: pid_t,
        screens: [PermissionGuideScreen]
    ) -> CGRect? {
        let frames = windowInfo.compactMap { info -> CGRect? in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid == settingsPID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else {
                return nil
            }
            let frame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
            guard frame.width > 320, frame.height > 240 else { return nil }
            return frame
        }
        guard let largest = frames.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return nil
        }
        return appKitFrame(fromQuartz: largest, screens: screens)
    }

    static func screen(
        containing frame: CGRect,
        screens: [PermissionGuideScreen]
    ) -> PermissionGuideScreen? {
        screens.max { lhs, rhs in
            let left = lhs.appKitFrame.intersection(frame)
            let right = rhs.appKitFrame.intersection(frame)
            return left.width * left.height < right.width * right.height
        }
    }

    private static func appKitFrame(
        fromQuartz frame: CGRect,
        screens: [PermissionGuideScreen]
    ) -> CGRect {
        let match = screens
            .filter { $0.cgBounds.intersects(frame) }
            .max { lhs, rhs in
                let left = lhs.cgBounds.intersection(frame)
                let right = rhs.cgBounds.intersection(frame)
                return left.width * left.height < right.width * right.height
            }
        guard let match else { return frame }
        let localX = frame.minX - match.cgBounds.minX
        let localY = frame.minY - match.cgBounds.minY
        return CGRect(
            x: match.appKitFrame.minX + localX,
            y: match.appKitFrame.maxY - localY - frame.height,
            width: frame.width,
            height: frame.height
        )
    }
}

enum PermissionGuideLayout {
    /// How far the panel rises over the Settings window's bottom edge, so it
    /// reads as attached to that window.
    static let overlap: CGFloat = 24
    static let screenMargin: CGFloat = 8

    static func panelFrame(
        settingsFrame: CGRect,
        visibleFrame: CGRect,
        panelSize: CGSize
    ) -> CGRect {
        var origin = CGPoint(
            x: settingsFrame.midX - panelSize.width / 2,
            y: settingsFrame.minY + overlap - panelSize.height
        )
        origin.x = min(
            max(origin.x, visibleFrame.minX + screenMargin),
            visibleFrame.maxX - screenMargin - panelSize.width
        )
        origin.y = max(origin.y, visibleFrame.minY + screenMargin)
        return CGRect(origin: origin, size: panelSize)
    }

    /// The bundle URL to drag into System Settings. Symlinks such as
    /// `/tmp` → `/private/tmp` are resolved so the list accepts the drop.
    /// `resolvingSymlinksInPath()` is not used because it strips `/private`
    /// back off, leaving the `/tmp` form.
    static func dragURL(for bundleURL: URL) -> URL {
        guard let resolved = realpath(bundleURL.path, nil) else {
            return bundleURL
        }
        defer { free(resolved) }
        return URL(
            fileURLWithPath: String(cString: resolved),
            isDirectory: bundleURL.hasDirectoryPath
        )
    }
}

/// What the guide panel does on each tracking tick.
enum PermissionGuidePanelAction: Equatable {
    case attach(to: CGRect)
    case showAtScreenBottom
    case hide
    case dismiss

    /// System Settings can take a few seconds to open its window.
    static let settingsLaunchGrace: TimeInterval = 5
    /// A window missing this long after it was seen counts as closed; shorter
    /// gaps happen while switching panes or Spaces.
    static let closedWindowThreshold: TimeInterval = 0.4

    static func decide(
        settingsIsRunning: Bool,
        settingsIsFrontmost: Bool,
        settingsWindowFrame: CGRect?,
        hasSeenSettingsWindow: Bool,
        windowMissingFor: TimeInterval,
        elapsed: TimeInterval
    ) -> PermissionGuidePanelAction {
        if let settingsWindowFrame {
            return settingsIsFrontmost ? .attach(to: settingsWindowFrame) : .hide
        }
        // Settings may keep running after its window is closed.
        if hasSeenSettingsWindow {
            return windowMissingFor >= closedWindowThreshold ? .dismiss : .hide
        }
        guard elapsed > settingsLaunchGrace else {
            return .hide
        }
        guard settingsIsRunning else {
            return .dismiss
        }
        return settingsIsFrontmost ? .showAtScreenBottom : .hide
    }
}
