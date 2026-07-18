# Combined Recording Recovery Design

## Context

Issue #181 requires Quill to preserve in-progress recordings across crashes, force-quits, `SIGKILL`, and power loss. The microphone-only path is complete in #205, bounded-memory mixdown in #206, System Audio-only recovery in #207, and the durable two-source combined journal foundation in #209.

The remaining combined-source work is split into exactly two PRs:

- **Phase 3B-2A:** connect the combined journal to real recording, persist source alignment, and use it for normal-stop mixed or degraded finalization.
- **Phase 3B-2B:** reuse the same finalization path during startup recovery, surface the recovered item in Note Browser, and validate real `SIGKILL` behavior.

This split separates the live recording path from startup recovery without deferring any Issue #181 combined-source requirement. Source alignment is completed across these two PRs and is not a separate follow-up.

## Confirmed behavior

### Source availability

For both normal stop and startup recovery:

- If microphone and System Audio are valid, produce one aligned mixed WAV.
- If only microphone is valid, produce one microphone-only degraded WAV.
- If only System Audio is valid, produce one System Audio-only degraded WAV.
- If neither source is valid, preserve the inflight journal for manual recovery rather than deleting it.

A source that fails to start must not invalidate a source that started successfully. A source that fails during recording must not stop the overall combined session while the other source remains active.

### Alignment

Both child recorders use a shared monotonic recording anchor. Each source records the monotonic time of its first non-empty canonical PCM chunk and converts it into a 16 kHz frame offset. The offset is committed in the existing `firstCommittedFrameOffset` field.

Finalization uses the offsets to prepend silence to the later-starting source before mixing. Shorter tails continue to use silence padding. Wall-clock `Date` values are not used for alignment.

### User control

Startup recovery never automatically transcribes or uploads audio. Recovered recordings remain local until the user chooses Playback, Retry Transcription, or Delete.

## Phase 3B-2A: Live integration and normal stop

### Recorder boundary

Extend the normalized journal sink boundary so a source can report the monotonic time associated with its first canonical PCM buffer without performing filesystem work in the audio callback.

The preferred interface is a timestamp-aware sink method that accepts copied canonical PCM and a monotonic nanosecond timestamp. Existing single-source sinks retain source-local offset `0` through a compatibility wrapper or adapter. The callback remains enqueue-only; timestamp conversion, checkpointing, file synchronization, and manifest replacement remain on journal queues.

`AudioRecorder` and `SystemAudioRecorder` obtain the timestamp from each `CMSampleBuffer` using one common conversion utility. Both recorders must use the same monotonic clock domain. Tests must prove that equivalent sample-buffer timestamps produce comparable frame offsets.

### Combined controller integration

`AppState` creates one `CombinedRecordingJournalController` before `SystemDefaultAndSystemAudioRecorder.startRecording()` is allowed to activate audio.

It attaches:

- `controller.microphoneSink` to `AudioRecorder.normalizedPCM16Sink`
- `controller.systemAudioSink` to `SystemAudioRecorder.normalizedPCM16Sink`

The controller owns the stable recording ID, shared segment ID, shared monotonic anchor, checkpoint timer, and source offsets.

Existing combined start policy remains unchanged:

- start microphone and System Audio independently,
- continue if either starts,
- fail only if both fail.

If one source fails to start, its sink is detached and the other journal source remains valid with no committed frames. If both fail, both recorders are drained or cancelled before the newly created combined journal is discarded.

### Stop and cancellation APIs

Add a source-drain result to `SystemDefaultAndSystemAudioRecorder` so `AppState` can stop both child recorders without invoking the recorder's existing temporary-WAV mix path.

The existing `stopRecording(completion:)` remains available for Setup's audio test and continues to return the current temporary-file mixed/degraded result. `AppState` uses the new source-drain API and then finalizes the durable journal.

Cancellation waits for both child recorder cancellation completions before discarding the combined journal. Runtime failure detaches both sinks, drains both writers, and preserves the journal as recoverable.

Input switching remains outside Phase 3B-2. Switching away from or into combined mode continues through the existing temporary-segment path and does not create segment-aware durable recovery yet.

### Shared combined finalizer

Add a focused combined finalization service reusable by normal stop and Phase 3B-2B startup recovery.

The service:

1. Loads and validates the combined manifest.
2. Evaluates each source independently at its committed boundary.
3. Truncates uncommitted or odd trailing bytes and patches the reserved WAV header for each usable source.
4. Selects complete mix, microphone-only degraded, System Audio-only degraded, or manual recovery.
5. Applies leading silence from `firstCommittedFrameOffset`.
6. Uses `AudioMixdownService` in bounded memory.
7. Creates one temporary canonical WAV and atomically promotes it to the recording-ID-derived permanent URL.
8. Persists the `.promoted` transition only after the permanent WAV is durable.

The finalizer returns metadata describing whether the result is complete combined, microphone-only, or System Audio-only. It does not create history entries or start transcription.

### Offset-aware bounded-memory output

Extend `AudioMixdownService` with offset-aware streaming entry points while preserving existing APIs as zero-offset wrappers.

- Two valid sources: prepend per-source silence and mix using the existing headroom/gain policy.
- One valid source: remove its source offset and stream samples from the original first frame into one canonical WAV without leading silence.
- Never load a complete recording into `Data` or `[Int16]`.
- Preserve fixed-size chunking and output-size overflow checks.

### Normal-stop AppState flow

