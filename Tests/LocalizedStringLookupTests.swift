import Foundation

@main
struct LocalizedStringLookupTests {
    static func main() throws {
        try testFormattingUsesRequestedLanguageLocale()
        try testRepeatedLookupUsesCachedDictionary()
        print("LocalizedStringLookupTests passed")
    }

    private static func testRepeatedLookupUsesCachedDictionary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-localized-string-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let localizationDirectory = root.appendingPathComponent("en.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: localizationDirectory, withIntermediateDirectories: true)
        let stringsURL = localizationDirectory.appendingPathComponent("Localizable.strings")
        try #""Greeting" = "First";"#.write(to: stringsURL, atomically: true, encoding: .utf8)
        guard let bundle = Bundle(path: root.path) else {
            throw TestFailure("Unable to create localization test bundle")
        }

        assert(localizedCatalogString("Greeting", language: "en", bundle: bundle) == "First")
        try #""Greeting" = "Second";"#.write(to: stringsURL, atomically: true, encoding: .utf8)
        assert(localizedCatalogString("Greeting", language: "en", bundle: bundle) == "First")
    }

    private static func testFormattingUsesRequestedLanguageLocale() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-localized-format-locale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let localizationDirectory = root.appendingPathComponent("fr_FR.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: localizationDirectory, withIntermediateDirectories: true)
        let stringsURL = localizationDirectory.appendingPathComponent("Localizable.strings")
        try #""Amount: %.1f" = "Montant : %.1f";"#.write(to: stringsURL, atomically: true, encoding: .utf8)
        guard let bundle = Bundle(path: root.path) else {
            throw TestFailure("Unable to create format locale test bundle")
        }

        let formatted = localizedCatalogFormat(
            "Amount: %.1f",
            1234.5,
            language: "fr_FR",
            bundle: bundle
        )
        assert(formatted.contains("1\u{202F}234,5"), "Unexpected French number formatting: \(formatted)")
    }

    private struct TestFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
