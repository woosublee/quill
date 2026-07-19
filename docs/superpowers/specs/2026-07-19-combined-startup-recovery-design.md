# Combined Startup Recovery Design

## Context

Issue #181 requires in-progress audio to survive crashes, force-quits, `SIGKILL`, and power loss. The following foundations are already merged:

- microphone journal and startup recovery in #205
- bounded-memory combined mixdown in #206
- System Audio journal and startup recovery in #207
- durable two-source combined journal in #209
- real combined recording, monotonic source alignment, and normal-stop mixed or degraded finalization in #210

Phase 3B-2B is the final combined-source recovery step. It connects the existing combined journal and `CombinedRecordingArtifactFinalizer` to startup recovery, persists one idempotent local history item, exposes Playback, Retry Transcription, and Delete through the existing Note Browser controls, and verifies real process-death behavior.

This phase remains one PR. It does not introduce a second recovery-only mix path.

## Confirmed recovery behavior

For combined journals discovered during startup:

- If microphone and System Audio are usable, recover one aligned combined WAV.
- If only microphone is usable, recover one microphone-only degraded WAV.
- If only System Audio is usable, recover one System Audio-only degraded WAV.
- If neither source is usable, preserve the inflight journal as a manual recovery candidate.
- Startup recovery never starts transcription, post-processing, or provider upload automatically.
- Recovered audio remains local until the user chooses Playback, Retry Transcription, or Delete.

The Note Browser must identify the surviving source for degraded recovery rather than showing the same copy as a complete combined recovery.

## Architecture

The existing startup sequence remains authoritative:

```text
AppState initialization
→ InflightRecordingRecovery.scan()
→ RecordingJournalRecoveryExecutor.recoverAll()
→ RecordingRecoveryHistory.persist()
→ pipeline history load
→ Note Browser
```

Responsibilities stay separated:

- `InflightRecordingRecovery` determines the next lifecycle action and protects artifacts.
- `RecordingJournalRecoveryExecutor` executes lifecycle transitions and invokes finalizers.
- `CombinedRecordingArtifactFinalizer` remains the only component that evaluates combined source usability, repairs committed WAV boundaries, applies frame offsets, selects combined or degraded output, and promotes the permanent WAV.
- `RecordingRecoveryHistory` creates or reuses one stable history row.
- `PipelineHistoryItem` stores durable recovered-mode status without a Core Data migration.
- `NoteBrowserView` maps that stored status to source-specific copy while reusing existing controls.

## Scanner actions

Add one executable action:

```swift
case finalizeCombined
```

Combined manifests are classified by lifecycle state:

| Manifest state | Scanner action |
| --- | --- |
| `.recording` | `.finalizeCombined`; executor first transitions to `.recoverable` |
| `.stopping` | `.finalizeCombined` |
| `.recoverable` | `.finalizeCombined` |
| `.promoted` | `.persistHistory` |
| `.historyStored` | `.markFinalized` |
| `.finalized` | `.cleanupEligible` |

The scanner validates the manifest shape, recording ID, filenames, permanent artifact state, and basic per-source physical diagnostics. It does not choose complete versus degraded output.

A missing, empty, short, truncated, odd-tail, or manifest-behind source contributes diagnostics but does not by itself force manual recovery. The shared finalizer evaluates both sources independently and may use the surviving source.

The scanner returns `manualRecoveryRequired` when:

- the manifest is missing, corrupt, unsupported, or unsafe
- the directory recording ID and manifest recording ID disagree
- a permanent recording-ID WAV exists but is invalid
- the manifest is `.promoted`, `.historyStored`, or `.finalized` but the permanent WAV is absent
- the combined manifest shape is invalid
- later finalization confirms that neither source is usable

Manual candidates retain `protectedPermanentFileName` so orphan cleanup cannot remove a related recovery artifact.

## Recovery artifact mode

Add a recovery mode shared by executor, history, and UI:

```swift
enum RecoveredRecordingMode: Equatable {
    case complete
    case microphoneOnly
    case systemAudioOnly
}
```

`RecoveredRecordingArtifact` carries this mode alongside the recording ID, permanent audio URL, promotion metadata, and manifest.

`RecordingPromotion` also stores the mode as a new optional Codable field. Old schema-v1 manifests decode a missing value as `nil`, which means `.complete`. Combined finalization writes the explicit mode when it transitions the manifest to `.promoted`. This makes the mode durable across a crash after promotion but before history persistence without requiring source-file reclassification or a schema-version bump.

