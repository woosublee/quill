# Meeting Reminder Animation Lifecycle Design

## Goal

Improve meeting reminder overlay transitions so recording and processing state changes animate inside one persistent SwiftUI tree instead of replacing the AppKit content view on every refresh. This should make existing `matchedGeometryEffect` transitions visible while preserving screen-geometry snap behavior from issue #112.

## Current root cause

`MeetingReminderOverlayManager.render(...)` currently creates a new `MeetingReminderOverlayViewModel`, a new `MeetingReminderOverlayRootView`, and a new `FixedHostingContainer` on each render. It then assigns the new container to `panel.contentView`.

The SwiftUI root view owns the `@Namespace` used by `matchedGeometryEffect`. Replacing the root view and content view during recording/processing refreshes means SwiftUI does not reliably see one continuous tree changing state. The transition can therefore feel like a redraw instead of an element movement.

## Design

### Persistent presentation host

Keep the presentation host alive while one reminder is visible:

- `panel: NSPanel?`
- `viewModel: MeetingReminderOverlayViewModel?`
- `contentContainer: FixedHostingContainer<AnyView>?`

The manager will create these objects only when a reminder first appears or after a previous reminder has been fully reset. While the same reminder remains visible, refreshes update the existing host.

### First presentation path

When no host exists:

1. Calculate `displayData` and target frame.
2. Create `MeetingReminderOverlayViewModel(displayData:)`.
3. Create `MeetingReminderOverlayRootView` once with that view model.
4. Wrap it in `FixedHostingContainer` and assign it to `panel.contentView`.
5. Show the panel with the existing entrance animation when `animated` is true.

### Existing presentation update path

When the host already exists:

1. Recalculate `displayData` and frame.
2. Update `viewModel.displayData` instead of replacing the view model.
3. Update `contentContainer.setFixedContentSize(frame.size)` so SwiftUI's fixed root size follows the AppKit panel.
4. Update the panel frame.
   - If the refresh is app-state driven, use the existing panel frame animation.
   - If the refresh comes from `didChangeScreenParametersNotification`, use `animated: false` and snap to the new frame.
5. Do not replace `panel.contentView` in this path.

This keeps the same SwiftUI tree and `@Namespace` alive across idle, recording, and processing variants for the same visible reminder.

### Reset path

When a reminder is dismissed and the hide animation completes, reset the presentation host:

- `panel.orderOut(nil)`
- `panel.alphaValue = 1`
- `panel.contentView = nil`
- `panel = nil`
- `viewModel = nil`
- `contentContainer = nil`

The next reminder starts with a fresh root view and namespace, preventing old meeting content or animation state from leaking into a different reminder.

### Screen geometry behavior

The screen-change path remains unanimated:

- `handleScreenParametersChanged()` continues to call `refreshVisibleReminder(animated: false)`.
- The visible host is reused, but the panel frame and fixed content size are updated without animation.
- This preserves the issue #112 behavior where display changes snap immediately to the new geometry.

## Testing

Add source-level regression tests in `MeetingReminderOverlayGeometryTests` to verify structure because visual animation timing is not practical to assert in the current `swiftc` test harness.

The tests should check that:

- `MeetingReminderOverlayManager` stores `contentContainer`.
- Existing refreshes update `viewModel.displayData`.
- Existing refreshes call `contentContainer.setFixedContentSize(frame.size)`.
- `panel.contentView = container` is limited to the host creation path, not every render.
- The reset path clears `panel`, `viewModel`, and `contentContainer`.
- `handleScreenParametersChanged()` still calls `refreshVisibleReminder(animated: false)`.

Run `make test` after implementation. Build and run the development app with `make run` to manually inspect the recording transition when a reminder is visible. If the local setup requires explicit signing, run `make run CODESIGN_IDENTITY="<YOUR_IDENTITY>"`. Actual visual quality still requires human inspection, but the structure should make matched geometry transitions possible.

## Non-goals

- No new visual design.
- No new motion style beyond making the existing matched-geometry transitions work.
- No changes to reminder scheduling, reminder queue policy, or calendar behavior.
- No change to the screen-change snap policy from issue #112.
