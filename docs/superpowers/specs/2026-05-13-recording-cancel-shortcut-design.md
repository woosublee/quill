# Recording Cancel Shortcut Design

**Goal:** Let users disable or change the shortcut that opens the recording cancellation confirmation, while keeping the current `Esc` behavior as the default.

**Context:** Today `GlobalShortcutBackend` special-cases key code `53` (`Esc`) and routes it through `onEscapeKeyPressed`. `AppState` consumes that key while recording, transcribing, or waiting on a toggle recording start, then shows the existing cancellation confirmation. This prevents `Esc` from reaching other apps during active recording sessions. Issue #89 asks for this cancel shortcut to be configurable or changeable separately from `Esc`.

## Approach

Add a dedicated recording cancel shortcut that uses the existing `ShortcutBinding` model.

- Add `recordingCancelShortcut` to `AppState`, with default value `Esc`.
- Allow the shortcut to be `Disabled`, `Esc`, or a custom `ShortcutBinding`.
- Persist both the selected cancel shortcut and the last custom cancel shortcut in `UserDefaults`.
- Generalize the hotkey path so cancel is matched by shortcut configuration instead of a hard-coded `Esc` callback.
- Keep the existing cancellation confirmation behavior and dialog copy.
- Add the setting inside the existing `Settings → Dictation Shortcuts` card.

## Behavior

The default behavior remains unchanged: pressing `Esc` during recording, transcription, or a pending toggle recording start opens the cancellation confirmation dialog and consumes the key event.

When the cancel shortcut is disabled, Quill does not consume `Esc` or any other cancel shortcut during recording. `Esc` remains available to the foreground app.

When the cancel shortcut is custom, Quill consumes only that configured shortcut while cancellation is applicable. Other keys, including `Esc`, pass through unless they are also part of the dictation hold/tap shortcut system.

The cancel shortcut has no effect and should not consume events when cancellation is not applicable. Cancellation is applicable only when `AppState.shouldConfirmEscapeCancellation` would currently return true: recording, transcribing, pending toggle start, or active toggle recording session.

## Architecture

### AppState

`AppState` owns the persisted setting and validation.

- `@Published var recordingCancelShortcut: ShortcutBinding`
- `@Published private(set) var savedRecordingCancelCustomShortcut: ShortcutBinding?`
- storage keys:
  - `recording_cancel_shortcut`
  - `saved_recording_cancel_custom_shortcut`
- default:
  - `ShortcutBinding.defaultRecordingCancel`, representing `Esc`

Add a setter such as `setRecordingCancelShortcut(_:) -> String?` that mirrors `setShortcut(_:for:)`.

Validation should reject cancel shortcuts that conflict with the hold or tap dictation shortcuts. A disabled cancel shortcut is always valid. Command-mode manual modifier collisions are not rejected because the cancel shortcut is a separate one-shot action and should only conflict when it shares the same full shortcut identity with hold or tap.

### Shortcut model

Extend the shortcut configuration and matcher rather than preserving a separate escape-only path.

- Add `recordingCancel: ShortcutBinding` to `ShortcutConfiguration`.
- Add a cancel event to the emitted shortcut event model, for example `ShortcutEvent.recordingCancelRequested`.
- Update matching so the cancel shortcut can emit a cancel event on key down or modifier activation, while still respecting `ShortcutBinding.disabled`.
- Do not emit cancel events for repeated keyDown events.
- Ensure unrelated key events remain passthrough.

This keeps shortcut matching in one place and removes the brittle assumption that recording cancellation is always `Esc`.

### HotkeyManager and GlobalShortcutBackend

`GlobalShortcutBackend` should stop treating `Esc` as a special global callback. Key code `53` should flow through the normal key event path so `ShortcutMatcher` can decide whether it belongs to the configured cancel shortcut.

`HotkeyManager` should expose a dedicated cancel callback, such as `onRecordingCancelShortcut: (() -> Bool)?`, where the returned Boolean decides whether the triggering event is consumed. Hold/tap shortcut events continue to use `onShortcutEvent`.

