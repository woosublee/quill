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
        try expect(openScreen.contains("guidePermission(.screenRecording)"), "opening Screen Recording settings uses the guide")

        let accessibility = block(source, from: "func openAccessibilitySettings()", to: "\n    }\n")
        try expect(accessibility.contains("guidePermission(.accessibility)"), "Accessibility request opens the guide")
        try expect(!accessibility.contains("kAXTrustedCheckOptionPrompt"), "Accessibility request does not show the system dialog")

        let recordingStart = block(source, from: "func requestScreenCapturePermissionForRecordingStart()", to: "\n    }\n")
        try expect(!recordingStart.contains("CGRequestScreenCaptureAccess"), "recording start does not show the system dialog")
        try expect(recordingStart.contains("guidePermission(.screenRecording)"), "recording start opens the guide")

        let contextAlert = block(source, from: "private func showScreenshotPermissionAlert(", to: "let alert = NSAlert()")
        try expect(contextAlert.contains("isPermissionGuidePresented"), "Context alert is skipped while the guide is open")

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
