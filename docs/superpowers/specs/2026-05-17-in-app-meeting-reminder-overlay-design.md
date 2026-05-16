# In-app meeting reminder overlay design

## Context

GitHub issue #98 asks Quill to make in-app calendar recording reminders the primary reminder experience while the app is running. The existing reminder path schedules macOS local notifications through `CalendarRecordingReminderScheduler` and starts recording through `AppNotificationManager` when a user clicks a notification.

The first implementation should add an in-app overlay with one-click recording while preserving macOS notifications as the fallback when Quill is not running or cannot present its own UI.

## Goals

- Show a Quill in-app meeting reminder overlay when a due calendar recording reminder is handled while the app is running.
- Keep macOS local notifications scheduled as a fallback so reminders still work if Quill exits before the reminder fires.
- Let the user start a normal recording from the overlay with one click.
- Let the user dismiss only the currently shown reminder.
- Queue simultaneous reminders and show them one at a time.
- Show reminder information even if a recording is already active, without interrupting or replacing the current recording.
- Preserve the existing calendar note-title suggestion flow for recordings started from the overlay.

## Non-goals

- Do not add snooze.
- Do not open the calendar event from the overlay.
- Do not add per-calendar reminder controls from the overlay.
- Do not add backend calendar sync or push delivery while Quill is closed.
- Do not make overlay-started recordings use special calendar matching metadata in this pass.
- Do not auto-apply calendar titles for overlay-started recordings.

## Architecture

Add a dedicated `MeetingReminderOverlayManager` rather than extending `RecordingOverlayManager`. The new manager owns only meeting reminder state, queueing, and the reminder `NSPanel`.

The existing recording overlay remains responsible for recording, initializing, transcribing, feedback, and update states. This keeps meeting reminder UI separate from recording overlay ownership and avoids coupling reminder queue state to transcription state.

Recommended structure:

- `MeetingReminderOverlayManager`
  - owns a non-activating `NSPanel`;
  - displays one reminder at a time;
  - queues additional reminder schedules;
  - calls `onStart(schedule)` or `onDismiss(schedule)`.
- `MeetingReminderOverlayView`
  - renders the compact flush-top black island UI;
  - accepts display data: meeting title, start time, relative time, and recording state.
- `CalendarRecordingReminderScheduler`
  - keeps existing reminder planning and macOS notification scheduling;
  - accepts an optional in-app presenter;
  - maintains an in-app due timer for scheduled reminders while Quill is running;
  - routes due/immediate reminders to the presenter first when possible;
  - removes only the pending macOS notification for reminders that were actually shown in-app.
- `AppState`
  - wires the presenter to `MeetingReminderOverlayManager`;
  - starts normal recording when the overlay Start action is pressed;
  - exposes current recording state so the overlay can show a non-starting state while recording.

## Overlay visual design

Use the approved compact unified island design for non-recording reminders, and expand from the active recording overlay layout when recording or processing is active. The backed-up visual matrix is in `docs/superpowers/specs/2026-05-17-recording-reminder-matrix-mockup.html`.

Default reminder panel:

- The overlay is a flush-top black panel centered at the top of the screen.
- The top edge is square and attached to the screen edge.
- The lower corners are rounded.
- The center-top notch-safe zone contains no content on notch displays.
- Approximate final dimensions: 336 pt wide and 92 pt tall.
- If the screen is too narrow, keep safe side margins and fall back to a smaller centered variant rather than clipping controls.
- Top-left side area: real Quill app icon and `Quill` label centered on the same left-side basis used by contextual center layouts.
- Top-right side area: circular `×` dismiss button centered on the same right-side basis used by contextual center layouts.
- Body left: one-line meeting title and `Starts at 10:30 AM` secondary text.
- Body right: primary `Start` button.

Recording-context reminder panels:

- The existing recording overlay remains visible and foregrounded; the reminder panel sits behind or around it.
- For Notch Sides, size the reminder panel from the notch-side overlay width and keep the panel compact vertically. The reminder row uses app icon, truncated title, start time, and an `×` button aligned to the right edge.
- For Center Dropdown Fill on a notch display, keep the notch+center recording overlay foregrounded. Put the app icon and `Quill` label in the left top side area and `×` in the right top side area. Put title and `Starts at 10:30 AM` on one row below; the title truncates and the start time is right-aligned.
- For Center Dropdown Fill on a non-notch display, use the same C layout without the notch-safe zone.
- Long meeting titles are always single-line truncated with an ellipsis.

Processing-context reminder panels:

- When recording stops while a reminder is still visible, keep the same reminder-in-recording panel shape.
- Only the foreground recording overlay changes to its processing indicator.
- When processing fully finishes and the reminder is still visible, transition to the default reminder panel with `Start` available.

## Overlay behavior

When a reminder is due and Quill can present in-app UI, the overlay manager enqueues it.

If no reminder is visible, the manager shows the next queued reminder. If another reminder is already visible, the new reminder waits until the current reminder is handled.

Dismiss behavior:

