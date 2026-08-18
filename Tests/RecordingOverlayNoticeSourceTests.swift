import Foundation

@main
struct RecordingOverlayNoticeSourceTests {
    static func main() throws {
        let source = try String(contentsOfFile: "Sources/RecordingOverlay.swift", encoding: .utf8)

        precondition(
            source.contains("func showDegradedCombinedCaptureNotice("),
            "RecordingOverlayManager exposes a way to surface a degraded combined-capture notice"
        )
        precondition(
            source.contains("struct DegradedCaptureNoticeView: View"),
            "a dedicated view renders the degraded-capture notice"
        )

        guard let managerRange = source.range(of: "func showDegradedCombinedCaptureNotice("),
              let anchoredRange = source.range(
                of: "private func showAnchoredDegradedCaptureNotice(",
                range: managerRange.upperBound..<source.endIndex
              ) else {
            preconditionFailure("Could not locate showDegradedCombinedCaptureNotice / showAnchoredDegradedCaptureNotice")
        }
        let managerBody = source[managerRange.lowerBound..<anchoredRange.lowerBound]
        precondition(
            managerBody.contains("overlayState.phase == .recording"),
            "the notice only surfaces while the recording phase is showing"
        )
        precondition(
            managerBody.contains("noticeAnchorFrame("),
            "the notice reuses the existing anchor-frame logic"
        )

        guard let nextMethodRange = source.range(
            of: "func showUpdateAvailable(",
            range: anchoredRange.upperBound..<source.endIndex
        ) else {
            preconditionFailure("Could not locate the end of showAnchoredDegradedCaptureNotice")
        }
        let anchoredBody = source[anchoredRange.lowerBound..<nextMethodRange.lowerBound]
        precondition(
            anchoredBody.contains("panel.ignoresMouseEvents = false"),
            "unlike the plain notice toast, this panel must accept mouse events so hover/dismiss work"
        )
        precondition(
            !anchoredBody.contains("asyncAfter"),
            "the degraded-capture notice must not auto-dismiss like the plain notice toast — it stays until explicitly dismissed"
        )
        precondition(
            anchoredBody.contains("DegradedCaptureNoticeView("),
            "the anchored panel's content is the dedicated degraded-capture view"
        )
        precondition(
            anchoredBody.contains("degradedCaptureNoticeWindow"),
            "the degraded-capture notice must use its own panel, not the shared transient noticeWindow — otherwise an unrelated toast (e.g. showRecordingNotice on a rejected input switch) can silently overwrite and auto-dismiss this persistent notice"
        )

        // The view must use the codebase's existing NSTrackingArea-based hover
        // approach (SwiftUI's own .onHover is documented elsewhere in this
        // file as unreliable inside this borderless, non-activating panel),
        // and must not duplicate a Stop action the pill already provides.
        guard let viewRange = source.range(of: "struct DegradedCaptureNoticeView: View") else {
            preconditionFailure("Could not locate DegradedCaptureNoticeView")
        }
        let viewBody = source[viewRange.lowerBound..<source.endIndex]
        precondition(
            viewBody.contains("NSTrackingArea("),
            "hover is tracked via NSTrackingArea, matching this file's existing InputSwitchMenu approach, not SwiftUI's .onHover"
        )
        precondition(
            !viewBody.contains("stop.fill"),
            "the notice must not duplicate the pill's own Stop button"
        )
        precondition(
            viewBody.contains("onDismiss"),
            "dismissing the notice is driven by an explicit callback, not a timer"
        )

        print("RecordingOverlayNoticeSourceTests passed")
    }
}