- Existing microphone-only and System Audio-only journal recovery uses `.complete`; those recordings are complete for their selected input mode.
- Combined finalization maps `.combined` to `.complete`.
- Combined finalization maps degraded output to `.microphoneOnly` or `.systemAudioOnly`.

## Executor flow

For `.finalizeCombined`:

1. Load the current manifest.
2. If state is `.recording`, transition it to `.recoverable`.
3. Call `CombinedRecordingArtifactFinalizer.finalizeAndPromote(recordingID:)`.
4. Return one `RecoveredRecordingArtifact` with the finalizer's mode.

The executor does not inspect or mix source PCM itself.

For combined `.promoted`, `.historyStored`, and `.finalized` candidates, the executor validates the permanent WAV and obtains the combined mode through the shared finalizer's promoted-state classification. It must not use broad `try?`; unexpected source I/O or synchronization failures remain failures and preserve the journal.

## Promotion crash window

A crash may occur after the final WAV is atomically renamed to the recording-ID path but before the manifest reaches `.promoted`.

On the next launch:

- the scanner protects the valid permanent filename
- the executor still runs the shared combined finalizer
- bounded-memory source finalization may reconstruct a temporary candidate
- `RecordingArtifactFinalizer.promote` validates the existing recording-ID WAV and reuses it rather than replacing it
- tests verify the permanent file's inode remains unchanged
- the manifest then advances to `.promoted`

This preserves one permanent WAV without adding a special recovery-only mix implementation.

## History persistence and stable status

No Core Data property is added. Recovered mode is encoded in existing `postProcessingStatus` values.

Intermediate placeholders:

```text
transcription-interrupted
transcription-interrupted:microphone-only
transcription-interrupted:system-audio-only
```

Stable recovered states after startup normalization:

```text
recording-recovered
recording-recovered:microphone-only
recording-recovered:system-audio-only
```

`PipelineHistoryItem` exposes computed helpers that parse these exact values:

- `isIncompleteTranscription`
- `isRecoveredRecording`
- `recoveredRecordingMode`

`markInterruptedBeforeCompletion()` preserves the suffix while converting an intermediate placeholder into its stable recovered state.

`RecordingRecoveryHistory` always uses:

```swift
id: recovered.recordingID
```

When the same ID already exists:

- an incomplete or recovered placeholder is updated idempotently
- a completed transcription history row is never replaced
- lifecycle completion and inflight cleanup may still proceed

## History lifecycle crash windows

The existing manifest lifecycle remains unchanged:

```text
promoted → historyStored → finalized → inflight directory removed
```

Recovery is idempotent across every boundary:

1. **Promotion completed, manifest not updated**
   - validate and reuse the recording-ID WAV
   - transition to `.promoted`

2. **Manifest `.promoted`, history not stored**
   - upsert a placeholder using the recording ID
   - preserve complete or degraded mode in status

3. **History upsert completed, manifest not `.historyStored`**
   - the next launch upserts the same ID rather than inserting another row

4. **Manifest `.historyStored`, not `.finalized`**
   - keep the existing history row
   - transition the manifest only

5. **Manifest `.finalized`, inflight directory still present**
   - remove the inflight directory only

After any repeated launch sequence, there is at most one recording-ID WAV and one history row.

## Note Browser presentation

The existing audio player, retry toolbar action, and delete flow are reused.

### Complete combined recovery

- Title: `Recording interrupted`
- Description: `Recovered after an unexpected shutdown. Not yet transcribed.`

### Microphone-only degraded recovery

- Title: `Microphone audio recovered`
- Description: `System Audio could not be recovered. Microphone audio is available for playback or transcription.`

### System Audio-only degraded recovery

- Title: `System Audio recovered`
- Description: `Microphone audio could not be recovered. System Audio is available for playback or transcription.`

English and Korean localization entries are added for new copy.

The existing controls continue to behave as follows:

- **Playback:** `NoteAudioPlayerView` opens the recording-ID WAV.
- **Retry Transcription:** `AppState.retryTranscription(item:)` uses the current available transcription configuration and the recovered audio file.
- **Delete:** `deleteHistoryEntry(id:)` removes the history row and the referenced permanent WAV.

No new control or automatic action is introduced.

## Failure handling

