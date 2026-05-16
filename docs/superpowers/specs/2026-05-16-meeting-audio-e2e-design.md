# Meeting Audio End-to-End Design

## Goal

Add a user-facing `Meeting Audio` input that records the system default microphone and system audio together, mixes them into one final WAV after recording stops, and sends that final file through the existing transcription/history pipeline.

## Architecture

Keep existing single-source paths intact:

- Microphone inputs continue to use `AudioRecorder`.
- `System Audio` continues to use `SystemAudioRecorder`.
- `Meeting Audio` adds a thin coordinator that reuses those same recorders and returns one final audio URL to `AppState`.

```text
selectedMicrophoneID
  ├─ normal mic ID / default → AudioRecorder → final URL
  ├─ __system_audio__       → SystemAudioRecorder → final URL
  └─ __meeting_audio__      → MeetingAudioRecorder
                               ├─ AudioRecorder → mic.wav
                               ├─ SystemAudioRecorder → system.wav
                               └─ AudioMixdownService → mixed.wav/fallback URL
```

`AppState` keeps its existing responsibility: route the selected input, start/stop/cancel the active recorder, then pass one URL to `saveAudioFile(from:)` and the existing transcription pipeline.

## Input selection

Add `AudioInputDevice.meetingAudioID = "__meeting_audio__"` and expose it as `Meeting Audio` wherever `System Audio` is currently selectable.

Meaning:

- `System Default` and physical devices: microphone-only.
- `System Audio`: computer audio only.
- `Meeting Audio`: system default microphone plus computer audio.

For this PR, `Meeting Audio` always uses `AudioInputDevice.defaultMicrophoneID` for the microphone side. Choosing a separate microphone inside Meeting Audio is out of scope.

## Recorder coordination

Add `MeetingAudioRecorder` with the same external shape used by the current routing helpers:

- `@Published var audioLevel: Float`
- `var onRecordingReady: (() -> Void)?`
- `var onRecordingFailure: ((Error) -> Void)?`
- `func startRecording() async throws`
- `func stopRecording(completion: @escaping (URL?) -> Void)`
- `func cancelRecording()`
- `func cleanup()`

It receives the existing `AudioRecorder` and `SystemAudioRecorder` instances. It does not create duplicate recorder paths.

Start policy:

- Try to start microphone and system audio as close together as possible.
- If both fail, throw a start error.
- If one succeeds, continue with that source and report ready when it receives audio.

Ready policy:

- The first child recorder to receive real audio fires `MeetingAudioRecorder.onRecordingReady()`.
- Do not wait for both sources; this prevents the overlay from being stuck when one source is silent or failed.

Audio level policy:

- Publish `max(micLevel, systemLevel)`.

Stop policy:

- Stop both child recorders.
- If both URLs exist, mix them.
- If mixdown fails, fall back to one source instead of dropping the recording.
- If only one URL exists, return that URL.
- If neither URL exists, return `nil` and let the existing “No audio recorded” path run.

## Mixdown

Add `AudioMixdownService` as a standalone service that treats recorder outputs as opaque audio files.

Initial implementation:

- Target format: 16 kHz mono signed Int16 PCM WAV.
- Read both input files.
- Convert to target format if needed.
- Align at frame zero.
- Output length is `max(micFrames, systemFrames)`.
- Missing samples from the shorter source are silence.
- Mix with averaging to avoid clipping:

```text
mixed = (activeInputSamplesSum / activeInputCount)
```

This is intentionally simple. More advanced gain control and realtime alignment are follow-up work.

## Permission and fallback

`Meeting Audio` needs both microphone access and Screen/System Audio Recording access for the full experience. However, the recording should preserve usable audio when one source is unavailable.

- Both permissions available: full Meeting Audio.
- Only microphone available: record microphone and continue.
- Only system audio available: record system audio and continue.
- Neither available: fail to start.

First-time permission prompts should reuse the existing microphone and system audio permission paths as much as possible.

## Live/realtime transcription

Meeting Audio realtime mixing is out of scope for this PR.

- Microphone: existing realtime/live behavior remains.
- System Audio: existing single-source behavior remains.
- Meeting Audio: skip realtime/live streaming and transcribe the final file after stop.

A follow-up PR can add a realtime mixer that aligns two PCM streams before sending a single stream to the realtime transcription service.

## File retention

Only the final file should survive the normal flow.

- Mixdown success: keep `mixed.wav`, delete `mic.wav` and `system.wav`.
- Fallback: keep the fallback file, delete unused source files.
- Existing `AppState.saveAudioFile(from:)` then moves the final file into history storage.

## Minimal-change boundaries

Avoid broad refactors.

- Do not rename `selectedMicrophoneID` in this PR.
- Do not split `AppState` beyond the small routing additions.
- Do not rewrite `AudioRecorder` or `SystemAudioRecorder` internals.
- Add focused tests around sentinel selection, routing shape, mixdown behavior, and coordinator source retention/fallback.

## Validation

Automated validation:

- `make test`
- New `AudioMixdownServiceTests` for output shape and fallback-independent mix behavior.
- Source-shape tests that ensure Meeting Audio uses the coordinator and does not replace existing mic/system paths.

Manual validation:

- Build with `make run`.
- Select `Meeting Audio`.
- Play system audio and speak into the microphone.
- Stop recording and confirm the final transcript contains both sources.
- Confirm microphone-only and System Audio-only inputs still work.
