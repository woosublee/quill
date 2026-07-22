# Local AI Processing Backends — Design

## Context

The local AI runtime milestone in `docs/superpowers/plans/2026-07-22-local-ai-runtime-infrastructure.md` is complete. Quill now bundles `llama-server`, manages Qwen2.5 7B and 1.5B GGUF packages, downloads and validates model artifacts, and exposes a lease-based `LocalAIServerManager.withBaseURL(for:operation:)` API with lazy startup, idle shutdown, model switching, and crash containment.

The remaining work connects that infrastructure to the product. Post-processing, Edit Mode, and Context still resolve only a cloud `apiBaseURL`, API key, and model string. Their Settings cards are disabled when no cloud API key is configured. This follow-up introduces independent cloud/local backend choices for Post-processing and Context, routes both services through one shared execution boundary, adds the model-management UI and hardware gating, and localizes the resulting user-facing states and errors.

This design refines and completes the product-integration portion of `docs/superpowers/specs/2026-07-21-local-ai-processing-engine-design.md`. The runtime and catalog implemented in commit `e68387d` remain the foundation.

## Goals

- Allow Post-processing and Edit Mode to run with a downloaded local model and no cloud API key.
- Allow Context inference to run text-only with a downloaded local model and no cloud API key.
- Keep Post-processing and Context backend choices independent: either feature may select a different cloud or local model.
- Share one execution abstraction and one `LocalAIServerManager` without forcing the features to share a selected model.
- Preserve all existing cloud request, fallback, cooldown, prompt, parsing, and instruction-guard behavior for users who remain on cloud models.
- Reuse Transcription's sectioned picker plus contextual model-management-row interaction pattern.
- Support multiple local model downloads and model-specific install state.
- Offer local AI processing only on supported Apple Silicon builds.
- Provide localized, safe user issues for local model, startup, and process-exit failures.
- Leave a reusable backend execution boundary for meeting summary issue #187.

## Non-goals

- Implementing meeting summary generation or its UI.
- Combining Post-processing and Context into one global model choice.
- Sending screenshots to the starter local Qwen models.
- Adding Intel support.
- Adding user controls for the local server port, context size, or idle timeout.
- Changing Transcription's backend-selection behavior.
- Replacing the completed local model store, installer, or server manager with a generic framework shared with Native Whisper.
- Refactoring unrelated AppState responsibilities.

## Confirmed product decisions

1. Post-processing and Context store independent backend choices.
2. Both features use a common backend executor and the same resident local server manager.
3. Selecting a local Post-processing model never falls back to cloud. On failure, the existing upper-level safety behavior keeps the original transcript.
4. Cloud Post-processing retains its existing cloud fallback model and retry rules.
5. Local Context is text-only and remains best-effort; a failure falls back to metadata-derived context without blocking dictation.
6. Local model availability is a recommendation and capability check, not a RAM-based hard restriction.
7. Meeting summary later reuses the Post-processing backend choice, not the Context choice and not a third independent choice.

## Architecture

### Backend choice

```swift
enum AIProcessingBackendChoice: Codable, Hashable, Sendable {
    case cloud(modelID: String)
    case localAI(modelID: String)
}
```

AppState owns separate published values:

```swift
@Published var postProcessingBackendChoice: AIProcessingBackendChoice
@Published var contextBackendChoice: AIProcessingBackendChoice
```

The type is shared because both features select from the same cloud provider and local catalog. The stored values are not shared.

Existing `postProcessingModel` and `contextModel` settings remain as the last selected cloud model IDs. This avoids losing a user's custom cloud model while a local backend is selected. Changing the cloud model editor updates this remembered value; it updates the active backend choice only when that feature is currently using cloud.

`postProcessingFallbackModel` remains a cloud-only setting and does not become an `AIProcessingBackendChoice`.

### Endpoint and executor

A new source file, `Sources/AIProcessingBackend.swift`, defines the choice, endpoint, executor, display metadata, availability checks, and persistence helpers.

```swift
struct AIProcessingEndpoint: Sendable {
    enum Kind: Sendable {
        case cloud
        case local
    }

    let kind: Kind
    let baseURL: URL
    let authorizationToken: String?
    let requestModelID: String
    let selectedModelID: String
    let supportsImages: Bool
}
```

The distinction between `requestModelID` and `selectedModelID` is intentional:

- Cloud uses the configured provider model ID for both.
- Local uses `"local"` in the OpenAI-compatible request payload, matching the verified `llama-server` smoke-test contract, while `selectedModelID` remains the real catalog ID used for Settings, diagnostics, and persistence.

