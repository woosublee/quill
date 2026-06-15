<p align="center">
  <img src="Resources/AppIcon-Source.png" width="128" height="128" alt="Quill icon">
</p>

<h1 align="center">Quill</h1>

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
- **Write into any Mac app:** Dictate into text fields, documents, chat apps, browsers, terminals, and other focused inputs.
- **Turn speech into finished text:** Clean up filler words, punctuation, phrasing, names, and project-specific vocabulary before the text is pasted.
- **Edit by voice:** Highlight existing text and say what to change, such as “make this shorter” or “turn this into bullets.”
- **Keep context with your notes:** Use local history, optional calendar context, and Note Browser workflows to connect recordings with the work they came from.
- **Choose your transcription path:** Use provider-based transcription or local transcription options depending on your privacy, speed, and setup needs.
- **Automate with Claude Code:** Expose a local MCP server so Claude Code can start recordings, add context, stop recordings, and read recent transcripts.

## How it works

1. Quill records audio when you press your dictation shortcut.
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

Quill can expose a local MCP server while the app is running, so Claude Code can start recordings, add context, stop recordings, and read recent transcripts from your local Quill history.

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
3. Keep Quill running while using the MCP server.
4. Ask Claude to use the `quill` MCP server.

Available MCP tools:

- `start_recording` — start a Quill recording session, optionally with initial context such as meeting name, participants, topic, or a Notion URL.
- `add_context` — append more context while a recording is in progress.
- `stop_recording` — stop the recording and trigger transcription.
- `get_status` — check whether Quill is idle, recording, or transcribing.
- `list_transcripts` — list recent transcript history entries.
- `get_transcript` — fetch a specific transcript by id.
- `get_meeting_source` — fetch structured meeting data for a transcript id as JSON (resolved title, ISO 8601 timestamps, calendar match, attendees, audio file path, transcript, and context) for meeting-note generation.

Notes:

- Quill MCP does not require a separate MCP API key.
- The server is local to your Mac and is only available while Quill is running.
- The Claude Code registration is user-scoped.
- Each person should run Quill on their own machine and register their own local `quill` MCP server.

## Privacy

Quill does not operate a server that stores your transcripts, audio recordings, calendar data, OAuth tokens, or app history. App data is stored locally on your Mac unless you choose to send data to a configured transcription or AI provider.

If you connect Google Calendar, Quill requests read-only access and uses selected calendar events only for local meeting-related workflows such as note title suggestions and recording reminders.

## Credits

Quill is maintained as a fork of [`zachlatta/freeflow`](https://github.com/zachlatta/freeflow) and builds on the original FreeFlow project and its upstream contributors.

## License

Licensed under the MIT license.
