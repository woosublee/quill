# Quill maintenance guide

Quill is a native macOS menu-bar dictation and meeting-notes app built directly
with `swiftc` and Make. It does not use an Xcode project for the application
build. Preserve that architecture unless a separately approved migration says
otherwise.

## Repository map

- `Sources/App.swift` and `Sources/AppDelegate.swift`: app lifecycle.
- `Sources/AppState.swift`: central pipeline orchestration and shared state.
- `Sources/AudioRecorder.swift` and `Sources/SystemAudioRecorder.swift`: audio capture.
- `Sources/TranscriptionService.swift`, `Sources/RealtimeTranscriptionService.swift`,
  and the native Whisper sources: transcription backends.
- `Sources/PostProcessingService.swift`: transcript cleanup and command transforms.
- `Sources/AppContextService.swift`: foreground-app metadata and screenshots.
- `Sources/ShortcutCore/`: shortcut models, matching, and session behavior.
- `Sources/PipelineHistoryStore.swift` and `Sources/NoteAssetStore.swift`: local note history.
- `Sources/UpdateManager.swift`: Sparkle update behavior.
- `Sources/SettingsView.swift`, `Sources/SetupView.swift`, and other SwiftUI files: UI.
- `Packages/QuillNoteSyncCore/`: note sync record, merge, payload, CloudKit,
  and audio-part logic shared with the iPhone app (#634).
- `Packages/QuillAITextCore/`: AI text rules shared with the iPhone app:
  spoken- and output-language checks, protected atoms, text chunking, the
  post-processing prompt policy, vocabulary parsing, the instruction-execution
  detector, the post-processing output validator, the prompt data envelope,
  the local-model token budget, transcript cleanup (its prompt, splitter,
  and the chunk runner, which can take the model's own token counter and
  then splits again any chunk whose counted prompt doesn't fit), which
  cleanup errors try the fallback model
  (`PostProcessingFallbackPolicy`), and what a failed cleanup stores: its
  issue (`PostProcessingError.userIssueRecord`, which imports
  `QuillUserIssueCore`) and its outcome
  (`AIProcessingOutcome.afterPostProcessingFailure`). Cleanup requests, the
  fallback model choice, and Edit Mode stay in
  `Sources/PostProcessingService.swift`.
- `Packages/QuillUserIssueCore/`: the stored user-issue record (codes,
  severity, context, the provider diagnostic code allow-list) and its
  persisted status string (`user-issue:v1:`). It also decides how an issue
  reads on screen, for both apps: the copy keys for each code
  (`QuillUserIssueCode.copy(for:)`), the recovery action and its button key,
  and the detail rows (`QuillUserIssueRecord.presentation(localize:)`). Each
  app translates the keys with its own String Catalog. It imports no other
  shared module; `QuillAITextCore`, `QuillSummaryFormatCore`,
  `QuillSummaryGenerationCore`, and `QuillNoteCore` import it. The Mac's
  catalog lookup, the error constructors, and the issue views stay in
  `Sources/QuillUserIssue.swift` and `Sources/QuillUserIssueView.swift`.
- `Packages/QuillSummaryFormatCore/`: the stored meeting-summary format
  (envelope, content, attempt, calendar context, source fingerprint, Markdown
  rendering) and summary editing (what counts as an empty row, dropping
  empty rows, saving an edit, reverting to the original, keeping done
  states, and keeping rows on a same-text regeneration).
  The attempt's on-screen details stay in `Sources/MeetingSummaryModels.swift`.
- `Packages/QuillSummaryGenerationCore/`: how a meeting summary is made: the
  prompts, chunking (which, like cleanup, splits again any chunk whose
  counted prompt doesn't fit) and merging, the strict draft decoder,
  evidence repair and output checks, and the summary errors. Model
  requests, fallbacks, and cooldowns stay in
  `Sources/MeetingSummaryService.swift`, which plugs into the generator as
  its draft requester.
- `Packages/QuillProviderCore/`: model rules shared with the iPhone app: the
  cloud and local model lists and capabilities, rate-limit cooldowns, the
  temperature capability cache, the request transport, provider URL checks,
  the API key check, the cloud transcription failure categories and retry
  policy, the cloud transcription request and reply parser, whether a saved
  cloud or local AI transcription job resumes, starts over, or waits for a
  retry under the current settings (`CloudTranscriptionResumeDecision`; the
  Mac fills its identities in `Sources/CloudTranscriptionResumeIdentity.swift`),
  the realtime
  session rules (WebSocket URL, connection request, `session.update`), the
  chat completion request, and cloud consent (#693): the per-origin grants
  (`CloudConsentLedger`), which providers a set of saved keys goes to and
  what withdrawing one clears (`CloudConsentTargets`), which provider clearing
  a key withdraws (#723), and the prompt's copy
  keys (`CloudConsentCopy`). Each app still sends the request with its own
  transport and logging, reads the reply, and runs the realtime socket
  itself, and draws its own consent prompt. Cooldowns, the temperature
  cache, the Groq model migration, and the consent grants read and write
  `UserDefaults`. API keys and the rest of the settings stay in the app.
- `Packages/QuillAudioLevelCore/`: the recording meter level and waveform bar
  heights, shared with the iPhone app. Reading RMS from the capture, the
  locking around it, and the SwiftUI drawing stay in `Sources/`.
- `Packages/QuillAudioFormatCore/`: the canonical recording file (16 kHz mono
  16-bit PCM with the 44-byte WAV header), shared with the iPhone app: the
  header, validation, the canonical copy of other PCM WAV layouts, and how
  much of a cut-off recording can be read. Recording, journaling, recovery,
  and chunking stay in `Sources/`.
- `Packages/QuillNoteCore/`: note data and rules shared with the iPhone app:
  how a note's date reads in a list row, its detail, and as an untitled
  note's name (`NoteTimestampFormatter`), and the calendar match record
  (`CalendarEventMatch` and its attendee, source, title state, and provider),
  which syncs as a note's `calendarMatch` bytes, so keep its keys and raw
  values, and what the note list's Select All button does
  (`NoteSelectAllAction`: Deselect All once every selectable visible note is
  selected), and what a note's transcript is after an edit
  (`NoteTranscriptEdit`: clearing it clears the raw transcript too, so a
  cleared note shows, summarizes, and syncs as empty on both apps), and how a
  note's synced post-processing status reads (`NoteMachineStatus`: importing,
  recording, transcribing, recovered, failed, or finished, and whether an
  empty transcript is still to come or was cleared and stays editable), with
  its status parsers and the one interrupted-transcription placeholder check
  (`NoteMachineStatus.isTranscriptionPlaceholder`, #720). It imports
  `QuillUserIssueCore`; the status text and recovery file work stay in
  `Sources/`. Reading a
  note's recording times stays in
  `Sources/NoteListRowDisplayData.swift`, and each app keeps its own selection
  state.
- `Packages/QuillNoteUI/`: SwiftUI note screens shared with the iPhone app
  (#697), built for macOS and iOS. So far: the note toolbar's state table
  (`NoteToolbarState`, the #690 rules for both apps) and its view
  (`NoteFloatingToolbar`); the one-line notice banner (`NoteBanner`, its
  "+N" and close buttons, and its surface, #744: the Mac's
  `QuillStatusBanner` forwards to it); the work status (`NoteWorkStatus`:
  every transcribing, post-processing, summarizing, waiting, cancelling, and
  paused state, its copy key, indicator, reason, and progress, and the
  toolbar's work labels, read from the same table) and its views
  (`NoteWorkStatusView`, `NoteWorkStatusOverlay`, `NoteWorkStatusIndicator`);
  the layout helper `QuillWidthClass`, which turns a container's width
  into compact, regular, or wide, so screens lay out by width, never by
  device model; and the note layout rules (`QuillNoteLayout`): the window's
  width and height decide whether the list sits beside the note (wide and
  not compact height), and the note column's own width decides its side
  margins and body maximum width; the work-status capsule sits in the
  middle of the visible note area at every width. The Mac maps its work in
  `Sources/NoteBrowserWorkStatus.swift` and uses only the layout's list
  column width; its note column keeps its own margins. Each app passes the note's state, its localized
  strings, and the actions; the views hold no app state and run no work.
  Platform differences stay in small `#if os` branches. The Mac's note
  window, shortcuts, and the work itself stay in `Sources/`.
- `Packages/QuillDesignTokens/`: design tokens shared with the iPhone app
  (#623): spacing and radius scales, the issue colors, the note page
  background (a color per platform, #697), the tints (glass,
  toolbar, hairline, banner, chip, row hover, selection and badge, empty disc,
  record ring, and the accent tints), the glass, status, banner, record,
  iPhone record, and selected-row shadows (the last two per appearance),
  the status wash, settings card, and summary bullet opacities, the text
  styles (note title, transcript, row, banner, meta line, and work status:
  a fixed size on the Mac, Dynamic Type on iOS;
  draw a style with `quillTextStyle(_:)`, which also applies its
  per-platform tracking and scales the meta line from its Mac size on iOS),
  the control sizes (note toolbar, status progress, touch minimum, note
  row, checkbox, status dot, empty disc, record button, close button,
  search field, summary bullet; a value per platform where they differ),
  the note layout sizes (`QuillLayoutSize`: list column, note side margins,
  body maximum width, and the Mac Summary tab's width and bottom room), and
  the width breakpoints (#697).
  `Tests/QuillDesignTokensTests.swift` checks them against
  `docs/design-system/tokens.json`; change both together.
  `QuillNoteUI` imports it.
- The Makefile builds each shared module as its own Swift 6 module before the
  app and every test executable; the root `Package.swift` exposes them to the
  iPhone app in the same language mode.
  Resolving that package also downloads Sparkle, which the iPhone app never
  builds or links.
- `Tests/`: dependency-free executable and grouped full-source tests.
- `.github/workflows/tests.yml`: sharded pull-request verification.
- `.github/workflows/release.yml`: official notarized Developer ID release.
- `.github/workflows/self-signed-release.yml`: retired self-signed release; do not dispatch.
- `.github/workflows/manual-release.yml`: manually published prerelease builds.
- `.github/workflows/dev-release.yml`: signed development release workflow.

## Working rules

- Search with `rg` or `rg --files` before editing.
- Preserve unrelated changes in a dirty worktree.
- Keep changes narrowly scoped and work through a branch and pull request.
- Do not push directly to `main`.
- Do not push, open a pull request, merge, tag, publish a release, dispatch a
  workflow, or move the `dev` tag without explicit authorization for that action.
- Do not change versions, release notes, signing, notarization, updater assets,
  or release workflows during ordinary maintenance.
- Avoid adding dependencies when the standard library or existing frameworks
  are sufficient.
- Production sources are discovered automatically by the Makefile. Every test
  source must be compiled and executed exactly once by the existing shard wiring.

## Shared core with the iPhone app

Logic both apps need lives once, in `Packages/`, and the iPhone app loads it
from this repository at a pinned revision. Change it here; never copy it.

- Keep code in `Packages/` free of Mac-only types. Conversions to and from
  `PipelineHistoryItem` stay in `Sources/` as extensions.
- A change to shared code changes the iPhone app when it next moves its pin.
  Keep record shapes and synced bytes compatible, and say in the PR when shared
  behavior changes.
- Anything in `Packages/` is public under this repository's MIT license.

## Verification

Run before handing off code changes:

```bash
make check
git diff --check
```

`make check` validates plist, entitlement, shell, and YAML files, then runs the
complete Core, Recording, Transcription, and App State test suite. Two
`make check` runs (from two worktrees) can run at once: the two full-source
runners hold a `lockf` lock on `/tmp/quill-full-source-tests-<uid>.lock` and take
turns, because UserDefaults are shared across processes. Standalone tests
that touch `UserDefaults.standard` aren't covered by the lock. For a local
development app bundle build, the Makefile signs with the first valid Developer ID
Application identity in the login keychain (official releases are signed and
notarized in CI). If several are valid, pick one by hash from
`security find-identity -v -p codesigning`:

```bash
make ARCH="$(uname -m)"
make ARCH="$(uname -m)" CODESIGN_IDENTITY=<sha1>
```

Do not claim end-to-end behavior is verified from compilation or unit tests.
Changes involving audio capture, global shortcuts, Accessibility, Screen
Recording, clipboard or paste behavior, updater behavior, or a signed app
require documented manual verification before merge. Do not trigger permission
prompts or change system permissions without approval.

Every deterministic bug fix should include a focused regression test. Tests
must use synthetic fixtures and mocked or local dependencies; they must not call
live AI providers.

## Protected release contracts

The current official update path is `.github/workflows/release.yml` (Developer ID,
notarized, since v1.0.0). Preserve all of these contracts:

- Official releases are signed with the team's Developer ID Application identity
  and both the app and DMG are notarized and stapled. Do not ship an official
  release with another identity; switching identities makes existing users grant
  macOS permissions again.
- `.github/workflows/self-signed-release.yml` and the self-signed `Quill` identity
  are retired and must not be dispatched for stable releases. Local builds use
  Developer ID too; the self-signed certificate is no longer kept.
- Google Calendar OAuth client ID and secret are passed to both app and DMG builds.
- Official releases generate and sign a Sparkle `appcast.xml`.
- Official releases publish both `Quill.dmg` and `appcast.xml`.
- Stable versions and build numbers remain monotonically increasing.
- Stable release workflows share the `quill-official-stable-release` lock.
- Manual releases remain prereleases and are not used by Sparkle automatic updates.

## Privacy and security

Quill handles highly sensitive user data. Never commit, print, upload, or place
in test fixtures:

- API keys, signing credentials, Google Calendar OAuth secrets, or `.env` contents.
- Real audio or transcripts.
- Screenshots or screen-capture payloads.
- Selected text or clipboard contents.
- Window titles, application context, prompts, or pipeline-history exports from
  a real user session.
- Private provider URLs, usernames, or identifying filesystem paths.

Use invented synthetic data in tests. Do not inspect `.env`. Never add telemetry,
crash reporting, persistent logging, or additional data transmission without
explicit approval. New logs must avoid user content and secrets. Treat transcripts,
selected text, screenshots, provider responses, and imported files as untrusted input.

Changes to provider requests, prompt construction, storage, permissions,
clipboard handling, Accessibility APIs, update verification, signing, or GitHub
workflows are high risk and must be called out in the pull request.

## Definition of done

A change is complete only when:

- The requested behavior is implemented with no unrelated edits.
- Relevant regression tests were added or the no-test reason is documented.
- `make check` and `git diff --check` pass.
- Required manual verification is complete before merge or clearly marked pending.
- Privacy, permissions, migration, updater, and release impact are described.

## Code review rules

- Flag any new path that can log, persist, export, or transmit user content or
  credentials without a clear opt-in and redaction boundary.
- Flag changes that weaken exact shortcut matching, clipboard restoration,
  update validation, Sparkle compatibility, signing, or permission handling
  without a regression test and a documented safe path.
- Treat workflow changes as sensitive because code executed from `main` may
  access signing, OAuth, and release credentials.
