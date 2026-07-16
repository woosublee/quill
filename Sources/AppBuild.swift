import Foundation

enum AppBuild {
    static var isDevBundle: Bool {
        isDevBundleName(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
    }

    static func isDevBundleName(_ bundleName: String?) -> Bool {
        bundleName == "Quill Dev"
    }
}
