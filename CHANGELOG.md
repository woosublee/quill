# Changelog

All notable changes to Quill are documented here.

This project uses semantic versioning for public releases. Use `MAJOR.MINOR.PATCH`, where:

- `MAJOR` changes include breaking behavior or major compatibility changes.
- `MINOR` changes add user-visible features and improvements.
- `PATCH` changes fix bugs, polish existing behavior, or make small internal improvements.

## [0.1.5] - 2026-06-05

### Added

- Model picker dropdowns in Settings for the post-processing, fallback, context, and transcription models, including qwen3-32b and a Custom entry for any other model ID.

### Improved

- Post-processing handles reasoning-model output more cleanly, stripping `<think>` tags and normalizing providerless model aliases.

### Fixed

- Transcription no longer hangs indefinitely when a provider accepts the connection but never returns a response.

## [0.1.4] - 2026-05-31

### Improved

- Adopted upstream overlay improvements, including multi-display overlay selection, in-pill error notifications, retry-to-clipboard behavior, and configurable local model timeout settings.
- Unified transcript post-processing so app context, API transport, and transcription flows use the same shared path.

### Fixed

- Fixed recording overlay target screen resolution by bridging the AppKit screen number through `NSNumber` before converting to a display ID.
- Preserved Paste Again behavior when post-processing fails by keeping the completed transcript available earlier in the flow.
- Avoided false screen recording alerts in upstream permission handling.

## [0.1.3] - 2026-05-29

### Improved

- Reorganized Settings into focused sidebar sections (Models, Shortcuts, Input, About) so the General page is no longer overcrowded. General now keeps app, updates, and permissions, and menu-bar shortcut links open the Shortcuts section.
- Run Log is now a developer-only tab, since the Note Browser covers transcript history for everyday use.

### Fixed

- Removed a retired signing certificate from the updater allowlist now that signing is consolidated on a single certificate.

## [0.1.2] - 2026-05-27

### Fixed

- Updated Quill repository, release, updater, and website links to use the renamed `woosublee/quill` repository.
- Reworded the README download link so the link purpose is clear to readers and assistive technology.
- Fixed local release signing by clearing staged app metadata before codesigning.

## [0.1.1] - 2026-05-26

### Fixed

- Fixed in-app updates for the temporary self-signed Quill release channel by allowing known Quill signing certificates after Gatekeeper rejects the DMG, while keeping staged app metadata and code-signing validation before replacement.

## [0.1.0] - 2026-05-17

### Added

- First public Quill release as a maintained fork of `zachlatta/freeflow`.
- Quill branding, bundle identity, app metadata, release packaging, and fork-specific setup flow.
- Local transcription setup path with model download lifecycle improvements and clearer local-only setup messaging.
- Google Calendar connection, calendar-based note title suggestions, meeting recording reminders, sync status, and calendar matching diagnostics.
- In-app meeting reminder overlay for upcoming recordings, with macOS notification fallback.
- Note Browser workflow improvements, including custom note titles, persisted title migration, and clearer recording time display.
- Configurable recording cancel shortcut with conflict validation and settings UI.
- System Audio capture and System default + System Audio recording for meeting audio workflows.
- Quill MCP setup instructions for connecting the running app to Claude Code.

### Improved

- Recording overlay behavior now follows upstream notch-side improvements while preserving Quill-specific layout choices.
- Stopped transcription completion now has a more reliable completion flow.
- Google Calendar sync and error states are clearer in Settings.
- Release metadata is stamped into app bundles so release builds can be traced by version, build number, and release tag.
- Privacy and Google data-sharing disclosures now better match Quill's Calendar integration behavior.

### Fixed

- Fixed cases where the recording overlay could disappear after display changes.
- Fixed local model download cancellation and download progress layout edge cases.
- Fixed duplicate legacy note title migration keys.
- Fixed calendar reconnect prompt paths that could send users through an unnecessary flow.

## Upstream FreeFlow history

The entries below come from the upstream FreeFlow project before this fork started publishing Quill releases.

## [0.3.3] - 2026-04-25

### Added

- Output Language setting for automatically translating dictated text before it is pasted.
- Transcription Language setting for choosing the language FreeFlow listens for during dictation.
- Recording state flag file for external tools that need to know when FreeFlow is actively recording.
- Distinct FreeFlow Dev app and menu bar icons so development builds are easier to tell apart from release builds.

### Improved

- Permission prompts and setup screens now use the correct app name for the installed build.
- Release notes in update prompts now render changelog formatting more clearly.
- Development builds now have clearer bundle naming and icon handling.

### Fixed

- Fixed audio recording crashes caused by unexpected input formats, resampling, and upload-path conversion.
- Fixed cases where FreeFlow could silently fall back when the selected microphone was unavailable.
- Fixed paste shortcuts on Colemak-DH and other non-QWERTY keyboard layouts.
- Fixed output language handling when custom system prompts are enabled.

## [0.3.2] - 2026-04-23

### Fixed

- Removed the pause-based audio interruption mode that could misfire and resume playback unexpectedly; dictation now only mutes audio.

## [0.3.1] - 2026-04-23

### Added

- Faster live dictation with realtime transcription support.
- A setting for choosing the realtime transcription model.
- Run log exports, so you can save a full dictation run for debugging or sharing.
- A Copy Transcript action in the run log.
- A voice command for submitting text: say "press enter" at the end of a dictation.
- Audio controls that can mute or pause other audio while you dictate, then restore it when recording stops.
- Build details in Settings for easier troubleshooting.
- Direct shortcuts from FreeFlow to the right macOS permission settings.
- A What’s New popup when an update is available.

### Improved

- Recording feedback now feels more responsive.
- The run log is easier to scan and use.
- Exported run logs include more useful context for reproducing issues.
- Realtime transcription is more reliable when recordings are cancelled, retried, or finish with no text.
- Provider settings are easier to edit without accidental whitespace or half-saved values.
- FreeFlow now warns you if alert sounds may be hard to hear because system audio is muted or very low.
- Update prompts now show the version, release date, and release notes more clearly.
- FreeFlow now uses proper version numbers for updates instead of internal build names.

### Fixed

- Fixed cases where arrow or navigation keys could be mistaken for Fn shortcut input.
- Fixed a clipboard timing issue that could paste the wrong content.
- Fixed empty realtime transcriptions getting stuck instead of finishing cleanly.
- Fixed waveform glitches caused by invalid audio levels.
- Filtered out more common transcription artifacts.
- Fixed alert sound hints staying visible after alert sounds are turned off.
- Fixed update checks so users only see real app releases, not internal builds.
- Fixed update checks so the app does not offer an older or already-installed version.
