import Foundation

/// Asking for Screen Recording or Accessibility from Quill must open only
/// System Settings with the drag-to-add guide, never the system permission
/// dialog at the same time (#370).
@main
struct PermissionGuideSourceTests {
    static func main() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)

        let screen = block(source, from: "func requestScreenCapturePermission()", to: "\n    }\n")
        try expect(screen.contains("guidePermission(.screenRecording)"), "Screen Recording request opens the guide")
        try expect(!screen.contains("SCShareableContent"), "Screen Recording request does not trigger the system dialog")
        try expect(!screen.contains("CGRequestScreenCaptureAccess"), "Screen Recording request does not call the system prompt")

        let openScreen = block(source, from: "func openScreenCaptureSettings()", to: "\n    }\n")
        try expect(
            openScreen.contains("guidePermission(.screenRecording, opensPaneWhenGranted: true)"),
            "after a capture failure the pane opens even if the preflight still reports access"
        )

        let accessibility = block(source, from: "func openAccessibilitySettings()", to: "\n    }\n")
        try expect(accessibility.contains("guidePermission(.accessibility)"), "Accessibility request opens the guide")
        try expect(!accessibility.contains("kAXTrustedCheckOptionPrompt"), "Accessibility request does not show the system dialog")

        let recordingStart = block(source, from: "func requestScreenCapturePermissionForRecordingStart()", to: "\n    }\n")
        try expect(!recordingStart.contains("CGRequestScreenCaptureAccess"), "recording start does not show the system dialog")
        try expect(recordingStart.contains("guidePermission(.screenRecording)"), "recording start opens the guide")

        let contextAlert = block(source, from: "private func showScreenshotPermissionAlert(", to: "let alert = NSAlert()")
        try expect(contextAlert.contains("isPermissionGuidePresented"), "Context alert is skipped while the guide is open")

        // #392: the drag-only guide offers VoiceOver a non-drag path and
        // announces the grant; the panel style and mouse drag are unchanged.
        let controller = try String(contentsOfFile: "Sources/PermissionGuideController.swift", encoding: .utf8)
        let dragView = block(controller, from: "final class AppIconDragView", to: "\n}\n")
        try expect(dragView.contains("setAccessibilityElement(true)"), "drag icon is an accessibility element")
        try expect(dragView.contains("setAccessibilityRole(.button)"), "drag icon is exposed as a button")
        try expect(
            dragView.contains("override func accessibilityPerformPress() -> Bool {\n        NSWorkspace.shared.activateFileViewerSelecting([url])"),
            "pressing the icon with VoiceOver shows the app in Finder"
        )
        try expect(dragView.contains("beginDraggingSession(with: [item], event: event, source: self)"), "mouse drag remains")

        let guideView = block(controller, from: "private struct PermissionGuideView: View", to: "\n}\n")
        try expect(guideView.contains("accessibilityHelp: localizedCatalogFormat("), "icon explains the + button path")
        try expect(guideView.contains(".accessibilityAction(\n                    named: Text(localizedCatalogFormat(\"Show %@ in Finder\""), "named Finder action")
        try expect(guideView.contains(".accessibilityLabel(localizedCatalogString(\"Close\"))"), "Close is labeled")

        let tick = block(controller, from: "private func tick()", to: "let settings = NSRunningApplication")
        try expect(tick.contains("notification: .announcementRequested"), "grant is announced")
        try expect(
            tick.contains("PermissionGuideTiming.grantedDisplayDuration(\n                voiceOverRunning: NSWorkspace.shared.isVoiceOverEnabled"),
            "auto-close waits longer only while VoiceOver runs"
        )

        let makePanel = block(controller, from: "private static func makePanel()", to: "\n    }\n")
        try expect(makePanel.contains("styleMask: [.borderless, .nonactivatingPanel]"), "panel stays non-activating")
        try expect(makePanel.contains("panel.becomesKeyOnlyIfNeeded = true"), "panel key behavior unchanged")

        print("PermissionGuideSourceTests passed")
    }

    private static func block(_ source: String, from start: String, to end: String) -> String {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            preconditionFailure("Expected source block from \(start)")
        }
        return String(source[startRange.lowerBound..<endRange.upperBound])
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TestFailure(message) }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
