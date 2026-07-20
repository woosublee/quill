# Native Whisper Metal Contract Design

## Context

Issue #184 was opened under the assumption that Quill's bundled whisper.cpp v1.9.1 helper was built without Metal and therefore ran local transcription on CPU only. Investigation against the current `origin/main`, the checked-out whisper.cpp source, the built helper, and an installed `ggml-large-v3-turbo` model showed that this assumption is no longer correct.

On macOS, whisper.cpp v1.9.1 defaults to:

- `GGML_METAL=ON`
- `GGML_METAL_EMBED_LIBRARY=ON`
- `whisper-cli` GPU use enabled unless `-ng` or `--no-gpu` is passed
- flash attention enabled by default

Quill's current helper contains the Metal backend, links Metal and MetalKit, and embeds the Metal kernel source inside the executable. `NativeWhisperRuntime` does not pass the no-GPU flag, so the normal local transcription path already uses Metal when available.

A local probe on an Apple M4 Max using the bundled arm64 helper, the installed `ggml-large-v3-turbo` model, and a deterministic 30-second 16 kHz mono WAV measured:

- default Metal path: 0.89 seconds wall-clock
- explicit CPU path with `-ng`: 2.49 seconds wall-clock
- observed speedup: approximately 2.8×

The probe also logged Metal initialization and selection of the Apple M4 Max device. This is preliminary engineering evidence rather than a portable benchmark guarantee.

The remaining product risk is not absent acceleration. It is that Quill relies on upstream defaults and does not enforce or continuously validate its Metal artifact contract. A future whisper.cpp update or build change could silently produce a CPU-only helper.

## Goal

Make Quill's existing Native Whisper Metal support explicit, reproducible, and regression-resistant without changing local transcription behavior, model installation, UI, or backend selection.

## Product decision

Issue #184 will be completed as a build and validation hardening task rather than as a new acceleration feature.

Quill will:

- explicitly request the Metal backend and embedded Metal kernels when building whisper.cpp on macOS,
- fail the build if the helper no longer satisfies the expected Metal artifact contract,
- retain the current GPU-enabled `whisper-cli` runtime behavior,
- retain the x86_64 slice in universal releases,
- document and measure the existing acceleration,
- avoid adding an unproven automatic GPU-to-CPU retry path.

## Non-goals

- Replacing the `whisper-cli` subprocess with a direct whisper.cpp library integration
- Changing the recommended Native Whisper model or its checksum
- Adding a model quantization or model-selection feature
- Changing Legacy mlx-whisper behavior
- Changing cloud transcription or post-processing
- Adding a user-facing Metal toggle
- Adding automatic CPU retry after a Metal failure without a reproduced failure case
- Guaranteeing a fixed performance multiplier on every Apple Silicon generation
- Adding a separate `default.metallib` while embedded Metal kernels remain the selected build mode
- Removing x86_64 support from the universal release

## Verified current behavior

### Build configuration

`BuildSupport/WhisperRuntime/build-whisper.cpp.sh` builds whisper.cpp v1.9.1 with static whisper and ggml libraries. The script already:

- builds `whisper-cli`,
- rejects dynamic `libwhisper` and `libggml` dependencies,
- validates requested architectures,
- supports a universal `arm64;x86_64` build.

It does not explicitly pass the Metal CMake options. Metal is enabled only because whisper.cpp currently sets the macOS default to ON.

### Embedded Metal resource model

With `GGML_METAL_EMBED_LIBRARY=ON`, whisper.cpp v1.9.1 does not require Quill to bundle a separate `.metallib`. It combines the Metal source and required headers and embeds them in the executable's `__DATA,__ggml_metallib` section, exposing `ggml_metallib_start` and `ggml_metallib_end` symbols.

At runtime, ggml compiles the embedded Metal source through Metal. `GGML_METAL_PATH_RESOURCES` belongs to the non-embedded source fallback and is not needed for Quill's selected mode.

### Runtime behavior

`NativeWhisperRuntime` executes the bundled helper with the current arguments:

```text
-m <model>
-f <audio>
-nt
-mc 0
-oj
-of <temporary-output-base>
[-l <language>]
```

The helper's GPU behavior is enabled by default. Quill does not pass `-ng` or `--no-gpu`, so no new runtime argument is necessary to enable Metal.

