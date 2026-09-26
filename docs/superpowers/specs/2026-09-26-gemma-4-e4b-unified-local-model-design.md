# Gemma 4 E4B as One Local Model for Every AI Feature — Design

**Date:** 2026-09-26
**Status:** Draft — awaiting review

## Goal

Offer Gemma 4 E4B as a second on-device model alongside Qwen2.5 7B. One download
of the model package makes it selectable in every feature it supports:
post-processing, meeting summary, screen context, and (after validation)
transcription. This follows the model-first settings direction: people choose a
model per feature, and install state is shared by model ID.

## What the user asked for

- Add Gemma as another local model choice (a comparison option next to Qwen).
- Use one model package for transcription, context, summary, and post-processing.
- After a single download, show the model in every applicable settings list.

## Assumptions (to confirm in review)

- Qwen2.5 7B stays the default recommended local model. Gemma 4 E4B is an
  additional choice, not a replacement.
- The same 16 GB minimum memory as Qwen applies, so the two can be compared on
  equal hardware. This can be lowered later with measurements.
- No silent Local-to-Cloud fallback, matching existing Local AI rules.

## Current state

- `LocalAIModelCatalog.all` contains only `qwen2.5-7b-instruct` (GGUF, Q4_K_M,
  two shards, 16 GB minimum RAM) with `features: [.postProcessing, .meetingSummary]`.
- Feature settings lists are already built from model capabilities
  (`isAIProcessingChoiceCompatible`). Install and download state is shared per
  model ID through `LocalAIModelWorkflow`.
- `LocalAIRuntime.visionChat(projectorArtifactFileName:)` already launches
  `llama-server --mmproj`. `AppContextService` already sends screenshots as
  `image_url` to local or cloud backends.
- Transcription uses a separate chooser (Native Whisper, Apple Speech, cloud).
- The bundled llama.cpp is pinned to `b4406` (January 2025). It predates Gemma 3
  and Gemma 4 support, so no Gemma model can run on it.

## Model facts

- `unsloth/gemma-4-E4B-it-GGUF` (base `google/gemma-4-E4B-it`), Apache 2.0, not
  gated.
- `gemma-4-E4B-it-Q4_K_M.gguf`: 4,977,171,584 bytes, SHA-256
  `85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87`.
- Multimodal projector: `mmproj-BF16.gguf` (991,552,320 bytes, SHA-256
  `ee01cba03fd9c71ea2ea722225d24a84f72e7197714367e550ef705ef8851bc6`). BF16 is
  recommended; F16 and Q8_0 are reported to cause repetition. The same projector
  serves image and audio input.
- Gemma 4 has a thinking mode. Quill disables it with
  `--chat-template-kwargs '{"enable_thinking":false}'`, so reasoning text never
  reaches transcripts or summaries.
- The model supports up to 128K context. Quill keeps its existing 16,384-token
  local context window.

Artifact metadata above was read from the Hugging Face API on 2026-09-26 and is
re-verified by downloading during implementation.

## Stages

Each stage merges on its own.

### Stage 1 — Upgrade the bundled llama.cpp runtime

- Pin `LLAMA_CPP_VERSION` to a recent `b####` release that supports Gemma 4
  text, vision, and audio (mtmd). Record the exact tag in the Makefile and PR.
- Keep the build contract: static libraries, Metal embedded, universal
  `arm64` + `x86_64`, same helper verification (`verify-llama-server.sh`), same
  bundled path and signing.
- Adjust CMake options only where upstream renamed or changed defaults, for
  example making sure the helper does not require libcurl or other new dynamic
  libraries. The verify script must keep rejecting dynamic llama/ggml linkage.
- Qwen2.5 7B must keep working unchanged: server start, readiness probe,
  post-processing, and meeting summary.
- Out of scope: any Gemma catalog entry or UI change.

**Verification:** `make check`; `make llama-server-helper-test`; a universal
build; `make test-local-ai-integration` with the installed Qwen model; and a
manual post-processing and summary run in a signed dev build.

### Stage 2 — Add Gemma 4 E4B for post-processing, summary, and screen context

- Add a `LocalAIModelCatalog` entry `gemma-4-e4b-it`:
  - Artifacts: the Q4_K_M model file and `mmproj-BF16.gguf`, with the sizes and
    checksums above. Both download and verify through the existing installer.
  - Runtime: `.visionChat(projectorArtifactFileName: "mmproj-BF16.gguf")`.
  - Capabilities: `features: [.postProcessing, .meetingSummary, .contextCapture]`,
    `modalities: [.text, .image]`, recommended context 16,384.
  - Memory: 16 GB minimum. Resident RAM estimate set from a measured run.
- Allow a model to declare extra `llama-server` launch arguments. Gemma uses
  this to disable thinking. Qwen passes none.
- Settings: through the existing capability filter, Gemma appears in the
  post-processing, summary, and screen-context lists. Downloading from any list
  installs the shared package. Qwen stays recommended.
- Localized display name and description (en, ko).
- Out of scope: transcription.

**Verification:** unit tests for the catalog entry (artifacts, checksums,
runtime, capabilities, feature lists), launch arguments per model, and
settings choices per feature. Checks use synthetic data and no live downloads
in CI. Manual checks in a signed dev build: download once and see Gemma in all
three lists; run post-processing (ko/en), a meeting summary, and a screen
context capture. The screen-context check needs Screen Recording permission, so
it is done by the user.

### Stage 3 — Validate speech recognition (spike, no product code)

Answer, with a recorded result, whether Gemma 4 E4B transcription through the
bundled `llama-server` is good enough to ship:

- Endpoint shape for audio input (`input_audio` routing) on the pinned runtime.
- Maximum audio length per request and chunking needs.
- Korean and English accuracy against Native Whisper on synthetic recordings
  (text generated for the test, spoken by macOS `say` or other synthetic
  audio; no real user audio).
- Speed, memory, and cancellation on a 16 GB Apple Silicon Mac.
- Output: a go or no-go recommendation. If go, retarget or supersede the
  Qwen3-ASR issues (#283–#286) with Gemma 4.

### Stage 4 — Offer Gemma 4 E4B in the transcription chooser (if Stage 3 passes)

- An ASR transport separate from text-processing requests (the #285 scope):
  typed errors, cancellation, and no silent Cloud fallback.
- Long recordings are split into chunks with checkpoints, monotonic progress,
  retry, and relaunch recovery. Durable local audio stays the source of truth
  (the #286 scope).
- The transcription chooser lists installed local AI models that support speech
  recognition, next to Native Whisper, Apple Speech, and cloud. It reuses the
  already downloaded package; no second download.
- Its own spec and plan once Stage 3 results exist.

## Risks

- **Runtime upgrade regression.** Fifteen months of llama.cpp changes may alter
  server flags, the chat template, or build options. Mitigation: Stage 1 ships
  alone, with Qwen integration and manual checks before Gemma work starts.
- **Local screenshot speed.** Screen context on a local 4B model may be slower
  than cloud. Measured in Stage 2; the default screen-context model does not
  change.
- **Audio path maturity.** Server-side audio input may be incomplete on the
  pinned tag. Stage 3 decides; Stage 2 does not depend on it.
- **Download size.** About 6.0 GB total (5.0 GB model + 1.0 GB projector).

## Privacy and security

- Everything runs on device; no new network destinations other than the
  Hugging Face artifact downloads, which are checksum-verified like Qwen.
- Tests use synthetic text, images, and audio only.
- No new logging of user content.
- The runtime upgrade changes a bundled signed helper. The PR calls this out and
  keeps the same signing and verification path.
