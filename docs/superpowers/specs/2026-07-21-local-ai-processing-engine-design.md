# Local AI Processing Engine — Design

## Context

Quill already runs transcription fully on-device via Native Whisper (`whisper-cli`, GGML/Metal). Everything *after* the transcript — post-processing cleanup, Edit Mode, App-context inference, and the planned in-app meeting summary (GitHub issue [#187](https://github.com/woosublee/quill/issues/187)) — still requires a cloud API key, because `PostProcessingService` and `AppContextService.inferActivityWithLLM` only speak to a configured OpenAI-compatible provider (`apiBaseURL` + `apiKey`).

This is a precondition for #187: right now, a user with no API key configured cannot generate a meeting summary at all, and Settings hides Post-processing and Context entirely behind "add an API key first." This issue closes that gap by adding a downloadable, on-device LLM that Quill can point the same OpenAI-compatible request path at — mirroring how Native Whisper closed the equivalent gap for transcription (GitHub issue [#75](https://github.com/woosublee/quill/issues/75)) and continuing the local-first roadmap in [#145](https://github.com/woosublee/quill/issues/145).

This issue delivers the **engine and the Settings UX** for local AI processing. It does not implement meeting summary itself — that is #187, which consumes this engine once it exists.

## Goals

- A user with **no cloud API key** can enable Post-processing, Edit Mode, and Context on a fresh Quill install by downloading a local model, the same way they can already do this for transcription.
- Post-processing and Context stop being entirely gated behind a configured cloud API key. Instead, each exposes a **backend choice** — cloud model or one of several on-device models — mirroring how transcription already lets a user pick Local Whisper or an API model, and how the cloud side already offers a list of model IDs (`ModelConfiguration.llmModels`) rather than a single fixed one.
- Users can choose **among multiple downloadable local models** with different size/quality/RAM tradeoffs, not just install-or-not for a single fixed model. This mirrors the existing cloud model list rather than treating local as a single hardcoded option.
- Whichever local model a user has selected serves Post-processing, Edit Mode, and Context inference (text-only) for that feature. A future #187 reuses the same resolved backend for meeting summary without adding a second model concept.
- Apple Silicon is the only officially supported hardware for local AI processing at launch. Intel Macs keep working exactly as they do today (cloud-only).

## Non-goals

- Implementing meeting summary itself (#187's job).
- Screenshot-based local Context inference. Local Context inference in this issue is text-only (app name, window title, selected text). Screenshot analysis continues to require a cloud model, exactly as today.
- Official Intel/x86_64 support for local AI processing. The local option is disabled there with guidance toward a cloud model.
- A permanent global "local vs. cloud" mode toggle. Each feature (Transcription, Post-processing, Context) keeps its own independent backend choice, consistent with Quill's existing model-first Settings direction.
- User-configurable idle-timeout duration, port, or other local-server tuning knobs. These are internal implementation details in this iteration.
- Changing Transcription's existing local/cloud selection mechanics. This issue reuses that pattern for Post-processing and Context; it does not redesign Transcription.
- Mobile/iOS support. Quill is macOS-only today; this design targets that platform. (The model and engine family — `llama.cpp`/GGUF — remain reusable if Quill ever adds a mobile target, but no mobile work happens here.)

## Architecture

### Runtime: bundled `llama-server`

Quill bundles the `llama-server` binary from `llama.cpp` inside the app, the same way it bundles `whisper-cli` for Native Whisper today (`Sources/NativeWhisperRuntime.swift` resolves it via `Bundle.main.url(forResource:withExtension:subdirectory:)`; the new component follows the identical resolution and build-time embedding pattern, with its own build contract test analogous to `Tests/NativeWhisperBuildContractTests.swift`).

`llama-server` exposes an OpenAI-compatible `/v1/chat/completions` endpoint. This is the entire reason it's the right integration: `PostProcessingService` and `AppContextService.inferActivityWithLLM` already build OpenAI-compatible chat-completions requests through `LLMAPITransport`. Pointing their base URL at `http://127.0.0.1:<port>/v1` requires no change to their request-building, retry, fallback, or cooldown logic — only to how the base URL and API key are resolved for the local backend.

Alternative considered: linking `llama.cpp` directly into the Quill process (as its Swift/iOS example, `llama.swiftui`, does via an XCFramework). Rejected for this issue because:
- It would require writing and maintaining a new Swift/C binding layer, duplicating retry/fallback/parsing logic that `PostProcessingService` already has for the HTTP path.
- A crash inside the inference engine would crash the whole Quill process, including any in-progress recording. A separate process keeps that failure contained — the same reasoning that already justifies running `whisper-cli` as a subprocess rather than a linked library.
- `llama-server` already implements request queuing, batching, and context management; linking the library directly would mean reimplementing that ourselves.

Loopback-only binding (`127.0.0.1`) and no external network exposure. No API key is required at the wire level, since the server is unreachable from outside the machine; `LocalAIServerManager` (see below) generates a random local port per launch to avoid collisions.

### Process lifecycle: lazy start, idle shutdown, active-model switching

`llama-server` does **not** start when Quill launches. A resident LLM model holds several GB of RAM (see model sizes below); keeping one resident for the app's entire lifetime regardless of use is an unacceptable default cost.

`LocalAIServerManager` owns this lifecycle:

- **Lazy start**: the first Post-processing, Edit Mode, or Context request that resolves to a local model calls `withBaseURL(for:operation:)`, which starts `llama-server` with that model's `--model` path when needed. The operation awaits `/health` returning `200` before sending the chat-completions request and holds an active-request lease until its transport work returns or throws (mirroring `llama-server`'s documented `503` "Loading model" → `200` "ok" transition).
- **Idle shutdown**: after a fixed idle window with no requests (an internal constant, not user-configurable at this stage), the manager terminates the process and frees the RAM. A held `withBaseURL` operation is not idle and cannot be terminated by this check. The next request re-triggers a lazy start, paying the model-load cost again (several seconds, dominated by disk read + Metal buffer setup — not meaningfully different whether the caller is HTTP or an in-process library call).
- **Active-model switching**: only one local model can be resident at a time (RAM cost), even though a user may have several downloaded (disk cost, like Whisper's model directory). If a request resolves to a different local model than the one currently loaded, the manager waits for active operations on the current model to drain, then terminates the running process and lazily starts a new one for the requested model — same cost profile as an idle-triggered restart, just triggered by a model change instead of a timeout.
- **Crash containment**: if the `llama-server` process exits unexpectedly outside of the manager's own shutdown, in-flight requests fail with a distinct `QuillUserIssueCode` (see Error handling) rather than hanging; the next request starts a fresh process.
- **App-quit handling**: on quit, the manager terminates the process synchronously if running — no user-facing confirmation is needed here, unlike the Native Whisper *download* cancellation warning, because terminating an idle inference server has no partial-file state to lose.

### Models: multiple downloadable GGUF options, Whisper-symmetric lifecycle

`LocalAIModelCatalog` mirrors `NativeWhisperModelCatalog`'s shape (`Sources/NativeWhisperModel.swift`), extended to a real multi-entry catalog rather than a single `recommended`:

```swift
struct LocalAIModelArtifact: Identifiable, Hashable, Codable {
    var id: String { expectedFileName }
    let downloadURL: URL
    let expectedFileName: String
    let approximateBytes: Int64
    let checksumSHA256: String
}

struct LocalAIModel: Identifiable, Hashable, Codable {
    let id: String
    let displayName: String
    let description: String
    let artifacts: [LocalAIModelArtifact]
    let approximateResidentRAMBytes: Int64

    var approximateBytes: Int64 {
        artifacts.reduce(0) { $0 + $1.approximateBytes }
    }

    /// The first GGUF shard passed to `llama-server --model`.
    var primaryArtifact: LocalAIModelArtifact { artifacts[0] }
}

struct LocalAIModelCatalog {
    static let quality = LocalAIModel(
        id: "qwen2.5-7b-instruct",
        displayName: "Qwen2.5 7B Instruct",
        description: "Best quality. Needs more memory.",
        artifacts: [
            LocalAIModelArtifact(
                downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf")!,
                expectedFileName: "qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf",
                approximateBytes: 3_993_201_344,
                checksumSHA256: "dfce12e3862a5283ccfb88221b48480e58745165de856439950d0f22590580db"
            ),
            LocalAIModelArtifact(
                downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf")!,
                expectedFileName: "qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf",
                approximateBytes: 689_872_288,
                checksumSHA256: "539cf93f78e887edea1c04e2d7d8cdaca9d01dae9c9025bcb8accbe29df3d72a"
            )
        ],
        approximateResidentRAMBytes: 6_400_000_000
    )
    static let fast = LocalAIModel(
        id: "qwen2.5-1.5b-instruct",
        displayName: "Qwen2.5 1.5B Instruct",
        description: "Faster and lighter. Good for lower-memory Macs.",
        artifacts: [
            LocalAIModelArtifact(
                downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
                expectedFileName: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
                approximateBytes: 1_117_320_736,
                checksumSHA256: "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e"
            )
        ],
        approximateResidentRAMBytes: 2_500_000_000
    )
    static let recommended = quality
    static let all: [LocalAIModel] = [quality, fast]
    static func find(id: String) -> LocalAIModel { all.first { $0.id == id } ?? recommended }
}
```

Both starter models are official **Qwen2.5 Instruct, GGUF, Q4_K_M quantization** releases, differing only in parameter count (7B vs 1.5B). The official Hugging Face model cards declare both Apache-2.0, unlike the prior 3B GGUF repository's `qwen-research` license. Apache-2.0 keeps both catalog entries compatible with Quill's sellable direction; retaining the same official publisher, model family, and license lets future tiers be added as catalog entries without runtime or installer changes.

The Quality package is two shards totaling 4_683_073_632 bytes on disk; Fast is one 1_117_320_736-byte file. `approximateResidentRAMBytes` is intentionally higher than each package's disk size because inference also needs loaded weights, runtime buffers, and context/KV cache: Quality reserves 6_400_000_000 bytes and Fast conservatively reserves 2_500_000_000 bytes. `ProcessInfo.processInfo.physicalMemory` can suggest — not force — the `fast` tier on lower-memory Macs. This is a UI-level default/suggestion, not a hard block — a user can still choose `quality` if they accept the tradeoff.

`LocalAIModelStore` mirrors `NativeWhisperModelStore` byte-for-byte in behavior: same `.download`-suffixed partial-file convention, same size-floor + SHA-256 checksum validation, same `install/delete/deletePartial` operations, same `NativeWhisperInstallStatus`-shaped status enum, applied per-model (each model in the catalog has its own independent install/delete lifecycle — installing one does not require deleting another; disk usage is the user's tradeoff to manage, same as it already is for Whisper's `NativeWhisperModelCatalog.all` shape). `LocalAIInstaller` mirrors `NativeWhisperInstaller`: same in-flight-install de-duplication lock (keyed per-model, so two different models can download concurrently without colliding), same cancellation-token shape, same streaming-download-with-progress delegate. These are structurally identical to the Whisper versions — the implementation plan should evaluate whether to factor out a shared generic (`GGUFModelStore<T>`) or keep them as parallel, independently-testable types matching the existing duplication style between similar Quill subsystems. Either is acceptable; do not force a premature shared abstraction if the two call sites diverge even slightly (e.g. differing corruption-detection tolerances).

### Hardware gating

Local AI processing is offered only when `arch(arm64)` (see the existing `#if arch(arm64)` check in `Sources/SettingsView.swift:3209` used for diagnostics) **and** the bundled `llama-server` binary is present and executable. On Intel Macs, the local backend choice is not offered in the Post-processing/Context dropdowns at all (not shown-but-disabled) — Intel users see only the cloud model choice, unchanged from today. This differs deliberately from how a locally-installed-but-not-yet-downloaded local model is presented (visible, offered, with a download affordance) versus hardware that cannot run it at all (not offered).

## Settings UX: backend-choice pattern for Post-processing and Context

### Current state (what changes)

Today, `postProcessingFeatureSection` and `contextFeatureSection` in `SettingsView.swift` each render a toggle and a `ModelDropdownView` (a free-text-with-suggestions field over `ModelConfiguration.llmModels`), both wrapped in `.disabled(!hasConfiguredCloudAPIKey)` with a warning label when no key is configured. Neither has a concept of a local backend.

`transcriptionFeatureSection`, in the same file, already solves the exact problem this section needs to solve, for Transcription: `transcriptionChoicePicker` renders a sectioned `Picker("Model", selection:)` (sections `"API"` / `"Local"` / `"Legacy mlx-whisper"`, one tag per `TranscriptionBackendChoice`, each with `.selectionDisabled(!canSelectTranscriptionDisplay(display))` for per-choice availability). Directly below that picker, `NativeWhisperModelRowView` is rendered conditionally — only when a native-Whisper choice is selected or pending (`managedNativeModel != nil`) — showing the install/download/progress/delete row scoped to that one model. This is the load-bearing precedent for this whole section: not a pattern to design fresh, but the exact mechanism to copy.

### New behavior — reusing the Transcription picker mechanism, not inventing one

Post-processing and Context each get the **same two-part structure Transcription already has**: a sectioned `Picker` over backend choices, plus a conditional install row below it when a local choice is selected.

```swift
enum AIProcessingBackendChoice: Equatable {
    case cloud(modelID: String)
    case localAI(modelID: String)
}
```

(Post-processing and Context can share one enum type since both point at the same catalog of local models and the same cloud provider settings; the implementation plan should confirm whether a single shared choice type or two parallel ones — mirroring the existing `postProcessingModel` / `contextModel` separation — better fits the codebase's existing conventions.)

- **The enable/disable toggle no longer depends on `hasConfiguredCloudAPIKey`.** A user can turn Post-processing or Context on with no cloud key configured at all, provided they then pick an installed local model.
- **The picker gets an `"On This Mac"` section**, structured exactly like Transcription's `"Local"` section: one tagged entry per `LocalAIModelCatalog.all` item (`On This Mac — Qwen2.5 7B Instruct`, `On This Mac — Qwen2.5 1.5B Instruct`, …), always present and selectable on Apple Silicon regardless of cloud key state — the existing cloud entries (still free-text-with-suggestions, or migrated to the same sectioned-`Picker` shape as Transcription, to be confirmed in the implementation plan) live in their own section next to it, exactly as `"API"` sits next to `"Local"` today.
  - On Intel, the `"On This Mac"` section is simply absent from the picker (see Hardware gating) — unchanged in spirit from how Transcription's sections already appear/disappear based on `!displays.isEmpty`.
- **Below the picker, the exact same conditional-row mechanism as `managedNativeModel` + `NativeWhisperModelRowView`** renders an install/download/progress/delete row scoped to whichever local model is currently selected or pending — reusing `NativeWhisperModelRowView` itself if it can be generalized to `LocalAIModel`, or a structurally identical `LocalAIModelRowView` if the two models' fields diverge enough to make sharing awkward (the implementation plan should decide which, the same open question already flagged for `LocalAIModelStore`/`NativeWhisperModelStore`).
- The existing cloud choice, when selected without a key configured, keeps today's inline "Add an API key in Cloud Provider to enable this" warning — but scoped to that one choice now, not to the whole section, exactly as Transcription's `currentTranscriptionUsesAPI && !appState.hasTranscriptionAPIKey` warning is already scoped to the API choice rather than disabling the whole Transcription section.
- Selecting a local model that is not yet installed does not silently fail — it starts the download inline, exactly as `handleTranscriptionChoiceSelection(.nativeWhisper(modelID:))` already does (`pendingNativeModelID` / `pendingNativeWhisperAutoSelectionModelID` auto-select the choice once install completes); `AIProcessingBackendChoice` gets the equivalent pending-selection field, keyed by model ID.
- If the currently-selected local model is deleted (from Settings) while a feature's choice points at it, that feature falls back to another installed local model if one exists, else to the cloud choice if available, else to disabled — mirroring `normalizedNoteBrowserTranscriptionChoice`'s fallback-chain behavior, not a bespoke new rule.
- A low-RAM machine sees the `fast` (1.5B) entry suggested/pre-selected by default rather than `quality` (7B), per the RAM heuristic described under Models above; this is a default only, not a restriction on which entries are selectable.

### Read path for #187

Meeting summary (#187) reads whichever backend Post-processing currently resolves to (cloud or local) — it does not introduce a third, separate model choice. If neither a cloud key nor an installed local model is available, #187's "Summarize Meeting" action shows a toast ("Meeting summary needs an AI processing model.") with a "Model Settings" action routing to this same Settings section. That toast and its wiring belong to #187, not this issue; this issue only needs to guarantee that a resolvable backend-availability check exists for #187 to call.

## Error handling

New `QuillUserIssueCode` cases (or a request-context tag on the existing post-processing/context codes — the implementation plan should confirm which fits the existing `QuillUserIssueRecord` shape better) covering:
- Local server failed to start (binary missing/not executable — should not happen in a signed build, but must degrade gracefully rather than hang).
- Local model file missing or failed checksum validation at request time (mirrors `NativeWhisperRuntimeError.modelNotFound` / the existing model-corruption path).
- Local server process exited unexpectedly mid-request.

These follow the same friendly-message + technical-detail pattern already established for Native Whisper (`NativeWhisperRuntimeError.userIssue(modelID:)`) and for cloud post-processing (`PostProcessingError.userIssue(providerHost:modelID:)`) per #183's localized user-issue infrastructure. No raw process stderr or stack trace reaches the user-facing surface.

Download/checksum/corruption errors for the local model itself reuse the existing `NativeWhisperInstallerError`-equivalent shape (a parallel `LocalAIInstallerError`), not a new error taxonomy.

## Localization

All new UI copy (backend picker labels, download/progress rows, availability warnings, quit-time behavior if any user-visible copy is needed, error messages) goes through the existing String Catalog infrastructure from #177, verified by the same `assertFinalManagedSourceAudit` mechanism that already catches missing en/ko entries for every other Quill surface.

## Testing

- **Model catalog/store/installer**: tests symmetric to `NativeWhisperModelTests` / `NativeWhisperInstallerTests` — download-progress reporting, checksum validation, corruption detection, delete/delete-partial, in-flight de-duplication.
- **Build contract**: a test analogous to `NativeWhisperBuildContractTests` verifying the bundled `llama-server` binary is present, executable, contains the expected architecture slice, and links Metal on Apple Silicon builds.
- **Process lifecycle**: `LocalAIServerManager`'s lazy-start / idle-shutdown / crash-containment behavior, tested via an injected process-starter closure (same seam pattern as `AppState.nativeWhisperInstallStarter`), not a real subprocess — deterministic, no real `llama-server` execution in unit tests.
- **Backend-choice availability and fallback**: tests mirroring the existing Transcription availability/normalization tests — cloud unavailable without a key, local unavailable without an installed model or on Intel, fallback chain resolves correctly when a choice becomes unavailable (e.g. model deleted while selected).
- **Regression**: confirm `PostProcessingService` and `AppContextService` behave identically today (cloud-only) when `AIProcessingBackendChoice` resolves to `.cloud` — this refactor must not change any existing cloud-only behavior for users who never touch the new local option.
- **Settings UI contract**: a test analogous to `ModelsSettingsUIContractTests` asserting the toggle is no longer gated by `hasConfiguredCloudAPIKey`, and that the local backend row/download UI is present in the Post-processing and Context sections.
- Full verification loop before finishing: `make check-test-wiring`, `make test-core`, `make test-transcription` (or the equivalent new local-AI test target), `make clean && make test`, plus a signed `Quill Dev.app` build and manual smoke test per the project's `verify` skill.

## Open questions for the implementation plan

- Whether `AIProcessingBackendChoice` is one shared enum for Post-processing and Context or two parallel types (matching the existing `postProcessingModel`/`contextModel` separation).
- Whether `LocalAIModelStore`/`LocalAIInstaller` share a generic base with the Native Whisper equivalents or remain independent, matching Quill's existing tolerance for parallel-but-independent subsystems.
- Exact idle-timeout duration (a concrete default, e.g. 5 minutes, needs to be chosen and justified against real load-time measurements on the recommended model).
- Where exactly the new `QuillUserIssueCode` cases slot into the existing enum/localization tables.
