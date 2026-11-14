import Foundation

@main
struct ShortcutCoreTests {
    static func main() {
        testBareFnHoldLifecycle()
        testDefaultShortcutSpecificityOrdering()
        testRightOptionPresetIsSideSpecific()
        testExactModifierMatching()
        testReducerHonorsExactModifierMatching()
        testRepeatedKeyDownDoesNotReactivate()
        testPasteAgainFiresOnLeadingEdgeOnly()
        testBackendResetClearsActiveBindings()
        testBindingMigrationAndIdentity()
        testPickersListEveryNonCustomSelection()
        testConflictDetection()
        testHoldSessionControllerLifecycle()
        testToggleSessionControllerLifecycle()
        testHoldToToggleSessionControllerLifecycle()
        testDoubleTapIsOffByDefault()
        testDoubleTapLatchesAndHoldShortcutStops()
        testDoubleTapLatchedSessionStopsOnFirstToggleShortcutPress()
        testSingleTapStopsWhenDoubleTapWindowExpires()
        testLongHoldStopsImmediatelyWithDoubleTapEnabled()
        testToggleStartedSessionIgnoresHoldShortcut()
        testDoubleTapModifierChordThroughMatcher()
        testShortcutPostProcessingPreferenceDefaultsToTheSwitch()
        testShortcutPostProcessingPreferenceRoundTrips()
        testShortcutPostProcessingOverrideFollowsTheStartingShortcut()
        print("ShortcutCoreTests passed")
    }

    /// #517: a picker must show exactly one row for any non-custom
    /// selection. Tap to Toggle's Fn + Command default and older preset +
    /// Command toggles match no preset row.
    private static func testPickersListEveryNonCustomSelection() {
        let roles: [ShortcutRole] = [.hold, .toggle, .copyAgain]
        var selections: [ShortcutBinding] = [.defaultHold, .defaultToggle]
        for preset in ShortcutPreset.allCases {
            selections.append(preset.binding)
            selections.append(preset.binding.withAddedModifiers(.command))
        }
        for role in roles {
            for selection in selections {
                let rows = role.pickerBindings(selection: selection)
                expectEqual(rows.filter { $0.id == selection.id }.count, 1)
            }
            let presetRows = role.pickerBindings(selection: .disabled)
            expectEqual(Array(presetRows.prefix(ShortcutPreset.allCases.count)), ShortcutPreset.allCases.map(\.binding))
        }

        // The toggle default stays offered after picking something else.
        expectEqual(ShortcutRole.toggle.pickerBindings(selection: .disabled).contains(.defaultToggle), true)
        expectEqual(ShortcutRole.hold.pickerBindings(selection: .disabled).contains(.defaultToggle), false)

        // Custom and disabled selections belong to their own rows.
        let custom = ShortcutBinding(keyCode: 49, keyDisplay: "Space", modifiers: [.control], kind: .key, preset: nil)
        expectEqual(ShortcutRole.toggle.pickerBindings(selection: custom).contains(custom), false)
        expectEqual(ShortcutRole.toggle.pickerBindings(selection: .disabled).contains(.disabled), false)

        expectEqual(ShortcutRole.recordingCancel.pickerBindings(selection: .defaultRecordingCancel), [])

        // A stored preset whose display text differs keeps its preset row.
        let fn = ShortcutPreset.fnKey.binding
        let olderFn = ShortcutBinding(keyCode: fn.keyCode, keyDisplay: "Fn 🌐", modifiers: fn.modifiers, kind: fn.kind, preset: .fnKey)
        let olderFnRows = ShortcutRole.hold.pickerBindings(selection: olderFn)
        expectEqual(olderFnRows.count, ShortcutPreset.allCases.count)
        expectEqual(olderFnRows.filter { $0.id == olderFn.id }.count, 1)

        // The menu disables rows by conflict, as setShortcut checks; the
        // default pair must stay pickable together.
        expectEqual(ShortcutBinding.defaultToggle.conflicts(with: .defaultHold), false)
        expectEqual(ShortcutBinding.defaultHold.conflicts(with: .defaultToggle), false)
        expectEqual(olderFn.conflicts(with: fn), true)

        // Fn + Command no longer reads as plain Fn.
        expectEqual(ShortcutBinding.defaultHold.selectionTitle, ShortcutPreset.fnKey.title)
        expectEqual(ShortcutBinding.defaultToggle.selectionTitle, ShortcutBinding.defaultToggle.displayName)
    }

