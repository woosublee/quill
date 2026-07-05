# Local Whisper native runtime design

GitHub issues: [#75](https://github.com/woosublee/quill/issues/75), [#145](https://github.com/woosublee/quill/issues/145), [#9](https://github.com/woosublee/quill/issues/9), [#132](https://github.com/woosublee/quill/issues/132)

## Goal

Replace Quill's default Local Whisper path from the current Python/`mlx_whisper` CLI dependency to a Quill-managed native Whisper runtime based on whisper.cpp.

The first implementation should make this flow work:

```text
Quill recording
→ Quill-managed native Whisper runner
→ Quill-managed whisper.cpp model
→ local transcript
```

This is the first phase of #75 and the Phase 1 transcription work inside #145. The intent is not to build a new local provider abstraction first; it is to replace the existing `mlx_whisper` execution path with a native equivalent that normal users can use after installing Quill.

## Current problem

Today the Settings model download UI looks like it prepares Local Whisper, but it only downloads model files after a separate Python `mlx_whisper` environment already exists.

Current default path:

```text
Quill
→ ~/.local/bin/mlx_whisper
→ mlx-whisper Python environment
→ MLX model cache under Hugging Face cache
→ ffmpeg invoked internally by mlx_whisper
```

On a clean Mac, this fails before model download because the user has not installed Python tooling, `pipx`, `mlx-whisper`, Hugging Face dependencies, or `ffmpeg`. The resulting error also exposes an expanded home path such as `/Users/<name>/.local/bin/mlx_whisper`, which feels like an internal developer path in product UI.

## Decision

Introduce a Quill-managed native Whisper path as the default non-Apple local transcription path.

```text
Quill
→ bundled whisper.cpp runner
→ model stored under Quill Application Support
→ Quill recording WAV/PCM input
→ transcript
```

Keep the existing `mlx_whisper` code path only as a legacy/advanced escape hatch for now. Do not build a complex migration UI for existing `mlx_whisper` users in the first implementation, because Quill is currently mostly self-used and the priority is unblocking the clean-install product path.

## Relationship to upstream local-provider support

This design does not replace the upstream-aligned OpenAI-compatible local-provider path.

There are two different ideas that both use the words "local model":

1. **Quill-managed native runtime** — Quill ships or manages the runtime/model. This is #75 and is the no-extra-setup path for Local Whisper.
2. **BYO OpenAI-compatible provider** — the user runs Ollama, LM Studio, or another local/self-hosted server and Quill points API settings at it. This belongs to #64 / #145 Phase 2 and remains important for post-processing, Edit Mode, context, and advanced transcription providers.

For #75, the implementation should focus on replacing `mlx_whisper` with whisper.cpp for Quill's own Local Whisper flow. Provider settings cleanup remains separate.

## First implementation scope

### In scope

- Bundle or otherwise include a whisper.cpp-based runner in the app build.
- Add a Quill-owned model store for whisper.cpp-compatible model files.
- Add one recommended installable model for the first version.
- Download, verify, delete, and report readiness for that model.
- Transcribe Quill-recorded audio files through the native runner.
- Route Local Whisper to native runner by default once the native model is installed.
- Keep Apple Speech working as the no-download built-in local option.
- Keep `mlx_whisper` available as a legacy advanced path.
- Hide Python, `pipx`, Hugging Face CLI, and raw `/Users/...` paths from the normal Local Whisper UI.
- Preserve technical details for debugging while showing concise user-facing errors.

### Out of scope for the first implementation

- External audio import support for `mp3`, `m4a`, `mp4`, `webm`, `ogg`, `flac`, and similar formats.
- Bundling or selecting an FFmpeg build.
- AVFoundation import conversion pipeline.
- Reusing or migrating existing MLX model caches.
- Detecting every existing `mlx_whisper` installation and presenting a migration wizard.
- Embedded local LLM / meeting-note generation.
- OpenAI-compatible local provider configuration cleanup.

## Model format and migration

`mlx_whisper` and whisper.cpp use different model formats.

Existing MLX models such as:

```text
mlx-community/whisper-large-v3-turbo
weights.npz / weights.safetensors
```

are not treated as installed native Whisper models. The native path uses a whisper.cpp-compatible model file stored in Quill-owned storage.

The first implementation should not delete or modify the existing Hugging Face / MLX cache. It should simply require a one-time download of the native model.

User-facing copy can be simple:

```text
Native Whisper uses a different model format from legacy mlx-whisper. Download the recommended model once to use the built-in local engine.
```

## Components

### `NativeWhisperModel`

Represents one whisper.cpp-compatible model.

Initial fields:

```swift
struct NativeWhisperModel: Identifiable, Equatable, Codable {
    let id: String
    let displayName: String
    let description: String
    let downloadURL: URL
    let expectedFileName: String
    let approximateBytes: Int64
    let checksumSHA256: String
}
```

The first version should expose one recommended model. Additional models can be added later by extending the catalog.

### `NativeWhisperModelCatalog`

Small static catalog for installable native models.

Responsibilities:

- provide the recommended model;
- find a model by id;
- keep display metadata separate from install state.

This should not replace the broader model-selection design from the 2026-06-19 spec. It is the concrete native transcription catalog for #75 Phase 1.

### `NativeWhisperModelStore`

Owns model files under Quill Application Support.

Recommended root:

```text
~/Library/Application Support/<Bundle display name or Quill>/LocalWhisper/Models
```

Responsibilities:

- return the expected final model path;
- return a temporary partial-download path;
- detect installed, missing, partial, and corrupt states;
- verify expected size and required checksum;
- safely delete a model;
- avoid touching non-Quill-owned Hugging Face caches.

The store should follow the existing app-owned storage pattern used by audio persistence rather than writing to `~/.cache/huggingface`.

### `NativeWhisperInstaller`

Downloads and verifies the recommended native model.

States:

```swift
enum NativeWhisperInstallState: Equatable {
    case notInstalled
    case downloading(downloadedBytes: Int64, totalBytes: Int64?)
    case verifying
    case ready
    case failed(message: String, details: String?)
}
```

Responsibilities:

- stream download with progress;
- write to a partial file first;
- support cancel/retry;
- verify before moving into the final path;
- clean partial files on cancel/failure when safe;
- surface concise messages and optional technical details.

### `NativeWhisperRuntime`

Runs the whisper.cpp helper.

Responsibilities:

- find the bundled runner;
- check executable availability;
- build arguments for model path and audio path;
- run the process with a minimal controlled environment;
- capture stdout/stderr;
- return normalized transcript text;
- classify runner/model/audio failures.

The first implementation should use a CLI helper process, not a linked C/C++ library. This keeps Swift integration small and leaves room to change the internals later without changing `TranscriptionService` call sites.

Potential bundle locations:

```text
Quill.app/Contents/Resources/whisper/whisper-cli
```

or:

```text
Quill.app/Contents/MacOS/whisper-cli
```

Prefer a bundle-owned path that is code-signed with the app. The Makefile should copy and sign the helper explicitly rather than relying on a developer-local binary path.

### Legacy `mlx_whisper`

The existing path remains as advanced fallback.

Initial UI treatment:

```text
Advanced
Use legacy mlx-whisper
mlx_whisper Path
```

The first implementation does not need to detect all legacy users, show a migration wizard, or manage legacy caches. If the user enables the legacy path, Quill uses the current `mlx_whisper` code path.

## Transcription routing

After the first implementation, local transcription routing should be conceptually:

```text
if selected model is Apple Speech:
    use Apple Speech
else if legacy mlx_whisper is explicitly enabled:
    use legacy mlx_whisper
else if native model is installed:
    use NativeWhisperRuntime
else:
    report Local Whisper is not installed and show install action
```

This keeps the default path native while preserving an escape hatch.

Do not silently fall back from native Whisper to legacy `mlx_whisper` unless the user explicitly enabled the legacy path. Silent fallback would make failures harder to diagnose and could reintroduce Python/ffmpeg dependency surprises.

## Audio input strategy

The first native path supports Quill-recorded audio only.

The runner should receive an audio file produced by Quill's recording pipeline. Require the recording pipeline to emit a whisper.cpp-compatible WAV/PCM format for phase 1. Defer any conversion work to a separate follow-up.

External imports remain on the existing supported path until a later phase decides how to handle decoding/conversion.

This keeps #9 contained:

- `mlx_whisper` currently calls `ffmpeg` internally even for prepared WAV files.
- whisper.cpp can avoid user-installed `ffmpeg` when given compatible WAV/PCM input.
- broad import support may still need AVFoundation conversion or a bundled LGPL-only FFmpeg later, but that is not required for the first Quill-recording path.

## Settings UX

The normal Local Whisper section should describe the Quill-managed path.

Not installed:

```text
Local Whisper
Private transcription on your Mac.

Whisper Large v3 Turbo
Fast local transcription. About 900 MB.

[Install Local Whisper]
```

Installing:

```text
Installing Local Whisper
Downloading model… 42%
[Cancel]
```

Ready:

```text
Local Whisper is ready.
[Use Local Whisper]
[Delete Model]
```

Failed:

```text
Could not install Local Whisper.
Check your network connection and free disk space, then try again.
[Retry]
[Show Details]
```

Advanced:

```text
Use legacy mlx-whisper
Path: ~/.local/bin/mlx_whisper
```

Normal users should not see Python, `pipx`, Hugging Face cache paths, or expanded `/Users/<name>` paths unless they open technical details.

## Error handling

Use two layers for errors.

### User-facing messages

Examples:

```text
Local Whisper is not installed yet. Install the recommended model to use local transcription.
```

```text
Local Whisper could not read this recording. Try again or switch to Apple Speech.
```

```text
Could not install Local Whisper. Check your network connection and free disk space, then try again.
```

### Technical details

Preserve details for debugging:

- runner path;
- runner executable status;
- model path;
- model file size;
- model checksum result when available;
- input audio path;
- input audio existence/readability/size;
- process exit code;
- stdout/stderr summary with both head and tail when useful.

This aligns with #132 without turning the first implementation into a full diagnostic-export project.

## Build and packaging

The app build must not depend on a developer-local whisper.cpp binary.

First implementation should add an explicit build/package path for the helper:

- build or vendor the whisper.cpp CLI helper in a reproducible location;
- copy it into the app bundle;
- code-sign it with the same identity as the app;
- verify it exists in the built app before marking build successful.

The exact helper acquisition method can be decided in the implementation plan. The design requirement is that release builds produce an app whose native Local Whisper runtime does not depend on `/opt/homebrew`, `~/.local`, or a manually installed `mlx_whisper`.

## Testing strategy

### Unit-level tests

Add tests for:

- model catalog lookup;
- model store paths under a temporary Application Support root;
- installed/missing/partial/corrupt state detection;
- safe delete behavior;
- install state display text;
- routing decision: Apple Speech vs native vs legacy.

### Runtime tests

Add a test seam so `NativeWhisperRuntime` can run a fake helper script in tests.

Fake-helper tests should cover:

- successful transcript output;
- empty transcript;
- non-zero exit;
- missing runner;
- missing model;
- missing/zero-byte audio file;
- stdout/stderr summarization.

### Manual verification

Before claiming the implementation works:

1. Build Quill Dev in the isolated worktree.
2. Confirm the bundled runner exists inside the app bundle.
3. Install/download the native model through Settings.
4. Record a short sample through Quill.
5. Confirm local transcription returns text without `mlx_whisper`, Python, `pipx`, or user-installed `ffmpeg` in the normal path.
6. Confirm Apple Speech still works.
7. Confirm legacy `mlx_whisper` remains available only when explicitly enabled.

## Baseline note

Before this design was written, `make test` was run in the isolated worktree. Several existing tests passed, then the suite failed on SwiftUI macro plugin lookup errors such as:

```text
external macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found
```

No product code had been changed at that point. Treat this as a pre-existing local toolchain/baseline issue to resolve or work around before using full `make test` as the final verification signal.

## Implementation order

1. Add the native model catalog/store types and tests.
2. Add installer state and model delete/retry behavior.
3. Add `NativeWhisperRuntime` with a fake-helper test seam.
4. Add build packaging for the whisper.cpp helper.
5. Wire native runtime into `TranscriptionService` routing.
6. Update Settings Local Options UI for install/ready/failure states.
7. Move existing `mlx_whisper Path` under Advanced/Legacy.
8. Run focused tests, then resolve or document the full-suite SwiftUI macro baseline before final verification.

## Explicit non-goals

- Do not implement #64 provider settings split in this work.
- Do not implement local LLM or meeting-note generation in this work.
- Do not implement external import conversion in this work.
- Do not delete legacy MLX/Hugging Face caches.
- Do not require users to install Homebrew, Python, `pipx`, `mlx-whisper`, or `ffmpeg` for the normal native Local Whisper path.
