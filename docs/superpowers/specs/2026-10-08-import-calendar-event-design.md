# Calendar Event Selection for Imported Audio — Design

**Date:** 2026-10-08
**Status:** Draft — awaiting review
**Mockup:** https://claude.ai/artifact/ALRqABy3BUthBonFGPFdAw (v10)

## Goal

When someone imports an audio file, let them attach a calendar event from
their connected calendars (Google and Apple), so the note gets the meeting
title and attendees the same way a recorded meeting does. Show the real
recording time of the file in the note list and note header.

## What the user asked for

- Choose a calendar event while importing an audio file.
- Use the time recorded inside the file to suggest the event; the file's
  filesystem dates are not reliable (they change when a file is copied or
  downloaded).
- Show the recording time next to the file name in the import sheet, without
  a "녹음" label; when the file has no recording time, say so there in plain
  secondary text (no orange banner).
- The calendar section shows a date button above the event list; tapping it
  opens a calendar popover; any past or future date can be chosen.
- The list always shows the chosen day's events in time order, recommends the
  one that overlaps the recording most, and ends with "No event".
- A chosen event names the note the same way as applying a calendar
  suggestion after recording: `2026-10-07 주간 기획 회의`.
- With no calendar connected, show a hint and a "Calendar Settings…" button
  that opens Settings › Calendar without closing the import sheet.
- Imported notes appear in the note list at their real recording time, and
  the new note is selected and scrolled into view.

## Current state

- `NoteBrowserView.showAudioImportPicker()` opens an `NSOpenPanel`, then shows
  `TranscriptionChoiceSheet` ("Import Audio File" + file name + transcription
  method). Confirm calls `AppState.importAudioFile(_:choice:)`.
- The import creates a placeholder `PipelineHistoryItem` with
  `timestamp: startedAt` (import time), `recordingStartedAt/EndedAt: nil`,
  `calendarMatch: nil`, and registers the job with `isImportedAudio: true`.
  `calendarMatchForHistoryItem` skips imported audio.
- Note titles (`NoteTitleResolver.displayTitle`): custom title → applied
  calendar title → first transcript line (≤ 60 characters). Applying a
  calendar suggestion after recording sets the custom title to
  `NoteTitleResolver.calendarAppliedTitle` (`yyyy-MM-dd <event title>`).
- The note list and history store order notes by `timestamp` (newest first).
  Recorded meetings use `timestamp = recordingEndedAt`. The row shows
  `recordingStartedAt ?? timestamp`; the header shows the start–end range when
  both exist. History is not trimmed (`maxPipelineHistoryCount = Int.max`).
- `CalendarEventMatcher.bestMatch` picks the event with the largest overlap.
  `CalendarRecordingReminderScheduler.isReminderEligible` excludes all-day,
  untitled, invalid, and declined events.
- Google events come from `GoogleCalendarService` through AppState's token
  flow; Apple events from `AppleCalendarService` (main actor);
  `CalendarEventCollection.combine` merges them.

## Design

### 1. Recording time from the file

- New `AudioFileRecordingTime` reads, without decoding audio:
  `AVURLAsset.creationDate` (the QuickTime/MP4 creation date written by Voice
  Memos and recorders) and the duration.
- Result: `start` and `end = start + duration`, or `nil` when the file has no
  embedded creation date. Filesystem creation/modification dates are never
  used.
- Read when the import sheet opens (async; the sheet shows the file name first
  and adds the time when ready).

### 2. Import sheet

