import Cocoa

final class HotkeyManager {
    private let backend = GlobalShortcutBackend()
    private var configuration = ShortcutConfiguration(
        hold: .defaultHold,
        toggle: .defaultToggle
    )
    private var inputState = ShortcutInputState()

    var onShortcutEvent: ((ShortcutEvent) -> Void)?
    var onRecordingCancelShortcut: (() -> Bool)?
    var onCopyAgainShortcut: (() -> Bool)?

    var currentPressedModifiers: ShortcutModifiers {
        inputState.currentModifiers
    }

    var hasPressedShortcutInputs: Bool {
        inputState.hasPressedShortcutInputs(configuration: configuration)
    }

    func start(configuration: ShortcutConfiguration) throws {
        stop()
        self.configuration = configuration
        backend.onInputEvent = { [weak self] event in
            self?.handleInputEvent(event) ?? .passthrough
        }
        do {
            try backend.start()
        } catch {
            backend.onInputEvent = nil
            inputState = ShortcutInputState()
            throw error
        }
    }

    func stop() {
        backend.stop()
        backend.onInputEvent = nil
        inputState = ShortcutInputState()
    }

    deinit {
        stop()
    }

    private func handleInputEvent(_ event: ShortcutInputEvent) -> ShortcutConsumeDecision {
        let result = ShortcutMatcher.reduce(
            state: inputState,
            event: event,
            configuration: configuration
        )
        inputState = result.state
        return Self.dispatchShortcutMatchResult(
            result,
            onShortcutEvent: { [weak self] event in self?.onShortcutEvent?(event) },
            onRecordingCancelShortcut: { [weak self] in self?.onRecordingCancelShortcut?() ?? false },
            onCopyAgainShortcut: { [weak self] in self?.onCopyAgainShortcut?() ?? false }
        )
    }

    static func dispatchShortcutMatchResult(
        _ result: ShortcutMatchResult,
        onShortcutEvent: (ShortcutEvent) -> Void,
        onRecordingCancelShortcut: () -> Bool,
        onCopyAgainShortcut: () -> Bool = { true }
    ) -> ShortcutConsumeDecision {
        var consumedByForwardedShortcut = false
        var consumedByRecordingCancel = false
        var consumedByCopyAgain = false
        var sawRecordingCancelEvent = false
        var sawCopyAgainEvent = false

        for event in result.emittedEvents {
            switch event {
            case .recordingCancelRequested:
                sawRecordingCancelEvent = true
                consumedByRecordingCancel = onRecordingCancelShortcut() || consumedByRecordingCancel
            case .copyAgainTriggered:
                sawCopyAgainEvent = true
                consumedByCopyAgain = onCopyAgainShortcut() || consumedByCopyAgain
            case .holdActivated, .holdDeactivated, .toggleActivated, .toggleDeactivated:
                consumedByForwardedShortcut = true
                onShortcutEvent(event)
            }
        }

        if consumedByForwardedShortcut || consumedByRecordingCancel || consumedByCopyAgain {
            return .consume
        }
        if result.consumeDecision == .consume && !sawRecordingCancelEvent && !sawCopyAgainEvent {
            return .consume
        }
        return .passthrough
    }
}