- Clicking `×` hides only the current reminder.
- After dismissal, the next queued reminder is shown if one exists.
- Dismissal does not disable future reminders for the event or calendar.

Start behavior:

- When not recording and not processing, clicking `Start` dismisses the current reminder first and starts a normal toggle recording only after the reminder closes.
- The overlay-started recording uses the existing calendar overlap suggestion flow for note metadata and titles.
- No special `calendarNotification` match source is added in this first pass.
- No calendar title is auto-applied.

Recording-active behavior:

- If a reminder arrives while recording is already active, show the contextual information panel for the current recording overlay layout.
- The contextual panel has no `Start` or `Recording` action label.
- The `×` button still dismisses the reminder.
- This reminder must not stop, restart, or replace the current recording.
- This reminder must not override the calendar match for the active recording.

External recording start behavior:

- If the default reminder panel is visible and the user starts recording through another path, keep the reminder visible and transition it into the contextual recording panel.
- This differs from pressing `Start`, which closes the reminder before starting recording.

Processing behavior:

- If recording stops while a contextual reminder is visible, keep the contextual reminder panel visible and transition only the foreground recording overlay to processing.
- Once processing fully finishes, the visible reminder transitions back to the default reminder panel and `Start` becomes available again.
- Calendar reminder UI must not take ownership of existing transcription jobs.

## macOS notification fallback

Keep macOS local notifications scheduled as the offline fallback.

The scheduler should still add pending local notifications for eligible reminders. While Quill is running, it should also keep an in-app timer for the next scheduled reminder fire date. The local notification fallback should be scheduled a short grace interval after the in-app timer so the overlay gets first chance to show while the app is alive. When the in-app timer fires, the presenter gets the first chance to show the reminder. If the presenter confirms that the overlay was shown, the scheduler removes that reminder's pending local notification to prevent duplicate delivery.

If Quill exits before the in-app timer fires, the pending macOS local notification remains and can fire as today.

If the in-app presenter cannot show an overlay, the scheduler keeps the macOS notification path intact.

The existing macOS notification click behavior remains a fallback recording start path and can continue to start normal recording without special calendar metadata.

## Calendar metadata and note titles

Overlay Start is only a fast path to normal recording. The final history item should be handled like any other normal recording.

- Calendar matching remains based on recording interval overlap.
- Matching results remain suggestions.
- Calendar titles are not auto-applied.
- This pass does not persist a reminder-triggered event on the active recording session.

This intentionally keeps the first implementation smaller than the issue's suggested explicit event-linking path. Explicit reminder-source metadata can be added later if the overlap-based behavior is insufficient.

## Error handling and edge cases

- If calendar reminders are disabled, disconnected, or no calendars are selected, no reminder overlay is scheduled.
- If the in-app overlay cannot be shown, keep the local notification fallback.
- If multiple reminders are due in one refresh, enqueue them sorted by fire date and identifier.
- If duplicate immediate reminders are encountered, keep using identifier-based suppression.
- If a reminder for the same calendar event and start time is already queued or visible, treat later lead-time reminders as already represented and do not enqueue another overlay.
- If the meeting title is empty or the event is all-day, keep existing scheduler eligibility rules and do not show the reminder.
- If recording starts from the overlay but permission checks fail, existing recording start error handling applies.

## Testing

Add or update unit tests around `CalendarRecordingReminderScheduler` for:

- due reminders are offered to the in-app presenter before relying on immediate macOS notification delivery;
- scheduled reminders create an in-app due timer while keeping a slightly delayed local notification fallback pending;
- a reminder shown in-app removes only its matching pending macOS notification;
- presenter failure keeps the macOS notification fallback path;
- simultaneous due reminders are handled in stable order;
- duplicate identifiers are not re-presented repeatedly.

Add testable layout helpers where practical for `MeetingReminderOverlayManager` or its geometry:

- default compact dimensions;
- minimum screen-width fallback;
- idle, recording, and processing variant selection;
- Notch Sides contextual sizing;
- notch and non-notch Center Dropdown Fill contextual sizing;
- title truncation constraints represented in display data or view model.

Manual verification:

1. Build with the Makefile-based path.
2. Run the built app.
3. With calendar reminders enabled and Quill running, confirm a due reminder shows the compact top island overlay.
4. Confirm long meeting titles truncate without moving the time line or Start button.
5. Confirm `×` dismisses only the current reminder.
6. Confirm simultaneous reminders show one at a time.
7. Confirm `Start` closes the reminder before normal recording starts.
8. Confirm starting recording from a non-reminder path while a reminder is visible transitions the reminder into the contextual recording panel.
9. Confirm reminder arrival during an active recording shows information and does not stop or restart recording.
10. Confirm stopping recording while the contextual reminder is visible keeps the reminder panel and changes only the foreground recording overlay to processing.
11. Confirm finishing processing transitions the visible reminder back to the default reminder panel.
12. Confirm quitting Quill before a scheduled reminder still allows the existing macOS notification fallback to fire.