`TranscriptionChoiceSheet` gains an optional calendar section, shown only for
audio import (Retranscribe keeps today's sheet).

- **Header:** `<file name> · 10월 7일 (화) 오후 2:02~2:46`, or
  `<file name> · 녹음 시각이 없어 날짜를 직접 골라 주세요` in secondary text.
- **Calendar Event section** (above Transcription Method):
  - A date button (`10월 7일 (화) ▾`) opening a graphical date-picker popover.
    Initial date: recording start day, otherwise today. Any date is allowed.
    The recording day stays marked when another day is shown.
  - The event list for that day (see §3), each row: title, time range,
    source (Google/Apple), attendee count when present. The recommended row
    has a "추천" chip and shows the title it will produce.
  - "No event" (일정 없음 · 전사문 첫 줄로 제목을 정합니다) is always last.
  - While loading: "Loading events…" in place of the list. If Google fails,
    Apple events still show with a one-line "Some calendars couldn't be
    loaded" note.
  - No calendar connected: "캘린더를 연결하면 회의 제목과 참석자를 붙일 수
    있어요." and a "캘린더 설정…" button that opens Settings › Calendar and
    keeps the sheet open. When a source connects or calendars change, the
    sheet reloads the shown day.
- Transcribe stays enabled regardless of the calendar choice.

### 3. Day events and recommendation

- New `CalendarDayEvents` loads one local day (`startOfDay`…next day) from
  the selected Google and Apple calendars, merges duplicates with
  `CalendarEventCollection.combine(toleratesGoogleFailure: true)`, and keeps
  only events that pass `isReminderEligible` (no all-day, untitled, or
  declined events), sorted by start time.
- Recommendation: `CalendarEventMatcher.bestMatch` against the file's
  recording interval; only when the shown day overlaps it. With a
  recommendation it is preselected; otherwise "No event" is preselected.
- Nothing is cached or stored; the list is fetched when the sheet opens, when
  the date changes, and when calendar connections change.

### 4. Applying the choice

`importAudioFile(_:choice:)` gains `recordingTime: AudioFileRecordingTime?`
and `calendarEvent: CalendarEvent?`.

- With a recording time: the placeholder uses `recordingStartedAt/EndedAt`
  from the file and `timestamp = recordingEnd` (same as recorded meetings), so
  the note sorts at its real time.
- With an event:
  - `calendarMatch` = `event.match(accountID:source: .importSelection,
    titleState: .suggested)` (keeps attendees, provider, and event identity
    for the meeting summary);
  - `customTitle` = `NoteTitleResolver.calendarAppliedTitle(suggestedTitle:
    event.title, recordingStartedAt: recordingStart ?? selectedDayNoon)`,
    i.e. `2026-10-07 주간 기획 회의`, editable later like any custom title.
- `CalendarMatchSource` gains `importSelection = "import_selection"`.
- `calendarMatchForHistoryItem` keeps skipping imported audio, so the chosen
  event is never replaced by an automatic match.
- In-memory `pipelineHistory` inserts the new note in timestamp order instead
  of at the top; Note Browser selects it and scrolls to it.

### 5. Errors

| Situation | Behavior |
|---|---|
| File has no embedded creation date | Header says so; date defaults to today; no recommendation; note keeps import time |
| No calendar connected | Hint + Calendar Settings…; import works without an event |
| Google fails for the day | Apple events still listed; short note; can choose No event |
| Day has no eligible events | Only "No event" |
| Calendar connected while sheet is open | Shown day reloads |

## Privacy and risk

- Calendar data is read only for the shown day and only kept in memory while
  the sheet is open; the chosen event is stored on the note exactly like
  recorded meetings. No new transmission beyond the existing Google Calendar
  API calls; no logging of titles, attendees, or file metadata values.
- Reading the file's creation date and duration does not decode audio.
- Risk to call out: note ordering for imports changes (timestamp = recording
  end); new `CalendarMatchSource` raw value (older builds cannot decode it if
  someone downgrades).

## Testing

Automated (synthetic data):

- `AudioFileRecordingTime` from a generated short audio file with and without
  a creation date (temporary file written by the test; no real recordings).
- Day filtering: all-day, untitled, and declined events excluded; time order;
  merge of duplicates; Google failure keeps Apple events.
- Recommendation: overlapping best match preselected; other day → no
  recommendation, "No event" preselected.
- Applied title text `yyyy-MM-dd <title>` from recording start, and from the
  chosen day when there is no recording time.
- Import placeholder: recording interval and `timestamp = end` with a
  recording time; unchanged without; `calendarMatch.matchSource ==
  .importSelection`; `CalendarMatchSource` decodes the new value and old
  values.
- History insertion keeps timestamp order.
- Settings copy (ko) for new strings.

Manual (Quill Dev):

- Import a Voice Memos file: header time, recommended event, title, attendees
  in the meeting summary, list position, auto-select and scroll.
- File without creation date; no calendar connected → Calendar Settings… →
  connect → list appears; date popover past and future.

## Out of scope

- Changing the event after import (existing title editing covers the title).
- Using transcript content to guess the meeting.
- Batch import of several files.
