import AppKit

enum ShortcutCaptureKeyAction: Equatable {
    case finishCapture
    case updateCapture(ShortcutBinding)
    case ignore
}

enum ShortcutCaptureKeyHandling {
    static func action(
        for event: NSEvent,
        pressedModifierKeyCodes: Set<UInt16>,
        hasPendingCapture: Bool
    ) -> ShortcutCaptureKeyAction {
        if hasPendingCapture,
           pressedModifierKeyCodes.isEmpty,
           isFinishCaptureKey(event.keyCode) {
            return .finishCapture
        }

        guard !ShortcutBinding.modifierKeyCodes.contains(event.keyCode),
              let binding = ShortcutBinding.from(
                event: event,
                pressedModifierKeyCodes: pressedModifierKeyCodes
              ) else {
            return .ignore
        }

        return .updateCapture(binding)
    }

    private static func isFinishCaptureKey(_ keyCode: UInt16) -> Bool {
        keyCode == 36 || keyCode == 53 || keyCode == 76
    }
}
