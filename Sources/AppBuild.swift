import Foundation

enum AppBuild {
    static var isDevBundle: Bool {
        isDevBundleName(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
    }

    static func isDevBundleName(_ bundleName: String?) -> Bool {
        bundleName == "Quill Dev"
    }

    /// The app's marketing version, such as "1.1.0".
    static var shortVersion: String {
        shortVersion(from: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString"))
    }

    /// Falls back to "unknown" when the bundle has no version, as in a test
    /// binary, so callers never report an empty or made-up version.
    static func shortVersion(from value: Any?) -> String {
        guard let version = value as? String, !version.isEmpty else { return "unknown" }
        return version
    }
}
