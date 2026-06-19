# Model selection UX design

Interactive mockup: [`2026-06-19-model-selection-ux-mockup.html`](./2026-06-19-model-selection-ux-mockup.html) (open in a browser — click the per-feature dropdowns and the bulk shortcuts).

Part of Epic #145 (Local-first AI pipeline). This design covers the **settings UX and data model** for how users choose models, so that local back-ends added in Phases 2–3 land on a coherent foundation.

## Goal

Unify how the user picks models for the three LLM/ASR-backed features — **transcription, post-processing, context inference** — into one consistent control, where choosing a model implies whether it runs via a cloud API or locally. Make it approachable for non-technical users without losing power-user control.

## Background: the current state and its problem

Today the three choices are inconsistent (see `AppState.swift`, `SettingsView.swift`):

- **Transcription** has a real model concept: a `Local`/`API Provider` segmented toggle (`useLocalTranscription`), a downloadable `TranscriptionModel` catalog for local, and a separate `transcriptionModel` string for API.
- **Post-processing** (`postProcessingModel`, `postProcessingFallbackModel`) and **context** (`contextModel`) are plain free-text model strings, **API-only**, chosen via `ModelDropdownView` over `ModelConfiguration.llmModels`.

Two problems:
1. **Inconsistent UX** across the three features.
2. A naive fix — a single global "Cloud / Local" mode — **assumes every feature has a symmetric back-end on both sides**, which is false. Context needs vision (screenshot analysis); a local vision model is weak/absent, so local context is text-only at best. A global "Local" mode would lie or silently downgrade.

Model selection is really an **asymmetric graph** of *feature × available back-ends*. The source of truth must therefore be **per-feature**.

## Decision

**Per-feature selection is the source of truth (option C).** A global Cloud/Local mode is NOT a binding mode; it survives only as a **non-binding bulk action** layered on top.

Three layers (all in one settings screen, progressive disclosure — no separate "advanced" screen):

1. **Source of truth — per-feature unified dropdown.** Each feature shows **only the models it actually supports**, cloud and local mixed in one list, each tagged with a back-end badge. Picking a model implies its back-end. This is exactly the original intent: *choose the model; API-vs-local is just an attribute.*
2. **Convenience — bulk shortcuts.** Buttons like *"All cloud"* / *"As local as possible"* apply in one click. Asymmetric features opt out automatically (e.g. "As local as possible" keeps **context on cloud** because it needs screen analysis), with an inline note. Not a mode — just a one-shot apply; per-feature selection remains editable afterward.
3. **Advanced — base URL / API key**, collapsed by default.

## Data model

### Back-end and choice

```swift
enum ModelBackend: Equatable, Codable {
    case cloud   // remote OpenAI-compatible API (Groq, etc.)
    case local   // on-device: native ASR, or a local OpenAI-compatible LLM server
}

struct ModelChoice: Equatable, Codable {
    var modelID: String        // catalog id or free-text (advanced)
    var backend: ModelBackend
}
```

Per-feature persisted choices (replacing the scattered booleans/strings):

```swift
@Published var transcriptionChoice: ModelChoice
@Published var postProcessingChoice: ModelChoice
@Published var postProcessingFallbackChoice: ModelChoice
@Published var contextChoice: ModelChoice
```

`ModelChoice.backend` decides routing at the call site:
- `.cloud` → existing path (`apiBaseURL` + key) in `TranscriptionService` / `PostProcessingService` / `AppContextService`.
- `.local` → for LLM features, a `localhost` OpenAI-compatible base URL (Ollama/LM Studio in Phase 2; bundled `llama-server` in Phase 3) reusing the same `LLMAPITransport`. For transcription, the existing native path (`mlx_whisper` / Apple Speech; native whisper.cpp in Phase 1).

### Feature enablement (required vs optional)

The user decides *whether* to use a feature before *which model* — matching their mental order ("turn this on? → with what?").

- **Transcription is required** — always shown, always has a model.
- **Post-processing and context are optional** — each has an on/off toggle, and the model picker only appears when on.

```swift
@Published var postProcessingEnabled: Bool
@Published var contextEnabled: Bool
```

Disabling a feature skips its pipeline stage entirely (post-processing off → raw transcript; context off → the existing non-LLM behavior). Bulk shortcuts and readiness checks apply **only to enabled features**.

### Backend readiness (the precondition to actually run)

Choosing a model does not mean it can run yet. Each backend has a **symmetric precondition**, and the UI handles both the same way:

| Backend | Precondition | Inline readiness card (same spot) | Dropdown marker |
|---|---|---|---|
| `.cloud` | **API key** (Groq key in Keychain; existing `apiKey` / `validateAPIKey`) | "Cloud models need an API key — [Enter key]" | 🔒 needs key |
| `.local` | **model installed** (download/pull; built-ins like Apple Speech are always ready) | "Not downloaded yet · ~N GB — [Download]" | ↓ download |

Flow: pick a model → check `isReady(choice)` → if not ready, surface the readiness card in the row and let the user satisfy it in place. Issue #70 already permits local-only setup without a Groq key; this generalizes it to a per-choice readiness check.