Local requests omit the `Authorization` header. Cloud requests preserve the existing bearer token behavior.

```swift
struct AIProcessingBackendExecutor: Sendable {
    let choice: AIProcessingBackendChoice
    let cloudBaseURL: URL
    let cloudAPIKey: String
    let localServerManager: LocalAIServerManager

    func withEndpoint<Result: Sendable>(
        _ operation: @escaping @Sendable (AIProcessingEndpoint) async throws -> Result
    ) async throws -> Result
}
```

Execution rules:

- `.cloud(modelID:)` constructs the existing provider endpoint and runs the operation immediately.
- `.localAI(modelID:)` resolves the catalog model and calls `localServerManager.withBaseURL(for:operation:)` so the lease covers the entire HTTP operation.
- The executor does not decide feature fallback policy. Post-processing decides whether a second cloud executor exists; Context uses one executor.
- Unsupported or unknown local model IDs fail with a typed backend error rather than silently falling back to a different model.

### Shared local server, independent selections

AppState owns exactly one `LocalAIServerManager` and passes it into every local-capable executor. Post-processing and Context may select different local models. If they do, the manager follows its existing contract:

1. keep the active model alive for in-flight operations;
2. wait for active operations to drain;
3. stop the prior process;
4. start the newly requested model;
5. run the waiting operation.

This bounds resident model memory to one model while preserving independent user choices.

### Request snapshot semantics

Every recording, import, retry, Edit Mode operation, and resumed cloud transcription captures an immutable backend executor when its processing service is created. Later Settings changes do not change an already-running operation.

AppState centralizes service construction through factories rather than leaving direct `PostProcessingService(...)` calls in multiple flows:

```swift
func makePostProcessingService(
    choice: AIProcessingBackendChoice? = nil,
    cloudFallbackModelID: String? = nil
) -> PostProcessingService

func makeAppContextService(
    choice: AIProcessingBackendChoice? = nil
) -> AppContextService
```

The implementation replaces the existing direct constructors in retry, audio import, normal recording completion, and cloud-resume paths with these factories. Configuration snapshots carry the captured choice or a Sendable executor as appropriate; they do not read mutable AppState values from background work.

## Service integration

### PostProcessingService

`PostProcessingService` keeps its existing prompt construction, payload fields, response parsing, instruction-execution guard, timeout behavior, and result validation. Its transport boundary changes from fixed `apiKey` and `baseURL` strings to a primary executor and an optional cloud fallback executor.

Cloud behavior remains:

- primary model: the selected cloud model;
- fallback model: `postProcessingFallbackModel`, unless it equals the primary model;
- fallback triggers: the same rate-limit, empty-output, and instruction-guard conditions currently implemented for each operation;
- cooldown identity: the cloud endpoint base URL plus cloud request model ID;
- authentication and provider user-issue mapping: unchanged.

Local behavior is deliberately different:

- one selected local model;
- no cloud fallback, even when a cloud API key exists;
- no second local model fallback;
- no provider cooldown substitution;
- if processing cannot complete, the existing AppState processing path preserves the original transcript and records a warning issue.

The internal request methods receive an `AIProcessingEndpoint`. They use `endpoint.baseURL`, conditionally set authorization from `endpoint.authorizationToken`, put `endpoint.requestModelID` in the payload, and use `endpoint.selectedModelID` for display prompts and diagnostics.

### AppContextService

`AppContextService` receives one backend executor.

Cloud behavior remains:

1. attempt the selected cloud model with the screenshot when available;
2. retry the same model with text-only metadata;
3. fall back to the existing metadata-derived activity string when both fail.

Local behavior is text-only:

- `supportsImages` is false;
- screenshot capture may still populate the history/debug fields used by the rest of Quill, but the screenshot data URL is never included in the local model request;
- only app name, bundle ID, window title, and selected text are sent to `llama-server`;
- a local startup, process, transport, or response failure returns the existing metadata fallback and does not fail transcription.

Context backend failures are converted to safe `QuillUserIssueError` values for private logging. They do not overwrite `postProcessingStatus`, mark the pipeline item failed, or show a separate intrusive toast, preserving Context's existing best-effort contract.

## Local server lifecycle integration

`LocalAIServerManager` retains its existing five-minute idle timeout. AppState starts one lightweight periodic task that calls `shutdownIfIdle()` every 30 seconds. The task is cancelled during AppState teardown.

On application termination:

1. existing model-download confirmation logic runs;
2. if the user continues, active downloads are cancelled and partial files are cleaned through their installers;
3. AppState awaits `LocalAIServerManager.stop()`;
4. application termination continues.

