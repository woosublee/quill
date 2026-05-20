enum ShortcutValidationTarget {
    case hold
    case toggle
    case recordingCancel
    case copyAgain
}

struct ShortcutValidationMessages: Equatable {
    var hold: String?
    var toggle: String?
    var recordingCancel: String?
    var copyAgain: String?

    mutating func applySelectionResult(_ message: String?, target: ShortcutValidationTarget) {
        switch target {
        case .hold:
            hold = message
        case .toggle:
            toggle = message
        case .recordingCancel:
            recordingCancel = message
        case .copyAgain:
            copyAgain = message
        }

        guard message == nil else { return }
        hold = nil
        toggle = nil
        recordingCancel = nil
        copyAgain = nil
    }
}
