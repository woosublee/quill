# Multiple Meeting Reminder Lead Times Design

## Context

GitHub issue #100 asks Quill to let users select multiple Meeting Recording Reminder lead times instead of a single reminder time. The current implementation stores one lead time, fetches eligible calendar events, and schedules one macOS notification per event. Notification identifiers already include the lead time, which gives us stable identity for multiple reminders per event.

## Goals

- Let users choose multiple reminder lead times from the existing options: 1, 5, 10, 15, 30, and 60 minutes.
- Schedule one notification per selected lead time for each eligible calendar event.
- Preserve existing single-value settings by migrating the stored value into a one-item selection.
- Keep notification identifiers stable and distinct across event ID, event start, and lead time.
- Clean up stale pending reminders when selected lead times change.

## Non-goals

- Do not add custom lead time entry.
- Do not change the Google Calendar event fetch window or eligibility rules.
- Do not remove delivered notifications; keep using them only for duplicate suppression.

## Architecture

`AppState` will own a multi-value reminder setting and pass the selected lead times to `CalendarRecordingReminderScheduler`. The scheduler will fetch calendar events once per refresh, then expand each eligible event across the selected lead times to build a single reminder plan.

The existing notification identifier format remains unchanged:

```text
calendar-recording-reminder:<calendarID>:<eventID>:<startTimestamp>:<leadMinutes>
```

Because the identifier already includes `leadMinutes`, reminders for the same event at different lead times remain stable and distinct.

## Settings persistence and migration

Add a new array-backed storage key, for example `calendar_recording_reminder_lead_minutes_list`. During initialization, if the new key has no value, read the legacy `calendar_recording_reminder_lead_minutes` integer, normalize it, and use it as a one-item selection. If neither value exists, default to `[10]`.

Persisted selections will be normalized by clamping each value, removing duplicates, sorting ascending, and falling back to `[10]` if the input is empty. The legacy key remains only as a migration source.

## Settings UI

Replace the single segmented picker with a multi-select control over the existing lead time options. Users may select any combination of the existing values, but the UI will prevent removing the last selected value. The reminder toggle remains the top-level enable/disable control.

## Scheduler behavior

Update scheduler APIs to accept multiple lead times, including:

- `start(leadMinutes: [Int], refreshIntervalMinutes:)`
- `rescheduleNow(leadMinutes: [Int])`
- `reminderPlan(... leadMinutes: [Int] ...)`

For each eligible event and normalized lead time, the scheduler applies the existing scheduled/immediate rules independently. A single event may therefore produce both an immediate reminder for one elapsed lead time and scheduled reminders for later lead times.

Immediate duplicate suppression remains identifier-based. Since lead time is part of the identifier, duplicate suppression applies per event and lead time.

## Cleanup behavior

`replacePendingNotifications` continues to remove pending calendar reminder IDs that are not in the new scheduled plan. When selected lead times change, identifiers for removed lead times disappear from the plan and their pending notifications are removed. Delivered notification IDs continue to suppress duplicate immediate delivery but are not removed.

## Testing

Extend `CalendarRecordingReminderSchedulerTests` to cover:

- one event producing multiple scheduled reminders for multiple lead times;
- stable identifiers differing by lead time;
- one event producing immediate and scheduled reminders at different lead times;
- multi-value normalization: clamping, de-duplication, sorting, and empty fallback;
- existing eligibility, title, and refresh interval behavior.

Add AppState-level coverage where practical for migration from the legacy single lead time and defaults cleanup for the new storage key.