The manager's deinitializer remains the final defensive cleanup for abnormal ownership teardown.

### Mid-request process exit

`LocalAIServerManagerError` gains a distinct process-exit case:

```swift
case processExited(String)
```

When the operation passed to `withBaseURL` throws, the manager checks whether the leased process has exited:

- if it has exited, the manager clears the stale lifecycle state and throws `.processExited` with private diagnostic detail;
- if it remains alive, the original operation error is rethrown;
- lease accounting is released in either case.

This distinguishes an actual local process crash from an HTTP error, invalid response, timeout, or cancellation while retaining the existing lease and switching guarantees.

## Persistence and migration

New UserDefaults keys store encoded backend choices:

- `post_processing_backend_choice`
- `context_backend_choice`

Load behavior is deterministic:

1. decode and normalize a valid stored choice;
2. if no choice exists, create `.cloud(modelID:)` from the existing feature model string;
3. if the stored choice is malformed, recover to `.cloud(modelID:)` using the remembered cloud model;
4. if a stored local choice is unsupported by the current hardware/runtime or its model is unavailable, apply the availability fallback chain described below.

Existing users therefore remain on their current cloud models after updating. Local processing is activated only by an explicit local selection.

The existing model keys remain:

- `post_processing_model`: remembered Post-processing cloud model;
- `context_model`: remembered Context cloud model;
- `post_processing_fallback_model`: cloud-only fallback model.

No migration changes the current defaults or custom provider values.

## Hardware and recommendation policy

`LocalAIProcessingAvailability` evaluates two conditions through injectable seams:

1. the app is running on `arm64`;
2. `RealLocalAIServerProcess.defaultRunnerURL()` resolves to an executable bundled helper.

The `"On This Mac"` picker section is present only when both conditions are satisfied. Intel builds remain cloud-only and do not show disabled local choices.

A stored local choice on unsupported hardware or a build missing the runner is normalized through the feature fallback chain rather than allowed to fail every request.

RAM affects recommendation only:

- physical memory below 16 GiB: prefer `LocalAIModelCatalog.fast`;
- physical memory at or above 16 GiB: prefer `LocalAIModelCatalog.quality`.

The recommendation controls the order/default used when choosing among installed local fallbacks and the visual recommended label. It never disables a catalog model.

## Settings UX

Post-processing and Context use the same interaction pattern as Transcription: a sectioned model picker and a conditional management row below it.

### Picker sections

Each feature shows:

- `"Cloud"`: all `ModelConfiguration.llmModels` plus the feature's current custom cloud model when it is not already in the catalog;
- `"On This Mac"`: all `LocalAIModelCatalog.all` entries when local processing is supported.

The macOS 14 native `Picker` and the older macOS `Menu` fallback follow the existing Transcription implementation.

Cloud entries remain visible without an API key but are unavailable for activation and show the scoped provider warning. Local entries remain selectable without an API key.

The feature enable toggles are no longer disabled by `hasConfiguredCloudAPIKey`.

### Cloud model editing

The existing arbitrary OpenAI-compatible model support remains available in Details:

- Post-processing exposes a cloud primary model editor and the existing cloud fallback model editor;
- Context exposes a cloud model editor;
- editing a cloud model while the feature is local updates the remembered cloud model without changing the active local choice;
- the Post-processing fallback editor is visibly cloud-only and disabled while the active choice is local.

### Pending local selection

Selecting an uninstalled local model does not immediately replace the active choice. AppState records a pending selection for the feature and starts or joins that model's download.

```swift
enum AIProcessingFeature: Hashable, Sendable {
    case postProcessing
    case context
}

@Published private(set) var localAIInstallStates: [String: LocalAIModelInstallViewState]
private var localAIInstallTasks: [String: LocalAIInstallTask]
private var pendingLocalAISelections: [AIProcessingFeature: String]
```

Rules:

- the same model requested by both features uses one download task;
- both pending feature choices activate after successful validation;
- different models may download concurrently;
- choosing another backend clears only that feature's pending auto-selection and allows an already-running download to continue;
- explicitly cancelling a model download cancels the shared task and clears every pending feature selection for that model;
- failure clears pending selections for that model and exposes a model-scoped issue;
- Settings-window closure does not cancel downloads.

### LocalAIModelRowView

A new `Sources/LocalAIModelRowView.swift` provides model-specific status and actions:

- model name, localized description, and package size;
- installed state;
- download button;
- aggregate progress and reusable `DonutProgressView`;
- cancellation;
- model-scoped issue presentation;
- delete confirmation.

