# Gemma 4 E4B in the Transcription Chooser — Design

**Date:** 2026-09-26
**Status:** Implemented — manual verification pending
**Issue:** #366 (Stage 4 of `2026-09-26-gemma-4-e4b-unified-local-model-design.md`)
**Also implements:** the model-neutral parts of #285 (ASR transport) and #286
(long-form chunking and resume)

## Goal

Let people pick Gemma 4 E4B for transcription and use it the same way they use
Native Whisper today. The package they already downloaded for post-processing,
summaries, and Context also transcribes, with no second download. Long
recordings are split, checkpointed, and resumed.

The transport and long-form pieces are model-neutral. Gemma 4 E4B is the first
model on them. A later speech model such as Qwen3-ASR (#283, #284, #287) only adds
a catalog entry and a request format.

## Principle: use it like Native Whisper

Wherever Native Whisper appears, a local AI transcription model appears and
behaves the same way. Differences are limited to what the model requires:
download size, the 16 GB memory gate, internal chunking, and the model reload
hint.

| Surface | Native Whisper today | Local AI model (Gemma) |
| --- | --- | --- |
| Settings transcription picker | Selectable before install, label suffix "Download required" / "Downloading...", download row and warning below the picker | Same. Downloading from here installs the shared Local AI package, which then appears in every feature list |
| Onboarding "On This Mac" | Apple Speech card and Whisper card with download row. Apple Speech is used while downloading. Microphone permission only | A Gemma card with the same download row, the same fallback while downloading, and the same permissions |
| Note Browser picker, import, retry | Importable. mp3/mp4/mpeg/mpga/m4a/wav, converted to 16 kHz mono WAV | Same formats and the same conversion service |
| Transcription language | Language list plus Auto Detect | Same list. Auto asks the model to keep the spoken language |
| Status while transcribing | "Transcribing" state | Same state. Multi-chunk jobs also show the existing chunk counter (for example 3/12) |
| Errors | `QuillUserIssueError.local(.localModelMissing / .audioPreparationFailed, …)` | The same codes and message format with the model's name |
| Recording journal, recovery history | Grouped with local file backends | Same group |
| Deleting the selected model | The choice becomes unavailable and the Note Browser falls back through `noteBrowserFallbackChoices` | Same |

No separate "experimental" notice is shown next to the picker. If needed, it
lives only in the model description text.

## Assumptions

- Native Whisper stays the default transcription choice. Apple Speech and Cloud
  stay available.
- Gemma is a batch backend like Native Whisper. Live and realtime transcription
  are out of scope.
- No silent Local-to-Cloud fallback, and no silent switch to another local model.

## Current state (at `b669ca7`)

- `TranscriptionBackendChoice` (`AudioImportOptions.swift`) has `apiStandard`,
  `apiRealtime`, `nativeWhisper`, `legacyMlxWhisper`, and `appleLive`. No single
  value is stored. `AppState.currentNoteBrowserTranscriptionChoice` derives it
  from `use_local_transcription`, `use_legacy_mlx_whisper`,
  `realtime_streaming_enabled`, `transcription_model`, and
  `local_transcription_model`.
- `AIModelFeature` has no transcription feature and `AIModelModality` has no
  audio modality. `LocalAIModelCatalog.gemma4E4B` runs `.visionChat` with the
  BF16 projector, which also serves audio (Stage 3).
- `LocalAIServerManager` runs one model at a time. Requesting another model
  drains in-flight requests, stops the server, and starts the new model.
- Cloud long-form transcription already has:
  - silence-aware chunk planning (`CloudTranscriptionChunkPlanner`)
  - a per-note checkpoint (`CloudTranscriptionJobStore`, schema v1)
  - relaunch auto-resume and manual retry (`TranscriptionRetryWorkflow`)
  - progress display (`CloudTranscriptionHistoryCoordinator`)

  Planning is sized only by the 20 MB encoded upload ceiling. Job identity is
  cloud-specific (`providerID`, `model`, `responseFormat`).
- Import copies the original file. Only Native Whisper converts it to WAV
  (`AudioImportConversionService.prepareForNativeWhisper`), into a temporary file.
- `SetupFlow.LocalModel` is `{appleSpeech, nativeWhisper}` and
  `ProcessingPreset` has `localAppleSpeech` and `localNativeWhisper`.

## Stage 3 facts this design depends on

These come from #366:

- `llama-server` b11046 accepts `input_audio` (16 kHz mono WAV) on
  `/v1/chat/completions` with the Gemma projector.
- Audio beyond about 2 minutes per request is dropped silently, not rejected.
- Fixed 30 s cuts raised error rates (ko 11.1% → 14.1%) by splitting words, so
  cuts must land in silence.
- About 6.4–6.7 GB RSS during audio requests. Speed is far faster than real time.

## Design

### 1. Capabilities and catalog

- Add `AIModelFeature.transcription` and `AIModelModality.audio`.
- `gemma4LocalCapabilities` gains both. Qwen2.5 7B gains neither.
- Add `LocalAIModel.transcriptionRequestFormat: LocalASRRequestFormat?`. Gemma
  uses `.chatCompletionsInputAudio`. It is nil for models without transcription.
- A model is a transcription candidate when it:
  - supports `.transcription`
  - has audio modality
  - has a request format
  - passes `LocalAIProcessingAvailability.isModelSupported`

  This is the same capability filter the other feature lists use.

### 2. Transcription choice

- Add `TranscriptionBackendChoice.localAI(modelID: String)`.
  - `mode` is local.
  - `isImportable` is true.
  - `usesCloudAPI` is false.
  - The picker section is "On This Mac", listed after Native Whisper.
- Persist it with a new key `local_ai_transcription_model` (model ID string).
  Selecting a Local AI model sets `use_local_transcription = true`, clears
  `use_legacy_mlx_whisper`, and sets this key. Selecting any other choice clears
  the key.
- `currentNoteBrowserTranscriptionChoice` reads the key first when local
  transcription is on. An ID that is missing from the catalog, or no longer has
  the capability, resolves to unavailable with a reason, and never to another
  model.
- Display, readiness, fallback, and journal handling mirror `.nativeWhisper`:
  - `noteBrowserTranscriptionDisplay`
  - `isNoteBrowserTranscriptionChoiceReady` (package installed and verified)
  - `noteBrowserFallbackChoices`
  - `RecordingTranscriptionBackendSnapshot`, which gets a new `localAI` case
    with the model ID
  - `RecordingRecoveryHistory`, which joins the local file backend group
- Settings (`SettingsView`):
  - `handleTranscriptionChoiceSelection` and `transcriptionChoiceMenuLabel`
    treat the new choice like `.nativeWhisper`.
  - The label suffix and the download row below the picker call the shared
    `LocalAIModelWorkflow` install and download state.

### 3. Local ASR transport (#285 scope)

A new `LocalASRTranscriptionClient` handles transcription only. Text
processing stays on its existing requests.

- **Input:** one canonical 16 kHz mono PCM16 WAV chunk URL, a language hint (a
  code or auto), and the model.
- **Server:** leases the server through `LocalAIServerManager.withBaseURL(for:)`.
  The same model already running is reused, not reloaded.
- **Request format:** chosen by `LocalASRRequestFormat`. For
  `.chatCompletionsInputAudio`:
  - `POST chat/completions` with `temperature: 0`
  - one user message with an `input_audio` part (base64 WAV, `format: "wav"`)
    and a short text instruction: transcribe verbatim, output only the
    transcript, and either keep the spoken language (Auto) or use the chosen
    language
  - `max_tokens` sized for 60 s of fast speech. The initial value is 1,536,
    tuned in the integration check.
  - Thinking is already disabled by the model's `serverArguments`.
- **Output:** `LocalASRChunkResult { text, finishReason }`, trimmed. Empty text
  is valid.
- **Typed errors.** The client and its execution snapshot throw the chunk
  failure types the shared core already classifies, so retry rules stay in one
  place:
  - `TranscriptionChunkRuntimeFailure` (server start failed or exited):
    retryable
  - `LocalAITranscriptionModelUnavailableFailure` (package missing or corrupt):
    not retryable, shown as `localModelMissing`
  - `TranscriptionChunkTruncatedFailure` (`finish_reason == "length"`): split,
    see below
  - `CloudTranscriptionHTTPFailure` (non-200 status: 5xx retryable, 4xx not)
  - `CloudTranscriptionInvalidResponseFailure` (unparseable body)
  - `URLError` (timeouts retryable) and `CancellationError`
- **Timeout:** 120 s per chunk request, matching the local AI default. The cloud
  override `transcription_timeout_seconds` (default 20 s) does not apply,
  because a cloud-sized value would cut off local chunks.
- **Cancellation:** cancels the HTTP task. The lease ends normally. Durable audio
  and checkpoints are untouched.
- **Logging:** no audio, text, or prompt in logs. Only the error kind, chunk
  index, and durations.

### 4. Model-neutral long-form engine (#286 scope)

The existing cloud engine is generalized in place. Cloud behavior and existing
cloud plan IDs must not change.

- **Chunk limits.** `CloudTranscriptionChunkPlanner.plan` takes a
  `TranscriptionChunkLimit`:
  - `.encodedUpload(multipart:, ceilingBytes:)`: today's behavior, 3 s silence
    search. Cloud plans and plan IDs stay byte-identical.
  - `.rawWAVDuration(maximumFrames:, silenceSearchFrames:)`: used by local ASR.
    - The nominal length is 60 s (960,000 frames).
    - The silence search goes back up to 20 s (320,000 frames) for the quiet run
      nearest the end, with the same 20 ms windows and RMS ≤ 128 rule.
    - With no silence, the cut is at 60 s, so no chunk ever exceeds 60 s.
    - The chunk size is the raw WAV byte count (header + PCM), so the existing
      byte-ceiling validation still applies.

  The plan stores two new optional fields: `sizing` (nil means cloud multipart)
  and `silenceSearchFrameCount` (nil means 3 s). Old records decode unchanged.
  Local plan IDs hash both fields, so they never collide with cloud plan IDs.
- **Job identity (no schema change).** `CloudTranscriptionJobIdentity` keeps its
  fields. A local job fills them this way:
  - `providerID = "local-ai:" + packageDigest`, where `packageDigest` is the
    SHA-256 of the model's artifact checksums in order
  - `model = modelID`
  - `responseFormat` = the request format's raw value
  - `language` and `source` as for cloud

  A typed accessor (`identity.backend`) returns `.cloud` or
  `.localAI(modelID:)` from the `local-ai:` prefix. The job store keeps
  schema v1 and its directory, so no migration is needed. An older app sees a
  provider it does not know and leaves the job waiting for retry, which is safe.
- **Core loop.** `CloudTranscriptionCore` already takes the request as a
  closure (`(URL, TimeInterval) async throws -> String`). A local job passes a
  closure that calls `LocalASRTranscriptionClient`. Planning, materializing,
  checkpoints, progress, and assembly are shared.
- **Retry policy.** It keeps 3 attempts per chunk. Local errors map to existing
  categories:
  - `processExited`, `runtimeUnavailable`, and `timedOut` → `providerUnavailable`
    (retryable)
  - `invalidResponse` → `invalidResponse` (not retryable)

  Retry-After does not apply to local.
- **Truncation.** When the request throws `truncated`, the core splits that
  chunk at its middle and requests both halves in order.
  - The halves' texts join into that chunk's single result.
  - Splitting goes at most two levels deep (60 s → 30 s → 15 s).
  - If a 15 s part still truncates, the job fails with earlier chunks kept.
  - Splits are not checkpointed. An interrupted chunk is redone whole on resume.
- **Assembly.** Chunks are joined with a single space, as in cloud. Empty chunk
  results are skipped.
- **Progress.** The existing `.planned / .uploading(index,total,attempt) /
  .completed` events drive the same display.
  - The Note Browser shows the Native Whisper "Transcribing" state and appends
    the chunk counter only when the plan has more than one chunk.
  - Progress stays monotonic because chunks run in order and split halves emit
    no events. A test pins this.

### 5. Source audio

- **Recordings** are canonical WAV next to the note. They use the durable job
  store, so a quit or crash mid-job resumes at the next chunk after relaunch.
- **Imports that are already canonical WAV** behave like recordings.
- **Other imports** are converted with the service Native Whisper uses
  (`AudioImportConversionService`) into its temporary file, as today.
  - They use an in-memory checkpoint for that one run, so retries within the
    run keep completed chunks.
  - After a relaunch or a manual retry they start again from the first chunk.
  - No converted audio copy is persisted, so no new user-audio files exist.
  - Local transcription is far faster than real time, so a full redo is short.
- The original recording or imported file remains the source of truth and is
  never modified.

### 6. TranscriptionService routing

- Add `TranscriptionExecutionSnapshot.local` support for a Local AI model:
  `LocalAITranscriptionExecutionSnapshot { model, language, chunkTimeout }`,
  captured before async work like the Native Whisper snapshot. Import, retry,
  stop, and startup resume use the snapshot, never live settings mid-job.
- `transcribeAudioLocally` gains a Local AI branch that runs the long-form
  engine with the local limit and client.
- The result feeds the existing `TranscriptionResult`:
  - `spokenLanguage` is the chosen language when one is set.
  - With Auto, it comes from `SpokenLanguageResolver` on the text.
  - Post-processing handoff (`processTranscript`, `TranscriptionCompletionSnapshot`)
    is unchanged.
- Errors map to the same `QuillUserIssueError.local` codes Native Whisper uses:
  - missing or corrupt package → `localModelMissing`
  - conversion failure → `audioPreparationFailed`
  - runtime and transport failures → the existing local failure code, with the
    backend label and model ID

### 7. Onboarding

- `SetupFlow.LocalModel` becomes `{appleSpeech, nativeWhisper,
  localAIModel(id:)}`. `ProcessingPreset` gains `localAIModel(id:)`.
- The "On This Mac" step lists a card for each transcription-capable Local AI
  model supported on this Mac. The card is a `LocalAIModelRowView` modeled on
  `NativeWhisperModelRowView` (select, download progress, ready state). An
  unsupported Mac does not show the card, consistent with Local AI lists
  elsewhere.
- While the package downloads, the flow falls back to Apple Speech exactly as the
  Whisper card does. `requiredPermissions` is `[.microphone]`.
- `applySetupProcessingPreset` applies the `localAI` choice.
- The onboarding caption about AI cleanup stays. Choosing Gemma for
  transcription does not turn on post-processing automatically.

### 8. Model reload hint

- Keep every per-feature model choice as the user set it.
- The hint appears in Settings when both of these are true:
  - Transcription uses a Local AI model.
  - Another enabled feature (post-processing, Context, summary) uses a different
    Local AI model.

  Text: "Different on-device models reload for each recording, which is slower.
  Using the same model for all features avoids this." It appears under the
  transcription picker and the affected feature pickers. No automatic change.
- This resolves the open decision from the #365 review.

## Error handling

| Situation | Behavior |
| --- | --- |
| Package missing or corrupt | `localModelMissing`. Audio kept. Retry available after install |
| Server fails to start, or exits during a request | Retry the chunk under the retry policy. When attempts are exhausted, the job waits for retry with completed chunks kept |
| Chunk timeout | The same retry policy, then waiting for retry |
| Truncated output | Split and retry (max two levels). Then failure with completed chunks kept |
| Empty text | Accepted as silence. No retry |
| Malformed response | Not retried. The job fails with completed chunks kept |
| User cancel | Cancel the request. The checkpoint stays. The next retry resumes |
| Relaunch mid-job | Auto-resume when identity matches. Otherwise wait for retry |
| Model changed or deleted mid-job | The snapshot keeps the running job consistent. The next resume sees the identity mismatch and waits for retry |

Two rules hold in every case:

- Nothing falls back to Cloud or to another local model.
- An existing transcript is never replaced by an empty or partial result.

## Out of scope

- Live or realtime transcription with a Local AI model.
- Changing the default transcription choice.
- Qwen3-ASR itself. The #283, #284, and #287 issues stay open on this foundation.
- Automatically aligning other feature models when Gemma is chosen for
  transcription.

## Delivery

The plan may split this into pull requests that each merge on their own:

1. **Model-neutral engine:** chunk limits, the local identity accessor, and
   truncation splitting in the core. No user-visible change. Cloud regression
   tests prove identical plans and resume.
2. **Local ASR and the chooser:**
   - capabilities and the transport
   - the `localAI` choice with Settings, Note Browser, import, and retry
   - the journal case, error mapping, and the reload hint
3. **Onboarding card.**

## Testing

All tests use synthetic audio or text and mocked servers. None call a live model
in CI. New test files are wired into the existing shards exactly once
(`check-test-wiring`).

- **Planner:**
  - Duration limit math, silence search range, and the 60 s hard cap.
  - A tone with no silence cuts at 60 s.
  - Cloud plans and plan IDs are unchanged for existing fixtures (regression).
- **Identity and store:**
  - Existing records and plans decode unchanged as cloud.
  - A local record round-trips and reports `.localAI`.
  - Mismatched backend, model, digest, or language does not resume.
  - A non-WAV import uses an in-memory checkpoint and writes no job file.
- **Transport:** with a stub `URLProtocol` server:
  - request body shape
  - `finish_reason: length` → `truncated`
  - error mapping
  - cancellation
  - no content in log strings
- **Core:**
  - truncation split and depth limit
  - one failed chunk keeps earlier results
  - progress never decreases
  - an empty chunk is skipped
- **Choice and UI state:**
  - The Local AI choice appears only for installed, supported, capable models.
  - Qwen does not appear.
  - Selection round-trips through the keys.
  - A missing model resolves unavailable, not to another model.
  - The fallback order matches Native Whisper.
  - The reload hint condition.
- **Onboarding:** preset mapping, permissions, and the download fallback, all
  matching the Whisper card.
- **Opt-in integration** (like `test-local-ai-integration`): synthetic `say`
  ko/en meetings over 5 minutes through the installed Gemma package. Checks:
  - every chunk is 60 s or less
  - no truncation
  - total output length is proportional to the audio length
- **Manual, in a signed dev build:**
  - record, and import an mp3
  - retranscribe from the Note Browser
  - cancel mid-job and resume
  - quit mid-job and relaunch to auto-resume
  - onboarding with the Gemma card
  - Native Whisper, Apple Speech, and Cloud still work

## Privacy and security

- Audio goes only to the local `llama-server` on 127.0.0.1. There is no new
  network destination.
- Converted imports stay in the existing temporary file and are deleted after
  the run, as with Native Whisper.
- Logs contain no audio, transcript text, or prompts.
- High-risk areas for the PR description:
  - local jobs sharing the cloud job store (same schema, `local-ai:` provider)
  - a new request type sent to the bundled runtime
