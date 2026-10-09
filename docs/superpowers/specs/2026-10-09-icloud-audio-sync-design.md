# iCloud Audio Sync — Design

**Date:** 2026-10-09
**Status:** Draft — awaiting review
**Parent spec:** `2026-10-08-icloud-note-sync-design.md` (delivery item 5)

## Goal

A note recorded on one Mac plays, retranscribes, and exports on every other
Mac with the same iCloud account. Audio uploads in the background after the
note text. Other Macs download it only when the user plays, retranscribes,
or exports it.

## What exists after item 4

- `audioFileName` already syncs in the `.audio` field group. The bytes do
  not, so on another Mac the note looks like a note without audio: the
  audio bar is hidden, Retranscribe is unavailable, and audio export is off.
- `NoteSyncCloudKitEngine` (CKSyncEngine) sends `Note` records in the
  `Notes` zone, with retry, offline handling, and quota pauses.
  `NoteSyncController.turnOn()` creates the zone before the engine starts.
- Recordings are 16 kHz mono 16-bit WAV: about 2 MB a minute, 115 MB an
  hour. Imported files keep their own format and size.
- Every audio reader resolves `audioDirectory + audioFileName` and treats a
  missing file as "no audio".

## Decisions

| Topic | Decision |
|---|---|
| Upload channel | The same CKSyncEngine. Audio parts are records in a second zone, `NoteAudio`, so retry, offline, and quota handling come for free. |
| Parts | 50 MB each (`partSize` is stored, so it can change later). A file under 50 MB is one part. |
| Order | Note text first. Audio parts after. The ready marker last. |
| Ready marker | A new synced field, `audioManifest`, set only after every part is up. Receivers trust it to mean "downloadable". |
| Download | On demand, part by part, verified by SHA-256, then saved under `audio/` with the synced file name. |
| Availability | Derived, not stored. The parent spec's `audioAvailability` attribute is dropped: the file on disk plus the manifest answer the question. |
| Downloading needs sync on | With sync off the app does not talk to iCloud. A note whose audio isn't local says to turn sync on. |

## CloudKit layout

- Zone `NoteAudio`, record type `NoteAudio`, record name
  `<note UUID>-<part index>` (index from 0).
- Fields: `data` (`CKAsset`, one part), `index` (Int), `noteID` (String).
- The engine's fetch scope excludes the `NoteAudio` zone, so other Macs
  never download audio during a normal fetch.
- `audioManifest` on the `Note` record: JSON
  `{"v":1,"sha256":"<hex>","bytes":<Int>,"partSize":<Int>,"parts":<Int>}`.
  It belongs to the `.audio` field group, with `audioFileName`. Keys never
  change once shipped; the iPhone app reads the same shape.

## Local storage

- `PipelineHistoryItem.audioSyncManifest: Data?` and the Core Data
  attribute `audioSyncManifestJSON` (optional, lightweight migration).
- Nothing else is stored. Upload progress lives in the engine's pending
  changes, which the engine already persists.

## Upload (item 5a)

1. A settled note with a local audio file and no manifest needs audio. On
   engine start, after the initial upload, and after each local change, the
   coordinator queues `.saveRecord(<id>-<k>)` for every part `k` that is not
   already pending.
2. `nextRecordZoneChangeBatch` puts `Notes` changes first and sends at most
   one audio part per batch. For a part it builds a `CKRecord` whose asset is
   the file itself (one part) or a part file cut into
   `Sync/outbox/<id>-<k>` (several parts). Part files are removed after the
   batch is sent or fails.
3. When a part is saved and no other part of that note is pending, the
   coordinator hashes the file off the main thread, writes the manifest
   through the store (stamping the `.audio` clock), and the normal hook
   queues the note save. Other Macs see the manifest only after every part
   is in iCloud.
4. Failures reuse the item-4 paths: network waits for the engine, quota
   pauses with the same status, `serverRecordChanged` resends with the
   server's change tag, `zoneNotFound` in `NoteAudio` stops sync as deleted
   elsewhere unless this Mac is deleting.
5. The file is gone before its parts are sent (the note was deleted): the
   part is dropped.
6. The audio of a note that already has a manifest is never uploaded again.
   Audio files don't change after a note settles.

Upload status: `Uploading · 12 of 80 notes` counts notes, as today. The
counter includes notes whose audio is still going up, so it reaches the
total only when the last part is sent.

## Delete and turn off (item 5a)

- Purge (Delete Now, the 30-day purge, or a server delete applied as a
  purge) queues deletes for `<id>-0 … <id>-(parts-1)`, using the manifest,
  or the local file size when there is no manifest yet. `unknownItem` on
  these deletes counts as done.
