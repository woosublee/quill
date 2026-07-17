import Foundation

@main
struct OverlayDisplayCopyTests {
    static func main() throws {
        let bundle = try compiledLocalizationBundle()
        testMeetingStartKeepsFormattedTimeVerbatim(bundle: bundle)
        testInputChangeKeepsDeviceNameVerbatim(bundle: bundle)
        testUpdateAvailabilityKeepsVersionVerbatim(bundle: bundle)
        testUpdateAvailabilityWithoutVersionUsesNonVersionedCopy(bundle: bundle)
        print("OverlayDisplayCopyTests passed")
    }

    private static func testMeetingStartKeepsFormattedTimeVerbatim(bundle: Bundle) {
        let time = "9:30 AM"
        assert(OverlayDisplayCopy.meetingStarts(at: time, language: "en", bundle: bundle) == "Starts at 9:30 AM")
        assert(OverlayDisplayCopy.meetingStarts(at: time, language: "ko", bundle: bundle) == "9:30 AM에 시작")
    }

    private static func testInputChangeKeepsDeviceNameVerbatim(bundle: Bundle) {
        let deviceName = "Studio Mic"
        assert(OverlayDisplayCopy.inputChanged(to: deviceName, language: "en", bundle: bundle) == "Input changed to Studio Mic")
        assert(OverlayDisplayCopy.inputChanged(to: deviceName, language: "ko", bundle: bundle) == "입력이 Studio Mic(으)로 변경됨")
    }

    private static func testUpdateAvailabilityKeepsVersionVerbatim(bundle: Bundle) {
        let version = "9.9.9"
        assert(OverlayDisplayCopy.updateAvailable(version: version, language: "en", bundle: bundle) == "Update available: 9.9.9")
        assert(OverlayDisplayCopy.updateAvailable(version: version, language: "ko", bundle: bundle) == "업데이트 가능: 9.9.9")
    }

    private static func testUpdateAvailabilityWithoutVersionUsesNonVersionedCopy(bundle: Bundle) {
        assert(OverlayDisplayCopy.updateAvailable(version: " \n ", language: "en", bundle: bundle) == "Update available")
        assert(OverlayDisplayCopy.updateAvailable(version: "", language: "ko", bundle: bundle) == "업데이트 사용 가능")
    }

    private static func compiledLocalizationBundle() throws -> Bundle {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard let bundle = Bundle(path: root.appendingPathComponent("build/localization").path) else {
            throw NSError(domain: "OverlayDisplayCopyTests", code: 1)
        }
        return bundle
    }
}
