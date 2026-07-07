# Changelog

All notable changes to Quill are documented here.

This project uses semantic versioning for public releases. Use `MAJOR.MINOR.PATCH`, where:

- `MAJOR` changes include breaking behavior or major compatibility changes.
- `MINOR` changes add user-visible features and improvements.
- `PATCH` changes fix bugs, polish existing behavior, or make small internal improvements.

## [0.1.21] - 2026-07-07

### Improved

- The Note Browser transcription selector now shows compact backend names in the sidebar while preserving the full backend/model description for assistive technology.

## [0.1.20] - 2026-07-07

### Improved

- The Note Browser transcription menu now shows the selected backend and model, distinguishing API Standard, API Realtime, Native Whisper, Apple Live, and installed legacy mlx-whisper models.
- Audio import now uses the same backend/model choices as the Note Browser, so choosing Native Whisper or a legacy mlx-whisper model matches the backend used for the import job.

## [0.1.19] - 2026-07-07

### Improved

- Long Note Browser detail titles now stay on one line while allowing horizontal scrolling to reveal hidden text.
- The legacy mlx-whisper settings toggle now keeps legacy model choices visible without forcing the legacy engine, so switching to another local model no longer hides those choices.

## [0.1.18] - 2026-07-06

### Improved

- Native Local Whisper now supports compatible audio imports by preparing selected files for the bundled whisper.cpp runtime.
- Audio import keeps API-compatible formats selectable while only offering Local Whisper for formats the native runtime can handle.
- Local Whisper imports now fail faster when the bundled runner or model is unavailable, before converting audio.
- The global API key field in Settings can now be cleared after a key has been saved.

## [0.1.17] - 2026-07-06

### Added

- Local Whisper beta now ships with a bundled native whisper.cpp runtime and managed recommended model download, so Quill recordings can use local transcription without developer-installed Python, pipx, mlx-whisper, Hugging Face CLI, or ffmpeg.

### Improved

- The Local/API transcription settings tabs no longer switch Note Browser into an unavailable API mode when no API key is configured.
- Native Local Whisper model installs now verify file size and checksum, clean up partial downloads more safely, and keep download cancellation accessible from the keyboard.

## [0.1.16] - 2026-06-30

### Improved

- Note Browser audio player labels now keep their full intrinsic width, so long durations no longer overlap the waveform.
- Waveform bars now clamp spacing to stay inside the available player width, including narrow layouts.
- The Recordings sidebar header stays on one line while recording or when the count grows.
- The Note Browser detail toolbar restores the Liquid Glass pill on macOS 26 and keeps an ultra-thin material fallback on older macOS versions.

## [0.1.15] - 2026-06-27

### Improved

- Imported audio transcription now uses one consistent configuration snapshot for local/API transcription, language, vocabulary, and post-processing settings, reducing mismatches between the import dialog and background jobs.
- Imported audio files are copied off the main thread before transcription starts, keeping the app more responsive when selecting larger files.
- Instruction Guard now remains active when Quill translates dictated output, so translation runs still avoid answering or executing dictated instructions.

## [0.1.14] - 2026-06-25

### Added

- Paste custom words into your vocabulary straight from the menu bar, with a brief checkmark confirmation.
- New setting to keep dictations in your clipboard history (off by default), so clipboard managers like Paste, Raycast, or Maccy can record them when you want.
- Instruction Guard: when post-processing looks like it answered your dictated text instead of cleaning it up, Quill retries or falls back to the literal transcript. It can be toggled off in settings.

### Improved

- Transcription errors now tell a real network outage ("No internet — check connection") apart from a slow-provider timeout, instead of showing a confusing system message.

### Fixed

- Fixed a recording overlay window leak that kept the app busy in the background (CPU and memory) after dictations.

## [0.1.13] - 2026-06-19

### Fixed

- Google Calendar sign-in is now available again in released builds. The 0.1.12 build shipped without its bundled Google OAuth credentials, so calendar sign-in reported "not configured"; release builds now embed the credentials again.

## [0.1.12] - 2026-06-19

### Added

- The note audio player now supports pause and resume, seeking by clicking or dragging anywhere on the waveform, and a volume control in the player.

### Improved

- Recording the microphone together with system audio no longer adds crackle. The two sources are now mixed continuously instead of switching gain per sample.
- Quill now checks for updates daily instead of weekly, so released fixes reach you sooner.

## [0.1.11] - 2026-06-17

### Added

- Recording Overlay settings: choose how the overlay shows recording progress — Waveform only (new default), Show elapsed time on hover (the previous behavior), or Show elapsed time instead of the waveform. Clicking the overlay still opens the input switcher in every mode.

### Improved

- Accessibility is now requested only when a recording will actually use it — auto-paste or command mode. Plain dictation, MCP, Rec-button, and calendar recordings no longer demand Accessibility or block on it. When it is needed, the app shows the single native macOS prompt instead of a custom alert first.

### Fixed

- Switching the audio input mid-recording to a source that lacks permission (e.g. System Audio without Screen Recording) now shows a short notice on the overlay itself, instead of silently doing nothing. The detailed guidance still appears in the menu bar.

## [0.1.10] - 2026-06-17

### Added

- Note Browser: a down-chevron beside the Rec button lets you choose the audio input for the next recording — System Default, System Audio, or System Default + System Audio, plus any connected microphones — with the current input checked.

### Improved

- Recordings that switched inputs mid-session now finish faster: the captured segments are stitched by copying the raw audio instead of re-encoding it sample by sample, removing the pause before transcription on longer recordings.

## [0.1.9] - 2026-06-16

### Added

- Hover the recording overlay's waveform to see the elapsed recording time without taking up extra space — it shows in the same spot as `MM:SS` (or `H:MM:SS` past an hour) and reflects the full session, including across mid-recording input switches. Clicking the waveform still opens the input switcher.

## [0.1.8] - 2026-06-16

### Added

- Switch the audio input while a recording is in progress: click the recording overlay's waveform to choose System Default, System Audio, or System Default + System Audio without ending the session. Audio captured before each switch is stitched into a single continuous note.

### Fixed

- On displays without a notch, the recording overlay no longer extends past the menu bar — its height now matches the menu bar. The meeting reminder overlay uses the same height so it stays aligned when it wraps an active recording.

## [0.1.7] - 2026-06-13

### Improved

- Adopted the upstream permission polling fix so Accessibility and Screen Recording polling stops once both permissions are granted.
- Re-checks Accessibility trust immediately before recording starts to avoid stale permission state.

## [0.1.6] - 2026-06-13

### Added

- Replaced the custom in-app updater with Sparkle 2, including Sparkle-signed appcast generation for future updates.

### Improved

- Kept the stable `Quill.dmg` release asset as the bridge path for existing installs using the previous updater.
- Separated manual ad-hoc release artifacts from the stable update channel.

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
