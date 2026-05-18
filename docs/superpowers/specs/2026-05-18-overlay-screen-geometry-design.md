# Overlay Screen Geometry Design

## Goal

Meeting reminder overlays should immediately re-layout when display geometry changes, and both recording overlays and meeting reminder overlays should interpret screen geometry through the same model. This fixes issue #112 and reduces future divergence around notches, menu bars, visible frames, scaling, rotation, and external display changes.

## Current root cause

`RecordingOverlayManager` observes `NSApplication.didChangeScreenParametersNotification` and recomputes its panel frame when the active screen configuration changes. `MeetingReminderOverlayManager` can re-render an existing reminder, but it does not observe screen-parameter changes. A visible reminder can therefore keep the old panel frame until another app state transition refreshes it.

The two overlay systems also calculate screen geometry separately. Recording overlay code already accounts for screen frame, visible frame, safe-area, and notch auxiliary areas. Meeting reminder geometry mostly derives from `screen.frame`, which makes future notch and visible-frame edge cases easier to miss.

## Design

### Shared geometry model

Add `OverlayScreenGeometry` in `Sources/OverlayScreenGeometry.swift`. It will be initialized from `NSScreen` and expose the screen facts needed by top overlays:

- `screenFrame`
- `visibleFrame`
- `hasNotchGeometry`
- `notchOverlap`
- `notchSideGeometry(regionWidth:panelHeight:horizontalInset:)`
- `centeredTopFrame(width:height:)`

The shared type owns generic screen interpretation. Overlay-specific types keep only overlay policy.

### Recording overlay changes

`RecordingOverlayManager` will build an `OverlayScreenGeometry` from `NSScreen.main` when computing layout. Existing recording-specific decisions stay in `RecordingOverlayGeometry`, including phase eligibility, locked transcribing width, and width selection.

The current generic helpers `RecordingOverlayGeometry.notchSideGeometry(...)` and `RecordingOverlayGeometry.centeredFrame(...)` will move to the shared geometry model. Recording overlay tests will be updated to assert the same geometry through the new shared API.

### Meeting reminder overlay changes

`MeetingReminderOverlayGeometry` will keep variant and size decisions, but frame calculation will use `OverlayScreenGeometry` instead of interpreting `NSScreen` directly. The reminder overlay will therefore use the same top-centered and notch-side frame semantics as the recording overlay.

`MeetingReminderOverlayManager` will add a `screenParametersObserver`. On `NSApplication.didChangeScreenParametersNotification`, it will refresh the visible reminder without animation so display attach/detach, scaling, rotation, or visible-frame changes snap to the new geometry instead of playing a reminder entrance animation.

The existing public `refreshVisibleReminder()` behavior remains animated for app-state transitions such as recording and transcribing changes. Internally this can delegate to an overload that accepts `animated`.

## Data flow

1. A reminder is queued and shown.
2. The manager asks its `screenProvider` for the current `NSScreen`.
3. The screen is converted to `OverlayScreenGeometry`.
4. `MeetingReminderOverlayGeometry` determines variant, size, center recording width, and final frame from the shared geometry.
5. If AppKit posts `didChangeScreenParametersNotification` while a reminder is visible, the manager repeats the render path with `animated: false`.
6. Recording overlay continues to recompute its frame on the same notification, now using the same shared screen interpretation.

## Error handling and edge cases

- If there is no screen, reminder presentation continues to fail without marking the reminder as presented.
- If a screen has no valid notch auxiliary geometry, notch-side layout falls back to centered/default behavior as it does today.
- If a screen parameter change occurs with no visible reminder, the refresh is a no-op.
- The screen observer is removed in `deinit`, matching the recording overlay manager pattern.

## Tests

Add or update tests to cover:

- Shared centered top frame calculation responds to changed screen frame.
- Shared notch-side geometry preserves the existing frame/content-frame expectations from recording overlay tests.
- Shared `notchOverlap` reflects the gap between `screenFrame.maxY` and `visibleFrame.maxY`.
- Recording overlay tests use `OverlayScreenGeometry` for generic geometry assertions while keeping recording-specific tests intact.
- Meeting reminder frame calculation changes when the supplied screen geometry changes.
- Meeting reminder source has a screen-parameter observer and unanimated screen-change refresh path.
- Existing meeting reminder notch sizing tests continue to protect the #115 behavior.

## Verification

Run `make test` after implementation. If possible, build the app and manually inspect the reminder overlay path; actual monitor attach/detach coverage depends on the local environment and should be reported separately from automated verification.
