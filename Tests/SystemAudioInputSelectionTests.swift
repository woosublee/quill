import Foundation

@main
struct SystemAudioInputSelectionTests {
    static func main() throws {
        testSystemAudioInputIdentifier()
        try testSettingsPickerShowsSystemAudioBeforeMicrophones()
        try testMenuBarPickerShowsSystemAudioBeforeMicrophones()
        try testSetupPickerShowsSystemAudioBeforeMicrophones()
        print("SystemAudioInputSelectionTests passed")
    }

    private static func testSystemAudioInputIdentifier() {
        assert(AudioInputDevice.systemAudioID == "__system_audio__")
        assert(AudioInputDevice.defaultMicrophoneID == "default")
        assert(AudioInputDevice.isSystemAudio(AudioInputDevice.systemAudioID))
        assert(!AudioInputDevice.isSystemAudio(AudioInputDevice.defaultMicrophoneID))
        assert(!AudioInputDevice.isSystemAudio(""))
    }

    private static func testSettingsPickerShowsSystemAudioBeforeMicrophones() throws {
        let source = try sourceFile("Sources/SettingsView.swift")
        assertOrder(
            source: source,
            first: "name: \"System Audio\"",
            second: "name: \"System Default\"",
            file: "Sources/SettingsView.swift"
        )
    }

    private static func testMenuBarPickerShowsSystemAudioBeforeMicrophones() throws {
        let source = try sourceFile("Sources/MenuBarView.swift")
        assertOrder(
            source: source,
            first: "Text(\"✓ System Audio\")",
            second: "Text(\"✓ System Default\")",
            file: "Sources/MenuBarView.swift"
        )
    }

    private static func testSetupPickerShowsSystemAudioBeforeMicrophones() throws {
        let source = try sourceFile("Sources/SetupView.swift")
        assertOrder(
            source: source,
            first: "Text(\"System Audio\").tag(AudioInputDevice.systemAudioID)",
            second: "Text(\"System Default\").tag(AudioInputDevice.defaultMicrophoneID)",
            file: "Sources/SetupView.swift"
        )
    }

    private static func sourceFile(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    private static func assertOrder(source: String, first: String, second: String, file: String) {
        guard let firstRange = source.range(of: first) else {
            preconditionFailure("Missing first marker in \(file): \(first)")
        }
        guard let secondRange = source.range(of: second) else {
            preconditionFailure("Missing second marker in \(file): \(second)")
        }
        precondition(
            firstRange.lowerBound < secondRange.lowerBound,
            "Expected \(first) to appear before \(second) in \(file)"
        )
    }
}
