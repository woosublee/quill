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

## Verification

Run before handing off code changes:

```bash
make check
git diff --check
```

`make check` validates plist, entitlement, shell, and YAML files, then runs the
complete Core, Recording, Transcription, and App State test suite. For a local
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
