import Foundation

@main
struct LocalizedUserMessageTests {
    static func main() throws {
        let bundle = try compiledLocalizationBundle()
        testShortcutStatusUsesLocalizedCompleteSentence(bundle: bundle)
        testPermissionAndScreenshotMessagesKeepOneVerbatimDetail(bundle: bundle)
        testProviderFailurePreservesProviderDetailVerbatim(bundle: bundle)
        print("LocalizedUserMessageTests passed")
    }

    private static func testShortcutStatusUsesLocalizedCompleteSentence(bundle: Bundle) {
        assert(LocalizedUserMessage.shortcutStatus(shortcut: "⌥ Space", isToggleMode: false, language: "en", bundle: bundle) == "Hold ⌥ Space to dictate")
        assert(LocalizedUserMessage.shortcutStatus(shortcut: "⌥ Space", isToggleMode: true, language: "ko", bundle: bundle) == "⌥ Space을(를) 눌러 받아쓰기")
    }

    private static func testPermissionAndScreenshotMessagesKeepOneVerbatimDetail(bundle: Bundle) {
        let permissionDetail = "Screen Recording access was not granted."
        let screenshotDetail = "Unsupported MIME type: image/heic"
        let englishPermission = LocalizedUserMessage.screenRecordingPermission(detail: permissionDetail, language: "en", bundle: bundle)
        let koreanPermission = LocalizedUserMessage.screenRecordingPermission(detail: permissionDetail, language: "ko", bundle: bundle)
        let screenshot = LocalizedUserMessage.screenshotFailure(detail: screenshotDetail, language: "ko", bundle: bundle)

        assert(englishPermission == "\(permissionDetail)\n\nQuill requires Screen Recording permission to capture screenshots for context-aware transcription.\n\nGo to System Settings > Privacy & Security > Screen Recording and enable Quill.")
        assert(koreanPermission == "\(permissionDetail)\n\nQuill에서 맥락 인식 전사를 위한 스크린샷을 캡처하려면 화면 기록 권한이 필요합니다.\n\n시스템 설정 > 개인정보 보호 및 보안 > 화면 기록에서 Quill을 활성화하세요.")
        assert(screenshot == "스크린샷을 캡처하지 못했습니다: \(screenshotDetail)\n\n맥락 인식 전사에는 스크린샷이 필요합니다. 녹음이 중지되었습니다.")
        assert(englishPermission.components(separatedBy: permissionDetail).count == 2)
        assert(koreanPermission.components(separatedBy: permissionDetail).count == 2)
        assert(englishPermission.components(separatedBy: "System Settings > Privacy & Security > Screen Recording").count == 2)
        assert(koreanPermission.components(separatedBy: "시스템 설정 > 개인정보 보호 및 보안 > 화면 기록").count == 2)
        assert(screenshot.components(separatedBy: screenshotDetail).count == 2)
    }

    private static func testProviderFailurePreservesProviderDetailVerbatim(bundle: Bundle) {
        let detail = "HTTP 429: rate limited"
        let result = LocalizedUserMessage.providerFailure(
            prefix: localizedCatalogString("Transcription failed", language: "ko", bundle: bundle),
            providerDetail: detail,
            language: "ko",
            bundle: bundle
        )

        assert(result == "전사 실패: \(detail)")
        assert(result.contains(detail))
    }

    private static func compiledLocalizationBundle() throws -> Bundle {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard let bundle = Bundle(path: root.appendingPathComponent("build/localization").path) else {
            throw NSError(domain: "LocalizedUserMessageTests", code: 1)
        }
        return bundle
    }
}
