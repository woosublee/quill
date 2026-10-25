import Foundation

/// Keeps Sources/QuillDesignTokens.swift and docs/design-system/tokens.json in
/// step for the tokens the Swift file carries: the spacing and radius scales
/// and the issue colors. A token added, removed or changed in one of those on
/// either side fails here.
@main
struct QuillDesignTokensTests {
    static func main() {
        let tokens = loadTokens()
        testSpacingMatchesTokensFile(tokens)
        testRadiusMatchesTokensFile(tokens)
        testIssueColorsMatchTokensFile(tokens)
        print("QuillDesignTokensTests passed")
    }

    private static func loadTokens() -> [String: Any] {
        let url = URL(fileURLWithPath: "docs/design-system/tokens.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            preconditionFailure("Run from the repository root: docs/design-system/tokens.json is missing or invalid")
        }
        return object
    }

    /// `name -> points` for a family's tokens. Every value must be in `px`,
    /// so a token in another unit fails instead of being skipped.
    private static func lengths(_ tokens: [String: Any], family: String) -> [String: Double] {
        let entries = (tokens[family] as? [String: Any])?["tokens"] as? [[String: Any]] ?? []
        precondition(!entries.isEmpty, "tokens.json has no \(family) tokens")
        var result: [String: Double] = [:]
        for entry in entries {
            let name = entry["name"] as? String ?? "?"
            let raw = entry["value"] as? String ?? ""
            guard raw.hasSuffix("px"), let value = Double(raw.dropLast(2)) else {
                preconditionFailure("\(family) token \(name) has value \(raw); QuillDesignTokens only reads px")
            }
            result[name] = value
        }
        return result
    }

    private static func assertSame(_ swift: [String: Double], _ file: [String: Double], _ label: String) {
        let missingInSwift = Set(file.keys).subtracting(swift.keys).sorted()
        let missingInFile = Set(swift.keys).subtracting(file.keys).sorted()
        let different = file.keys.filter { swift[$0] != nil && swift[$0] != file[$0] }.sorted()
            .map { "\($0): Swift \(swift[$0]!) vs tokens.json \(file[$0]!)" }
        precondition(
            missingInSwift.isEmpty && missingInFile.isEmpty && different.isEmpty,
            "\(label) drifted. Missing in Swift: \(missingInSwift). Missing in tokens.json: \(missingInFile). Different: \(different)"
        )
    }

    private static func testSpacingMatchesTokensFile(_ tokens: [String: Any]) {
        let swift = Dictionary(uniqueKeysWithValues: QuillSpacing.scale.map { ($0.name, Double($0.value)) })
        assertSame(swift, lengths(tokens, family: "spacing"), "QuillSpacing")
    }

    /// The capsule radius is a shape (`Capsule()`), not a number, in Swift, so
    /// it is unit-checked with the rest but left out of the comparison.
    private static func testRadiusMatchesTokensFile(_ tokens: [String: Any]) {
        var file = lengths(tokens, family: "radius")
        guard file.removeValue(forKey: "radius-capsule") != nil else {
            preconditionFailure("tokens.json has no radius-capsule token")
        }
        let swift = Dictionary(uniqueKeysWithValues: QuillRadius.scale.map { ($0.name, Double($0.value)) })
        assertSame(swift, file, "QuillRadius")
    }

    /// QuillColor draws one color in both appearances, so every theme declared
    /// in color.themes must hold that same value.
    private static func testIssueColorsMatchTokensFile(_ tokens: [String: Any]) {
        let color = tokens["color"] as? [String: Any]
        let entries = color?["tokens"] as? [[String: Any]] ?? []
        let themeIDs = Set((color?["themes"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        precondition(!themeIDs.isEmpty, "tokens.json has no color themes")
        for (name, rgb) in [("issue-warning", QuillColor.issueWarningRGB), ("issue-error", QuillColor.issueErrorRGB)] {
            let entry = entries.first { $0["name"] as? String == name }
            guard let themes = entry?["value"] as? [String: String], !themes.isEmpty else {
                preconditionFailure("tokens.json has no per-theme value for \(name)")
            }
            precondition(
                Set(themes.keys) == themeIDs,
                "\(name) has themes \(themes.keys.sorted()) but color.themes is \(themeIDs.sorted())"
            )
            let expected = hexString(rgb)
            for (theme, value) in themes.sorted(by: { $0.key < $1.key }) {
                precondition(
                    value.lowercased() == expected,
                    "\(name) (\(theme)) is \(value) in tokens.json but \(expected) in QuillColor"
                )
            }
        }
    }

    /// Rounds half away from zero, as the hex values in tokens.json were
    /// written (issue-warning's green, 0.70 × 255 = 178.5, is #b3).
    private static func hexString(_ rgb: QuillColor.RGB) -> String {
        let channels = [rgb.red, rgb.green, rgb.blue].map { Int(($0 * 255).rounded()) }
        return "#" + channels.map { String(format: "%02x", $0) }.joined()
    }
}