    private static func testBareFnHoldLifecycle() {
        let configuration = ShortcutConfiguration(hold: .defaultHold, toggle: .disabled)
        let down = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 63, isDown: true),
            configuration: configuration
        )
        let up = ShortcutMatcher.reduce(
            state: down.state,
            event: .modifierChanged(keyCode: 63, isDown: false),
            configuration: configuration
        )

        expectEqual(down.emittedEvents, [.holdActivated])
        expectEqual(down.consumeDecision, .consume)
        expectEqual(up.emittedEvents, [.holdDeactivated])
        expectEqual(up.consumeDecision, .consume)
    }

    private static func testDefaultShortcutSpecificityOrdering() {
        let configuration = ShortcutConfiguration(
            hold: .defaultHold,
            toggle: .defaultToggle
        )
        let commandDown = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 55, isDown: true),
            configuration: configuration
        )
        let fnDown = ShortcutMatcher.reduce(
            state: commandDown.state,
            event: .modifierChanged(keyCode: 63, isDown: true),
            configuration: configuration
        )
        let fnUp = ShortcutMatcher.reduce(
            state: fnDown.state,
            event: .modifierChanged(keyCode: 63, isDown: false),
            configuration: configuration
        )

        expectEqual(fnDown.emittedEvents, [.toggleActivated, .holdActivated])
        expectEqual(fnUp.emittedEvents, [.holdDeactivated, .toggleDeactivated])
    }

    private static func testRightOptionPresetIsSideSpecific() {
        let configuration = ShortcutConfiguration(
            hold: ShortcutPreset.rightOption.binding,
            toggle: .disabled
        )
        let leftOption = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 58, isDown: true),
            configuration: configuration
        )
        let rightOption = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 61, isDown: true),
            configuration: configuration
        )

        expectEqual(leftOption.emittedEvents, [])
        expectEqual(rightOption.emittedEvents, [.holdActivated])
    }

    private static func testExactModifierMatching() {
        expect(
            ShortcutBinding.exactModifierKeyCodesMatch([54], exactModifierKeyCodes: [54, 55]),
            "A generic Command binding should accept Right Command"
        )
        expect(
            ShortcutBinding.exactModifierKeyCodesMatch([55], exactModifierKeyCodes: [54, 55]),
            "A generic Command binding should accept Left Command"
        )
        expect(
            !ShortcutBinding.exactModifierKeyCodesMatch([55, 56], exactModifierKeyCodes: [55]),
            "Unexpected Shift should invalidate an exact Command binding"
        )
        expect(
            ShortcutBinding.exactModifierKeyCodesMatch(
                [55, 56],
                exactModifierKeyCodes: [55],
                permittedAdditionalExactMatchModifiers: [.shift]
            ),
            "Explicitly permitted Shift should not invalidate an exact Command binding"
        )
    }

    private static func testReducerHonorsExactModifierMatching() {
        let binding = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [.command],
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [55]
        )

        let rightCommandState = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 54, isDown: true),
            configuration: ShortcutConfiguration(hold: binding, toggle: .disabled)
        ).state
        let rightCommandKey = ShortcutMatcher.reduce(
            state: rightCommandState,
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
            configuration: ShortcutConfiguration(hold: binding, toggle: .disabled)
        )
        expectEqual(rightCommandKey.emittedEvents, [])

        let leftCommandState = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 55, isDown: true),
            configuration: ShortcutConfiguration(hold: binding, toggle: .disabled)
        ).state
        let leftCommandKey = ShortcutMatcher.reduce(
            state: leftCommandState,
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
            configuration: ShortcutConfiguration(hold: binding, toggle: .disabled)
        )
        expectEqual(leftCommandKey.emittedEvents, [.holdActivated])

        let shiftedState = ShortcutMatcher.reduce(
            state: leftCommandState,
            event: .modifierChanged(keyCode: 56, isDown: true),
            configuration: ShortcutConfiguration(hold: binding, toggle: .disabled)
        ).state
        let shiftedKey = ShortcutMatcher.reduce(
            state: shiftedState,
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
            configuration: ShortcutConfiguration(hold: binding, toggle: .disabled)
        )
        expectEqual(shiftedKey.emittedEvents, [])

        let permittedConfiguration = ShortcutConfiguration(
            hold: binding,
            toggle: .disabled,
            permittedAdditionalExactMatchModifiers: [.shift]
        )
        let permittedKey = ShortcutMatcher.reduce(
            state: shiftedState,
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
            configuration: permittedConfiguration
        )
        expectEqual(permittedKey.emittedEvents, [.holdActivated])
    }

    private static func testRepeatedKeyDownDoesNotReactivate() {
        let binding = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [],
            kind: .key,
            preset: nil
        )
        let configuration = ShortcutConfiguration(hold: binding, toggle: .disabled)
        let first = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
            configuration: configuration
        )
        let repeated = ShortcutMatcher.reduce(
            state: first.state,
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: true),
            configuration: configuration
        )

        expectEqual(first.emittedEvents, [.holdActivated])
        expectEqual(repeated.emittedEvents, [])
        expectEqual(repeated.state, first.state)
        expectEqual(repeated.consumeDecision, .consume)
    }

    private static func testPasteAgainFiresOnLeadingEdgeOnly() {
        let binding = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [],
            kind: .key,
            preset: nil
        )
        let configuration = ShortcutConfiguration(hold: .disabled, toggle: .disabled, copyAgain: binding)
        let firstDown = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
            configuration: configuration
        )
        let repeated = ShortcutMatcher.reduce(
            state: firstDown.state,
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: true),
            configuration: configuration
        )
        let up = ShortcutMatcher.reduce(
            state: repeated.state,
            event: .keyChanged(keyCode: 96, isDown: false, isRepeat: false),
            configuration: configuration
        )
        let secondDown = ShortcutMatcher.reduce(
            state: up.state,
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
            configuration: configuration
        )

        expectEqual(firstDown.emittedEvents, [.copyAgainTriggered])
        expectEqual(repeated.emittedEvents, [])
        expectEqual(up.emittedEvents, [])
        expectEqual(secondDown.emittedEvents, [.copyAgainTriggered])
    }

    private static func testBackendResetClearsActiveBindings() {
        let configuration = ShortcutConfiguration(hold: .defaultHold, toggle: .defaultToggle)
        let commandDown = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 55, isDown: true),
            configuration: configuration
        )
        let fnDown = ShortcutMatcher.reduce(
            state: commandDown.state,
            event: .modifierChanged(keyCode: 63, isDown: true),
            configuration: configuration
        )
        let reset = ShortcutMatcher.reduce(
            state: fnDown.state,
            event: .backendReset,
            configuration: configuration
        )

        expectEqual(reset.emittedEvents, [.holdDeactivated, .toggleDeactivated])
        expectEqual(reset.consumeDecision, .passthrough)
        expect(reset.state.pressedKeyCodes.isEmpty, "Backend reset should clear pressed keys")
        expect(reset.state.pressedModifierKeyCodes.isEmpty, "Backend reset should clear modifiers")
        expect(!reset.state.holdIsActive && !reset.state.toggleIsActive, "Backend reset should clear active bindings")
    }

    private static func testBindingMigrationAndIdentity() {
        let stored = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [],
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [999, 61]
        )
        let normalized = stored.normalizedForStorageMigration()
        expectEqual(normalized.exactModifierKeyCodes, [61])
        expectEqual(normalized.modifiers, [.option])

        let first = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [.command, .option],
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [55, 58]
        )
        let second = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [.option, .command],
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [58, 55]
        )
        expectEqual(first.id, second.id)
    }

    private static func testConflictDetection() {
        let first = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [.command],
            kind: .key,
            preset: nil
        )
        let same = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [.command],
            kind: .key,
            preset: nil
        )
        let different = ShortcutBinding(
            keyCode: 97,
            keyDisplay: "F6",
            modifiers: [.command],
            kind: .key,
            preset: nil
        )

        expect(first.conflicts(with: same), "Equivalent bindings should conflict")
        expect(same.conflicts(with: first), "Conflict detection should be symmetric")
        expect(!first.conflicts(with: different), "Different primary keys should not conflict")
        expect(!first.conflicts(with: .disabled), "Disabled bindings should not conflict")
    }

    private static func testHoldSessionControllerLifecycle() {
        let controller = DictationShortcutSessionController()
        expectEqual(controller.handle(event: .holdActivated, isTranscribing: true), .start(.hold))
        controller.reset()
        expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .start(.hold))
        expectEqual(controller.handle(event: .holdDeactivated, isTranscribing: false), .stop)
        expectEqual(controller.activeMode, nil)
    }

    private static func testToggleSessionControllerLifecycle() {
        let controller = DictationShortcutSessionController()
        expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), .start(.toggle))
        expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), nil)
        expectEqual(controller.handle(event: .toggleDeactivated, isTranscribing: false), nil)
        expectEqual(controller.toggleStopArmed, true)
        expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), .stop)
        expectEqual(controller.activeMode, nil)
    }

    private static func testHoldToToggleSessionControllerLifecycle() {
        let controller = DictationShortcutSessionController()
        expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .start(.hold))
        expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), .switchedToToggle)
        expectEqual(controller.handle(event: .holdDeactivated, isTranscribing: false), nil)
        expectEqual(controller.activeMode, .toggle)
        expectEqual(controller.handle(event: .copyAgainTriggered, isTranscribing: false), nil)
        controller.beginManual(mode: .hold)
        expectEqual(controller.activeMode, .hold)
        controller.forceToggleMode()
        expectEqual(controller.activeMode, .toggle)
        controller.reset()
        expectEqual(controller.activeMode, nil)
        expectEqual(controller.toggleStopArmed, false)
    }

    private static func doubleTapHandle(
        _ controller: DictationShortcutSessionController,
        _ event: ShortcutEvent,
        at now: TimeInterval
    ) -> DictationShortcutAction? {
        controller.handle(event: event, isTranscribing: false, doubleTapToToggleEnabled: true, now: now)
    }

    private static func testDoubleTapIsOffByDefault() {
        let controller = DictationShortcutSessionController()
        expectEqual(controller.handle(event: .holdActivated, isTranscribing: false, now: 0), .start(.hold))
        expectEqual(controller.handle(event: .holdDeactivated, isTranscribing: false, now: 0.1), .stop)
        expectEqual(controller.handle(event: .holdActivated, isTranscribing: false, now: 0.2), .start(.hold))
    }

    private static func testDoubleTapLatchesAndHoldShortcutStops() {
        let controller = DictationShortcutSessionController()
        expectEqual(doubleTapHandle(controller, .holdActivated, at: 0), .start(.hold))
        expectEqual(
            doubleTapHandle(controller, .holdDeactivated, at: 0.1),
            .awaitDoubleTap(DictationShortcutSessionController.doubleTapWindow)
        )
        expectEqual(controller.activeMode, .hold)
        expectEqual(doubleTapHandle(controller, .holdActivated, at: 0.2), .switchedToToggle)
        expectEqual(controller.activeMode, .toggle)
        expectEqual(controller.handleDoubleTapTimeout(), nil)
        expectEqual(doubleTapHandle(controller, .holdDeactivated, at: 0.3), nil)
        expectEqual(controller.activeMode, .toggle)
        expectEqual(doubleTapHandle(controller, .holdActivated, at: 5), .stop)
        expectEqual(controller.activeMode, nil)
        expectEqual(doubleTapHandle(controller, .holdDeactivated, at: 5.1), nil)
    }

    private static func testDoubleTapLatchedSessionStopsOnFirstToggleShortcutPress() {
        let controller = DictationShortcutSessionController()
        _ = doubleTapHandle(controller, .holdActivated, at: 0)
        _ = doubleTapHandle(controller, .holdDeactivated, at: 0.1)
        _ = doubleTapHandle(controller, .holdActivated, at: 0.2)
        _ = doubleTapHandle(controller, .holdDeactivated, at: 0.3)
        expectEqual(doubleTapHandle(controller, .toggleActivated, at: 5), .stop)
    }

    private static func testSingleTapStopsWhenDoubleTapWindowExpires() {
        let controller = DictationShortcutSessionController()
        _ = doubleTapHandle(controller, .holdActivated, at: 0)
        _ = doubleTapHandle(controller, .holdDeactivated, at: 0.1)
        expectEqual(controller.handleDoubleTapTimeout(), .stop)
        expectEqual(controller.activeMode, nil)
        expectEqual(controller.handleDoubleTapTimeout(), nil)
    }

    private static func testLongHoldStopsImmediatelyWithDoubleTapEnabled() {
        let controller = DictationShortcutSessionController()
        _ = doubleTapHandle(controller, .holdActivated, at: 0)
        expectEqual(doubleTapHandle(controller, .holdDeactivated, at: 1), .stop)
    }

    private static func testToggleStartedSessionIgnoresHoldShortcut() {
        let controller = DictationShortcutSessionController()
        _ = doubleTapHandle(controller, .toggleActivated, at: 0)
        expectEqual(doubleTapHandle(controller, .holdActivated, at: 1), nil)
        expectEqual(doubleTapHandle(controller, .holdDeactivated, at: 1.1), nil)
        expectEqual(doubleTapHandle(controller, .holdActivated, at: 2), nil)
        expectEqual(controller.activeMode, .toggle)
    }

    /// Option stays down while only the grave key is tapped twice.
    private static func testDoubleTapModifierChordThroughMatcher() {
        let optionKeyCode: UInt16 = 58
        let graveKeyCode: UInt16 = 50
        let configuration = ShortcutConfiguration(
            hold: ShortcutBinding(keyCode: graveKeyCode, keyDisplay: "`", modifiers: [.option], kind: .key, preset: nil),
            toggle: .disabled
        )
        let controller = DictationShortcutSessionController()
        var state = ShortcutInputState()
        var actions: [DictationShortcutAction] = []
        var now: TimeInterval = 0

        let inputs: [ShortcutInputEvent] = [
            .modifierChanged(keyCode: optionKeyCode, isDown: true),
            .keyChanged(keyCode: graveKeyCode, isDown: true, isRepeat: false),
            .keyChanged(keyCode: graveKeyCode, isDown: false, isRepeat: false),
            .keyChanged(keyCode: graveKeyCode, isDown: true, isRepeat: false),
            .keyChanged(keyCode: graveKeyCode, isDown: false, isRepeat: false),
            .modifierChanged(keyCode: optionKeyCode, isDown: false),
        ]
        for input in inputs {
            let result = ShortcutMatcher.reduce(state: state, event: input, configuration: configuration)
            state = result.state
            for event in result.emittedEvents {
                if let action = doubleTapHandle(controller, event, at: now) {
                    actions.append(action)
                }
            }
            now += 0.1
        }

        expectEqual(actions, [
            .start(.hold),
            .awaitDoubleTap(DictationShortcutSessionController.doubleTapWindow),
            .switchedToToggle,
        ])
        expectEqual(controller.activeMode, .toggle)
    }

    /// #347: an unset or unknown choice follows the Post-processing switch.
    private static func testShortcutPostProcessingPreferenceDefaultsToTheSwitch() {
        let suite = "ShortcutCoreTests.postProcessing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        expectEqual(
            ShortcutPostProcessingPreference.load(
                from: defaults,
                key: ShortcutPostProcessingPreference.holdStorageKey
            ),
            .inherit
        )
        defaults.set("preserveExactWording", forKey: ShortcutPostProcessingPreference.toggleStorageKey)
        expectEqual(
            ShortcutPostProcessingPreference.load(
                from: defaults,
                key: ShortcutPostProcessingPreference.toggleStorageKey
            ),
            .inherit
        )
    }

    private static func testShortcutPostProcessingPreferenceRoundTrips() {
        let suite = "ShortcutCoreTests.postProcessing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        expect(
            ShortcutPostProcessingPreference.holdStorageKey
                != ShortcutPostProcessingPreference.toggleStorageKey,
            "each shortcut keeps its own choice"
        )
        for mode in [RecordingTriggerMode.hold, .toggle] {
            let key = ShortcutPostProcessingPreference.storageKey(for: mode)
            for preference in ShortcutPostProcessingPreference.allCases {
                preference.save(to: defaults, key: key)
                expectEqual(ShortcutPostProcessingPreference.load(from: defaults, key: key), preference)
            }
        }
    }

    private static func testShortcutPostProcessingOverrideFollowsTheStartingShortcut() {
        // A recording not started by a dictation shortcut follows the switch.
        expectEqual(
            ShortcutPostProcessingPreference.override(startedBy: nil, hold: .off, toggle: .on),
            nil as Bool?
        )
        // Each shortcut uses its own choice.
        expectEqual(
            ShortcutPostProcessingPreference.override(startedBy: .hold, hold: .off, toggle: .on),
            false as Bool?
        )
        expectEqual(
            ShortcutPostProcessingPreference.override(startedBy: .toggle, hold: .off, toggle: .on),
            true as Bool?
        )
        // Follow Post-processing leaves the switch in charge.
        expectEqual(
            ShortcutPostProcessingPreference.override(startedBy: .hold, hold: .inherit, toggle: .off),
            nil as Bool?
        )
        expectEqual(
            ShortcutPostProcessingPreference.override(startedBy: .toggle, hold: .on, toggle: .inherit),
            nil as Bool?
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T) {
        precondition(
            actual == expected,
            "Expected \(String(describing: expected)), got \(String(describing: actual))"
        )
    }
}
