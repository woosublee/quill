# Google Calendar meeting note title design

## Summary

Add Google Calendar integration so Quill can use calendar events as optional meeting-note metadata. The first implementation connects one Google account, lets the user choose which calendars to use, matches selected calendar events against recording intervals, and surfaces matched event titles as note title suggestions. Calendar data must not be fed into dictation post-processing context.

## Goals

- Add explicit persisted recording start and stop timestamps.
- Connect Google Calendar through a native desktop OAuth flow with PKCE.
- Let the user choose the calendars used for matching.
- Match selected calendar events to recording intervals by overlap duration.
- Store matched event metadata needed for note titles, future reminders, and attendee-aware note metadata.
- Keep calendar integration suggestion-oriented unless a future calendar reminder explicitly starts the recording.

## Non-goals

- Calendar-based recording reminders in the first implementation.
- Calendar event editing.
- Multi-account Google support in the first implementation.
- Hosted backend support.
- Feeding calendar event details into LLM post-processing context.
- Storing event descriptions, locations, meeting links, attachments, or attendee comments.

## User experience

### Settings

Add a Calendar section to Settings.

- Show Google Calendar connection state.
- Provide Connect and Disconnect actions.
- Provide a calendar list refresh action.
- Show the connected account identity when available.
- Show calendars as checkboxes.
- Select no calendars by default after connection.
- Use only explicitly selected calendars for event matching.

The first version supports one connected Google account. The settings shape should still be compatible with a future multi-account model by treating selected calendars as account-scoped calendar IDs internally.

### Note titles

Calendar title behavior depends on how the recording started.

- Future calendar-notification recordings: the event is an explicit user-selected recording source, so the event title may be applied automatically.
- Normal shortcut, menu, or MCP recordings: a time-overlapping event is only a suggested title.
- User-edited titles always win and are never overwritten by calendar metadata.
- If Calendar is disconnected, no calendars are selected, no interval exists, or no matching event exists, existing transcript-based title and fallback behavior remains unchanged.

Suggested titles should be shown in the note detail UI with an Apply action. Applying a suggested calendar title stores it as the note's user-confirmed title so later calendar changes do not unexpectedly alter the note title.

## Data model

Add optional fields to persisted pipeline history items.

- `recordingStartedAt: Date?`
  - The actual microphone recording start time.
  - Not the shortcut/request time or permission-check start time.
- `recordingEndedAt: Date?`
  - The time the user requested recording stop.
  - Not the audio-file-ready or transcription-complete time.
- `calendarMatch: CalendarEventMatch?`
  - `accountID: String?`
  - `calendarID: String`
  - `eventID: String`
  - `title: String`
  - `start: Date`
  - `end: Date`
  - `attendees: [CalendarEventAttendee]`
  - `matchSource: CalendarMatchSource`
  - `titleState: CalendarTitleState`

`CalendarMatchSource` values:

- `overlapSuggestion`
- `calendarNotification`

`CalendarTitleState` values:

- `suggested`
- `applied`

`CalendarEventAttendee` stores a minimal snapshot.

- `displayName: String?`
- `email: String?`
- `responseStatus: String?`
- `isOptional: Bool`
- `isSelf: Bool`

Do not store event description, location, Meet links, attachments, or attendee comments. Existing history entries must load with all new fields unset. Imported audio remains excluded from calendar matching unless a reliable recording interval exists.

Nested calendar match metadata should be persisted as Codable JSON on the history item rather than as separate Core Data entities. The metadata is a point-in-time snapshot attached to a note, and separate entities would add migration and query complexity without helping the first feature.

## Services

### `GoogleCalendarAuthService`

Responsible for Google OAuth.

- Generate PKCE verifier and challenge.
- Build the authorization URL.
- Open the user's browser for consent.
- Receive a local loopback callback with the authorization code.
- Exchange the code and verifier for access and refresh tokens.
- Refresh access tokens as needed.
- Delete tokens when the user disconnects.

Prefer loopback callback over a custom URL scheme for the first implementation because it avoids app URL scheme registration and fits native desktop OAuth.

### `GoogleCalendarService`

Responsible for Calendar API reads.

- Fetch the user's calendar list.
- Fetch events for selected calendar IDs over a recording interval.
- Use read-only scopes only.
- Use `singleEvents=true` so recurring meetings are evaluated as individual instances.
- Request only fields needed for matching and metadata.
- Exclude all-day events.
- Exclude private or otherwise unusable events that do not expose a title.
- Decode attendees only into the minimal snapshot fields.

### `CalendarEventMatcher`

Responsible for deterministic matching.

