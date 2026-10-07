# Apple Calendar as a Second Calendar Source — Design

**Date:** 2026-10-07
**Status:** Draft — awaiting review
**Mockup:** https://claude.ai/artifact/JAMgWJKUoCYchP7gQUmcNT (v3)

## Goal

Let people connect the calendars in the macOS Calendar app (EventKit) in
addition to Google Calendar. Meeting recording reminders, calendar-based note
titles, and meeting attendees work the same way whichever source an event comes
from.

## What the user asked for

- The user keeps their calendars in Apple Calendar and wants Quill to use them.
- Google Calendar and Apple Calendar can be connected at the same time (not
  either/or).
- The user's Mac Calendar app also contains their Google account, so the same
  event can arrive from both sources.
- Settings › Calendar is already long with Google alone, so the page must be
  reorganized instead of adding a second full card.
- When Calendar access is denied, reuse the recent System Settings permission
  guide where it fits.
- Calendar selection moves to a separate sheet, with the selected calendar
  names shown on each source row and the sheet opening automatically after the
  first connection.

## Current state

- There is no provider abstraction. `GoogleCalendarEvent`
  (`CalendarIntegrationModels.swift`) is the event type used by
  `CalendarEventMatcher`, `CalendarRecordingReminderScheduler`
  (`EventProvider` closure, `CalendarRecordingReminderSchedule.event`, reminder
  identifiers), and `AppState.calendarEventMatch` /
  `fetchCalendarRecordingReminderEvents`.
- `googleCalendarConnection` (`GoogleCalendarConnectionState`,
  `GoogleCalendarHealth`) gates reminders and title matching.
- Shared types already exist: `CalendarEventMatch`, `CalendarEventAttendee`,
  `RecordingCalendarSnapshot`, `MeetingSummaryCalendarContext`.
- History stores `CalendarEventMatch` as JSON (`calendarMatchJSON`) with no
  provider field; `accountID` holds the Google email.
