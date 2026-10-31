import Foundation
import QuillDesignTokens

/// Keeps the shared QuillDesignTokens module and docs/design-system/tokens.json
/// in step for the tokens the module carries: the spacing, radius, and
/// breakpoint scales, the issue colors, the tints (label, white, and accent
/// based), the shadows (single and per appearance), the opacities, the text
/// styles, and the control and layout sizes. The
/// scales fail on a token added, removed or changed on either side; the
/// other families fail when a Swift token is missing from tokens.json or
/// differs from it.
@main
struct QuillDesignTokensTests {
    static func main() {
        let tokens = loadTokens()
        testSpacingMatchesTokensFile(tokens)
        testRadiusMatchesTokensFile(tokens)
        testIssueColorsMatchTokensFile(tokens)
        testTintsMatchTokensFile(tokens)
        testShadowsMatchTokensFile(tokens)
        testControlSizesMatchTokensFile(tokens)
        testBreakpointsMatchTokensFile(tokens)
        testOpacitiesMatchTokensFile(tokens)
        testTypeStylesMatchTokensFile(tokens)
        testLayoutSizesMatchTokensFile(tokens)
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

    /// Each tint's opacity matches the token's alpha in both themes. A white
    /// tint needs a white token; `primary` is the label color, which
    /// tokens.json writes as black in light and white in dark. On the Mac the
    /// label color is itself about 85% opaque, so these draw a little lighter
    /// than the rgba() values; tokens.json's hex and rgba values are
    /// approximations of the system colors (its meta note). An `accent` tint
    /// needs the `accent` token's color in that theme.
    private static func testTintsMatchTokensFile(_ tokens: [String: Any]) {
        let entries = (tokens["color"] as? [String: Any])?["tokens"] as? [[String: Any]] ?? []
        guard let accent = entries.first(where: { $0["name"] as? String == "accent" })?["value"] as? [String: String],
              let accentLight = accent["light"].flatMap(hexRGB), let accentDark = accent["dark"].flatMap(hexRGB) else {
            preconditionFailure("tokens.json has no light and dark hex for accent")
        }
        let names = QuillColor.tints.map(\.name)
        precondition(Set(names).count == names.count, "a tint is listed twice")
        for (name, tint) in QuillColor.tints {
            guard let themes = entries.first(where: { $0["name"] as? String == name })?["value"] as? [String: String],
                  let light = themes["light"].flatMap(rgba), let dark = themes["dark"].flatMap(rgba) else {
                preconditionFailure("tokens.json has no light and dark rgba() for \(name)")
            }
            for (theme, value, expected) in [("light", tint.light, light), ("dark", tint.dark, dark)] {
                precondition(abs(value.opacity - expected.alpha) < 0.0001, "\(name) (\(theme)) opacity \(value.opacity) vs tokens.json \(expected.alpha)")
                let isWhite = expected.rgb == [255, 255, 255]
                let isBlack = expected.rgb == [0, 0, 0]
                switch value.base {
                case .white: precondition(isWhite, "\(name) (\(theme)) is white in Swift but \(expected.rgb) in tokens.json")
                case .primary: precondition(theme == "light" ? isBlack : isWhite, "\(name) (\(theme)) is the label color but \(expected.rgb) in tokens.json")
                case .accent:
                    let accentRGB = theme == "light" ? accentLight : accentDark
                    precondition(expected.rgb == accentRGB, "\(name) (\(theme)) is the accent color but \(expected.rgb) in tokens.json")
                }
            }
        }
    }

    private static func hexRGB(_ value: String) -> [Int]? {
        guard value.hasPrefix("#"), value.count == 7, let number = Int(value.dropFirst(), radix: 16) else { return nil }
        return [(number >> 16) & 0xff, (number >> 8) & 0xff, number & 0xff]
    }

    private static func rgba(_ value: String) -> (rgb: [Int], alpha: Double)? {
        let trimmed = value.replacingOccurrences(of: " ", with: "")
        guard trimmed.hasPrefix("rgba("), trimmed.hasSuffix(")") else { return nil }
        let parts = trimmed.dropFirst(5).dropLast().split(separator: ",").map(String.init)
        guard parts.count == 4, let alpha = Double(parts[3]) else { return nil }
        let rgb = parts[0..<3].compactMap { Int($0) }
        return rgb.count == 3 ? (rgb, alpha) : nil
    }

    /// `0 4px 28px rgba(0, 0, 0, 0.085)`: SwiftUI's radius is half the CSS blur.
    /// A single shadow is one string; a per-appearance shadow is a light and
    /// a dark string.
    private static func testShadowsMatchTokensFile(_ tokens: [String: Any]) {
        let entries = (tokens["shadow"] as? [String: Any])?["tokens"] as? [[String: Any]] ?? []
        func value(_ name: String) -> Any? { entries.first(where: { $0["name"] as? String == name })?["value"] }
        let names = QuillShadow.all.map(\.name) + QuillShadow.schemeShadows.map(\.name)
        precondition(Set(names).count == names.count, "a shadow is listed twice")
        for (name, shadow) in QuillShadow.all {
            guard let raw = value(name) as? String else {
                preconditionFailure("tokens.json has no single shadow value for \(name)")
            }
            assertShadow(shadow, raw, name)
        }
        for (name, shadow) in QuillShadow.schemeShadows {
            guard let themes = value(name) as? [String: String], let light = themes["light"], let dark = themes["dark"] else {
                preconditionFailure("tokens.json has no light and dark shadow for \(name)")
            }
            assertShadow(shadow.light, light, "\(name) (light)")
            assertShadow(shadow.dark, dark, "\(name) (dark)")
            precondition(shadow.shadow(for: .dark) == shadow.dark && shadow.shadow(for: .light) == shadow.light, "\(name) picks by appearance")
        }
    }

    private static func assertShadow(_ shadow: QuillShadow, _ value: String, _ name: String) {
        guard let open = value.range(of: "rgba(")?.lowerBound, let color = rgba(String(value[open...])) else {
            preconditionFailure("\(name) is \(value); expected x y blur rgba()")
        }
        let lengths = value[..<open].split(separator: " ").map { Double($0.replacingOccurrences(of: "px", with: "")) }
        guard lengths.count == 3, let x = lengths[0], let y = lengths[1], let blur = lengths[2] else {
            preconditionFailure("\(name) is \(value); expected x y blur rgba()")
        }
        precondition(color.rgb == [0, 0, 0], "\(name) is drawn black")
        precondition(abs(shadow.opacity - color.alpha) < 0.0001, "\(name) opacity")
        precondition(Double(shadow.x) == x && Double(shadow.y) == y, "\(name) offset")
        precondition(Double(shadow.radius) * 2 == blur, "\(name) radius \(shadow.radius) vs blur \(blur)")
    }

    /// Every control size, both platforms' values where a size has two.
    /// This test runs on the Mac, so the platform picks show the Mac value.
    private static func testControlSizesMatchTokensFile(_ tokens: [String: Any]) {
        let sizes = lengths(tokens, family: "size")
        for (name, value) in QuillControlSize.all {
            precondition(sizes[name] == Double(value), "\(name) is \(value) in Swift but \(sizes[name].map(String.init(describing:)) ?? "missing") in tokens.json")
        }
        let names = QuillControlSize.all.map(\.name)
        precondition(Set(names).count == names.count, "a control size is listed twice")
        // A size with an iPhone value carries both in Swift.
        for name in sizes.keys where name.hasSuffix("-iphone") {
            let base = String(name.dropLast("-iphone".count))
            precondition(names.contains(name) && names.contains(base), "tokens.json size \(name) needs \(base) and \(name) in QuillControlSize")
        }
        precondition(QuillControlSize.noteToolbarButton == QuillControlSize.noteToolbarButtonMac, "this Mac test sees the Mac value")
        precondition(QuillControlSize.checkbox == QuillControlSize.checkboxMac, "this Mac test sees the Mac checkbox")
        precondition(QuillControlSize.recordButton == QuillControlSize.recordButtonMac, "this Mac test sees the Mac record button")
        precondition(QuillControlSize.close == QuillControlSize.closeMac, "this Mac test sees the Mac close button")
        precondition(QuillControlSize.searchField == QuillControlSize.searchFieldMac, "this Mac test sees the Mac search field")
        // The iPhone's close button and search field are the touch minimum.
        precondition(QuillControlSize.closeIPhone == QuillControlSize.touchMin, "the iPhone close button is size-touch-min")
        precondition(QuillControlSize.searchFieldIPhone == QuillControlSize.touchMin, "the iPhone search field is size-touch-min")
        // The iPhone's toolbar button is the minimum touch target.
        precondition(QuillControlSize.noteToolbarButtonIPhone == QuillControlSize.touchMin, "the iPhone toolbar button is size-touch-min")
    }

    private static func testBreakpointsMatchTokensFile(_ tokens: [String: Any]) {
        let swift = Dictionary(uniqueKeysWithValues: QuillBreakpoint.scale.map { ($0.name, Double($0.value)) })
        assertSame(swift, lengths(tokens, family: "breakpoint"), "QuillBreakpoint")
        let values = QuillBreakpoint.scale.map(\.value)
        precondition(values == values.sorted() && Set(values).count == values.count, "breakpoints rise")
    }

    private static func testOpacitiesMatchTokensFile(_ tokens: [String: Any]) {
        let entries = (tokens["opacity"] as? [String: Any])?["tokens"] as? [[String: Any]] ?? []
        for (name, value) in QuillOpacity.all {
            guard let raw = entries.first(where: { $0["name"] as? String == name })?["value"] as? String,
                  let file = Double(raw) else {
                preconditionFailure("tokens.json has no opacity value for \(name)")
            }
            precondition(abs(value - file) < 0.0001, "\(name) is \(value) in Swift but \(raw) in tokens.json")
        }
        let swiftNames = Set(QuillOpacity.all.map(\.name))
        for name in entries.compactMap({ $0["name"] as? String }) where name.hasPrefix("opacity-status-") {
            precondition(swiftNames.contains(name), "tokens.json opacity \(name) is missing from QuillOpacity")
        }
    }

    /// Size, line height, weight, letter spacing and typeface of each style,
    /// by name, across every type group. A style in the `mono` family group
    /// is SF Mono in Swift; a style without `letterSpacing` has no tracking.
    private static func testTypeStylesMatchTokensFile(_ tokens: [String: Any]) {
        let groups = (tokens["type"] as? [String: Any])?["groups"] as? [[String: Any]] ?? []
        let styles = groups.flatMap { group in
            (group["styles"] as? [[String: Any]] ?? []).map { (style: $0, family: group["family"] as? String) }
        }
        func points(_ value: Any?) -> Double? {
            guard let raw = value as? String, raw.hasSuffix("px") else { return nil }
            return Double(raw.dropLast(2))
        }
        let swiftNamesList = QuillTypeStyle.all.map(\.name)
        precondition(Set(swiftNamesList).count == swiftNamesList.count, "a type style is listed twice")
        for (name, style) in QuillTypeStyle.all {
            guard let found = styles.first(where: { $0.style["name"] as? String == name }),
                  let size = points(found.style["fontSize"]), let lineHeight = points(found.style["lineHeight"]),
                  let weight = found.style["fontWeight"] as? Int else {
                preconditionFailure("tokens.json has no px fontSize, lineHeight and fontWeight for \(name)")
            }
            let entry = found.style
            precondition(Double(style.size) == size, "\(name) size \(style.size) vs tokens.json \(size)")
            precondition(Double(style.lineHeight) == lineHeight, "\(name) line height \(style.lineHeight) vs tokens.json \(lineHeight)")
            precondition(style.weight == weight, "\(name) weight \(style.weight) vs tokens.json \(weight)")
            func spacing(_ key: String, default fallback: Double) -> Double {
                guard entry[key] != nil else { return fallback }
                guard let value = points(entry[key]) else { preconditionFailure("\(name) \(key) is not px") }
                return value
            }
            let tracking = spacing("letterSpacing", default: 0)
            let trackingIPhone = spacing("letterSpacingIphone", default: tracking)
            precondition(Double(style.tracking) == tracking, "\(name) tracking \(style.tracking) vs tokens.json \(tracking)")
            precondition(Double(style.trackingIPhone) == trackingIPhone, "\(name) iPhone tracking \(style.trackingIPhone) vs tokens.json \(trackingIPhone)")
            let isMono = (entry["family"] as? String ?? found.family) == "mono"
            precondition((style.design == .monospaced) == isMono, "\(name) is \(style.design) in Swift but family \(found.family ?? "-") in tokens.json")
        }
        precondition(QuillTypeStyle.metaMono.platformTracking == QuillTypeStyle.metaMono.tracking, "this Mac test sees the Mac tracking")
        precondition(QuillTypeStyle.noteTitle.fontWeight == .bold, "the note title is bold, as the Mac draws it")
        precondition(QuillTypeStyle.metaMono.scalesFromMacSize && QuillTypeStyle.metaChipMono.scalesFromMacSize, "the meta line keeps its Mac size on iOS and scales it")
        // A banner's detail sits beside its title at the same size on both
        // platforms, so on iOS the two scale from the same text style (#744).
        precondition(QuillTypeStyle.callout.dynamicStyle == QuillTypeStyle.bannerTitle.dynamicStyle, "a banner's detail scales with its title on iOS")
        for (name, style) in QuillTypeStyle.all {
            precondition(style.fontWeight != nil, "\(name) weight \(style.weight) is not a CSS weight")
        }
        precondition(QuillTypeStyle.statusTitle.fontWeight == .semibold, "600 is semibold")
        precondition(QuillTypeStyle.statusPercent.fontWeight == .regular, "400 is regular")
        precondition(QuillTypeStyle(size: 1, lineHeight: 1, weight: 350, dynamicStyle: .footnote).fontWeight == nil)
        precondition(QuillTypeStyle.statusPercent.monospacedDigits, "a percentage keeps its width as it changes")
        // The work-status styles are this module's: one only in tokens.json
        // fails too.
        let swiftNames = Set(QuillTypeStyle.all.map(\.name))
        for name in styles.compactMap({ $0.style["name"] as? String }) where name.hasPrefix("status-") {
            precondition(swiftNames.contains(name), "tokens.json style \(name) is missing from QuillTypeStyle")
        }
    }

    /// The note layout sizes (#697). The margins are steps of the spacing
    /// scale, so a margin can't drift off it.
    private static func testLayoutSizesMatchTokensFile(_ tokens: [String: Any]) {
        let sizes = lengths(tokens, family: "size")
        for (name, value) in QuillLayoutSize.all {
            precondition(sizes[name] == Double(value), "\(name) is \(value) in Swift but \(sizes[name].map(String.init(describing:)) ?? "missing") in tokens.json")
        }
        let layoutPrefixes = ["size-sidebar-notes", "size-note-margin-", "size-note-body-"]
        for name in sizes.keys where layoutPrefixes.contains(where: name.hasPrefix) {
            precondition(QuillLayoutSize.all.contains { $0.name == name }, "tokens.json size \(name) is missing from QuillLayoutSize")
        }
        precondition(QuillLayoutSize.noteMarginCompact == QuillSpacing.space16, "compact margin is space-16")
        precondition(QuillLayoutSize.noteMarginRegular == QuillSpacing.space24, "regular margin is space-24")
        // Where the list first fits beside the note, it leaves the Mac's
        // narrowest note column, 520 pt.
        precondition(QuillBreakpoint.wide - QuillLayoutSize.sidebarNotes == 520, "800 = 280 list + 520 note")
    }

    /// Rounds half away from zero, as the hex values in tokens.json were
    /// written (issue-warning's green, 0.70 × 255 = 178.5, is #b3).
    private static func hexString(_ rgb: QuillColor.RGB) -> String {
        let channels = [rgb.red, rgb.green, rgb.blue].map { Int(($0 * 255).rounded()) }
        return "#" + channels.map { String(format: "%02x", $0) }.joined()
    }
}
