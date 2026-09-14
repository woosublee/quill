# Changelog

All notable changes to Quill are documented here.

This project uses semantic versioning for public releases. Use `MAJOR.MINOR.PATCH`, where:

- `MAJOR` changes include breaking behavior or major compatibility changes.
- `MINOR` changes add user-visible features and improvements.
- `PATCH` changes fix bugs, polish existing behavior, or make small internal improvements.

## [0.1.42] - 2026-09-15

### Improved

- Extended Save Files to export saved Meeting Summaries as separate TXT or Markdown files, including notes that only have a saved summary.
- Kept the Save Files layout stable as export selections change and showed when a saved summary may be out of date.

### Fixed

- Added filename-length preflight before exports, including generated summary suffixes, to reduce partial writes caused by overlong filenames.
- Distinguished interrupted transcription-service connections from offline errors, with clearer retry and alternative-network guidance in English and Korean.

## [0.1.41] - 2026-08-26

### Improved

- Continued `System Default + System Audio` recordings with the available source when one recorder fails to start after the required permissions are granted, while showing a persistent notice that identifies the missing and active inputs.
- Opened the Note Browser and started MCP integrations immediately after first-run setup, matching the normal relaunch path without starting services twice.
- Hardened transcript response handling so malformed JSON-like outputs and empty JSON containers are rejected while valid plain-text and one-word dictation remain accepted.

### Fixed

- Preserved Meeting Summary data, Calendar matches, language, processing status, titles, and other note metadata when transcripts are edited.
- Prevented failed Context captures from entering post-processing or Meeting Summary prompts, and classified unusable provider responses accurately.
- Prevented Realtime transcription from waiting indefinitely for a final commit by falling back to durable file transcription after a 10-second timeout.
- Classified oversized transcript-cleanup requests accurately, removed recovery actions that no longer apply after cleanup is disabled, and hid Calendar title suggestions that would not change the note title.

## [0.1.40] - 2026-08-16

### Improved

- Simplified the selected-note metadata header by keeping the compact `CTX` indicator without displaying generated Context summary prose.
- Hardened internal ownership and lifecycle boundaries for note storage, history recovery, Meeting Summary generation, transcription retry and resume, and local model management while preserving existing user-facing behavior.

## [0.1.39] - 2026-08-11

### Improved

- Show localized weekdays beside recording timestamps in the Note Browser list and note details, including recordings that span midnight.

## [0.1.38] - 2026-08-10

### Improved

- Adapted transcript cleanup automatically for short dictation and long meeting transcripts while preserving the source structure, language, and mixed-language text.

### Fixed

- Kept the original transcript when automatic-language cleanup translates all or part of a reliably detected source-language chunk, including Local AI processing.
- Preserved commands, paths, identifiers, URLs, email addresses, dates, and numeric facts when cleanup output is validated.

## [0.1.37] - 2026-08-06

### Fixed

- Rejected complete, partial, or reformatted transcript-cleanup prompt echoes and kept the original transcript instead of saving an incomplete model response.

## [0.1.36] - 2026-08-06

### Improved

- Made transcript cleanup warnings explain the safe, specific cause—including model output, response, context-limit, request, and timeout failures—and expose the selected model and effective timeout in Details.

### Fixed

- Kept dismissed cleanup warnings hidden during retranscription, including resumed Cloud retries, and showed a new warning only after its retry result was saved.
- Preserved original transcript fallbacks while correctly classifying malformed cleanup responses, empty model results, provider context limits, HTTP timeouts, and fractional timeout overrides.

## [0.1.35] - 2026-08-05

### Improved

- Extended Local AI post-processing time for cold model startup while keeping Cloud requests responsive.
- Added clearer timeout guidance for transcript cleanup and selected-text edits.

### Fixed

- Preserved original transcripts when AI cleanup times out and recorded accurate processing outcomes across audio imports, retries, and interrupted Cloud transcription resumes.

## [0.1.34] - 2026-08-02

### Improved

- Reduced typing lag in Vocabulary and Prompt editors by saving drafts on focus changes while flushing active drafts before recording snapshots them.
- Updated curated Cloud model choices, including currently supported Groq models and clearer image-input guidance for Context.

### Fixed

- Preserved custom prompt modification dates when draft flushes or prompt tests do not change the trimmed prompt.

## [0.1.33] - 2026-08-02

### Added

- Added a protected recovery flow for unavailable recording history: archive the current generation, start fresh, inspect and import snapshots from Recovery settings, and automatically delete completed recovery snapshots after seven days.

### Improved

- Protected recording history and audio assets when loading or persistence fails, blocking unsafe mutations while providing clear recovery guidance.
- Preserved spoken-language context through transcription and retries, with safer meeting-summary validation, durable diagnostics, consistent retry and deletion controls, and warnings when summary evidence cannot be verified.

### Fixed

- Untitled note exports now use locale-aware recording timestamps for filenames while continuing to prefer custom and calendar titles.

## [0.1.32] - 2026-07-31

### Improved

- Hardened Local AI processing with a 16 GiB model gate, completion-readiness retries, safer summary evidence validation, and durable recording-recovery storage checks.
- Retired the unsupported Qwen2.5 1.5B Local AI option while preserving unavailable saved selections for explicit replacement.

