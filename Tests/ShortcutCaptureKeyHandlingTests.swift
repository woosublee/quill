import AppKit

@main
struct ShortcutCaptureKeyHandlingTests {
    static func main() {
        testBareEscWithPendingBindingFinishesCapture()
        testCommandEscWithPendingBindingUpdatesCapture()
        testCommandReturnWithPendingBindingUpdatesCapture()
        print("ShortcutCaptureKeyHandlingTests passed")
    }

    private static func testBareEscWithPendingBindingFinishesCapture() {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        )!

        let action = ShortcutCaptureKeyHandling.action(
            for: event,
            pressedModifierKeyCodes: [],
            hasPendingCapture: true
        )

        assert(action == .finishCapture)
    }

    private static func testCommandEscWithPendingBindingUpdatesCapture() {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        )!

        let action = ShortcutCaptureKeyHandling.action(
            for: event,
            pressedModifierKeyCodes: [55],
            hasPendingCapture: true
        )

        assert(action == .updateCapture(ShortcutBinding(
            keyCode: 53,
            keyDisplay: "Esc",
            modifiers: .command,
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [55]
        )))
    }

    private static func testCommandReturnWithPendingBindingUpdatesCapture() {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        )!

        let action = ShortcutCaptureKeyHandling.action(
            for: event,
            pressedModifierKeyCodes: [55],
            hasPendingCapture: true
        )

        assert(action == .updateCapture(ShortcutBinding(
            keyCode: 36,
            keyDisplay: "↩",
            modifiers: .command,
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [55]
        )))
    }
}