- `CalendarSettingsView` (`SettingsView.swift`) has a long "Google Calendar"
  card: description, status, Connect/Sync Now/Disconnect, refresh interval
  with explanation, grouped calendar checkboxes ("My calendars" / "Shared
  calendars"), footnote; then a "Meeting Recording Reminders" card.
- `PermissionGuideController` / `PermissionGuideKind` support Screen Recording
  and Accessibility, where Quill is dragged into a System Settings list.
- `Info.plist` has no `NSCalendars*` usage description; `Quill.entitlements`
  has no calendar entitlement. Deployment target is macOS 13.

## Design

### 1. Shared event model and sources

- Add a provider-neutral `CalendarEvent`:
  `source` (`.google` / `.apple`), `calendarID`, `eventID`, `title`, `start`,
  `end`, `isAllDay`, `attendees: [CalendarEventAttendee]`.
  It keeps `hasUsableTitle` and `match(accountID:source:titleState:)` from
  `GoogleCalendarEvent`, which it replaces in shared code.
- Google keeps its existing fetch path in `AppState` (token refresh and health
  reporting are entangled there); it now returns `CalendarEvent`.
  `AppleCalendarService` reads `EKEventStore` events for the selected
  `EKCalendar` identifiers. A pure `CalendarEventMerger` combines the two
  results and removes duplicates. One source failing does not drop the other;
  failures are reported per source. (A provider protocol can be extracted when a
  third source arrives.)
- **Duplicates:** events with the same normalized title, start, end, and
  all-day flag are one event. The first source in a fixed order (Google, then
  Apple) wins, so Google's richer attendee data is kept when both have it.
- **Attendee mapping (Apple):** `EKParticipant.name` → `displayName`, the
  `mailto:` URL → `email`, `participantStatus` → `responseStatus` using
  Google's strings (`accepted`, `declined`, `tentative`, `needsAction`),
  `participantRole == .optional` → `isOptional`, `isCurrentUser` → `isSelf`.
  This keeps the scheduler's existing "declined" rule unchanged.
- **Consumers switch to the aggregator:** reminder scheduling
  (`fetchCalendarRecordingReminderEvents`), title matching after recording
  (`calendarEventMatch`, `calendarMatchForHistoryItem`), and the overlay's
  `RecordingCalendarSnapshot`. `CalendarEventMatcher` and the scheduler take
  `CalendarEvent`.
- **Reminder identifiers** keep today's `calendarID:eventID:start` format so
  already scheduled Google reminders are not duplicated. Apple calendar IDs are
  EventKit UUIDs and cannot collide with Google calendar IDs.
- **Change notifications:** `EKEventStoreChanged` triggers an immediate
  reminder refresh. The existing refresh interval still applies to all sources.

### 2. Stored history compatibility

- `CalendarEventMatch` gains an optional `source`. Existing JSON without it
  decodes as `.google`. Apple matches store `accountID = "apple-calendar"`.
- No migration of existing history items is needed.

### 3. Permission

- Permission is requested only when the person presses **Connect** on the Apple
  Calendar row. Launch and update never prompt.
- macOS 14+: `requestFullAccessToEvents`. macOS 13: `requestAccess(to: .event)`.
- `Info.plist` adds `NSCalendarsFullAccessUsageDescription` and
  `NSCalendarsUsageDescription`: "Quill reads your calendar events for meeting
  reminders and note titles and attendees. Events never leave your Mac."
  (localized in Korean in the string catalog).
- `Quill.entitlements` adds `com.apple.security.personal-information.calendars`,
  required for EventKit under the hardened runtime. This does not change the
  designated requirement, so existing Accessibility/Screen Recording grants
  stay valid.
- Quill only reads events; it never creates or edits them.
- **Denied:** the Apple row shows "Calendar access is off" with **Open System
  Settings**. That opens `Privacy_Calendars` through `PermissionGuideController`
  with a new `PermissionGuideKind.calendars`:
  - same pane opening, attached panel, grant polling, and return to the
    previous app;
  - no drag icon; the panel says "Turn on the switch next to Quill in the list"
    (the Calendars list has no + button, and Quill is already listed after a
    denial);
  - when access turns on, Quill closes the panel and opens the Apple calendar
    selection sheet.
- Access revoked later: the Apple row shows the same "off" state and Apple
  events are skipped; Google keeps working.

### 4. Settings › Calendar layout

- The "Google Calendar" card becomes a **Calendar connections** card:
  - a one-line description ("Events from connected calendars fill meeting
    reminders and note titles and attendees. Events never leave your Mac.");
  - one row per source: icon, name, status, account (Google email / "Mac
    Calendar app"), the selected calendar names, and actions;
  - Google row actions: **Choose Calendars…** and a **⋯** menu with Reconnect,
    Sync Now, Disconnect (today's buttons, same enablement rules);
  - Apple row actions: **Connect** / **Choose Calendars…** / **Open System
    Settings** depending on state, and a **⋯** menu with Reload Calendars and
    Disconnect (Disconnect clears Apple selection; macOS access is managed in
    System Settings);
  - health problems show as a single warning line under the affected row
    (today's Google reconnect/temporary-failure messages move here);
  - the **Refresh calendars** picker moves to the bottom of this card and
    applies to all sources.
- **Selected calendar names on the row:** up to two names, then "and N more"
  (for example "Personal, Work and 2 more"). With none selected the row says
  "Choose calendars to use".
- **Choose Calendars sheet:**
  - Google: today's grouped list ("My calendars" / "Shared calendars" with
    Primary/My calendar/Shared chips) and footnote, moved unchanged.
  - Apple: calendars grouped by `EKSource` (iCloud, Google account, Exchange,
    On My Mac…), each with its calendar color; a hint that Google-account
    calendars may also come through the Google connection and duplicates are
    used once.
  - Nothing is selected by default, as today.
- The sheet opens automatically right after a source connects with no
  calendars selected (Google after OAuth finishes, Apple after access is
  granted).
- **Meeting Recording Reminders card:** unchanged copy and reminder times. It
  is enabled when at least one source is connected with at least one calendar
  selected. "Connect Google Calendar first." becomes "Connect a calendar
  first."; "Select at least one calendar above." stays.

### 5. Errors

| Situation | Behavior |
|---|---|
| Apple access denied or revoked | Apple row "off" + Open System Settings; Apple events skipped |
| A selected Apple calendar disappears | Dropped from the selection; row names update |
| Google fetch fails, Apple works (or the reverse) | Reminders and matching use the working source; warning on the failing row |
| Same event from both sources | Merged into one; one reminder |
| macOS 13 | Legacy access request; otherwise identical |

## Privacy and risk

- New personal data read: calendar events, titles, and attendees from the Mac
  Calendar app. They are used locally only, exactly like Google events today;
  no new transmission, logging, or persistence beyond the existing
  `calendarMatchJSON` on a note.
- High-risk items to call out in the PR: new entitlement, new usage
  descriptions/permission flow, Settings layout change, and history JSON
  decoding change.
- Logs must not include event titles, attendees, or calendar names.

## Testing

Automated (synthetic data, no EventKit store or Google account):

- `CalendarEvent` conversion from Google API results and from a fake EventKit
  representation (attendees, declined status, all-day events).
- Aggregator: merge, duplicate removal and source priority, one source failing.
- `CalendarEventMatcher` and `CalendarRecordingReminderScheduler` produce the
  same results as before using `CalendarEvent` (existing tests moved over), and
  reminder identifiers include the source.
- `CalendarEventMatch` JSON without `source` decodes as Google.
- Row summary text for 0, 1, 2, and more selected calendars.
- Apple row state for not determined, granted with/without selection, denied.
- Reminder-card enablement for each combination of sources.

Manual verification before merge (cannot be automated):

- Permission prompt on macOS 14+ (and 13 if available) from Connect.
- Deny → Open System Settings → guide panel → switch on → sheet opens.
- Real events from iCloud and a Google account in the Mac Calendar app produce
  one reminder each and correct note titles.
- A notarized build with the new entitlement can read events.

## Out of scope

- Writing or editing calendar events.
- Apple Reminders.
- Onboarding (SetupView) calendar step.
- Other providers (Outlook API); the source protocol makes them possible later.
