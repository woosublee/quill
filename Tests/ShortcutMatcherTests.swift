import Foundation

@main
struct ShortcutMatcherTests {
    static func main() {
        testDisabledCancelShortcutPassesThrough()
        testEscCancelShortcutEmitsCancelEvent()
        testModifierOnlyCancelShortcutEmitsCancelEvent()
        testModifierCombinationCancelShortcutEmitsRegardlessOfPressOrder()
        testRepeatedEscDoesNotEmitCancelEvent()
        testCustomCancelShortcutRequiresConfiguredModifiers()
        testCancelDeclinePassesThrough()
        testCancelAcceptConsumes()
        testCancelDeclinePreservesForwardedShortcutConsumption()
        testCopyAgainDeclinePassesThrough()
        testCopyAgainAcceptConsumes()
        print("ShortcutMatcherTests passed")
    }

    private static func testDisabledCancelShortcutPassesThrough() {
        let configuration = ShortcutConfiguration(
            hold: .disabled,
            toggle: .disabled,
            recordingCancel: .disabled
        )

        let result = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .keyChanged(keyCode: 53, isDown: true, isRepeat: false),
            configuration: configuration
        )

        assert(result.emittedEvents.isEmpty)
        assert(result.consumeDecision == .passthrough)
    }

    private static func testEscCancelShortcutEmitsCancelEvent() {
        let configuration = ShortcutConfiguration(
            hold: .disabled,
            toggle: .disabled,
            recordingCancel: .defaultRecordingCancel
        )

        let result = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .keyChanged(keyCode: 53, isDown: true, isRepeat: false),
            configuration: configuration
        )

        assert(result.emittedEvents == [.recordingCancelRequested])
        assert(result.consumeDecision == .consume)
    }

    private static func testModifierOnlyCancelShortcutEmitsCancelEvent() {
        let configuration = ShortcutConfiguration(
            hold: .disabled,
            toggle: .disabled,
            recordingCancel: ShortcutPreset.rightOption.binding
        )

        let result = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 61, isDown: true),
            configuration: configuration
        )

        assert(result.emittedEvents == [.recordingCancelRequested])
        assert(result.consumeDecision == .consume)
    }

    private static func testModifierCombinationCancelShortcutEmitsRegardlessOfPressOrder() {
        let rightOptionWithCommand = ShortcutBinding(
            keyCode: 61,
            keyDisplay: "Right Option",
            modifiers: .command,
            kind: .modifierKey,
            preset: nil,
            exactModifierKeyCodes: [55, 61]
        )
        let configuration = ShortcutConfiguration(
            hold: .disabled,
            toggle: .disabled,
            recordingCancel: rightOptionWithCommand
        )

        let commandFirst = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 55, isDown: true),
            configuration: configuration
        )
        let commandThenRightOption = ShortcutMatcher.reduce(
            state: commandFirst.state,
            event: .modifierChanged(keyCode: 61, isDown: true),
            configuration: configuration
        )
        assert(commandThenRightOption.emittedEvents == [.recordingCancelRequested])
        assert(commandThenRightOption.consumeDecision == .consume)

        let rightOptionFirst = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 61, isDown: true),
            configuration: configuration
        )
        let rightOptionThenCommand = ShortcutMatcher.reduce(
            state: rightOptionFirst.state,
            event: .modifierChanged(keyCode: 55, isDown: true),
            configuration: configuration
        )
        assert(rightOptionThenCommand.emittedEvents == [.recordingCancelRequested])
        assert(rightOptionThenCommand.consumeDecision == .consume)
    }

    private static func testRepeatedEscDoesNotEmitCancelEvent() {
        let configuration = ShortcutConfiguration(
            hold: .disabled,
            toggle: .disabled,
            recordingCancel: .defaultRecordingCancel
        )

        let initial = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .keyChanged(keyCode: 53, isDown: true, isRepeat: false),
            configuration: configuration
        )
        let repeated = ShortcutMatcher.reduce(
            state: initial.state,
            event: .keyChanged(keyCode: 53, isDown: true, isRepeat: true),
            configuration: configuration
        )

        assert(repeated.emittedEvents.isEmpty)
        assert(repeated.consumeDecision == .passthrough)
    }

    private static func testCustomCancelShortcutRequiresConfiguredModifiers() {
        let commandPeriod = ShortcutBinding(
            keyCode: 47,
            keyDisplay: ".",
            modifiers: .command,
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [55]
        )
        let configuration = ShortcutConfiguration(
            hold: .disabled,
            toggle: .disabled,
            recordingCancel: commandPeriod
        )

        let barePeriod = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .keyChanged(keyCode: 47, isDown: true, isRepeat: false),
            configuration: configuration
        )
        assert(barePeriod.emittedEvents.isEmpty)
        assert(barePeriod.consumeDecision == .passthrough)

        let snapshot = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierSnapshot([55]),
            configuration: configuration
        )
        let commandPeriodResult = ShortcutMatcher.reduce(
            state: snapshot.state,
            event: .keyChanged(keyCode: 47, isDown: true, isRepeat: false),
            configuration: configuration
        )

        assert(commandPeriodResult.emittedEvents == [.recordingCancelRequested])
        assert(commandPeriodResult.consumeDecision == .consume)
    }

    private static func testCancelDeclinePassesThrough() {
        let result = ShortcutMatchResult(
            state: ShortcutInputState(),
            emittedEvents: [.recordingCancelRequested],
            consumeDecision: .consume
        )
        var forwardedEvents: [ShortcutEvent] = []

        let decision = HotkeyManager.dispatchShortcutMatchResult(
            result,
            onShortcutEvent: { forwardedEvents.append($0) },
            onRecordingCancelShortcut: { false }
        )

        assert(forwardedEvents.isEmpty)
        assert(decision == .passthrough)
    }

    private static func testCancelAcceptConsumes() {
        let result = ShortcutMatchResult(
            state: ShortcutInputState(),
            emittedEvents: [.recordingCancelRequested],
            consumeDecision: .consume
        )
        var forwardedEvents: [ShortcutEvent] = []

        let decision = HotkeyManager.dispatchShortcutMatchResult(
            result,
            onShortcutEvent: { forwardedEvents.append($0) },
            onRecordingCancelShortcut: { true }
        )

        assert(forwardedEvents.isEmpty)
        assert(decision == .consume)
    }

    private static func testCancelDeclinePreservesForwardedShortcutConsumption() {
        let result = ShortcutMatchResult(
            state: ShortcutInputState(),
            emittedEvents: [.holdActivated, .recordingCancelRequested],
            consumeDecision: .consume
        )
        var forwardedEvents: [ShortcutEvent] = []

        let decision = HotkeyManager.dispatchShortcutMatchResult(
            result,
            onShortcutEvent: { forwardedEvents.append($0) },
            onRecordingCancelShortcut: { false }
        )

        assert(forwardedEvents == [.holdActivated])
        assert(decision == .consume)
    }

    private static func testCopyAgainDeclinePassesThrough() {
        let result = ShortcutMatchResult(
            state: ShortcutInputState(),
            emittedEvents: [.copyAgainTriggered],
            consumeDecision: .consume
        )
        var forwardedEvents: [ShortcutEvent] = []

        let decision = HotkeyManager.dispatchShortcutMatchResult(
            result,
            onShortcutEvent: { forwardedEvents.append($0) },
            onRecordingCancelShortcut: { false },
            onCopyAgainShortcut: { false }
        )

        assert(forwardedEvents.isEmpty)
        assert(decision == .passthrough)
    }

    private static func testCopyAgainAcceptConsumes() {
        let result = ShortcutMatchResult(
            state: ShortcutInputState(),
            emittedEvents: [.copyAgainTriggered],
            consumeDecision: .consume
        )
        var forwardedEvents: [ShortcutEvent] = []

        let decision = HotkeyManager.dispatchShortcutMatchResult(
            result,
            onShortcutEvent: { forwardedEvents.append($0) },
            onRecordingCancelShortcut: { false },
            onCopyAgainShortcut: { true }
        )

        assert(forwardedEvents.isEmpty)
        assert(decision == .consume)
    }
}
