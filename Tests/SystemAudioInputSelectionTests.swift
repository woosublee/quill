import Foundation

@main
struct SystemAudioInputSelectionTests {
    static func main() throws {
        testSystemAudioInputIdentifier()
        testSystemDefaultAndSystemAudioInputIdentifier()
        testSpecialInputClassification()
        testSingleSourceClassification()
        testMicrophoneOnlyClassification()
        try testSettingsPickerShowsDefaultBeforeSystemAudio()
        try testMenuBarPickerShowsDefaultBeforeSystemAudio()
        try testSetupPickerShowsDefaultBeforeSystemAudio()
        try testSetupPickerTreatsEmptySelectionAsSystemDefault()
        try testSettingsPickerIncludesSystemDefaultAndSystemAudio()
        try testMenuBarPickerIncludesSystemDefaultAndSystemAudio()
        try testSetupPickerIncludesSystemDefaultAndSystemAudio()
        print("SystemAudioInputSelectionTests passed")
    }

    private static func testSystemAudioInputIdentifier() {
        assert(AudioInputDevice.systemAudioID == "__system_audio__")
        assert(AudioInputDevice.defaultMicrophoneID == "default")
        assert(AudioInputDevice.isSystemAudio(AudioInputDevice.systemAudioID))
        assert(!AudioInputDevice.isSystemAudio(AudioInputDevice.defaultMicrophoneID))
        assert(!AudioInputDevice.isSystemAudio(""))
    }

    private static func testSystemDefaultAndSystemAudioInputIdentifier() {
        assert(AudioInputDevice.systemDefaultAndSystemAudioID == "__system_default_and_system_audio__")
        assert(AudioInputDevice.isSystemDefaultAndSystemAudio(AudioInputDevice.systemDefaultAndSystemAudioID))
        assert(!AudioInputDevice.isSystemDefaultAndSystemAudio(AudioInputDevice.systemAudioID))
        assert(!AudioInputDevice.isSystemDefaultAndSystemAudio(AudioInputDevice.defaultMicrophoneID))
    }

    private static func testSpecialInputClassification() {
        assert(AudioInputDevice.isSpecialInput(AudioInputDevice.systemAudioID))
        assert(AudioInputDevice.isSpecialInput(AudioInputDevice.systemDefaultAndSystemAudioID))
        assert(!AudioInputDevice.isSpecialInput(AudioInputDevice.defaultMicrophoneID))
    }

    private static func testSingleSourceClassification() {
        assert(AudioInputDevice.isSingleSource(AudioInputDevice.defaultMicrophoneID))
        assert(AudioInputDevice.isSingleSource(AudioInputDevice.systemAudioID))
        assert(!AudioInputDevice.isSingleSource(AudioInputDevice.systemDefaultAndSystemAudioID))
    }

    private static func testMicrophoneOnlyClassification() {
        assert(AudioInputDevice.isMicrophoneOnly(AudioInputDevice.defaultMicrophoneID))
        assert(!AudioInputDevice.isMicrophoneOnly(AudioInputDevice.systemAudioID))
        assert(!AudioInputDevice.isMicrophoneOnly(AudioInputDevice.systemDefaultAndSystemAudioID))
    }

    private static func testSettingsPickerShowsDefaultBeforeSystemAudio() throws {
        let source = try sourceFile("Sources/SettingsView.swift")
        assertOrder(
            source: source,
            first: "title: \"System Default\"",
            second: "title: \"System Audio\"",
            file: "Sources/SettingsView.swift"
        )
    }

    private static func testMenuBarPickerShowsDefaultBeforeSystemAudio() throws {
        let source = try sourceFile("Sources/MenuBarView.swift")
        assertOrder(
            source: source,
            first: "Text(\"✓ System Default\")",
            second: "Text(\"✓ System Audio\")",
            file: "Sources/MenuBarView.swift"
        )
    }

    private static func testSetupPickerShowsDefaultBeforeSystemAudio() throws {
        let source = try sourceFile("Sources/SetupView.swift")
        assertOrder(
            source: source,
            first: "Text(\"System Default\").tag(AudioInputDevice.defaultMicrophoneID)",
            second: "Text(\"System Audio\").tag(AudioInputDevice.systemAudioID)",
            file: "Sources/SetupView.swift"
        )
    }

    private static func testSetupPickerTreatsEmptySelectionAsSystemDefault() throws {
        let source = try sourceFile("Sources/SetupView.swift")
        assertContains(source, "private var setupMicrophoneSelection: Binding<String>")
        assertContains(source, "appState.selectedMicrophoneID.isEmpty ? AudioInputDevice.defaultMicrophoneID : appState.selectedMicrophoneID")
        assertContains(source, "Picker(\"Input:\", selection: setupMicrophoneSelection)")
    }

    private static func testSettingsPickerIncludesSystemDefaultAndSystemAudio() throws {
        let source = try sourceFile("Sources/SettingsView.swift")
        assertContains(source, "title: \"System Default + System Audio\"")
        assertContains(source, "AudioInputDevice.systemDefaultAndSystemAudioID")
    }

    private static func testMenuBarPickerIncludesSystemDefaultAndSystemAudio() throws {
        let source = try sourceFile("Sources/MenuBarView.swift")
        assertContains(source, "Text(\"✓ System Default + System Audio\")")
        assertContains(source, "AudioInputDevice.systemDefaultAndSystemAudioID")
    }

    private static func testSetupPickerIncludesSystemDefaultAndSystemAudio() throws {
        let source = try sourceFile("Sources/SetupView.swift")
        assertContains(source, "Text(\"System Default + System Audio\").tag(AudioInputDevice.systemDefaultAndSystemAudioID)")
        assertContains(source, "AudioInputDevice.systemDefaultAndSystemAudioID")
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

    private static func assertContains(_ source: String, _ marker: String) {
        precondition(source.contains(marker), "Missing marker: \(marker)")
    }
}
