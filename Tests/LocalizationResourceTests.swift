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

        let noteBrowserSource = try String(
            contentsOf: root.appendingPathComponent("Sources/NoteBrowserView.swift"),
            encoding: .utf8
        )
        assert(noteBrowserSource.contains("help: LocalizedStringKey"))
        assert(noteBrowserSource.contains("let help: LocalizedStringKey"))
        assert(noteBrowserSource.contains("fieldLabel(_ key: LocalizedStringKey)"))
        assert(noteBrowserSource.contains("if vaultPath.isEmpty {\n                        Text(\"Select a folder\")"))
        assert(noteBrowserSource.contains("} else {\n                        Text(vaultPath)"))
        assert(strings["Obsidian Vault Folder"] != nil)

        let hangulPattern = try NSRegularExpression(pattern: "[가-힣]")
        let sourceFiles = ["Sources/NoteBrowserView.swift", "Sources/NoteListRowDisplayData.swift"]
        for sourceFile in sourceFiles {
            let source = try String(contentsOf: root.appendingPathComponent(sourceFile), encoding: .utf8)
            let lines = source.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                guard hangulPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { continue }
                let previousLine = index > 0 ? lines[index - 1] : ""
                let isAllowlistedGeminiPrompt = previousLine.contains("localization-allowlist: exact non-UI Gemini model prompt")
                    && line.contains("@AppStorage(\"obsidian_gemini_prompt\")")
                assert(isAllowlistedGeminiPrompt, "Unexpected Hangul literal in \(sourceFile):\(index + 1)")
            }
        }

        print("LocalizationResourceTests passed")
    }
}
