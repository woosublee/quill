# Contributing to Quill

Thanks for your interest in Quill. This guide covers how to build and test the app and how to send a change.

Quill is a fork of [FreeFlow](https://github.com/zachlatta/freeflow). Changes that belong in FreeFlow itself are best sent there; this repository takes changes to Quill.

## Prerequisites

- A Mac running macOS 13 or later (iCloud sync needs macOS 14 or later)
- Xcode Command Line Tools (`xcode-select --install`)
- CMake, which builds the bundled whisper.cpp and llama.cpp runtimes

An API key is not needed to build or test. To try cloud transcription or cleanup end to end, use a key for any OpenAI-compatible provider.

## Building

Quill is built with `swiftc` and Make. There is no Xcode project.

```bash
make run    # builds and opens Quill Dev.app, separate from an installed Quill
make        # builds Quill.app
```

The Makefile signs local builds with the first valid Developer ID Application identity in your login keychain. To choose one, pass its hash from `security find-identity -v -p codesigning`:

```bash
make ARCH="$(uname -m)" CODESIGN_IDENTITY=<sha1>
```

For a build check without a signing identity, ask for ad-hoc signing with `CODESIGN_IDENTITY=-`. macOS ties permissions to the signature and app path, so ad-hoc builds and identity changes can make macOS ask for permissions again.

## Testing

```bash
make check
git diff --check
```

`make check` validates plist, entitlement, shell and YAML files, then runs the Core, Recording, Transcription and App State test shards. It needs no API key or live provider.

- Add a focused regression test in `Tests/` for each deterministic bug fix.
- Production sources are discovered automatically. Every test file must be compiled and run exactly once by the existing Makefile wiring; `make check` fails otherwise.
- Use synthetic fixtures and mocked or local dependencies. Never put real audio, transcripts, screenshots, clipboard contents, window titles, credentials or private provider URLs in tests, logs or reports.

Unit tests don't verify audio capture, global shortcuts, Accessibility, Screen Recording, clipboard or paste behavior, updates or the signed app. Changes there need manual verification in a `make run` build before merge, with the steps written in the pull request. Don't trigger permission prompts or change system permissions without the tester's approval.

## Sending a change

1. Create a branch from `main`.
2. Keep the change focused and avoid unrelated edits.
3. Run `make check` and `git diff --check`.
4. Open a pull request against `woosublee/quill`. Describe what changed, how it was tested, and any effect on privacy, permissions, storage, updates or releases.

Changes to provider requests, prompts, storage, permissions, clipboard handling, Accessibility, update verification, signing or GitHub workflows are high risk. Call them out in the pull request.

Don't add telemetry, crash reporting, persistent logging or new data transmission without discussing it first in an issue.

## License

By contributing, you agree that your contributions are licensed under the project's MIT license.