**Friction-free default for keyless users:** transcription defaults to **Apple Speech** (built-in: no key, no download), so a brand-new user with no API key has a working pipeline immediately and can opt into cloud (enter key) or other local models (download) per feature.

### Feature model catalog (with capability metadata)

The dropdown contents come from a per-feature catalog that encodes **what each model supports**, so asymmetry is data, not special-casing:

```swift
struct CatalogModel {
    let id: String
    let displayName: String
    let backend: ModelBackend
    let note: String?            // e.g. "Built-in", "text only · no screen analysis"
    let requiresVision: Bool     // context: true; others: false
    let installable: Bool        // local models that need a download / pull
}

// feature -> [CatalogModel]; each feature exposes ONLY the back-ends it supports
```

Capability flags (e.g. `requiresVision`) let the UI mark a local context model as "text-only" and let bulk actions skip features that have no viable local option.

### Storage keys + migration

New keys (one `ModelChoice` per feature). Migrate from the legacy layout:
- `useLocalTranscription` + `transcriptionModel` (API) + `localTranscriptionModel` (local) → `transcriptionChoice` (existing `migrateModelStorageKeys()` in `AppState.swift` is the precedent to extend).
- `postProcessingModel` / `postProcessingFallbackModel` / `contextModel` (currently API-only strings) → `.cloud` `ModelChoice`s, preserving the model id.

Migration must be lossless and one-time (mirror the existing `*MigrationKey` guard pattern).

## UI structure

(See the mockup for the live layout.)

- **Per-feature row header**: required features show a "Required" tag; optional features show an on/off toggle (label "Off" + collapsed picker when disabled). The model picker only renders when the feature is on.
- **Per-feature row**: feature label + sub-label, and a model picker button showing `<model name> <backend badge>`.
- **Picker dropdown**: grouped `☁️ Cloud` / `🟢 On your Mac (local)` sections, listing only supported models, each with a badge; selecting one sets `ModelChoice`.
- **Bulk shortcuts** (top of card): *All cloud* / *As local as possible*. The latter keeps vision-dependent features (context) on cloud and notes why.
- **Inline hints**:
  - local LLM selected → BYO note ("needs a local server like Ollama; bundled in Phase 3").
  - local context selected → warning ("text only — no screen analysis; use cloud if you need screen understanding").
  - local model not yet installed → install / download affordance (reuse `ModelRowView` download flow from `TranscriptionModel`, generalized to "pull" for LLM models).
  - cloud model chosen without an API key → key-entry card in the same spot as the download card (the readiness symmetry above).
- **Advanced (collapsed)**: cloud base URL, local server URL, API key (today's `ProviderSettingsFields`).

## Phase evolution

- **Now → Phase 2 (#64):** split post-processing/context endpoints from the shared transcription `apiBaseURL`; allow pointing them at an external OpenAI-compatible local server (Ollama/LM Studio). Local context is text-only. "As local as possible" still surfaces a BYO setup note.
- **Phase 3 (#119):** bundle `llama-server` so local needs no external setup; models download like Whisper. Only then can the "As local as possible" bulk action be promoted into a friendly value-preset ("Private / on-device") for general users — because it finally becomes true one-click.

## Edge cases

- **No local option for a feature** → that feature's dropdown shows cloud only; bulk "local" leaves it on cloud.
- **Local model selected but not installed** → show install affordance; block use (or fall back) until installed, consistent with current transcription behavior.
- **Cloud selected but no API key** → not-ready; show the inline key-entry card and mark cloud models 🔒 in the dropdown. Bulk "All cloud" with no key applies the choice but surfaces the key card rather than silently failing.
- **Optional feature disabled** → its pipeline stage is skipped; bulk actions and readiness checks ignore it.
- **Fallback model** (post-processing) is itself a `ModelChoice`; it may differ in back-end from the primary.
- **Context vision**: `requiresVision` models are cloud-only for now; local context is explicitly text-only with a non-LLM fallback already present in `AppContextService`.

## Files to touch (implementation pointers)

- `Sources/AppState.swift` — replace scattered keys with per-feature `ModelChoice`; extend `migrateModelStorageKeys()`.
- `Sources/TranscriptionModel.swift` — generalize the catalog + install/download into the shared `CatalogModel` shape (LLM "pull" alongside Whisper download).
- `Sources/SettingsView.swift` (`ModelsSettingsView`, `ProviderSettingsFields`, `ModelRowView`) and `Sources/ModelDropdownView.swift` — the unified per-feature picker, badges, bulk shortcuts, hints.
- `Sources/PostProcessingService.swift`, `Sources/AppContextService.swift`, `Sources/TranscriptionService.swift` — route by `ModelChoice.backend` (cloud vs `localhost` OpenAI-compatible / native).
- Tests: extend `AppStateTranscriptionConfigurationTests` and add coverage for migration + bulk-action asymmetry.

## Open questions

- Default model ids per feature for cloud and local (pick per quality/licensing test — see epic notes on Gemma vs Qwen).
- Whether the fallback model is exposed in the main UI or stays advanced-only.
- Exact install UX for local LLMs in Phase 2 (Ollama detection / guided setup) vs Phase 3 (bundled download).