1. Stop and drain both child recorders.
2. Detach both journal sinks.
3. Close and batch-commit both journal writers.
4. Run the shared combined finalizer on `recordingJournalFinalizationQueue`.
5. Pass the promoted permanent WAV into the existing saved-audio and transcription flow without copying it again.
6. Complete or remove the inflight journal through the existing successful-transcription lifecycle.

If journal finalization fails, preserve the journal as recoverable. The existing child temporary WAVs may be used as a transcription fallback only when they are valid, but fallback processing must not delete the durable journal until a permanent recovery placeholder exists.

## Phase 3B-2B: Startup recovery

Phase 3B-2B replaces the combined manual-preservation action with executable complete or degraded recovery actions.

`RecordingJournalRecoveryExecutor` invokes the same combined finalizer used by normal stop. It reuses an existing recording-ID-derived permanent WAV when a crash occurs between promotion and manifest update.

`RecordingRecoveryHistory` creates or reuses one placeholder with the existing stable recording ID. Complete and degraded recovery mode is retained in recovery metadata and reflected in `debugStatus` and Note Browser copy without adding a Core Data migration.

Repeated launches must produce at most one permanent WAV and one history row. Playback, Retry, and Delete reuse the existing recovered-recording controls.

## Failure handling

- Journal creation failure before recording starts: do not start child recorders.
- One child start failure: detach that sink and continue with the surviving source.
- Both child start failures: cancel both children, then discard only the journal created for that attempt.
- Checkpoint failure: report once outside the lifecycle queue; recording may continue, but the journal remains at its last valid generation.
- One writer drain failure: still attempt to drain and close the other writer; preserve the journal as recoverable.
- Mix or promotion failure: preserve source journals and the last valid manifest generation.
- Existing reused journal initialization failure: never discard the existing journal.
- Neither source recoverable: keep a manual recovery candidate and protect any related permanent filename from orphan cleanup.

## Testing

### Phase 3B-2A automated tests

- timestamp conversion and 16 kHz frame-offset calculation
- single-source compatibility offset remains zero
- microphone and System Audio sinks receive timestamps from the same clock domain
- combined controller records independent first offsets exactly once
- partial child start preserves the surviving journal source
- both-child failure discards only the newly created journal
- stop and cancel wait for both child completions
- offset-aware mix prepends leading silence and preserves trailing silence
- one-source degraded finalization for each source kind
- two-source aligned finalization and existing gain/headroom behavior
- normal-stop promotion and manifest lifecycle idempotency
- journal failure fallback preserves committed audio
- Setup combined audio test behavior remains unchanged
- existing microphone, System Audio, realtime, Native Whisper, and Legacy tests remain green
- source-contract tests keep manifest and synchronization work out of callbacks

### Phase 3B-2A manual validation

- normal combined recording, stop, playback, and transcription
- microphone-only degraded start and stop
- System Audio-only degraded start and stop
- cancel during combined recording
- observable start-delay fixture confirms silence alignment

### Phase 3B-2B automated tests

- complete combined startup recovery
- microphone-only and System Audio-only degraded startup recovery
- missing, empty, short, truncated, odd-tail, and manifest-behind source cases
- promotion crash-window reuse
- history insertion and inflight cleanup crash windows
- repeated-launch idempotency
- degraded Note Browser copy, Playback, Retry, and Delete
- no automatic transcription or provider upload

### Phase 3B-2B manual validation

- real combined recording followed by `SIGKILL`
- relaunch and verify one aligned playable item
- repeat for each degraded-source case
- Retry Transcription and Delete
- repeated relaunch without duplicate files or history rows

## Files and boundaries

Representative files expected to change in Phase 3B-2A:

- `Sources/RecordingPCMJournalWriter.swift`
- `Sources/CombinedRecordingJournalController.swift`
- `Sources/RecordingJournalStore.swift`
- `Sources/AudioRecorder.swift`
- `Sources/SystemAudioRecorder.swift`
- `Sources/SystemDefaultAndSystemAudioRecorder.swift`
- `Sources/AudioMixdownService.swift`
- `Sources/RecordingArtifactFinalizer.swift` or a new focused combined finalizer
- `Sources/AppState.swift`
- corresponding focused and source-contract tests
- `Makefile`

Representative Phase 3B-2B files:

- `Sources/InflightRecordingRecovery.swift`
- `Sources/RecordingJournalRecoveryExecutor.swift`
- shared combined finalizer
- `Sources/RecordingRecoveryHistory.swift`
- `Sources/PipelineHistoryItem.swift`
- `Sources/NoteBrowserView.swift`
- corresponding recovery, history, UI contract, and process-death tests

## Explicit exclusions

- input-switch segment persistence and recovery
- watchdog policy changes
- retention or storage-cap policy
- automatic transcription after recovery
- transcription backend selection changes
- new permissions or entitlements
- unrelated Core Data and AVFoundation warning cleanup tracked by #208

## Completion boundary

Phase 3B-2A is complete when real combined recording uses durable aligned journals and normal stop produces one correct mixed or degraded permanent WAV through the existing transcription pipeline.

Phase 3B-2B is complete when the same aligned finalization path recovers combined recordings after real process death and Note Browser exposes one idempotent local recovery item with Playback, Retry, and Delete.

After both PRs, Issue #181 Phase 3 combined-source journaling, alignment, normal finalization, and startup recovery are complete. Phase 4 input-switch segment recovery remains next.