- One combined source unusable: create a degraded output from the surviving source.
- Both sources unusable: return or retain a manual recovery candidate; delete nothing.
- Mix, promotion, source I/O, or directory synchronization failure: return `.failed`, preserve source journals, permanent artifacts, and the last valid manifest generation.
- Valid existing permanent WAV: validate and reuse it.
- Invalid existing permanent WAV: preserve it and require manual recovery.
- History durable write failure: leave the manifest `.promoted` so the next launch retries.
- Manifest transition failure after history upsert: keep the stable-ID history row and finish the transition on the next launch.
- Existing completed history: never replace its transcript or status.
- Orphan sweeping: protect every permanent filename referenced by an inflight recovery candidate.

## Automated testing

### Scanner tests

- combined `.recording`, `.stopping`, and `.recoverable` produce `.finalizeCombined`
- combined `.promoted`, `.historyStored`, and `.finalized` produce existing lifecycle actions
- missing, empty, short, truncated, odd-tail, and manifest-behind source diagnostics remain visible without blocking a surviving source
- invalid combined shape, invalid permanent WAV, and missing promoted artifact remain manual candidates
- manual candidates preserve source files and protect the recording-ID filename

### Executor and finalizer tests

- complete aligned combined recovery
- microphone-only degraded recovery
- System Audio-only degraded recovery
- neither source usable remains manual
- recording state transitions to recoverable before finalization
- promotion rename crash-window reuses the existing inode
- unexpected source I/O and synchronization errors propagate as `.failed`
- no executor path invokes transcription, post-processing, or provider upload

### History tests

- complete and both degraded modes persist stable status
- stable recording ID produces one row across repeated persists
- placeholder status suffix survives startup normalization
- existing completed history is not replaced
- history write and manifest transition crash windows converge without duplicates
- permanent WAV remains after inflight cleanup

### Note Browser and localization tests

- complete recovery retains existing copy
- microphone-only and System Audio-only recovery show source-specific copy
- recovered items still expose Playback, Retry, and Delete
- new English and Korean localization keys are present

### Process-death integration fixtures

- simulate repeated launches from each manifest lifecycle state
- assert one permanent WAV, one history row, and eventual inflight cleanup
- assert no automatic transcription or upload is started

## Manual Quill Dev validation

1. Select `System Default + System Audio`.
2. Start recording with distinguishable microphone and System Audio content.
3. Send a real `SIGKILL` to the Quill Dev process.
4. Relaunch Quill Dev.
5. Verify one recovered item appears in Note Browser.
6. Play the audio and verify both sources and relative alignment.
7. Relaunch again and verify no duplicate file or history row.
8. Run Retry Transcription and verify the existing recovered item is updated.
9. Delete the item and verify the history row and permanent WAV are removed.
10. Exercise microphone-only and System Audio-only degraded fixtures where practical and verify source-specific copy.

## Representative files

Expected production files:

- `Sources/InflightRecordingRecovery.swift`
- `Sources/RecordingJournalRecoveryExecutor.swift`
- `Sources/CombinedRecordingArtifactFinalizer.swift`
- `Sources/RecordingRecoveryHistory.swift`
- `Sources/PipelineHistoryItem.swift`
- `Sources/NoteListRowDisplayData.swift`
- `Sources/NoteBrowserView.swift`
- `Sources/AppState.swift`
- `Resources/Localization/Localizable.xcstrings`
- `Makefile`

Expected tests:

- `Tests/RecordingJournalRuntimeTests.swift`
- `Tests/RecordingJournalRecoveryExecutorTests.swift`
- `Tests/CombinedRecordingArtifactFinalizerTests.swift`
- `Tests/RecordingRecoveryHistoryTests.swift`
- `Tests/TranscriptionRecoveryPlaceholderTests.swift`
- `Tests/NoteListRowDisplayDataTests.swift`
- `Tests/RecoveredRecordingNoteBrowserSourceTests.swift`
- a focused repeated-launch or process-death integration test

## Explicit exclusions

- input-switch segment persistence and recovery
- watchdog policy changes
- retention or storage-cap policy
- automatic transcription after recovery
- transcription backend selection changes
- new permissions or entitlements
- unrelated Core Data and AVFoundation warning cleanup tracked by #208
- changes to normal-stop combined recording beyond shared-finalizer regressions

## Completion boundary

Phase 3B-2B is complete when a real combined recording survives `SIGKILL`, relaunch produces one aligned complete or source-specific degraded local recovery item, Playback/Retry/Delete work through existing controls, and repeated relaunches produce no duplicate WAV or history row.

After Phase 3B-2B, Issue #181 Phase 3 combined journaling, alignment, normal finalization, and startup recovery are complete. Phase 4 input-switch segment persistence and recovery remains next.
