import Foundation

@main
struct LocalizedUserMessageTests {
    static func main() {
        testShortcutStatusUsesCompleteEnglishSentence()
        testPermissionAndScreenshotMessagesKeepDetailOrdering()
        testProviderFailurePreservesProviderDetailVerbatim()
        print("LocalizedUserMessageTests passed")
    }

    private static func testShortcutStatusUsesCompleteEnglishSentence() {
        assert(LocalizedUserMessage.shortcutStatus(shortcut: "⌥ Space", isToggleMode: false) == "Hold ⌥ Space to dictate")
        assert(LocalizedUserMessage.shortcutStatus(shortcut: "⌥ Space", isToggleMode: true) == "Tap ⌥ Space to dictate")
    }

    private static func testPermissionAndScreenshotMessagesKeepDetailOrdering() {
        let permissionDetail = "System Settings is unavailable"
        let screenshotDetail = "Unsupported MIME type: image/heic"

        assert(LocalizedUserMessage.screenRecordingPermission(detail: permissionDetail) == "Screen Recording permission is required. \(permissionDetail)")
        assert(LocalizedUserMessage.screenshotFailure(detail: screenshotDetail) == "Failed to capture screenshot: \(screenshotDetail)")
    }

    private static func testProviderFailurePreservesProviderDetailVerbatim() {
        let detail = "HTTP 429: rate limited"
        let result = LocalizedUserMessage.providerFailure(
            prefix: "Transcription failed",
            providerDetail: detail
        )

        assert(result == "Transcription failed: \(detail)")
        assert(result.contains(detail))
    }
}
