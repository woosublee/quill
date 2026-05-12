import Foundation

@main
struct ReleaseSDKCompatibilityTests {
    static func main() throws {
        let source = try String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)

        precondition(
            !source.contains("NSGlassEffectView"),
            "Release builds must not directly reference SDK symbols that are unavailable on GitHub's runner SDK"
        )

        print("ReleaseSDKCompatibilityTests passed")
    }
}