- Take a recording start/end interval and candidate events.
- Ignore candidates with no positive overlap.
- Choose the event with the longest overlap duration.
- If overlap duration ties, choose the event whose start is closest to the recording start.
- Return no match if no usable candidate remains.

## Recording and note flow

1. Capture `recordingStartedAt` when microphone recording actually begins.
2. Capture `recordingEndedAt` when the user requests stop.
3. Continue audio save and transcription even if Calendar is unavailable.
4. When creating the final history item, attempt calendar matching only if:
   - Calendar is connected,
   - at least one calendar is selected,
   - both recording timestamps exist, and
   - the item is not imported audio without a reliable interval.
5. Fetch events from selected calendars for the recording interval.
6. Match by overlap duration.
7. Store `calendarMatch` if a match exists.
8. Set `titleState` to `suggested` for normal recordings.
9. Reserve `calendarNotification` + `applied` for the future reminder-start flow.

Calendar API failures must not block note creation or transcription completion.

## Title display priority

Use this priority order when rendering note titles:

1. User-confirmed custom title.
2. Applied calendar title.
3. Existing transcript-based automatic title.
4. Existing fallback title.

Suggested calendar titles do not automatically change the rendered title. They appear as a suggestion with an Apply action. Apply writes the title through the existing user-title path so the user has explicit control.

## OAuth, scopes, and storage

Use a native desktop OAuth client with PKCE.

- Store OAuth tokens in macOS Keychain.
- Store selected calendar IDs and non-secret connection metadata outside Keychain.
- On disconnect, delete Keychain token items and clear selected calendar IDs.
- On refresh failure or revoked access, mark Calendar disconnected and skip matching.

Request only read-only Google Calendar scopes needed to list calendars and read event details. The preferred narrow scope pair is:

- `https://www.googleapis.com/auth/calendar.calendarlist.readonly` for calendar list selection.
- `https://www.googleapis.com/auth/calendar.events.readonly` for reading event title, time, and attendee snapshots.

If the narrow pair proves insufficient during manual OAuth verification, use `https://www.googleapis.com/auth/calendar.readonly` as the read-only fallback. Do not request event write scopes.

## Error handling

Calendar integration is auxiliary.

- Not connected: skip matching.
- No selected calendars: skip matching and show setup guidance in Settings.
- Access token expired: refresh and retry.
- Refresh failure or revoked access: disconnect Calendar state and skip matching.
- One calendar fails: skip that calendar and use events from calendars that succeeded.
- All calendar requests fail: complete the note without a suggestion.
- All-day events: exclude.
- Titleless events: exclude.
- Missing recording interval: skip matching.

A last Calendar error can be shown in Settings for troubleshooting, but the recording flow should not surface blocking alerts for calendar failures.

## Testing

### Unit tests

Add tests for `CalendarEventMatcher`.

- Selects the candidate with the longest positive overlap.
- Excludes zero-overlap events.
- Excludes all-day events.
- Applies the tie-break by start-time distance to recording start.
- Excludes titleless events.

Add persistence tests for history metadata.

- Existing history entries load when new optional fields are absent.
- Recording start/end timestamps persist and reload.
- Calendar match metadata persists and reloads.
- Minimal attendee snapshots persist and reload.

Add title behavior tests.

- User custom title overrides calendar titles.
- Applied calendar title is used before transcript-based auto title.
- Suggested calendar title does not override the displayed title.
- Applying a suggestion stores a user-confirmed title.

### Service boundary tests

Use fake transports for Calendar API and OAuth boundaries.

- Calendar list responses decode into selectable calendars.
- Event responses decode only required fields.
- Partial calendar request failures do not fail the whole matching attempt.
- Token refresh failure marks Calendar disconnected.

### Manual verification

Use a Google Cloud OAuth desktop client in Testing mode with the owner account as a test user.

- Connect Google Calendar from Settings.
- Verify no calendars are selected by default.
- Select a calendar and record during a timed meeting event.
- Confirm the event appears as a suggested title for normal recording.
- Apply the suggestion and confirm the title stays user-controlled.
- Confirm all-day events do not become suggestions.
- Disconnect Calendar and confirm matching is skipped.

## Future reminder extension

The design keeps space for calendar-based recording prompts without implementing them now.

- Selected calendars can later gain reminder settings.
- `calendarMatch.accountID/calendarID/eventID` can identify the event that launched a recording.
- `matchSource = calendarNotification` can distinguish explicit reminder-start recordings from inferred overlap suggestions.
- `titleState = applied` can be used when a user starts recording from a calendar notification.
- Attendee snapshots can later support note metadata or export frontmatter, still without feeding calendar details into LLM post-processing by default.