The row is structurally consistent with `NativeWhisperModelRowView` but is not forced into a generic lifecycle abstraction. Local AI supports multiple models, multi-artifact packages, concurrent downloads, and shared pending consumers, so only small visual primitives are reused.

A row appears below a feature picker when that feature currently selects or is pending a local model. If both features refer to the same model, each card may render a contextual row backed by the same AppState install state.

### Deletion and choice normalization

Before deleting any local AI model, AppState awaits `LocalAIServerManager.stop()` so no process retains an open model and resident memory is released. It then deletes the model package and normalizes every feature that selected it.

Per-feature fallback order:

1. choose another installed local model, preferring the RAM recommendation and then catalog order;
2. otherwise choose the remembered cloud model when a cloud API key is configured;
3. otherwise set the remembered cloud choice and turn the feature off.

If one feature deletes a model used by both, both choices normalize independently using the same rule.

Startup normalization applies the same fallback when a selected model was removed outside Quill, became corrupt, or is unsupported on the current machine.

## Download termination behavior

The existing Native Whisper quit confirmation is generalized into one model-download termination flow.

- If neither Native Whisper nor Local AI is downloading, termination proceeds immediately.
- If any model download is active, one localized confirmation explains that unfinished downloads will be cancelled.
- Continuing termination cancels Native Whisper and every Local AI install task, clears pending auto-selections, removes recognized partial downloads through the relevant stores, stops the local server, and then replies to the application termination request.
- Cancelling termination leaves all downloads running.

## Error handling

### User issue codes

Three Local AI-specific codes are added because the existing local codes use Local Transcription-specific copy:

```swift
case localAIModelUnavailable = "local-ai-model-unavailable"
case localAIStartFailed = "local-ai-start-failed"
case localAIProcessExited = "local-ai-process-exited"
```

Mappings:

- `LocalAIServerManagerError.modelUnavailable` and `.modelCorrupt` → `.localAIModelUnavailable`;
- runner resolution, launch, port, health, and startup failures → `.localAIStartFailed`;
- `.processExited` during an active operation → `.localAIProcessExited`.

Safe context includes:

- selected catalog model ID;
- `localBackend: "Local AI"`;
- process exit code only if the process abstraction can provide one safely.

Paths, stderr, provider bodies, prompts, selected text, and transcripts remain private diagnostics and are never persisted in `QuillUserIssueRecord`.

Default severity for the three codes is `.warning` because Post-processing preserves the original transcript and Context falls back. A Settings installation row may explicitly create an `.error` record for a failed installation without changing the code's default processing severity.

Recovery actions:

- `.localAIModelUnavailable` → `.openModelsSettings`;
- `.localAIStartFailed` → `.retryTranscription`;
- `.localAIProcessExited` → `.retryTranscription`.

Local HTTP/response errors that occur while the process is still alive map to the existing `.postProcessingFailed` warning with Local AI context. Cloud errors retain their existing authentication, quota, rate-limit, provider, and configuration mapping.

## Localization

All new user-visible strings are added to `Resources/Localization/Localizable.xcstrings` with complete English and Korean values.

The new copy covers:

- `"Cloud"` and `"On This Mac"` sections;
- local recommendation, availability, and text-only Context guidance;
- local model download, progress, cancellation, installation, deletion, pending auto-selection, and background-download states;
- scoped cloud API-key warnings;
- the cloud-only fallback explanation;
- the generalized model-download quit confirmation;
- title, body, and suggestion copy for all three Local AI user-issue codes.

No raw `LocalAIInstallerError`, `LocalAIServerManagerError`, process stderr, or file-system detail is displayed directly.

`LocalizationResourceTests.assertFinalManagedSourceAudit` remains the source-literal safety net, and `QuillUserIssueTests` verifies complete English and Korean presentations for every enum case.

## Testing

### AIProcessingBackendTests

- cloud endpoint preserves the configured URL, token, and model;
- local endpoint resolves the expected catalog model and runs inside the manager operation;
- local endpoint uses request model `"local"`, selected catalog model ID, no authorization token, and `supportsImages == false`;
- cloud endpoint uses `supportsImages == true`;
- unknown local model IDs fail without fallback;
- persistence decodes valid choices and migrates missing/malformed values to remembered cloud models;
- Post-processing and Context choices remain independent.

### LocalAIServerManagerTests

- an operation failure while the process remains alive rethrows the original error;
- an operation failure after the process exits throws `.processExited`;
- lease counts are released in both cases;
- existing startup, cancellation, switch, drain, idle, and stop tests continue to pass.