The generic `-ngl` option found in whisper.cpp's shared example utilities does not control `whisper-cli`. The transcription CLI uses a `use_gpu` boolean and exposes `-ng` only for disabling GPU execution.

## Architecture

### 1. Explicit build contract

`BuildSupport/WhisperRuntime/build-whisper.cpp.sh` will pass these CMake options explicitly:

```text
-DGGML_METAL=ON
-DGGML_METAL_EMBED_LIBRARY=ON
```

This records Quill's intent independently of upstream defaults. The existing static library, examples, tests, architecture, and release settings remain unchanged.

The build remains a single CMake invocation. For `ARCH=universal`, CMake continues to build `arm64;x86_64`, and the resulting helper must contain both slices.

### 2. Helper artifact verifier

The whisper helper's artifact checks will be represented by a focused shell verifier in `BuildSupport/WhisperRuntime/`. The build script will invoke this verifier after creating `whisper-cli`, and Makefile targets may invoke the same verifier against the helper copied into an app bundle.

The verifier consumes:

- helper path,
- expected architecture mode (`arm64`, `x86_64`, or `universal`).

It validates:

1. The helper exists and is executable.
2. The helper has nonzero physical size.
3. `lipo -archs` contains the requested architecture or both `arm64` and `x86_64` for a universal build.
4. `otool -L` shows Metal and MetalKit framework dependencies.
5. `otool -L` does not show dynamic `libwhisper` or `libggml` dependencies.
6. `nm` finds both `ggml_metallib_start` and `ggml_metallib_end`, proving that the selected embedded-kernel contract is present.

Each failure emits a specific diagnostic and exits nonzero. Quill must not silently package a CPU-only or incomplete helper.

The verifier uses only macOS command-line tools already required by the build: `test`, `stat`, `lipo`, `otool`, `nm`, and `grep`.

### 3. Makefile integration

The existing `.whisper-helper` build remains the source of the helper path. Its dependencies will include the new verifier so verifier changes invalidate the stamp.

A focused target, `native-whisper-helper-test`, will validate the built helper without rebuilding the full app when the current stamp is fresh. It accepts the existing `ARCH` setting and applies the same architecture expectation as the build script.

The app build will continue to:

- copy the verified helper to `Contents/Resources/whisper/whisper-cli`,
- mark it executable,
- sign the helper before signing the outer app.

No extra Metal resource file is copied.

### 4. Runtime contract

`NativeWhisperRuntime` keeps its current arguments and environment. It will not add:

- `-ng`,
- `--no-gpu`,
- `-ngl`,
- `GGML_METAL_PATH_RESOURCES`,
- a Metal resource path.

A runtime unit test will record helper arguments and assert that Quill does not disable GPU execution. Existing assertions for `-mc 0`, JSON output, language handling, process failure, and cancellation remain intact.

### 5. Release contract

Official universal release builds must produce:

- a universal app executable,
- a universal `whisper-cli` with arm64 and x86_64 slices,
- Metal and MetalKit dependencies in the helper,
- embedded Metal kernel boundary symbols,
- no dynamic whisper/ggml libraries,
- a valid deeply signed app and DMG.

The model remains downloaded after installation and is not included in the app or DMG.

## Data flow

```text
Makefile
  -> build-whisper.cpp.sh
      -> checkout whisper.cpp v1.9.1
      -> CMake with explicit Metal + embedded kernels
      -> build whisper-cli
      -> verify-native-whisper-helper.sh
  -> copy verified helper into app Resources/whisper
  -> sign helper
  -> sign app

NativeWhisperRuntime
  -> locate bundled helper
  -> validate helper and downloaded model
  -> execute whisper-cli without --no-gpu
  -> whisper.cpp selects Metal when available
  -> read JSON transcript
```

## Error handling

### Build-time failures

Artifact contract failures are release engineering errors, not user-facing runtime errors. The build stops with a targeted message when:

- the helper is missing, empty, or not executable,
- an expected architecture is absent,
- Metal or MetalKit linkage is absent,
- an embedded kernel symbol is absent,
- a dynamic whisper or ggml dependency is present.

There is no CPU-only packaging fallback. A release that unexpectedly loses Metal support must fail visibly.

### Runtime failures

Existing `NativeWhisperRuntimeError` behavior remains unchanged. This task does not add a second automatic CPU execution after a failed Metal run.