When `ShortcutMatcher` emits a cancel event, `HotkeyManager` asks the cancel callback before finalizing the consume decision. If `AppState` returns `true`, the triggering event is consumed and the existing cancellation alert is presented. If `AppState` returns `false`, the cancel event is dropped and the key event passes through unless a hold/tap shortcut also requires consumption. This makes the app-state-dependent passthrough behavior explicit while still matching cancel through the shared shortcut model.

## Settings UI

Add a `Recording Cancel Shortcut` section under `Dictation Shortcuts`, below the hold/tap editor and above `Shortcut Start Delay`.

The section contains:

1. `Disabled`
2. `Esc`
3. `Custom Shortcut`

The section description should explain the trade-off:

> While recording or transcribing, this shortcut opens the cancel confirmation dialog. Disable it if you want Esc to keep working in other apps.

The UI should show validation errors below the section, using the same visual style as existing shortcut validation. The likely validation message is:

> Cancel shortcut must be distinct from dictation shortcuts.

Prefer a focused `RecordingCancelShortcutSection` that reuses the existing row style and capture behavior where practical. Do not refactor the entire hold/tap shortcut editor unless the implementation requires a small extraction to avoid duplicated capture code.

## Data flow

1. App launches.
2. `AppState` loads hold, tap, and cancel shortcuts from `UserDefaults`.
3. Missing or invalid cancel shortcut data falls back to `Esc`.
4. `AppState.activeShortcutConfiguration` includes hold, tap, and recording cancel shortcuts.
5. Hotkey monitoring starts with the full shortcut configuration.
6. User presses a key while recording.
7. `GlobalShortcutBackend` forwards the key through normal shortcut input events.
8. `ShortcutMatcher` determines whether hold, tap, or cancel matched.
9. For hold/tap events, `AppState` receives the emitted shortcut event through `onShortcutEvent`.
10. For cancel events, `HotkeyManager` calls the dedicated cancel callback.
11. `AppState` checks whether cancellation is applicable.
12. If applicable, Quill shows the existing confirmation dialog and returns `true` so the event is consumed.
13. If not applicable, Quill returns `false` so the event passes through unless another shortcut matched.

## Error handling

- Missing stored cancel shortcut: default to `Esc`.
- Undecodable stored cancel shortcut: default to `Esc`.
- Disabled cancel shortcut: never consume events for cancellation.
- Conflict with hold/tap shortcut: do not commit the new cancel shortcut and show validation text.
- Event tap unavailable: preserve existing hotkey monitoring error behavior.
- Existing cancellation dialog already visible: do not open another dialog and do not consume unrelated events.

## Testing

Add or update tests in the existing `swiftc`-driven test suite.

### Shortcut matcher tests

Cover:

- Disabled cancel shortcut does not emit cancel or consume.
- Default `Esc` cancel shortcut emits cancel on `Esc` keyDown.
- Default `Esc` cancel shortcut ignores repeated keyDown.
- Custom cancel shortcut emits cancel only for the configured key/modifier combination.
- Unrelated keys pass through.
- Matched cancel shortcut passes through when the cancel callback declines consumption.
- Hold/tap behavior still works with cancel configured.

### AppState settings tests

Cover:

- Missing stored cancel shortcut loads as `Esc`.
- Disabled cancel shortcut persists and reloads.
- Custom cancel shortcut persists and reloads.
- A cancel shortcut conflicting with hold or tap is rejected.
- Changing cancel shortcut restarts hotkey monitoring through the existing published setting path.

### Manual verification

- Default settings: start recording, press `Esc`, confirm the cancellation dialog appears.
- Disabled setting: start recording, press `Esc`, confirm Quill does not show its cancellation dialog.
- Custom setting: set a custom cancel shortcut, start recording, press that shortcut, confirm the cancellation dialog appears.
- Run `make test`.

## Non-goals

- Do not change the confirmation dialog behavior beyond removing the hard-coded `Esc` assumption.
- Do not change hold/tap dictation shortcut semantics.
- Do not add a separate setup wizard step for the cancel shortcut.
- Do not migrate existing users away from `Esc`; the default remains `Esc` for both new and existing installs.