## [0.1.31] - 2026-07-30

### Added

- Added independent microphone selection for Microphone and Microphone + System Audio recording, so a chosen microphone stays in use when recording alongside System Audio.

### Improved

- Microphone selectors now show the active macOS default input device alongside System Default, and update when the default input changes without delaying menus.

## [0.1.30] - 2026-07-27

### Fixed

- Restored timestamp-based decoding in Native Whisper so local transcription follows detected speech boundaries instead of advancing in fixed 30-second windows.
- Made Native Whisper's Auto Detect option explicitly request automatic language detection instead of falling back to English.

## [0.1.29] - 2026-07-27

### Fixed

- Kept a discovered update visible in Settings and the menu bar after Quill restarts, while clearing notices for installed, skipped, or no-longer-available updates.
- Corrected the Sparkle setting used for the scheduled update-check interval.

### Improved

- Hardened official release publishing so stable display versions and build numbers must both move forward, with verification of the published latest appcast and Sparkle signature metadata.

## [0.1.28] - 2026-07-25

### Added

- Added in-app meeting summaries for completed notes, using the configured AI processing backend with retry and output-language controls.

### Improved

- Moved System Prompt, Instruction Guard, and Context Prompt editing and testing into a dedicated Prompts settings screen, keeping Models focused on providers, models, and context input settings.

## [0.1.27] - 2026-07-24

### Improved

- Kept Note Browser transcription choices and Models settings aligned, so the selected processing backend and model remain consistent across recording, import, retry, and configuration flows.
- Made context capture more resilient: Quill now warns when immediate capture is unavailable and only includes retry context when the active context setting permits it.

### Fixed

- Moved live-transcriber teardown off the main thread when switching inputs, reducing UI stalls during an active recording setup change.
- Scoped dismissible warning banners to their originating warning so one dismissal does not hide unrelated recovery guidance.

## [0.1.26] - 2026-07-22

### Added

- Added a retranscription recovery flow to Note Browser: saved recordings keep a visible retry entry point even when the currently selected transcription backend can't retry, with clear guidance to set up or switch to a supported model.
- Added a generic file export flow to Note Browser: save transcript text (as `.txt` or `.md`) and the original recording audio to any folder, remembering the last destination and confirming before replacing existing files.
- Enabled Note Browser by default for new installs.

### Improved

- Rebuilt onboarding as a streamlined 5-step wizard (Welcome, Processing, Permissions, Shortcut, Ready), running Native Whisper installs in the background instead of blocking setup navigation.
- Kept the existing Obsidian and Gemini export flow available from Note Browser's more-actions menu alongside the new file export.

## [0.1.25] - 2026-07-21

### Added

- Added durable recording journals and startup recovery for microphone, system-audio, and combined recordings, including sessions that switch audio inputs or encounter storage failures.
- Added automatic chunking, retry/backoff, and durable resume for oversized or interrupted cloud transcriptions.

### Improved

- Streamed combined-audio mixdown with bounded memory so long recordings no longer require loading entire source files at once.
- Built the bundled Native Whisper helper with an explicit embedded Metal contract on Apple Silicon.
- Replaced raw transcription and post-processing errors with safe, localized guidance and contextual recovery actions across Note Browser, Setup, Settings, and recording surfaces.

### Fixed

- Preserved recoverable audio and history state across crashes, force-quits, interrupted input switches, and low-storage failures.
- Kept original transcripts available when post-processing fails while presenting the failure as a warning instead of marking the note as failed.

## [0.1.24] - 2026-07-18

### Improved

- Redesigned Models settings around Cloud Provider, Transcription, Post-processing, and Context, with clearer model selection, API-key readiness, and feature-specific details.
- Integrated Native Whisper download and deletion controls with the main transcription model selector while preserving active-model behavior during installation.
- Kept installed legacy mlx-whisper choices available independently from the advanced management toggle.

### Fixed

- Preserved the selected Standard, Realtime, or Local transcription choice when saving a Cloud API key.
- Restored Native Whisper management immediately when opening Settings, removed a model-status refresh that could briefly freeze the UI, and added confirmation before closing Settings during a download.
- Disabled Output Language only when both Post-processing and Edit Mode are off, with localized guidance.

## [0.1.23] - 2026-07-17

### Added

- Added English and Korean app localization, including localized setup, settings, recording, meeting reminder, transcription, and update experiences with locale-aware formatting and automated resource validation.

### Fixed

- Fixed a startup crash when a stored Apple Live transcription choice for `System Default + System Audio` fell back to an installed Native Whisper model.

## [0.1.22] - 2026-07-17

### Security

- Restricted the local MCP server to loopback connections, validated local `Host` values, rejected browser-origin requests, and removed wildcard CORS access. Existing Claude Code MCP setups continue to use `http://localhost:3457` without an API key or migration.

### Improved

- Post-processing now switches to the fallback model immediately when the primary model is rate-limited and uses the updated Qwen 3.6 defaults for fallback and context work.
- Preserve exact wording translation now safely retains the literal transcript when a translation provider returns an empty result.
- Added English and Korean README documentation with clearer first-launch guidance.

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