An automatic fallback is intentionally excluded because:

- no Metal execution failure has been reproduced,
- a second full transcription changes latency and cancellation semantics,
- duplicate execution could obscure the actual artifact or hardware problem,
- Intel and Apple Silicon fallback policy should be based on concrete failure evidence.

If a reproducible Metal-only failure appears later, it should receive a separate runtime fallback design and tests.

## Test strategy

### Fast source and unit tests

Add `Tests/NativeWhisperBuildContractTests.swift` to verify that:

- the CMake invocation explicitly enables `GGML_METAL`,
- embedded kernels are explicitly enabled,
- the helper verifier is invoked,
- the verifier contains architecture, Metal framework, embedded symbol, and dynamic dependency checks,
- the Makefile exposes and wires `native-whisper-helper-test`.

Extend `Tests/NativeWhisperRuntimeTests.swift` so a fake helper records its arguments and the test asserts:

- `-ng` is absent,
- `--no-gpu` is absent,
- the existing `-mc 0` contract remains present.

These tests run under `make test` and do not rebuild whisper.cpp.

### Actual artifact validation

Run:

```bash
make native-whisper-helper-test ARCH=$(uname -m)
```

For release validation, run:

```bash
make native-whisper-helper-test ARCH=universal
```

The universal invocation may rebuild the helper when its current build settings do not match `ARCH=universal`.

### App validation

Build only the development bundle and never modify `/Applications/Quill.app`:

```bash
make all APP_NAME="Quill Dev" BUNDLE_ID="com.woosublee.quill.dev" CODESIGN_IDENTITY=Quill
xattr -cr build/
codesign --verify --deep --strict --verbose=2 "build/Quill Dev.app"
```

When local Keychain access prevents the configured identity from signing, an ad hoc build may verify compile and bundle structure, but that does not replace the required release-identity CI or release verification.

### Performance smoke

Performance is measured manually on Apple Silicon because wall-clock thresholds are unsuitable for shared CI.

Use:

- the same helper,
- the same installed model,
- the same canonical WAV,
- one warm-up run per mode,
- at least three measured runs per mode,
- median wall-clock time.

Compare:

```text
Metal: whisper-cli <normal Quill arguments>
CPU:   whisper-cli -ng <normal Quill arguments>
```

Record:

- hardware and macOS version,
- model identity,
- audio duration and format,
- Metal initialization/device-selection evidence,
- Metal median,
- CPU median,
- relative speedup,
- transcript equivalence,
- helper size,
- final DMG size.

Metal must be faster than CPU on the measured Apple Silicon machine. The issue's 2× target remains a product performance target, not an automated build gate.

## Acceptance criteria

- CMake explicitly sets `GGML_METAL=ON`.
- CMake explicitly sets `GGML_METAL_EMBED_LIBRARY=ON`.
- The helper verifier rejects missing architectures, missing Metal linkage, missing embedded kernels, and dynamic whisper/ggml dependencies.
- `make test` includes the fast build-contract and runtime-argument tests.
- `native-whisper-helper-test` validates the actual helper.
- Native Whisper continues to transcribe through the existing helper and model paths.
- Quill does not pass a no-GPU argument.
- No separate `.metallib` is added in embedded mode.
- A universal release helper contains both arm64 and x86_64.
- Quill Dev and release artifacts pass deep strict code-sign verification in their authorized signing environments.
- Apple Silicon manual smoke demonstrates Metal initialization and a performance advantage over explicit CPU mode.
- Issue #184 is updated to correct its original premise and closed with the artifact and performance evidence.

## Delivery strategy

Implement this as one focused PR from current `origin/main`.

Expected files:

- Modify `BuildSupport/WhisperRuntime/build-whisper.cpp.sh`
- Create `BuildSupport/WhisperRuntime/verify-whisper-helper.sh`
- Modify `Makefile`
- Modify `Tests/NativeWhisperRuntimeTests.swift`
- Create `Tests/NativeWhisperBuildContractTests.swift`
- Modify release/build contract tests only if necessary to wire the new target

Do not modify `NativeWhisperInstaller`, model metadata, Settings UI, transcription backend selection, or cloud transcription.

After merge:

1. Post the corrected technical findings and benchmark evidence on Issue #184.
2. Mark #184 complete in Roadmap #176.
3. Close #184 if the PR does not close it automatically.
