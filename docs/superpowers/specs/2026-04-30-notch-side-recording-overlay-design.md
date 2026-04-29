# Notch-side recording overlay design

## Goal

Reduce how often Quill's recording overlay blocks clicks in the active app by allowing the recording UI to use the MacBook notch's left and right top auxiliary areas instead of the current centered, below-notch overlay.

This should be optional and easy to disable. The existing centered overlay remains the default behavior.

## Scope

This design applies only to the recording phase.

- Recording on notch displays can use the new notch-side layout.
- Initializing, transcribing/processing, failure feedback, and update-available overlays keep the existing centered layout.
- Non-notch displays keep the existing centered layout.
- Existing concurrent recording/transcription ownership behavior must remain unchanged.

## User setting

Add a persistent setting for recording overlay placement.

Suggested storage key: `recording_overlay_layout`

Supported values:

- `centered` — existing centered overlay, default
- `notchSides` — recording waveform on the left side of the notch and stop affordance on the right side

Settings UI should expose this as a simple picker, for example:

- Label: `Recording Overlay Layout`
- Options: `Centered`, `Notch Sides`
- Help text: `Notch Sides applies only while recording on MacBooks with a notch. Other states and displays use the centered overlay.`

The default must be `centered` so disabling or reverting the feature restores the current behavior without migration risk.

## Layout behavior

### Centered layout

The current implementation remains the fallback and default path:

- Single centered `NSPanel`
- Current `overlayFrame` and `overlayWidth` behavior
- Existing below-notch vertical placement
- Existing transcribing, feedback, and update content

### Notch-side recording layout

When all of the following are true, recording uses the notch-side layout:

- setting is `notchSides`
- overlay phase is `.recording`
- the current screen has a notch/safe top area
- both `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` are available

The layout uses one transparent panel spanning the top notch area. Visible content is split into balanced left and right regions:

- Left region: recording waveform / command mode indicator if applicable
- Right region: stop button in toggle mode
- Hold mode: right region remains visually balanced but does not show a stop button

Left and right visible regions should use the same width. Use the smaller available side width as the maximum cap so the layout is visually symmetric around the notch.

The panel may span across the notch gap for simpler animation and layout. This may overlap menu bar hit-testing, but that is acceptable for this iteration because menu bar interaction during recording is not a primary workflow.

## Screen and fallback rules

Use `NSScreen` information already available in `RecordingOverlayManager`:

- `safeAreaInsets.top` to infer notch/safe-area presence
- `auxiliaryTopLeftArea` for the usable top-left area
- `auxiliaryTopRightArea` for the usable top-right area

If notch-side geometry is unavailable or too small, fall back to the centered layout.

External displays and non-notch Macs must use the centered layout.

`NSScreen.main` can remain the first implementation target. More precise active-screen selection can be handled separately if needed.

## Architecture

Keep the existing centered overlay code path intact and add a separate layout calculation path for recording-only notch-side placement.

Recommended structure:

- Add `RecordingOverlayLayout` enum.
- Store selected layout in `AppState` via UserDefaults.
- Pass the selected layout into `RecordingOverlayManager` before or during overlay display.
- Add a helper that decides whether notch-side layout is active for the current state.
- Add separate frame/content helpers for notch-side recording layout.
- Leave transcribing and feedback helpers on the existing centered path.

The implementation should avoid rewriting the entire overlay manager. The feature should be removable by deleting the setting, the notch-side layout helper, and the settings UI while leaving the centered path unchanged.

## Interaction behavior

Mouse-event behavior should match the existing intent:

- Hold-mode recording overlay should not need to accept mouse events.
- Toggle-mode recording overlay must allow the stop button to be clicked.
- Update overlay keeps existing centered behavior and click handling.

If using a single transparent panel causes too much menu bar click interception in practice, a follow-up can split the layout into two panels. That is not part of the initial implementation.

## Concurrent transcription safety

This feature must not change transcription ownership semantics.

Do not change:

- `activeTranscriptionJobs`
- `foregroundTranscriptionJobID`
- `overlayTranscriptionID`
- `prepareTranscribingOverlay(for: overlayID, ...)`
- transcribing completion/cancellation ownership checks

Because the notch-side layout applies only to `.recording`, it should not allow background transcription jobs to control recording UI or dismiss the active overlay.

## Testing and verification

Required verification:

1. Build with the Makefile-based build path.
2. Run the built app, not just compile it.
3. With default `Centered`, confirm the recording overlay behaves as before.
4. Switch to `Notch Sides` and confirm recording waveform appears on the left side of the notch.
5. In toggle recording mode, confirm the stop button appears on the right side and is clickable.
6. Confirm hold recording mode does not show a stop button.
7. Stop recording and confirm transcribing/processing uses the existing centered overlay.
8. Confirm failure feedback still uses the existing centered overlay.
9. If possible, verify external display or non-notch fallback uses the centered overlay.
10. Start a new recording while an older transcription is still processing and confirm overlay ownership does not regress.

## Out of scope

- Replacing Quill's processing indicator design.
- Integrating upstream `features/better-loader`.
- Adding multiple visual themes for the recording waveform.
- Multi-screen active-window-aware overlay placement.
- Switching to two separate overlay panels in the first iteration.