- Turn Off and Delete from iCloud deletes both zones.
- `turnOn()` creates both zones before starting. A Quill Dev Mac that
  turned sync on before item 5 has no `NoteAudio` zone: a part saved into
  the missing audio zone makes the zone and retries, rather than reading as
  a delete from another Mac (that removes the `Notes` zone).
- Turn-on confirmation: "Upload 12 notes (340 MB of audio) from this Mac to
  iCloud…". The size is the total local audio of the notes that will
  upload.
- Turn-off confirmation adds, when it applies: "3 notes have audio that
  isn't on this Mac yet." (The audio stays in iCloud unless the user also
  deletes from iCloud.)

## Download (item 5b)

`NoteAudioDownloader` (main-actor, one per app):

- `state(for item) -> NoteAudioState`:
  - `.local`: the file exists.
  - `.downloadable`: no file, sync on, manifest present.
  - `.downloading(progress)`.
  - `.unavailable(reason)`: `.notUploadedYet` (no manifest),
    `.syncOff`, `.offline`, `.failed`.
  - `.none`: the note has no `audioFileName`.
- `download(noteID)` fetches parts in order with `CKFetchRecordsOperation`,
  reporting byte progress, appends each part to
  `Sync/downloads/<id>.partial`, checks the size and SHA-256, and moves the
  file to `audio/<audioFileName>`. A hash or size mismatch discards the file
  and tries once more, then reports `.failed`.
- `cancel(noteID)` stops the operation and removes the partial file.
- Downloads keep going when the note view closes, and a second request for
  the same note joins the running one.
- It reaches CloudKit through a small protocol, so tests use a fake.

## Audio bar and actions (item 5b)

- The bar shows whenever the note has `audioFileName` and the state is not
  `.none`.
- Play button by state:
  - `.local`: today's play/pause.
  - `.downloadable`: a download arrow. Tapping downloads, then plays.
  - `.downloading`: a ring filling with progress and a stop mark. Tapping
    cancels.
  - `.unavailable`: dimmed, with the reason in the time label.
- Before the file is local the waveform shows flat bars and the duration
  comes from `recordingEndedAt - recordingStartedAt` (hidden when unknown).
- Retranscribe: availability gains `.needsDownload`. Choosing it downloads,
  then continues with the chosen option.
- Export: the audio checkbox is enabled when the audio is downloadable, and
  export downloads it first. Unavailable audio keeps today's disabled
  checkbox with the reason.

## Messages

| State | Text |
|---|---|
| `.notUploadedYet` | "Audio hasn't reached iCloud yet from the Mac that recorded it." |
| `.syncOff` | "Turn on iCloud sync to download this audio." |
| `.offline` | "Connect to the internet to download this audio." |
| `.failed` | "Couldn't download this audio. Try again." |

All new strings get Korean translations.

## Privacy and risk

- Audio is sent only to the user's private iCloud database, only with sync
  on. This is the data transmission the parent spec approved; the PRs call
  it out as high risk (transmission, storage, Core Data migration).
- Logs give counts, part indexes, and states only, never file names or
  note content.
- Part files and partial downloads live under `Sync/` and are removed after
  use and on turn off.

## Testing

Automated (synthetic bytes, fake engine and fake fetcher):

- Part planning: sizes 0, 1 byte, exactly 50 MB, 50 MB + 1, 120 MB.
- A part file has the right bytes at the right offset.
- Parts are queued once, not again while pending, and never for a note with
  a manifest.
- The manifest is written only after the last part is saved, and the note
  save follows it.
- Purge queues deletes for every part.
- Turn-on creates both zones; the confirmation text has the audio size.
- `audioManifest` round-trips through the payload and merges in the
  `.audio` group.
- Downloader: parts rejoin to the original bytes; a hash mismatch retries
  once then fails; cancel removes the partial file; two requests share one
  download; states for each case.
- Retranscribe and export ask for a download when the audio is remote.

Manual (Quill Dev, two Macs, CloudKit Development):

- Record on Mac A, play it on Mac B (download, ring, playback).
- Retranscribe and export on Mac B a note recorded on Mac A.
- Turn sync off on Mac A mid-upload: Mac B shows "hasn't reached iCloud".
- Delete Now on Mac B removes the audio records (CloudKit dashboard).
- Fill iCloud storage or go offline mid-upload and recover.

## Delivery

- **5a — Upload.** `audioManifest` field and Core Data attribute,
  `NoteAudio` zone, part planning and upload, manifest after the last part,
  purge deletes, both zones on turn on and delete, confirmation sizes and
  counts.
- **5b — Download and UI.** `NoteAudioDownloader`, audio bar states,
  Retranscribe and Export downloading first, messages.

## Out of scope

- Prefetching audio in the background.
- Freeing local audio that is in iCloud.
- Compressing audio before upload (#462).
- Backoff limits for retries (#479).
