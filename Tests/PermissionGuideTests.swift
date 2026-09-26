import CoreGraphics
import Foundation

@main
struct PermissionGuideTests {
    static func main() throws {
        try testPicksLargestNormalSettingsWindow()
        try testIgnoresOtherProcessesSmallWindowsAndOverlays()
        try testConvertsTopLeftCoordinatesOnSecondaryScreen()
        try testPanelSitsOnSettingsBottomEdgeCentered()
        try testPanelStaysInsideVisibleFrame()
        try testDragURLResolvesSymlinkedLocations()
        try testSettingsURLsTargetEachPane()
        try testPanelWaitsForSettingsWindow()
        try testPanelClosesWhenSettingsWindowCloses()
        try testPanelFollowsFrontmostSettings()
        print("PermissionGuideTests passed")
    }

    private static let mainScreen = PermissionGuideScreen(
        appKitFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
        cgBounds: CGRect(x: 0, y: 0, width: 1440, height: 900)
    )

    private static func window(
        pid: Int32,
        layer: Int = 0,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: [
                "X": x, "Y": y, "Width": width, "Height": height
            ] as [String: CGFloat]
        ]
    }

    private static func testPicksLargestNormalSettingsWindow() throws {
        let frame = SystemSettingsWindowLocator.settingsWindowFrame(
            windowInfo: [
                window(pid: 42, x: 100, y: 100, width: 700, height: 500),
                window(pid: 42, x: 50, y: 50, width: 900, height: 600)
            ],
            settingsPID: 42,
            screens: [mainScreen]
        )
        // Top-left CG (50, 50, 900x600) on a 900-tall screen is AppKit y = 900 - 50 - 600.
        try expectEqual(frame, CGRect(x: 50, y: 250, width: 900, height: 600), "largest window")
    }

    private static func testIgnoresOtherProcessesSmallWindowsAndOverlays() throws {
        let frame = SystemSettingsWindowLocator.settingsWindowFrame(
            windowInfo: [
                window(pid: 7, x: 0, y: 0, width: 1200, height: 800),
                window(pid: 42, layer: 25, x: 0, y: 0, width: 1000, height: 700),
                window(pid: 42, x: 10, y: 10, width: 300, height: 200)
            ],
            settingsPID: 42,
            screens: [mainScreen]
        )
        try expectEqual(frame, nil, "no usable settings window")
    }

    private static func testConvertsTopLeftCoordinatesOnSecondaryScreen() throws {
        // A second display to the right, taller, with its AppKit origin below the main one.
        let secondary = PermissionGuideScreen(
            appKitFrame: CGRect(x: 1440, y: -180, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1440, y: -180, width: 1920, height: 1055),
            cgBounds: CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        )
        let frame = SystemSettingsWindowLocator.settingsWindowFrame(
            windowInfo: [window(pid: 42, x: 1540, y: 100, width: 800, height: 600)],
            settingsPID: 42,
            screens: [mainScreen, secondary]
        )
        // AppKit y = screen.maxY (900) - localY (100) - height (600) = 200.
        try expectEqual(frame, CGRect(x: 1540, y: 200, width: 800, height: 600), "secondary screen")
    }

    private static func testPanelSitsOnSettingsBottomEdgeCentered() throws {
        let panel = PermissionGuideLayout.panelFrame(
            settingsFrame: CGRect(x: 200, y: 200, width: 800, height: 600),
            visibleFrame: mainScreen.visibleFrame,
            panelSize: CGSize(width: 440, height: 96)
        )
        try expectEqual(panel.midX, 600, "centered under the window")
        try expectEqual(panel.maxY, 200 + PermissionGuideLayout.overlap, "overlaps the bottom edge")
    }

    private static func testPanelStaysInsideVisibleFrame() throws {
        let panel = PermissionGuideLayout.panelFrame(
            settingsFrame: CGRect(x: 1200, y: 10, width: 700, height: 600),
            visibleFrame: mainScreen.visibleFrame,
            panelSize: CGSize(width: 440, height: 96)
        )
        try expectEqual(panel.minY >= mainScreen.visibleFrame.minY, true, "not below the screen")
        try expectEqual(panel.maxX <= mainScreen.visibleFrame.maxX, true, "not past the right edge")
        try expectEqual(panel.minX >= mainScreen.visibleFrame.minX, true, "not past the left edge")
    }

    private static func testDragURLResolvesSymlinkedLocations() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let real = root.appendingPathComponent("real/Quill Dev.app", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: root.appendingPathComponent("real", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let dragged = PermissionGuideLayout.dragURL(
            for: link.appendingPathComponent("Quill Dev.app", isDirectory: true)
        )
        try expectEqual(
            dragged.path,
            "/private" + real.path,
            "drag the real bundle location"
        )
        // /tmp is a symlink to /private/tmp on macOS.
        try expectEqual(
            PermissionGuideLayout.dragURL(for: URL(fileURLWithPath: "/tmp")).path,
            "/private/tmp",
            "/tmp resolves to /private/tmp"
        )
    }

    private static func testSettingsURLsTargetEachPane() throws {
        try expectEqual(
            PermissionGuideKind.screenRecording.settingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "screen recording pane"
        )
        try expectEqual(
            PermissionGuideKind.accessibility.settingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "accessibility pane"
        )
    }

    private static let settingsFrame = CGRect(x: 100, y: 100, width: 800, height: 600)

    private static func decide(
        running: Bool = true,
        frontmost: Bool = true,
        frame: CGRect? = settingsFrame,
        seen: Bool = false,
        missing: TimeInterval = 0,
        elapsed: TimeInterval = 1
    ) -> PermissionGuidePanelAction {
        PermissionGuidePanelAction.decide(
            settingsIsRunning: running,
            settingsIsFrontmost: frontmost,
            settingsWindowFrame: frame,
            hasSeenSettingsWindow: seen,
            windowMissingFor: missing,
            elapsed: elapsed
        )
    }

    private static func testPanelWaitsForSettingsWindow() throws {
        // Settings is still launching: the panel must not appear before it.
        try expectEqual(decide(running: false, frame: nil), .hide, "not running yet")
        try expectEqual(decide(frame: nil), .hide, "window not on screen yet")
        // Window never found after the grace period: fall back to the screen.
        try expectEqual(decide(frame: nil, elapsed: 6), .showAtScreenBottom, "fallback after grace")
        try expectEqual(decide(running: false, frame: nil, elapsed: 6), .dismiss, "Settings never opened")
    }

    private static func testPanelClosesWhenSettingsWindowCloses() throws {
        // Settings can keep running after its window closes. A window that is
        // briefly missing (pane switch, Space change) keeps the panel.
        try expectEqual(decide(frame: nil, seen: true, missing: 0.1), .hide, "briefly missing")
        try expectEqual(decide(frame: nil, seen: true, missing: 0.5), .dismiss, "window closed")
        try expectEqual(decide(running: false, frame: nil, seen: true, missing: 0.5), .dismiss, "Settings quit")
    }

    private static func testPanelFollowsFrontmostSettings() throws {
        try expectEqual(decide(), .attach(to: settingsFrame), "attached to the window")
        try expectEqual(decide(frontmost: false), .hide, "hidden behind another app")
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
        guard actual == expected else {
            throw TestFailure("\(label): expected \(expected), got \(actual)")
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
