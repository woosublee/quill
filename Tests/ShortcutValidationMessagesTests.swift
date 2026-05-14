@main
struct ShortcutValidationMessagesTests {
    static func main() {
        testSuccessfulSelectionClearsAllValidationMessages()
        print("ShortcutValidationMessagesTests passed")
    }

    private static func testSuccessfulSelectionClearsAllValidationMessages() {
        var messages = ShortcutValidationMessages(
            hold: "Hold and tap shortcuts must be distinct.",
            toggle: "Hold and tap shortcuts must be distinct.",
            recordingCancel: "Cancel shortcut must be distinct from dictation shortcuts."
        )

        messages.applySelectionResult(nil, target: .toggle)

        assert(messages.hold == nil)
        assert(messages.toggle == nil)
        assert(messages.recordingCancel == nil)
    }
}
