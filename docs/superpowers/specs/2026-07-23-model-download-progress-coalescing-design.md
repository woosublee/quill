# Model Download Progress Coalescing Design

## Problem

Local AI and Native Whisper installers report progress for every `URLSessionDataDelegate` data chunk. `AppState` forwards each callback with `DispatchQueue.main.async` and updates an `@Published` property. A multi-gigabyte model can therefore enqueue far more Main Queue work than SwiftUI can render, delaying scrolling, button actions, and other Settings interactions until the page appears frozen.

The download, file writes, package replacement, and Local AI checksum verification already run away from the MainActor. The problem is the unbounded publication rate at the UI boundary, not the transfer itself.

## Scope

Apply one shared progress-publication policy to:

- Native Whisper model downloads
- Local AI model downloads used by Post-processing and Context

Do not change:

- installer networking or file I/O
- Local AI artifact aggregation and transactional replacement
- Local AI background status/checksum verification
- model selection, cancellation, deletion, or termination semantics
- Settings layout or copy

## Architecture

Add a generic `LatestValueProgressCoalescer<Value>` with an injectable scheduler.

The production scheduler uses a 100 ms interval, limiting intermediate UI progress publication to approximately 10 updates per second per active download.

The coalescer behavior is:

1. Deliver the first submitted value immediately through the scheduler.
2. While a delivery is pending or the interval has not elapsed, replace the stored pending value with the newest submission.
3. At the next allowed delivery, emit only the newest pending value.
4. Continue scheduling only while a pending value exists.
5. `invalidate()` discards pending values and prevents already-scheduled work from delivering.

The coalescer owns thread-safe pending state because installer callbacks arrive from URLSession or utility queues. The delivery closure is scheduled onto the Main Queue and performs the existing `@Published` update.

## AppState Integration

### Native Whisper

`AppState` stores one optional Native Whisper coalescer for the active install.

- Create it before starting the installer.
- The installer progress callback submits values to the coalescer instead of dispatching every callback directly to Main Queue.
- The delivery closure updates `nativeWhisperInstallProgress` on the MainActor.
- Cancellation invalidates the coalescer before publishing `isCancelled = true` immediately.
- Completion invalidates and clears it before applying success, failure, install status, or auto-selection.
- A new install always receives a new coalescer, so stale scheduled work cannot affect a restart.

### Local AI

`AppState` stores coalescers keyed by Local AI model ID, matching its existing model-keyed task and token dictionaries.

- Create a model-specific coalescer when an install starts.
- The delivery closure retains the existing token, cancellation, and deletion guards before updating `localAIInstallStates[model.id]`.
- Cancellation invalidates that model's coalescer before publishing canceled progress immediately.
- Completion invalidates and removes the model's coalescer before `finishLocalAIInstall` publishes status and issue state.
- Different Local AI models retain independent progress cadence.
- Termination cleanup invalidates all active coalescers when installer cancellation begins.

## Final-State Priority

Intermediate progress is best-effort UI information. Cancellation, completion, failure, deletion, and verified install status are authoritative.

Therefore:

- Pending intermediate progress is discarded on cancellation or completion.
- The system does not force one last pending progress publication before applying the final state.
- Final states bypass coalescing and publish immediately.
- Existing install tokens remain the primary protection against callbacks from an older install generation; coalescer invalidation adds protection against already-scheduled UI work.

## Testing

Use an injectable scheduler rather than real sleeps.

### Coalescer unit contract

Verify that:

- the first submission is scheduled immediately
- a burst of submissions creates bounded scheduled work
- only the newest pending value is delivered at the next cadence
- no delivery occurs after invalidation
- a fresh coalescer starts independently after invalidation

### AppState contract

Using the existing Native Whisper and Local AI install harnesses, verify that:

- high-frequency progress callbacks do not produce one MainActor publication per callback
- Local AI models use independent coalescers
- cancellation state is visible immediately and cannot be overwritten by a pending progress update
- completion state is not overwritten by a pending progress update
- Local AI status providers remain off the main thread
- current cancellation, restart, deletion, and termination tests continue to pass

### Validation commands

- `make check-test-wiring`
- `make test-transcription`
- `make test`
- `git diff --check`

GUI automation and app launch are intentionally excluded; manual UI verification remains with the user.
