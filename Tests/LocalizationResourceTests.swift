import Foundation

@main
struct LocalizationResourceTests {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let catalogURL = root.appendingPathComponent("Resources/Localization/Localizable.xcstrings")
        let catalogData = try Data(contentsOf: catalogURL)
        let catalog = try JSONSerialization.jsonObject(with: catalogData) as! [String: Any]

        assert(catalog["sourceLanguage"] as? String == "en")
        let strings = catalog["strings"] as! [String: Any]
        assert(!strings.isEmpty)

        for (key, rawEntry) in strings {
            let entry = rawEntry as? [String: Any] ?? [:]
            guard entry["shouldTranslate"] as? Bool != false else { continue }
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            for language in ["en", "ko"] {
                let localization = localizations[language] as? [String: Any]
                let unit = localization?["stringUnit"] as? [String: Any]
                let value = unit?["value"] as? String
                assert(value?.isEmpty == false, "Missing \(language) translation for \(key)")
            }
        }

        for language in ["en", "ko"] {
            let infoURL = root.appendingPathComponent("Resources/Localization/\(language).lproj/InfoPlist.strings")
            let info = try String(contentsOf: infoURL, encoding: .utf8)
            assert(info.contains("NSMicrophoneUsageDescription"))
            assert(info.contains("NSSpeechRecognitionUsageDescription"))
        }

        print("LocalizationResourceTests passed")
    }
}
