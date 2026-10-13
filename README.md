<p align="center">
  <img src="Resources/AppIcon-Source.png" width="128" height="128" alt="Quill icon">
</p>

<h1 align="center">Quill</h1>

<p align="center">
  English · <a href="README.ko.md">한국어</a>
</p>

<p align="center">
  Speak your thoughts, meeting notes, and edits into any Mac app, then turn them into polished text you can use immediately.
</p>

<p align="center">
  <a href="https://github.com/woosublee/quill/releases/latest/download/Quill.dmg"><b>Download Quill.dmg</b></a><br>
  <sub>Works on all Macs (Apple Silicon + Intel)</sub>
</p>

---

<p align="center">
  <img src="Resources/demo.gif" alt="Quill demo" width="600">
</p>

## What is Quill?

Quill is a free, open-source Mac dictation app for turning spoken ideas into text you can actually use. Instead of stopping to type, you can hold a shortcut, say what you mean, and let Quill transcribe, clean up, and paste the result into the app you are already using.

It is built for everyday writing and work notes: replying to messages, drafting documents, capturing meeting thoughts, rewriting selected text, and keeping a local history of what you dictated. Quill can use app context, custom vocabulary, calendar context, and cleanup prompts so the output reads less like a raw transcript and more like finished writing.

## What Quill helps with

- **Capture thoughts before they disappear:** Speak rough ideas, meeting notes, follow-ups, or drafts without switching away from the app you are using.
- **Record the right audio source:** Choose a microphone independently, then record the microphone, System Audio, or both together—and switch sources mid-recording without ending the session.
- **Write into any Mac app:** Dictate into text fields, documents, chat apps, browsers, terminals, and other focused inputs.
- **Turn speech into finished text:** Clean up filler words, punctuation, phrasing, names, and project-specific vocabulary before the text is pasted.
- **Edit by voice:** Highlight existing text and say what to change, such as “make this shorter” or “turn this into bullets.”
- **Keep context with your notes:** Use local history, optional calendar context, and Note Browser workflows to connect recordings with the work they came from.
- **Choose your transcription path:** Use provider-based transcription or local transcription options depending on your privacy, speed, and setup needs.
- **Automate with Claude Code:** Expose a local MCP server so Claude Code can start recordings, add context, stop recordings, and find and read your notes.

## How it works

1. Quill records audio when you press your dictation shortcut and shows a compact overlay near the notch with a live waveform (and optional elapsed time).
2. It transcribes the audio using your configured local or provider-based transcription option.
3. It can clean up the transcript with app context, custom vocabulary, and output preferences.
4. It pastes the final text into the focused app and keeps a local history entry for review or retry.

## Requirements

- macOS 13 or later.
- Apple Silicon or Intel Mac.
- macOS Accessibility and Microphone permissions.
- A local transcription option or a configured transcription provider/API endpoint.
- Optional: Google Calendar access for meeting-aware note titles and recording reminders.

## Quick Start

1. [Download Quill.dmg](https://github.com/woosublee/quill/releases/latest/download/Quill.dmg).
2. Open Quill and complete the setup prompts.
3. Grant the required macOS permissions for dictation and paste automation.
4. Configure a transcription provider, local transcription option, or OpenAI-compatible API endpoint in Settings.
5. Hold `Fn` to talk, or tap `Command-Fn` to start and stop dictation.

## Claude Code MCP Setup

Quill can expose a local MCP server while the app is running, so Claude Code can start recordings, add context, stop recordings, and find and read notes (titles, transcripts, summaries, and calendar events) from your local Quill history.

The server is off until you turn on **Settings › AI Tools › Allow AI tools like Claude Code to connect to Quill**. A connected tool can start and stop recordings, add notes to a recording, receive each new transcript as soon as it is ready, and read your notes and dictations: titles, transcripts (original and edited), summaries, recording times, a summary of the app and screen context Quill noted while recording, audio file locations, and matched calendar events (title, times, and each attendee's name, email, response, and whether they're optional or you). While the switch is on, any app on your Mac can connect. Quill doesn't train AI on this data; once a tool has it, its provider's terms decide whether it keeps the data or trains on it, so check your AI tool's data settings. Turning the switch off closes the port and disconnects connected tools.

The local MCP endpoint is:

```text
http://localhost:3457
```

To register Quill in Claude Code, run:

```bash
claude mcp add -s user -t http quill http://localhost:3457
```

Then:

1. Install and launch Quill.
2. Complete the app setup if prompted.
3. Turn on **Settings › AI Tools › Allow AI tools like Claude Code to connect to Quill**.
4. Keep Quill running while using the MCP server.
5. Ask Claude to use the `quill` MCP server. A Claude Code session that was already open may need `/mcp` to reconnect.

Available MCP tools:

- `start_recording` — start a Quill recording session, optionally with initial context such as meeting name, participants, topic, or a Notion URL.
- `add_context` — append more context while a recording is in progress.
- `stop_recording` — stop the recording and trigger transcription.
- `get_status` — check whether Quill is idle, recording, or transcribing.
- `list_notes` — list notes in the Note Browser's order (newest first) as JSON (id, title as Quill shows it, recording time, matched calendar event title, whether a summary exists, and a short preview). Filter with `query` (searched like Quill's note search: title, transcript, summary, calendar event title) and `since`/`until` (a `YYYY-MM-DD` day or an ISO 8601 date-time, local time without an offset); use `offset` for the next page when `has_more` is true.
- `get_note` — fetch one note by id as JSON: title and where it comes from (`custom` set by you, `calendar` event title, or `automatic`), ISO 8601 timestamps, matched calendar event and attendees, audio file path (and whether it is on this Mac or only in iCloud), summary (Markdown, marked stale when the transcript changed after it was made), transcript, original transcript, and app context.

Notes:

- Quill MCP does not require a separate MCP API key.
- The server is local to your Mac and is only available while Quill is running.
- The Claude Code registration is user-scoped.
- Each person should run Quill on their own machine and register their own local `quill` MCP server.

## Privacy

Quill does not operate a server that stores your transcripts, audio recordings, calendar data, OAuth tokens, or app history. App data is stored locally on your Mac unless you choose to send data to a configured transcription or AI provider.

If Quill closes unexpectedly during a recording, recoverable audio may remain in local application storage. Recovered or partial recordings remain local until you retry transcription or delete them. Startup recovery does not automatically transcribe or upload recovered audio. If you choose **Retry Transcription**, Quill uses the local or provider-based transcription path you selected in Settings.

If you connect Google Calendar, Quill requests read-only access and uses selected calendar events only for local meeting-related workflows such as note title suggestions and recording reminders.

## Credits

Quill is maintained as a fork of [`zachlatta/freeflow`](https://github.com/zachlatta/freeflow) and builds on the original FreeFlow project and its upstream contributors.

## License

Licensed under the MIT license.
