# System Audio Input Design

## Goal

Add `System Audio` as an input device option so Quill can record audio playing from the computer and send the resulting audio file through the existing transcription pipeline.

## User-facing behavior

The existing input device picker gains one new first option:

1. `System Audio`
2. Existing microphone options, unchanged

No extra explanatory text is added in this first version.

## Recording flow

The current microphone path stays as-is:

```text
Microphone input
→ temporary audio file
→ save audio file
→ transcribe
→ post-process
→ save note/history
```

The new system audio path should match that shape:

```text
System Audio input
→ temporary audio file
→ save audio file
→ transcribe
→ post-process
→ save note/history
```

The important boundary is the temporary audio file. Once the selected recorder returns that file, the rest of Quill should use the existing flow.

## Scope for the first implementation

### Included

- Add `System Audio` to the top of the existing input device picker.
- Store the selection using the existing input-device setting, with a reserved internal value for system audio.
- Add a system audio recorder that records computer/app audio into a temporary audio file.
- Route stop-recording completion into the same existing file save and transcription path used by microphone recordings.
- Use the existing recording failure handling as much as possible.

### Not included

- Microphone + system audio combined recording.
- Mixing two recordings together.
- Additional Settings explanation text.
- Large changes to note saving, transcription, post-processing, or history.
- Replacing the existing microphone recorder.

## Platform and permission requirements

System audio capture uses ScreenCaptureKit and requires macOS Screen Recording permission. Quill must check this permission before starting `SystemAudioRecorder`.

If permission is missing, Quill should request it through the system prompt. If the user denies permission, Quill should show a clear Screen Recording permission message, keep the selected input unchanged, and use the existing recording failure cleanup path rather than falling back to microphone recording.

The app target remains macOS 13.0+, which is within ScreenCaptureKit's supported range.

## Failure behavior

System audio recording should behave like the existing microphone recording when it fails:

```text
recording start/recording fails
→ existing recording failure handling
→ status/error is shown
→ recording state is cleaned up
```

Do not silently fall back to microphone recording. If the user selected `System Audio`, Quill should not record a different input without making that explicit.

## Realtime behavior

System audio should try to fit the existing realtime path if practical: the system audio recorder can provide the same kind of live audio chunks that the microphone recorder provides today.

If that is not reliable in the first implementation, file-based transcription remains the required path. The final recorded file must still be produced so the existing transcription fallback can run.

## Implementation direction

Introduce the smallest new front-of-pipeline branch:

```text
selected input == System Audio
→ use SystemAudioRecorder

selected input != System Audio
→ use existing AudioRecorder
```

Both branches should return a temporary audio file URL on stop. After that, AppState should reuse the existing save/transcribe/history code.

## Validation

- Existing microphone recording still works with the same input picker choices as before.
- `System Audio` appears at the top of the input device picker.
- Selecting `System Audio` records audio playing from another app into a non-empty audio file.
- The recorded system audio file is transcribed through the existing pipeline.
- If `System Audio` is selected but no audio is playing on the machine, Quill handles the silent or empty recording through the existing recording failure path.
- If system audio recording cannot start or produces no audio, Quill uses the existing recording failure path.