### PostProcessingService tests

- existing cloud primary/fallback and cooldown behavior remains unchanged;
- local requests use the loopback endpoint and selected local diagnostic model;
- local requests omit authorization;
- local failure never invokes the cloud fallback even when a cloud key exists;
- local process exit maps to `.localAIProcessExited` and the upper pipeline keeps the original transcript;
- local model/start failures map to their dedicated codes;
- prompt, payload, parsing, translation, command transform, and instruction-guard regression tests remain green.

### AppContextService tests

- cloud screenshot then text-only retry remains unchanged;
- local requests never include an `image_url` payload;
- local requests include app/window/selection metadata;
- local model, startup, process, transport, and invalid-response failures return metadata fallback context;
- Context failure does not create a failed pipeline item or overwrite Post-processing status.

### AppState AI processing tests

- existing model strings migrate to cloud choices;
- changing one feature choice does not change the other;
- changing a remembered cloud model while local does not switch the backend;
- same-model download requests coalesce and activate every pending feature on success;
- different-model downloads run independently;
- selecting another backend clears only that feature's pending selection;
- explicit cancellation clears all pending consumers for the cancelled model;
- install failure and deletion expose model-scoped issues;
- deletion stops the server before file removal;
- deletion and startup normalization follow the local → cloud → disabled chain;
- RAM recommendation chooses Fast below 16 GiB and Quality at or above 16 GiB;
- Intel and missing-runner capability seams hide local options;
- service factories snapshot the correct backend choice for normal recording, retry, import, Edit Mode, and cloud resume;
- idle polling and termination cleanup call the shared manager.

### Settings and localization contract tests

`ModelsSettingsUIContractTests` is updated from the prior UI-only cloud-gating contract to assert:

- Post-processing and Context toggles are not disabled by the cloud API key;
- both cards use sectioned backend pickers;
- cloud and local sections are choice-scoped;
- the conditional `LocalAIModelRowView` is present;
- cloud fallback controls are local-choice aware;
- existing Transcription picker and model rows are unchanged.

`QuillUserIssueTests`, `LocalizationResourceTests`, and test-wiring checks cover the new codes and strings.

## File scope

Expected new files:

- `Sources/AIProcessingBackend.swift`
- `Sources/LocalAIModelRowView.swift`
- `Tests/AIProcessingBackendTests.swift`
- `Tests/AppStateAIProcessingBackendTests.swift`
- focused Post-processing and Context backend tests if keeping them separate from existing suites improves compile boundaries.

Expected modified files:

- `Sources/AppState.swift`
- `Sources/SettingsView.swift`
- `Sources/PostProcessingService.swift`
- `Sources/AppContextService.swift`
- `Sources/LocalAIServerManager.swift`
- `Sources/QuillUserIssue.swift`
- `Sources/AppDelegate.swift`
- `Resources/Localization/Localizable.xcstrings`
- `Tests/ModelsSettingsUIContractTests.swift`
- `Tests/QuillUserIssueTests.swift`
- relevant existing AppState, service, termination, and localization tests
- `Makefile` for exact test wiring.

The implementation plan may split tests more finely, but it must not broaden the product scope beyond this list of responsibilities.

## Verification and success criteria

Automated verification:

```bash
make check-test-wiring
make test-core
make test-transcription
make clean && make test
```

Signed application verification:

```bash
make CODESIGN_IDENTITY=Quill APP_NAME="Quill Dev" BUNDLE_ID=com.woosublee.quill.dev
codesign --verify --deep --strict "build/Quill Dev.app"
```

GUI verification uses the project `verify` skill and confirms:

1. with no cloud API key, a supported Mac can select, download, and activate a local Post-processing model;
2. normal dictation and Edit Mode use that local model and preserve the original text on failure;
3. local Context sends text metadata only and still produces or safely falls back to an activity summary;
4. Post-processing and Context can select different local models and the manager switches only after active work drains;
5. selecting the same uninstalled model in both cards uses one download and activates both after completion;
6. deleting a selected model applies the documented fallback independently to both features;
7. active model downloads produce one quit confirmation and are either preserved or cancelled according to the user's choice;
8. existing cloud-only users retain their models, provider settings, fallback behavior, and output;
9. Intel/runtime-unavailable capability tests expose no local choices;
10. English and Korean UI and error copy render without missing-catalog fallbacks.

The milestone is complete when these checks pass and meeting summary #187 can construct an executor from `postProcessingBackendChoice` without introducing another model-selection system.
