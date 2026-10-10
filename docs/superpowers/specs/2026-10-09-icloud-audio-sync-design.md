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
  `<note UUID>-<key>-<part index>` (index from 0), where `key` is the first
  16 lowercase hex digits of the file's SHA-256. A part is named after the
  bytes it holds, so parts never change: a new audio file gets new names,
  and a part saved twice is the same part. This holds only while the part
  size stays 50 MB; changing it needs a new name shape (for example the
  part size in the name), or old and new parts would share names.
- A manifest whose `sha256` isn't 64 lowercase hex digits, or whose
  `parts` isn't what `bytes` and `partSize` make (1 to 10,000), can't name
  parts and is read as no manifest. A record name is a part only when it
  is exactly the name the part would write.
- Fields: `data` (`CKAsset`, one part), `index` (Int), `noteID` (String).
- The engine's fetch scope excludes the `NoteAudio` zone, so other Macs
  never download audio during a normal fetch.
- `audioManifest` on the `Note` record: JSON
  `{"v":1,"sha256":"<hex>","bytes":<Int>,"partSize":<Int>,"parts":<Int>}`.
  It belongs to the `.audio` field group, with `audioFileName`. Its
  `sha256` names the parts, so a reader finds every part from it. Keys never
  change once shipped; the iPhone app reads the same shape.

## Local storage

- The Core Data attribute `audioSyncManifestJSON` (optional, lightweight
  migration) holds the manifest.
- `audioSyncUploadKey` (optional, this Mac only, never synced) holds the
  SHA-256 of the file this Mac is uploading. It is read once, before the
  first part goes up, and cleared when the note's audio file changes.
- Upload progress lives in the engine's pending changes, which the engine
  already persists.

## Upload (item 5a)

1. A settled note with a local audio file and no manifest needs audio. When
   a note changes, the coordinator reads the file's SHA-256 off the main
   thread (once; it is kept as the upload key), then checks iCloud (step 3).
2. `nextRecordZoneChangeBatch` puts `Notes` changes first, then audio
   deletes, and sends at most one audio part per batch. For a part it builds
   a `CKRecord` whose asset is the file itself (one part) or a part file cut
   into `Sync/outbox/<record name>.part` (several parts). Part files are
   removed after the batch is sent or fails. A stale part (the audio is
   gone, already marked, shorter, or named for another file) is dropped and
   the next one tried.
3. **Check before marking.** When no part of a note is waiting or waiting for
   a retry, the coordinator looks up every part `0..<parts` of its key in
   iCloud, asking for one small field (never the audio). Missing parts are
   queued. When every part is there, the coordinator writes the manifest
   with the upload key as its `sha256` (stamping the `.audio` clock) and
   queues the note save. Other Macs see the manifest only after a lookup
   confirmed every part. A note that changes during a check is checked
   again after the next sync.
4. The same check runs:
   - at turn-on, for every note, including marked audio this Mac doesn't
     have (its parts are named by the manifest). A marker iCloud can't back
     is cleared (stamped) and the note sent again; when the marked file is
     here, its missing parts go up under the marker's name. Marked notes go
     up only after their check, so a marker from another account never
     reaches this one.
   - at launch, for unmarked audio with nothing waiting. Audio whose last
     part went up just before quitting is marked without reading or sending
     it again.
   - when a fetched note arrives without a marker for audio this Mac has
     (another Mac cleared it).
   A lookup that fails is retried after the next sync.
5. Failures reuse the item-4 paths: network waits for the engine, quota
   pauses with the same status. A part that fails (any reason, quota
   included, or a part file that can't be cut) is retried after the next
   sync, at most twice, then waits for the next launch or an edit to the
   note. `serverRecordChanged` on a part means iCloud already has it, so it
   counts as saved. A part saved into a missing `NoteAudio` zone makes the
   zone and retries, but only when the `Notes` zone still exists; otherwise
   sync stops as deleted elsewhere. A zone the user deleted in System
   Settings counts as missing.
6. A part saved after its note was deleted is deleted.

Upload status: `Uploading · 12 of 80 notes` counts notes, as today. The
counter includes notes whose audio is still going up, so it reaches the
total only when the note's marker is written.

## Delete and turn off (item 5a)

- Purge (Delete Now, the 30-day purge, or a server delete applied as a
  purge) cancels waiting parts and deletes the parts the manifest names.
  When no manifest names them all (no manifest, an upload in progress, or
  another Mac stopped mid-upload), the coordinator lists the `NoteAudio`
  zone's record names and deletes that note's parts, unless the note has
  come back by then (another Mac edited it). `unknownItem` or a missing
  zone on these deletes counts as done.
- A note whose audio file changes: the store reports the earlier audio
  before the note's save. Its marked parts are deleted, and when no marker
  names them, the zone listing deletes the parts this Mac sent (its upload
  key and parts it had waiting) that neither the current marker nor the
  current upload key names. The note is still in use, so another Mac's
  upload for it is left alone; nothing sent from here means no listing.
- Turn Off and Delete from iCloud deletes the `Notes` zone first. Only when
  it is gone is the `NoteAudio` zone deleted (two tries), so notes never
  point at audio that is gone. If the audio zone stays, sync still turns off
  (#485). Markers are cleared and stamped.
- A delete from another Mac clears markers (stamped), so a Mac holding one
  can't merge it back. An account change keeps them: signing back into the
  same account finds the audio there, and the next turn-on checks them.
- `turnOn()` creates both zones before starting. A Quill Dev Mac that turned
  sync on before item 5 has no `NoteAudio` zone; the first part saved makes
  it (step 5).
- Turn-on confirmation: "Upload 12 notes (340 MB of audio) from this Mac to
  iCloud…". The size is the local audio of notes without a marker.
- Turn-off confirmation adds, when it applies: "3 notes have audio in iCloud
  that isn't on this Mac. After Turn Off and Delete from iCloud, this Mac
  can't get it."

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
- Each download has its own token and partial file
  (`Sync/downloads/<id>-<token>.partial`), so a request right after Stop
  starts a fresh download. Progress only moves forward.
- `cancel(noteID)` stops the operation and removes the partial file.
  Turning sync off, or sync stopping by itself, cancels every download, and
  the engine removes download files when it starts and stops. Deleting a
  note (here or from another Mac) cancels its download; a download that
  finishes after the delete removes the file.
- With sync off, a note without a marker shows no audio bar (a file lost
  on a Mac that never synced it looks as before); audio this Mac was
  uploading but has lost shows no bar either.
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
- Backoff for retries (#479). Audio parts already stop after three tries.
