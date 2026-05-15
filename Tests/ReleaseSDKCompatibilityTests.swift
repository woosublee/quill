import Foundation

@main
struct ReleaseSDKCompatibilityTests {
    static func main() throws {
        let noteBrowserSource = try String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)
        precondition(
            !noteBrowserSource.contains("NSGlassEffectView"),
            "Release builds must not directly reference SDK symbols that are unavailable on GitHub's runner SDK"
        )

        if FileManager.default.fileExists(atPath: "Sources/SystemAudioRecorder.swift") {
            let systemAudioSource = try String(contentsOfFile: "Sources/SystemAudioRecorder.swift", encoding: .utf8)
            let unavailableSystemAudioSymbols = [
                "SCRecordingOutput",
                "captureMicrophone",
                "SCStreamOutputTypeMicrophone",
                "type: .microphone"
            ]
            for symbol in unavailableSystemAudioSymbols {
                precondition(
                    !systemAudioSource.contains(symbol),
                    "System audio release builds must not directly reference \(symbol)"
                )
            }
        }

        print("ReleaseSDKCompatibilityTests passed")
    }
}
